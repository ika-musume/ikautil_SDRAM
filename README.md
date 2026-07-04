# ikautil_SDRAM

A multi-port SDRAM controller for the MiSTer 128MB SDRAM module (2x AS4C32M16SB-7),
written in SystemVerilog. It lets several independent read/write ports (up to 12
"slots") share one physical SDRAM bus, each with its own fixed address window.

## Layout

```
src/       ikautil_sdram.sv     - the controller module
           ikautil_sdram_ucode* - generated microcode tables (do not edit by hand)
docs/      ikautil_sdram.xlsx   - microcode timeline spreadsheet + SDRAM datasheets
scripts/   gen_ucode.py         - regenerates the .svh microcode files from the .xlsx
sim/       ikautil_sdram_tb.sv  - Verilator testbench, run.sh builds & runs it
sim_models/                     - vendor SDRAM simulation models (not committed)
```

## Using the controller

1. Drop `src/ikautil_sdram.sv` and the matching `ikautil_sdram_ucode*.svh` file into
   your project.
2. Instantiate `ikautil_sdram`, set `FREQ` to your clock frequency and enable/size the
   slots you need (`SLOTn_EN`, `SLOTn_SA`, `SLOTn_DW`). Slots 0-7 are read-only ROM
   ports, slots 8-11 are read/write.
3. Wire the `o_SDRAM_*` / `io_SDRAM_DQ` ports to your physical SDRAM pins, and pulse
   `i_RFSH` periodically (e.g. once per hblank) to keep refresh running.
4. Drive each `i_SLOTn_A` / `i_SLOTn_RD` (/ `i_SLOTn_WR`) as needed; watch
   `o_SLOTn_BUSY` and `o_SLOTn_RDY`/`o_SLOTn_DST` for request completion and read data.
5. To load ROM/RAM contents up front (e.g. MiSTer IOCTL download), use the
   `i_PRELOAD*` / `o_PRELOAD*` port instead of the slot ports.

See the header comment at the top of `ikautil_sdram.sv` for the full port and timing
details.

## Preload address map (default parameters, all 12 slots enabled)

The preload port addresses the whole SDRAM directly:
`i_PRELOAD_A = {chip, ba[1:0], row[12:0], col[9:0]}`, i.e.

```
i_PRELOAD_A = (global_bank << 23) | (SLOTn_SA + local_word_offset)
```

where `global_bank = {chip, ba}` (0-7) and addresses are 16-bit words.

**ROM slots (0-7)** — read-only, each lives on a mirror pair. Every word must be
written twice: once at the primary address, once at the mirror address (same
row/col, `ba` flipped) — see the "ROM data must be loaded identically into both
banks of a mirror pair" note in `ikautil_sdram.sv`.

| Slot | Chip | Primary bank | Mirror bank | SA (word) | Local word range | Primary `i_PRELOAD_A` | Mirror `i_PRELOAD_A` |
|---|---|---|---|---|---|---|---|
| 0 | 0 | bank0 | bank1 | 0x000000 | 0x000000–0x0FFFFF | 0x0000000–0x00FFFFF | 0x0800000–0x08FFFFF |
| 1 | 0 | bank0 | bank1 | 0x100000 | 0x100000–0x1FFFFF | 0x0100000–0x01FFFFF | 0x0900000–0x09FFFFF |
| 2 | 0 | bank0 | bank1 | 0x200000 | 0x200000–0x2FFFFF | 0x0200000–0x02FFFFF | 0x0A00000–0x0AFFFFF |
| 3 | 0 | bank0 | bank1 | 0x300000 | 0x300000–0x3FFFFF | 0x0300000–0x03FFFFF | 0x0B00000–0x0BFFFFF |
| 4 | 1 | bank4 | bank5 | 0x000000 | 0x000000–0x0FFFFF | 0x2000000–0x20FFFFF | 0x2800000–0x28FFFFF |
| 5 | 1 | bank4 | bank5 | 0x100000 | 0x100000–0x1FFFFF | 0x2100000–0x21FFFFF | 0x2900000–0x29FFFFF |
| 6 | 1 | bank4 | bank5 | 0x200000 | 0x200000–0x2FFFFF | 0x2200000–0x22FFFFF | 0x2A00000–0x2AFFFFF |
| 7 | 1 | bank4 | bank5 | 0x300000 | 0x300000–0x3FFFFF | 0x2300000–0x23FFFFF | 0x2B00000–0x2BFFFFF |

Slots 0-3 (and mirrored 4-7) only use 2MB (0x100000-word) windows because that's
how far apart the default `SLOTn_SA` values are spaced — nothing in the RTL
enforces that size. Each bank pair's full capacity is 0x800000 words (16MB), so
0x400000–0x7FFFFF is unused headroom with the default parameters.

**RW slots (8-11)** — read/write, each has its own dedicated bank, no mirroring
needed:

| Slot | Chip | Dedicated bank | SA (word) | `i_PRELOAD_A` base | Bank capacity (word range) |
|---|---|---|---|---|---|
| 8 | 0 | bank2 | 0x000000 | 0x1000000 | 0x1000000–0x17FFFFF |
| 9 | 0 | bank3 | 0x000000 | 0x1800000 | 0x1800000–0x1FFFFFF |
| 10 | 1 | bank6 | 0x000000 | 0x3000000 | 0x3000000–0x37FFFFF |
| 11 | 1 | bank7 | 0x000000 | 0x3800000 | 0x3800000–0x3FFFFFF |

Write only the actual working-RAM size your core needs, starting at the bank base.

`i_PRELOAD` gates normal slot issue for the whole controller — keep pulsing
`i_RFSH` throughout a long preload so refresh doesn't stall.

## Regenerating the microcode

If you change the timeline in `docs/ikautil_sdram.xlsx`, regenerate the `.svh` tables:

```bash
python3 scripts/gen_ucode.py
```

## Running the testbench

Requires Verilator (>=5.x) and the vendor SDRAM model in `sim_models/`:

```bash
cd sim
./run.sh
```

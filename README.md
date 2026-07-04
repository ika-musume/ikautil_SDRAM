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
   ports, slots 8-11 are read/write. Optionally place slots on specific chips/banks
   with `SLOTn_BANK` and set per-chip burst lengths with `BL0`/`BL1` (see
   "Slot placement and per-chip burst length" below).
3. Wire the `o_SDRAM_*` / `io_SDRAM_DQ` ports to your physical SDRAM pins, and pulse
   `i_RFSH` periodically (e.g. once per hblank) to keep refresh running.
4. Drive each `i_SLOTn_A` / `i_SLOTn_RD` (/ `i_SLOTn_WR`) as needed; watch
   `o_SLOTn_BUSY` and `o_SLOTn_RDY`/`o_SLOTn_DST` for request completion and read data.
5. To load ROM/RAM contents up front (e.g. MiSTer IOCTL download), use the
   `i_PRELOAD*` / `o_PRELOAD*` port instead of the slot ports.

See the header comment at the top of `ikautil_sdram.sv` for the full port and timing
details.

## Slot placement and per-chip burst length

Each slot's location is a parameter: `SLOTn_BANK` is the global bank `{chip, ba[1:0]}`
the slot lives on (chip = bit 2). Roles stay fixed - slots 0-7 are always ROM,
8-11 always R/W - only placement moves:

- **ROM slots (0-7)** name a *mirror pair*: `SLOTn_BANK` is the even bank of the
  pair and the partner is `SLOTn_BANK ^ 1` (pairs are ba0/ba1 or ba2/ba3 of one
  chip). Several ROM slots may share a pair; the loader must write identical data
  to both banks. A chip can host two pairs.
- **R/W slots (8-11)** name a bank. It must not fall inside any ROM mirror pair
  (a writer there would corrupt ROM data - `$error`ed at elaboration). R/W
  slots MAY share a bank with each other ("stacked" regions split by
  `SLOTn_SA`); they then contend for the bank's open row, which is the price
  of the slot-merging scheme below.

`BL0`/`BL1` declare the MRS burst length programmed into chip0/chip1; they must
match the generated microcode (checked at elaboration). Every enabled slot needs
`SLOTn_DW/16 <= ` its chip's burst length (also checked). Slots narrower than
the burst still work - trailing beats are DQM-masked padding - but they occupy
the full burst on the DQ bus. To avoid that waste, group slots of equal width
per chip and give each chip a matching burst length.

The defaults ARE the "everything on" reference configuration, and the committed
default microcode (70MHz bin, BL 4/1) matches it: all 12 slots enabled, the 8
ROM slots on two chip0 mirror pairs (slots 0-3 on ba0/ba1, 4-7 on ba2/ba3) at
`BL0=4`, the 4 R/W slots stacked pairwise in two chip1 banks at `BL1=1` -
slots 8+9 in ba0 (slot 9 at `SA=0x400000`), 10+11 in ba2, with ba1/ba3 as free
headroom. Single-word R/W accesses are roughly 4x denser on the bus with no
padding beats. A bare instantiation with just your `SLOTn_SA`/`SLOTn_DW` values
runs this config as-is. 12 enabled slots require the 70MHz bin; to trade ports
for clock speed WITHOUT changing any address, see the slot-merging scheme in
"Changing the frequency and microcode" below - the stacked R/W layout exists
exactly for that.

Trade-off to weigh when grouping by width: more ROM streams per mirror pair
means more row thrash between them, while the R/W slots gain private banks and
much better column-hit throughput. Judge with the testbench's latency report
for a traffic mix resembling your core.

## Preload address map (default parameters, all 12 slots enabled)

The preload port addresses the whole SDRAM directly:
`i_PRELOAD_A = {chip, ba[1:0], row[12:0], col[9:0]}`, i.e.

```
i_PRELOAD_A = (global_bank << 23) | (SLOTn_SA + local_word_offset)
```

where `global_bank = {chip, ba}` (0-7) and addresses are 16-bit words.

With custom placement the same formula holds with `global_bank = SLOTn_BANK`:
a slot's primary base is `SLOTn_BANK << 23`, and for ROM slots the mirror copy
goes to the pair partner, i.e. the same address with bit 23 flipped
(`^ 0x0800000`). The tables below are for the default `SLOTn_BANK` values.

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
| 4 | 0 | bank2 | bank3 | 0x000000 | 0x000000–0x0FFFFF | 0x1000000–0x10FFFFF | 0x1800000–0x18FFFFF |
| 5 | 0 | bank2 | bank3 | 0x100000 | 0x100000–0x1FFFFF | 0x1100000–0x11FFFFF | 0x1900000–0x19FFFFF |
| 6 | 0 | bank2 | bank3 | 0x200000 | 0x200000–0x2FFFFF | 0x1200000–0x12FFFFF | 0x1A00000–0x1AFFFFF |
| 7 | 0 | bank2 | bank3 | 0x300000 | 0x300000–0x3FFFFF | 0x1300000–0x13FFFFF | 0x1B00000–0x1BFFFFF |

ROM slots only use 2MB (0x100000-word) windows because that's how far apart the
default `SLOTn_SA` values are spaced — nothing in the RTL enforces that size.
Each pair's full capacity is 0x800000 words (16MB), so 0x400000–0x7FFFFF is
unused headroom in both pairs with the default parameters.

**RW slots (8-11)** — read/write, no mirroring needed. Pairs are stacked in one
bank (regions split by `SLOTn_SA`) so adjacent slots can be merged at higher
clocks without moving any address; banks 5 and 7 are free headroom:

| Slot | Chip | Bank | SA (word) | `i_PRELOAD_A` base | Region (word range) |
|---|---|---|---|---|---|
| 8 | 1 | bank4 | 0x000000 | 0x2000000 | 0x2000000–0x23FFFFF |
| 9 | 1 | bank4 | 0x400000 | 0x2400000 | 0x2400000–0x27FFFFF |
| 10 | 1 | bank6 | 0x000000 | 0x3000000 | 0x3000000–0x33FFFFF |
| 11 | 1 | bank6 | 0x400000 | 0x3400000 | 0x3400000–0x37FFFFF |

Each stacked region caps at 0x400000 words (8MB). Write only the actual
working-RAM size your core needs, starting at the region base.

`i_PRELOAD` gates normal slot issue for the whole controller — keep pulsing
`i_RFSH` throughout a long preload so refresh doesn't stall.

## Changing the frequency and microcode

The controller replays fixed command timelines from a compile-time microcode
table, so the clock is not a free-running parameter: `FREQ`, `BL0` and `BL1`
must equal the `UC_FREQ`/`UC_BL0`/`UC_BL1` constants baked into
`src/ikautil_sdram_ucode.svh` (the file the module `include`s), and
elaboration `$error`s on any mismatch. The issue-cone timing rule ties the
enabled slot count to the speed bin:

| ucode bin | max clock | max enabled slots | shipped table |
|---|---|---|---|
| f70 | 70MHz | 12 | `ikautil_sdram_ucode_f70.svh` — BL 4/1, **the default** |
| f95 | 95MHz | 8 | `ikautil_sdram_ucode_f95.svh` — BL 4/4 |
| f110 | 110MHz | 6 | `ikautil_sdram_ucode_f110.svh` — BL 4/4 |

132MHz is the hard ceiling. `ikautil_sdram_ucode.svh` (no suffix) is the active
table; it ships as a copy of the f70 one to match the all-slots defaults.

### Slot merging: same addresses at every bin

The default map is arranged so the slot limit costs *ports*, not addresses.
ROM windows share a mirror pair and paired R/W regions share a bank, so a
merged (even) port reaches its odd neighbor's region by simply driving higher
addresses - the SDRAM image and every preload address stay identical at all
three bins:

| bin | ROM ports | R/W ports | disabled slots |
|---|---|---|---|
| 70MHz | 0-7, one per window | 8-11 | none (the default) |
| 95MHz | 0,2,4,6 - each also serves its odd neighbor's window (`+0x100000`) | 8-11 | 1,3,5,7 |
| 110MHz | 0,2,4,6 as above | 8,10 - each also serves the stacked odd region (`+0x400000`) | 1,3,5,7,9,11 |

The core side must mux the two folded request streams onto the shared port
(one outstanding request per port), and the two regions of a merged R/W port
contend for one bank's open row - that is the merge cost; addresses never move.

To change the frequency:

1. Disable the odd slots per the table above (or any other set that meets the
   bin's limit).
2. Install a matching table as `src/ikautil_sdram_ucode.svh` — either generate
   one for your burst lengths:

   ```bash
   python3 scripts/gen_ucode.py --freq 110 --bl0 4 --bl1 1 -o src/ikautil_sdram_ucode.svh
   ```

   or copy a shipped BL-4/4 table
   (`cp src/ikautil_sdram_ucode_f110.svh src/ikautil_sdram_ucode.svh`).
3. Set the `FREQ`, `BL0`, `BL1` parameters to the same values.
4. If the burst lengths changed, re-check placement: every enabled slot needs
   `SLOTn_DW/16 <=` its chip's burst length. With a BL-4/4 table the 16-bit R/W
   slots may sit on either chip (they just pay padding beats); with `BL1=1`
   only 16-bit slots fit on chip1.

Example - the merged 110MHz tier (regenerate with `--freq 110 --bl0 4 --bl1 1`,
then):

```systemverilog
ikautil_sdram #(
    .FREQ(110),                                   //BL0/BL1 defaults (4/1) still apply
    .SLOT1_EN(0), .SLOT3_EN(0), .SLOT5_EN(0),     //merge: even ports serve both regions
    .SLOT7_EN(0), .SLOT9_EN(0), .SLOT11_EN(0)
) u_sdram ( ... );
```

If you change the timeline itself in `docs/ikautil_sdram.xlsx`, rerun
`gen_ucode.py` the same way; it also rewrites the human-readable
`*_windows.txt` reports next to each table.

## Running the testbench

Requires Verilator (>=5.x) and the vendor SDRAM model in `sim_models/`:

```bash
cd sim
./run.sh
```

The testbench runs the DUT's default configuration ("everything on", see above)
against the committed default microcode, covering all 12 regions, the preload
port, mirror relatch, the DST early path, refresh collisions and a random soak.
`TIER=95 ./run.sh` and `TIER=110 ./run.sh` run the merged tiers instead: the
same scenarios drive all 12 regions at the same addresses through 8 or 6 ports
(the matching ucode is generated into `sim/obj/`). `run.sh` rewrites the
`sdram_bank*.hex` files if their content scheme changed.

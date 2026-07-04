#!/usr/bin/env bash
# Build & run the ikautil_sdram scenario testbench with Verilator (>=5.x).
# The Micron model's three delayed DQ assignments are unsupported tristate
# constructs in Verilator; they are converted to plain NBAs at build time
# (cycle-accurate for posedge sampling since tMiST=0).
#
# TIER=70 (default) runs the DUT's default configuration ("everything on":
# all 12 slots) against the committed default ucode (f70, BL 4/1).
# TIER=95 / TIER=110 run the slot-MERGED tiers: same SDRAM image and region
# addresses, fewer ports (ROM folded pairwise at 95, ROM+RW at 110), with a
# matching ucode generated into obj/.
set -e
cd "$(dirname "$0")"
mkdir -p obj

TIER="${TIER:-70}"
case "$TIER" in
    70)  INCDIR="+incdir+../src" ;;      #committed default ucode
    95|110)
        mkdir -p obj/gen$TIER
        python3 ../scripts/gen_ucode.py --freq "$TIER" --bl0 4 --bl1 1 \
            -o "obj/gen$TIER/ikautil_sdram_ucode.svh"
        INCDIR="+incdir+obj/gen$TIER" ;;
    *)   echo "TIER must be 70, 95 or 110"; exit 1 ;;
esac
MDIR="obj/verilated_t$TIER"

# Memory preload: the model loads sdram_bank0..3.hex itself ($readmemh path,
# LOADROM undefined + JTFRAME_SDRAM_BANKS defined). Hierarchical array writes
# from the TB are avoided deliberately - under verilator --timing they leave
# the model's own in-process array reads stale by one activation.
# Both chips load the SAME files, and chip0 uses banks 2/3 as a second mirror
# pair, so bank2 == bank3 (tag 2) and bank0 == bank1 (untagged). Files are
# rewritten if their first word does not match this scheme.
python3 - << 'EOF'
import os
N = 0x120000                 # preloaded words per bank (covers all TB addresses)
def pat(i):  return (i & 0xFFFF) ^ ((i >> 16) << 9) & 0xFFFF
for b in range(4):
    fn = f'sdram_bank{b}.hex'
    x = 0 if b < 2 else 2    # pair1 = banks 0/1, pair2 = banks 2/3 (tag 2)
    first = f'{(pat(0) ^ x):04x}'
    if os.path.exists(fn) and os.path.getsize(fn) > 0:
        with open(fn) as f:
            if f.readline().strip() == first:
                continue
    with open(fn, 'w') as f:
        f.write('\n'.join(f'{(pat(i) ^ x):04x}' for i in range(N)))
        f.write('\n')
print('bank hex files ready')
EOF

# Verilator cannot lower procedural Z assignment, so the model's Dq_reg Z
# states become an explicit output enable (Dq_en). tMiST=0, so dropping the
# tAC/tOH/tHZ delays is cycle-accurate for posedge sampling.
sed -e 's/reg       \[data_bits - 1 : 0\] Dq_reg, Dq_dqm;/reg [data_bits-1:0] Dq_reg, Dq_dqm; reg Dq_en;/' \
    -e 's/assign  Dq               = Dq_reg;/assign Dq = Dq_en ? Dq_reg : {data_bits{1'"'"'bz}};/' \
    -e 's/^        Dq_reg = {data_bits{1'"'"'bz}};/        Dq_en = 1'"'"'b0;/' \
    -e 's/Dq_reg <= #(tOH+tMiST) {data_bits{1'"'"'bz}};/Dq_en = 1'"'"'b0;/' \
    -e 's/Dq_reg = #(tAC+tMiST) Dq_dqm;/begin Dq_en = 1'"'"'b1; Dq_reg = Dq_dqm; end/' \
    -e 's/Dq_reg = #(tHZ+tMiST) {data_bits{1'"'"'bz}};/Dq_en = 1'"'"'b0;/' \
    -e 's/#tHZ Burst_decode;/Burst_decode;/' \
    -e 's/always @ (posedge Sys_clk) begin/always @ (posedge Clk) begin \/\/CKE==1 always: Sys_clk===Clk; avoids verilator coroutine array-read staleness/' \
    -e 's/Dq_dqm \[ 7 : 0\] = 8'"'"'bz;/Dq_dqm [ 7 : 0] = 8'"'"'h00; \/\/z poisons verilator tristate lowering/' \
    -e 's/Dq_dqm \[15 : 8\] = 8'"'"'bz;/Dq_dqm [15 : 8] = 8'"'"'h00;/' \
    -e 's/if (Dqm\[0\] === 1'"'"'bx || Dqm\[1\]== 1'"'"'bx) begin/if (0) begin \/\/x-check: meaningless under 2-state verilator/' \
    -e 's/            \/\/ Dqm operation/            if (Debug) $display("FETCH %m t=%0t row=%0d col=%0d dqdqm=%h raw=%h bank=%0d doe=%b die=%b", $time, Row, Col, Dq_dqm, Bank0[{Row, Col}], Bank, Data_out_enable, Data_in_enable);/' \
    ../sim_models/mt48lc16m16a2.v > obj/mt48lc16m16a2_sim.v

verilator --timing --binary -j 4 \
    -DJTFRAME_SDRAM_BANKS -DSIMULATION \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-BLKANDNBLK \
    $INCDIR -GTIER=$TIER \
    --top-module tb \
    ../src/ikautil_sdram.sv mister_128mb.sv ikautil_sdram_tb.sv obj/mt48lc16m16a2_sim.v \
    -o tb_run --Mdir $MDIR "$@"

$MDIR/tb_run | tee obj/sim.log

if grep -q "ERROR" obj/sim.log; then
    echo "== FAILED: errors in log =="
    exit 1
fi
if ! grep -q "ALL SCENARIOS PASSED" obj/sim.log; then
    echo "== FAILED: did not reach PASS =="
    exit 1
fi
echo "== PASS =="

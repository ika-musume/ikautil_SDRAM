`timescale 1ns/1ps
/*
    Scenario testbench: ikautil_sdram against the MiSTer 128MB module model.

    TIER selects the frequency bin and the slot-merging arrangement
    (run.sh -GTIER=70/95/110). The SDRAM image and all region addresses are
    IDENTICAL at every tier - only the number of ports serving them changes:

      TIER 70  (12 ports): ROM regions 0-7 on ports 0-7, RW regions 8-11 on
                           ports 8-11 (the DUT's default config)
      TIER 95  (8 ports):  ROM merged pairwise - ports 0,2,4,6 each also serve
                           the odd neighbor's window; RW unchanged
      TIER 110 (6 ports):  ROM merged as above; RW merged - ports 8,10 each
                           also serve the stacked odd region

    Placement (DUT defaults): ROM regions 0-3 on the chip0 ba0/ba1 mirror
    pair, 4-7 on the chip0 ba2/ba3 pair (BL0=4); RW regions 8+9 stacked in
    chip1 ba0, 10+11 stacked in chip1 ba2 (BL1=1). The TB compacts the SA
    spacing (ROM windows 0x40000, RW regions 0x4000) so the generated hex
    files stay small - window sizes are a per-core convention.

    Memory background (see run.sh hex generator; both chips load the same
    files, so pair banks must hold identical content):
      bank0.hex = bank1.hex = pat(wa)        -> chip0 pair1, chip1 ba0/ba1
      bank2.hex = bank3.hex = pat(wa) ^ 2    -> chip0 pair2, chip1 ba2/ba3

    Scenarios:
      S1 single reads, all 8 ROM regions   S2 row-hit chain
      S3 all-ports concurrent burst        S4 RW write/readback + neighbors
      S5 BL=1 column-hit chain             S6 mirror relatch, both pairs
      S7 refresh collision                 S8 DST early path
      S9 whole-SDRAM preload/verify        S10 random soak w/ scoreboard
*/
module tb #(
    parameter integer TIER = 70     //70 / 95 / 110
);

localparam integer FREQ = TIER;
//run the bus at a rounded-up period: legal for the bin's ucode (all waits
//grow in ns) and keeps the model's real-valued $time checks free of rounding
localparam real    PERIOD = (TIER == 70) ? 15.0 : (TIER == 95) ? 11.0 : 10.0;

localparam ROM_MERGED = (TIER > 70);    //ports 0,2,4,6 serve two windows each
localparam RW_MERGED  = (TIER > 95);    //ports 8,10 serve two regions each

localparam [22:0] SAW  = 23'h04_0000;   //ROM window spacing (compacted)
localparam [22:0] RSAW = 23'h00_4000;   //stacked RW region size (compacted)

reg clk = 0;
always #(PERIOD / 2.0) clk = ~clk;

reg rst_n = 0;
reg rfsh  = 0;

//----------------------------------------------------------------------------
// DUT hookup
//----------------------------------------------------------------------------
wire [15:0] sd_dq;
wire [12:0] sd_a;
wire [1:0]  sd_ba;
wire        sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_dqml, sd_dqmh, sd_cke;
wire        init_done;

reg  [11:0] rd_r = 0, wr_r = 0;
reg  [22:0] a_r  [0:11];
reg  [15:0] di_r [0:11];
wire [11:0] busy_w, rdy_w, dst_w;
wire [63:0] do0, do1, do2, do3, do4, do5, do6, do7;
wire [15:0] do8, do9, do10, do11;
wire [15:0] rdata_w;

reg         pl_en = 0, pl_wr = 0, pl_rd = 0;
reg  [25:0] pl_a = 0;
reg  [15:0] pl_di = 0;
wire        pl_busy;
wire [15:0] pl_do;

initial begin : init_arrays
    integer k;
    for (k = 0; k < 12; k = k + 1) begin a_r[k] = 23'd0; di_r[k] = 16'd0; end
end

//DUT parameters are the shipped defaults apart from the tier's slot merging,
//the compacted SA windows and sim-friendly INIT_PAUSE/CAP_DELAY
ikautil_sdram #(
    .FREQ(FREQ), .DQM_SHARED(1), .CAP_DELAY(0), .INIT_PAUSE(100), .RFSHCNT(9),
    .SLOT1_EN(!ROM_MERGED), .SLOT3_EN(!ROM_MERGED),
    .SLOT5_EN(!ROM_MERGED), .SLOT7_EN(!ROM_MERGED),
    .SLOT9_EN(!RW_MERGED),  .SLOT11_EN(!RW_MERGED),
    .SLOT0_SA(0*SAW), .SLOT1_SA(1*SAW), .SLOT2_SA(2*SAW), .SLOT3_SA(3*SAW),
    .SLOT4_SA(0*SAW), .SLOT5_SA(1*SAW), .SLOT6_SA(2*SAW), .SLOT7_SA(3*SAW),
    .SLOT9_SA(RSAW), .SLOT11_SA(RSAW)
) dut (
    .i_CLK(clk), .i_RST_n(rst_n), .i_RFSH(rfsh), .o_INIT_DONE(init_done),

    .i_PRELOAD(pl_en), .i_PRELOAD_A(pl_a), .i_PRELOAD_DI(pl_di),
    .i_PRELOAD_WR(pl_wr), .i_PRELOAD_RD(pl_rd),
    .o_PRELOAD_BUSY(pl_busy), .o_PRELOAD_DO(pl_do),

    .o_RDATA(rdata_w),
    .o_SLOT0_DST(dst_w[0]),  .o_SLOT1_DST(dst_w[1]),  .o_SLOT2_DST(dst_w[2]),   .o_SLOT3_DST(dst_w[3]),
    .o_SLOT4_DST(dst_w[4]),  .o_SLOT5_DST(dst_w[5]),  .o_SLOT6_DST(dst_w[6]),   .o_SLOT7_DST(dst_w[7]),
    .o_SLOT8_DST(dst_w[8]),  .o_SLOT9_DST(dst_w[9]),  .o_SLOT10_DST(dst_w[10]), .o_SLOT11_DST(dst_w[11]),

    .io_SDRAM_DQ(sd_dq), .o_SDRAM_A(sd_a), .o_SDRAM_BA(sd_ba),
    .o_SDRAM_nCS(sd_ncs), .o_SDRAM_nRAS(sd_nras), .o_SDRAM_nCAS(sd_ncas),
    .o_SDRAM_nWE(sd_nwe), .o_SDRAM_DQML(sd_dqml), .o_SDRAM_DQMH(sd_dqmh),
    .o_SDRAM_CKE(sd_cke),

    .o_SLOT0_BUSY(busy_w[0]),  .o_SLOT1_BUSY(busy_w[1]),  .o_SLOT2_BUSY(busy_w[2]),  .o_SLOT3_BUSY(busy_w[3]),
    .o_SLOT4_BUSY(busy_w[4]),  .o_SLOT5_BUSY(busy_w[5]),  .o_SLOT6_BUSY(busy_w[6]),  .o_SLOT7_BUSY(busy_w[7]),
    .o_SLOT0_RDY(rdy_w[0]),    .o_SLOT1_RDY(rdy_w[1]),    .o_SLOT2_RDY(rdy_w[2]),    .o_SLOT3_RDY(rdy_w[3]),
    .o_SLOT4_RDY(rdy_w[4]),    .o_SLOT5_RDY(rdy_w[5]),    .o_SLOT6_RDY(rdy_w[6]),    .o_SLOT7_RDY(rdy_w[7]),
    .i_SLOT0_RD(rd_r[0]),      .i_SLOT1_RD(rd_r[1]),      .i_SLOT2_RD(rd_r[2]),      .i_SLOT3_RD(rd_r[3]),
    .i_SLOT4_RD(rd_r[4]),      .i_SLOT5_RD(rd_r[5]),      .i_SLOT6_RD(rd_r[6]),      .i_SLOT7_RD(rd_r[7]),
    .i_SLOT0_A(a_r[0]), .i_SLOT1_A(a_r[1]), .i_SLOT2_A(a_r[2]), .i_SLOT3_A(a_r[3]),
    .i_SLOT4_A(a_r[4]), .i_SLOT5_A(a_r[5]), .i_SLOT6_A(a_r[6]), .i_SLOT7_A(a_r[7]),
    .o_SLOT0_DO(do0), .o_SLOT1_DO(do1), .o_SLOT2_DO(do2), .o_SLOT3_DO(do3),
    .o_SLOT4_DO(do4), .o_SLOT5_DO(do5), .o_SLOT6_DO(do6), .o_SLOT7_DO(do7),

    .o_SLOT8_BUSY(busy_w[8]), .o_SLOT9_BUSY(busy_w[9]), .o_SLOT10_BUSY(busy_w[10]), .o_SLOT11_BUSY(busy_w[11]),
    .o_SLOT8_RDY(rdy_w[8]),   .o_SLOT9_RDY(rdy_w[9]),   .o_SLOT10_RDY(rdy_w[10]),   .o_SLOT11_RDY(rdy_w[11]),
    .i_SLOT8_RD(rd_r[8]),     .i_SLOT9_RD(rd_r[9]),     .i_SLOT10_RD(rd_r[10]),     .i_SLOT11_RD(rd_r[11]),
    .i_SLOT8_WR(wr_r[8]),     .i_SLOT9_WR(wr_r[9]),     .i_SLOT10_WR(wr_r[10]),     .i_SLOT11_WR(wr_r[11]),
    .i_SLOT8_A(a_r[8]), .i_SLOT9_A(a_r[9]), .i_SLOT10_A(a_r[10]), .i_SLOT11_A(a_r[11]),
    .i_SLOT8_DI(di_r[8]), .i_SLOT9_DI(di_r[9]), .i_SLOT10_DI(di_r[10]), .i_SLOT11_DI(di_r[11]),
    .o_SLOT8_DO(do8), .o_SLOT9_DO(do9), .o_SLOT10_DO(do10), .o_SLOT11_DO(do11)
);

mister_128mb u_mod (
    .clk(clk), .dq(sd_dq), .a(sd_a), .ba(sd_ba),
    .ncs(sd_ncs), .nras(sd_nras), .ncas(sd_ncas), .nwe(sd_nwe),
    .dqml(sd_dqml), .dqmh(sd_dqmh), .cke(sd_cke)
);

//----------------------------------------------------------------------------
// region model: 12 fixed-address regions, tier-dependent serving port
//----------------------------------------------------------------------------
function automatic [15:0] pat(input [22:0] wa);
    pat = wa[15:0] ^ {wa[22:16], 9'h0};
endfunction

//hex tag of a region's bank file (pair2 / chip1 ba2 files carry tag 2)
function automatic [15:0] rtag(input int r);
    rtag = ((r >= 4 && r <= 7) || r >= 10) ? 16'd2 : 16'd0;
endfunction

function automatic int rport(input int r);      //port serving region r
    if (r < 8)  rport = ROM_MERGED ? (r / 2) * 2 : r;
    else        rport = RW_MERGED  ? (r / 2) * 2 : r;
endfunction

function automatic [22:0] roff(input int r);    //region base, port-relative
    if (r < 8)  roff = (ROM_MERGED && (r % 2)) ? SAW  : '0;
    else        roff = (RW_MERGED  && (r % 2)) ? RSAW : '0;
endfunction

function automatic [22:0] rabs(input int r, input [22:0] ad);  //in-bank word address
    if (r < 8)  rabs = SAW * 23'(r % 4) + ad;
    else        rabs = ((r % 2) ? RSAW : 23'd0) + ad;
endfunction

//expected 64-bit ROM region data (4-word aligned address within the region)
function automatic [63:0] rom_rexp(input int r, input [22:0] ad);
    logic [22:0] wa;
    wa = rabs(r, ad);
    rom_rexp = {pat(wa+3) ^ rtag(r), pat(wa+2) ^ rtag(r),
                pat(wa+1) ^ rtag(r), pat(wa)   ^ rtag(r)};
endfunction

//----------------------------------------------------------------------------
// helpers
//----------------------------------------------------------------------------
integer errors = 0;
integer cycle = 0;
always @(posedge clk) cycle = cycle + 1;

integer lat_sum = 0, lat_n = 0, lat_max = 0;
integer t_req [0:11];

//RDY is a 1-cycle strobe; with mixed BL the fast chip1 ops can complete while
//the TB is still waiting on a chip0 slot, so count completions instead of
//polling the strobe
integer done_cnt [0:11];
integer pend_cnt [0:11];
initial begin : init_cnt
    integer k;
    for (k = 0; k < 12; k = k + 1) begin done_cnt[k] = 0; pend_cnt[k] = 0; end
end
always @(posedge clk) begin : count_rdy
    integer k;
    for (k = 0; k < 12; k = k + 1) if (rdy_w[k]) done_cnt[k] = done_cnt[k] + 1;
end

task automatic fire_read(input int s, input [22:0] addr);
    @(negedge clk);
    a_r[s] = addr; rd_r[s] = 1'b1; t_req[s] = cycle;
    pend_cnt[s] = pend_cnt[s] + 1;
    @(negedge clk);
    rd_r[s] = 1'b0;
endtask

task automatic fire_write(input int s, input [22:0] addr, input [15:0] d);
    @(negedge clk);
    a_r[s] = addr; di_r[s] = d; wr_r[s] = 1'b1; t_req[s] = cycle;
    pend_cnt[s] = pend_cnt[s] + 1;
    @(negedge clk);
    wr_r[s] = 1'b0;
endtask

task automatic preload_wr(input [25:0] a, input [15:0] d);
    int t0;
    @(negedge clk);
    pl_a = a; pl_di = d; pl_wr = 1'b1;
    @(negedge clk);
    pl_wr = 1'b0;
    t0 = cycle;
    while (pl_busy) begin
        @(posedge clk);
        if (cycle - t0 > 3000) begin $display("FATAL: preload wr timeout"); $finish; end
    end
endtask

task automatic preload_rd(input [25:0] a, output [15:0] d);
    int t0;
    @(negedge clk);
    pl_a = a; pl_rd = 1'b1;
    @(negedge clk);
    pl_rd = 1'b0;
    t0 = cycle;
    while (pl_busy) begin
        @(posedge clk);
        if (cycle - t0 > 3000) begin $display("FATAL: preload rd timeout"); $finish; end
    end
    d = pl_do;
endtask

task automatic wait_rdy(input int s, input int timeout = 3000);
    int t0;
    t0 = cycle;
    while (done_cnt[s] < pend_cnt[s]) begin
        @(posedge clk);
        if (cycle - t0 > timeout) begin
            $display("FATAL: slot%0d RDY timeout", s);
            errors = errors + 1;
            $finish;
        end
    end
    lat_sum = lat_sum + (cycle - t_req[s]);
    lat_n   = lat_n + 1;
    if (cycle - t_req[s] > lat_max) lat_max = cycle - t_req[s];
    @(posedge clk);
endtask

function automatic [63:0] slot_do(input int s);
    case (s)
        0: slot_do = do0;   1: slot_do = do1;  2: slot_do = do2;   3: slot_do = do3;
        4: slot_do = do4;   5: slot_do = do5;  6: slot_do = do6;   7: slot_do = do7;
        8: slot_do = {48'd0, do8};   9: slot_do = {48'd0, do9};
        10: slot_do = {48'd0, do10}; 11: slot_do = {48'd0, do11};
        default: slot_do = '0;
    endcase
endfunction

task automatic check64(input string tag, input [63:0] got, input [63:0] exp);
    if (got !== exp) begin
        $display("ERROR: %s got=%h exp=%h (cycle %0d)", tag, got, exp, cycle);
        errors = errors + 1;
    end
endtask

task automatic check16(input string tag, input [15:0] got, input [15:0] exp);
    if (got !== exp) begin
        $display("ERROR: %s got=%h exp=%h (cycle %0d)", tag, got, exp, cycle);
        errors = errors + 1;
    end
endtask

//region-level request wrappers
task automatic rom_read(input int r, input [22:0] ad);
    fire_read(rport(r), roff(r) + ad);
endtask

task automatic rw_write(input int r, input [22:0] ad, input [15:0] d);
    fire_write(rport(r), roff(r) + ad, d);
endtask

task automatic rw_read(input int r, input [22:0] ad);
    fire_read(rport(r), roff(r) + ad);
endtask

//----------------------------------------------------------------------------
// scenarios
//----------------------------------------------------------------------------

//RW scoreboards, one per bank, keyed by in-bank word address
reg [15:0] sh [0:1] [int];   //0 = chip1 ba0 (regions 8/9), 1 = chip1 ba2 (10/11)

function automatic [15:0] rw_exp(input int r, input [22:0] ad);
    automatic int b = (r >= 10);
    automatic int key = int'(rabs(r, ad));
    rw_exp = sh[b].exists(key) ? sh[b][key] : (pat(rabs(r, ad)) ^ rtag(r));
endfunction

task automatic rw_note(input int r, input [22:0] ad, input [15:0] d);
    sh[(r >= 10)][int'(rabs(r, ad))] = d;
endtask

integer i, j, t0;
integer lat1, lat2;

initial begin
    $display("TIER %0d: %0d ROM ports, %0d RW ports",
             TIER, ROM_MERGED ? 4 : 8, RW_MERGED ? 2 : 4);
    repeat (4) @(negedge clk);
    rst_n = 1;

    //S0: init (per-chip MRS: chip0 BL=4, chip1 BL=1)
    t0 = cycle;
    while (!init_done) begin
        @(posedge clk);
        if (cycle - t0 > 100000) begin $display("FATAL: init timeout"); $finish; end
    end
    $display("[S0] init done at cycle %0d", cycle);

    //S1: single reads covering all 8 ROM regions at their fixed addresses
    //(at merged tiers this drives the folded windows through the even ports)
    for (i = 0; i < 8; i = i + 1) begin
        rom_read(i, 23'(i) * 23'h1000 + 23'h40);
        wait_rdy(rport(i));
        check64($sformatf("S1 region%0d", i),
                slot_do(rport(i)), rom_rexp(i, 23'(i)*23'h1000 + 23'h40));
    end
    $display("[S1] all 8 ROM regions ok, avg latency so far %0d cycles", lat_sum / lat_n);

    //S2: row-hit chain on region 0 (same row, consecutive 4-word blocks)
    lat1 = lat_sum; lat2 = lat_n;
    for (i = 0; i < 8; i = i + 1) begin
        rom_read(0, 23'h2000 + 23'(i)*4);
        wait_rdy(0);
        check64("S2", slot_do(0), rom_rexp(0, 23'h2000 + 23'(i)*4));
    end
    $display("[S2] row-hit chain ok, avg latency %0d cycles",
             (lat_sum - lat1) / (lat_n - lat2));

    //S3: every live port at once - reads on all ROM ports + writes on all RW
    //ports fired in the same cycle
    @(negedge clk);
    for (i = 0; i < 8; i = i + 1) begin
        if (rport(i) == i) begin    //i is a live ROM port
            a_r[i] = 23'h3000 + 23'(i)*23'h100;
            rd_r[i] = 1'b1; t_req[i] = cycle; pend_cnt[i] = pend_cnt[i] + 1;
        end
    end
    for (i = 8; i < 12; i = i + 1) begin
        if (rport(i) == i) begin    //i is a live RW port
            a_r[i] = 23'h0500 + 23'(i);
            di_r[i] = 16'h3000 + 16'(i);
            wr_r[i] = 1'b1; t_req[i] = cycle; pend_cnt[i] = pend_cnt[i] + 1;
        end
    end
    @(negedge clk);
    rd_r = 12'd0; wr_r = 12'd0;
    for (i = 0; i < 12; i = i + 1) if (rport(i) == i) wait_rdy(i);
    for (i = 0; i < 8; i = i + 1) begin
        if (rport(i) == i)
            check64($sformatf("S3 port%0d", i), slot_do(i), rom_rexp(i, 23'h3000 + 23'(i)*23'h100));
    end
    for (i = 8; i < 12; i = i + 1) begin
        if (rport(i) == i) begin
            rw_note(i, 23'h0500 + 23'(i), 16'h3000 + 16'(i));
            rw_read(i, 23'h0500 + 23'(i)); wait_rdy(i);
            check16($sformatf("S3 port%0d rb", i), slot_do(i)[15:0], 16'h3000 + 16'(i));
        end
    end
    $display("[S3] all-ports concurrent ok");

    //S4: RW write/readback + neighbor integrity, all 4 regions at their
    //fixed addresses (folded regions go through the even ports when merged)
    for (i = 8; i < 12; i = i + 1) begin
        automatic logic [22:0] ad = 23'h0100 + 23'(i - 8) * 23'h10;
        rw_write(i, ad, 16'hBE00 + 16'(i)); wait_rdy(rport(i));
        rw_note(i, ad, 16'hBE00 + 16'(i));
        rw_read(i, ad); wait_rdy(rport(i));
        check16($sformatf("S4 region%0d rb", i), slot_do(rport(i))[15:0], 16'hBE00 + 16'(i));
        rw_read(i, ad + 1); wait_rdy(rport(i));
        check16($sformatf("S4 region%0d nbr", i), slot_do(rport(i))[15:0], rw_exp(i, ad + 1));
        rw_read(i, ad + 3); wait_rdy(rport(i));
        check16($sformatf("S4 region%0d nbr3", i), slot_do(rport(i))[15:0], rw_exp(i, ad + 3));
    end
    $display("[S4] BL=1 write/readback + neighbors ok");

    //S5: BL=1 column-hit chain (same row, 16 writes then 16 readbacks)
    lat1 = lat_sum; lat2 = lat_n;
    for (i = 0; i < 16; i = i + 1) begin
        rw_write(8, 23'h0400 + 23'(i), 16'hA000 + 16'(i));
        wait_rdy(8);
        rw_note(8, 23'h0400 + 23'(i), 16'hA000 + 16'(i));
    end
    for (i = 0; i < 16; i = i + 1) begin
        rw_read(8, 23'h0400 + 23'(i));
        wait_rdy(8);
        check16($sformatf("S5 w%0d", i), do8, 16'hA000 + 16'(i));
    end
    $display("[S5] BL=1 col-hit chain ok, avg latency %0d cycles",
             (lat_sum - lat1) / (lat_n - lat2));

    //S6: mirror relatch on both pairs: 3 rows through one port each
    rom_read(0, 23'h0000); wait_rdy(0);    //row A -> bank of pair1
    check64("S6 p1 rowA", slot_do(0), rom_rexp(0, 23'h0000));
    rom_read(0, 23'h8000); wait_rdy(0);    //row B -> mirror bank, no precharge
    check64("S6 p1 rowB", slot_do(0), rom_rexp(0, 23'h8000));
    rom_read(0, 23'h10000); wait_rdy(0);   //row C -> relatch (PRE + ACT)
    check64("S6 p1 rowC", slot_do(0), rom_rexp(0, 23'h10000));
    rom_read(4, 23'h0000); wait_rdy(4);    //same dance on pair2
    check64("S6 p2 rowA", slot_do(4), rom_rexp(4, 23'h0000));
    rom_read(4, 23'h8000); wait_rdy(4);
    check64("S6 p2 rowB", slot_do(4), rom_rexp(4, 23'h8000));
    rom_read(4, 23'h10000); wait_rdy(4);
    check64("S6 p2 rowC", slot_do(4), rom_rexp(4, 23'h10000));
    $display("[S6] mirror/relatch ok, both pairs");

    //S7: refresh burst colliding with mixed traffic on both chips
    @(negedge clk); rfsh = 1'b1;
    rom_read(0, 23'h4000);
    rom_read(4, 23'h5000);
    rw_write(9, 23'h0700, 16'h9A9A);
    @(negedge clk); rfsh = 1'b0;
    wait_rdy(0); wait_rdy(4); wait_rdy(rport(9));
    rw_note(9, 23'h0700, 16'h9A9A);
    check64("S7 region0", slot_do(0), rom_rexp(0, 23'h4000));
    check64("S7 region4", slot_do(4), rom_rexp(4, 23'h5000));
    rw_read(9, 23'h0700); wait_rdy(rport(9));
    check16("S7 region9 rb", slot_do(rport(9))[15:0], 16'h9A9A);
    repeat (300) @(posedge clk);   //let the refresh debt drain
    $display("[S7] refresh collision ok");

    //S8: jtframe-style early path - beats on o_RDATA from the DST strobe,
    //and first-word latency measurement
    begin
        automatic int t_fire, t_dst;
        automatic logic [63:0] early;
        rom_read(0, 23'h6100);
        t_fire = t_req[0];
        while (!dst_w[0]) @(posedge clk);
        t_dst = cycle;
        early[15:0] = rdata_w;
        for (i = 1; i < 4; i = i + 1) begin
            @(posedge clk);
            early[i*16 +: 16] = rdata_w;
        end
        wait_rdy(0);
        check64("S8 early beats", early, rom_rexp(0, 23'h6100));
        check64("S8 vs DO", early, slot_do(0));
        $display("[S8] DST early path ok, first word at %0d cycles (%.0f ns), full RDY at %0d cycles",
                 t_dst - t_fire, real'(t_dst - t_fire) * PERIOD, cycle - 1 - t_fire);
    end

    //S9: whole-SDRAM preload port - write/verify across chips and banks
    //(BL=4 chip0 exercises the DQM padding mask, BL=1 chip1 does not need it),
    //mirror duplication by the loader on BOTH pairs, then read through ports
    begin
        automatic logic [25:0] base;
        automatic logic [15:0] d;
        pl_en = 1'b1;
        //write 8 words into every global bank at row 0x555
        for (i = 0; i < 8; i = i + 1) begin          //{chip,ba} = 0..7
            for (j = 0; j < 8; j = j + 1) begin
                base = {i[2:0], 13'h0555, 10'(j)};
                preload_wr(base, 16'hD000 ^ 16'(i*256 + j));
            end
            if (i == 3) begin                        //refresh must coexist
                @(negedge clk); rfsh = 1'b1; @(negedge clk); rfsh = 1'b0;
            end
        end
        //verify every word through i_PRELOAD_RD
        for (i = 0; i < 8; i = i + 1) begin
            for (j = 0; j < 8; j = j + 1) begin
                base = {i[2:0], 13'h0555, 10'(j)};
                preload_rd(base, d);
                check16($sformatf("S9 verify c%0db%0d w%0d", i[2], i[1:0], j),
                        d, 16'hD000 ^ 16'(i*256 + j));
            end
        end
        //loader-style mirror duplication at row 0x556, then slot reads.
        //pair1 = global banks 0/1 (port 0), pair2 = global banks 2/3 (port 4)
        for (j = 0; j < 4; j = j + 1) begin
            preload_wr({3'd0, 13'h0556, 10'(j)}, 16'hE500 ^ 16'(j));
            preload_wr({3'd1, 13'h0556, 10'(j)}, 16'hE500 ^ 16'(j));   //mirror copy
            preload_wr({3'd2, 13'h0556, 10'(j)}, 16'hE600 ^ 16'(j));
            preload_wr({3'd3, 13'h0556, 10'(j)}, 16'hE600 ^ 16'(j));   //mirror copy
        end
        pl_en = 1'b0;
        fire_read(0, {13'h0556, 10'd0}); wait_rdy(0);
        check64("S9 port0 read of preloaded", slot_do(0),
                {16'hE500 ^ 16'd3, 16'hE500 ^ 16'd2, 16'hE500 ^ 16'd1, 16'hE500 ^ 16'd0});
        fire_read(4, {13'h0556, 10'd0}); wait_rdy(4);
        check64("S9 port4 read of preloaded", slot_do(4),
                {16'hE600 ^ 16'd3, 16'hE600 ^ 16'd2, 16'hE600 ^ 16'd1, 16'hE600 ^ 16'd0});
        $display("[S9] preload write/verify/mirror ok");
    end

    //S10: random soak with scoreboard over all 12 regions
    for (i = 0; i < 400; i = i + 1) begin
        automatic int r = $urandom_range(0, 11);
        if (r < 8) begin
            automatic logic [22:0] ad = {$urandom_range(0, 255) [7:0], $urandom_range(0, 255) [7:0]} & 23'h00_FFFC;
            rom_read(r, ad); wait_rdy(rport(r));
            check64($sformatf("S10.%0d region%0d", i, r), slot_do(rport(r)), rom_rexp(r, ad));
        end
        else begin
            automatic logic [22:0] ad = 23'($urandom_range(0, 16383));
            if ($urandom_range(0, 1)) begin
                automatic logic [15:0] d = 16'($urandom());
                rw_write(r, ad, d); wait_rdy(rport(r));
                rw_note(r, ad, d);
            end
            else begin
                rw_read(r, ad); wait_rdy(rport(r));
                check16($sformatf("S10.%0d region%0d", i, r), slot_do(rport(r))[15:0], rw_exp(r, ad));
            end
        end
        //sprinkle refresh
        if (i % 100 == 50) begin
            @(negedge clk); rfsh = 1'b1; @(negedge clk); rfsh = 1'b0;
        end
    end
    $display("[S10] random soak ok");

    $display("latency: n=%0d avg=%0d max=%0d cycles (%.1f / %.1f ns at %0dMHz)",
             lat_n, lat_sum / lat_n, lat_max,
             real'(lat_sum) / real'(lat_n) * PERIOD, real'(lat_max) * PERIOD, FREQ);
    if (errors == 0) $display("ALL SCENARIOS PASSED");
    else             $display("FAILED with %0d error(s)", errors);
    $finish;
end

//global watchdog
initial begin
    #6_000_000;   //6ms
    $display("FATAL: global watchdog");
    $finish;
end

//cycle-level trace for debugging (negedge: post-NBA, mid-cycle stable values)
`ifdef TRACE
always @(negedge clk) begin
    if (cycle >= `TRACE_FROM && cycle <= `TRACE_TO) begin
        $display("C%0d pins{ras%b cas%b we%b cs%b ba%b a%h} dq=%h oe%b rr=%h | u0{b%b t%0d rw%b c%0d s%0d bk%0d w=%h} u1{b%b t%0d rw%b c%0d s%0d bk%0d w=%h} | gr{v%b cl%0d s%0d bk%0d} pend=%b rdy=%b",
            cycle, sd_nras, sd_ncas, sd_nwe, sd_ncs, sd_ba, sd_a, sd_dq, dut.dq_oe, dut.rdata_reg,
            dut.u_busy[0], dut.u_type[0], dut.u_rw[0], dut.u_ctr[0], dut.u_slot[0], dut.u_bank[0], dut.u_word[0],
            dut.u_busy[1], dut.u_type[1], dut.u_rw[1], dut.u_ctr[1], dut.u_slot[1], dut.u_bank[1], dut.u_word[1],
            dut.gr_valid, dut.gr_class, dut.gr_slot, dut.gr_bank, busy_w, rdy_w);
    end
end
`endif

endmodule

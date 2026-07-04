/*
    ikautil_sdram - multi-port scheduled SDRAM controller for MiSTer 128MB module
    (2x AS4C32M16SB-7 sharing one bus; CS_n is a chip address bit: 0=chip0, 1=chip1)

    Scheduling model: each request is issued to an idle operation unit that
    replays a fixed microcode timeline (generated from docs/ikautil_sdram.xlsx
    by scripts/gen_ucode.py). All resource usage is known at issue time, so the
    SDRAM command outputs of all units are merged with a plain OR and issue
    legality is a parallel AND of per-class inhibit windows.

    DQM_SHARED=1 : MiSTer 128MB module - DQM pins are wired to A[12:11] on the
                   board; ACT placement is restricted by the DQM-shadow windows
                   (UCODE_SHR). DQML/DQMH outputs mirror A[12:11].
    DQM_SHARED=0 : dedicated DQM pins (Analogue Pocket / direct-routed chips);
                   spreadsheet windows verbatim (UCODE_DED).

    Bank map (global bank = {chip, ba[1:0]}):
      chip0: ba0/ba1 = ROM mirror pair, slots 0-3   ba2 = slot 8   ba3 = slot 9
      chip1: ba0/ba1 = ROM mirror pair, slots 4-7   ba2 = slot 10  ba3 = slot 11
    ROM data must be loaded identically into both banks of a mirror pair.

    Read data return, jtframe style: o_RDATA is the raw DQ capture register
    (same register jtframe calls dout - no extra latency); o_SLOTn_DST strobes
    when a slot's FIRST beat is on o_RDATA and the remaining beats follow on
    consecutive cycles. The assembled o_SLOTn_DO + o_SLOTn_RDY path is kept as
    a convenience (one extra register after the LAST beat only).

    Preload port (MiSTer IOCTL download): addresses the WHOLE SDRAM space,
    i_PRELOAD_A = {chip, ba[1:0], row[12:0], col[9:0]}. i_PRELOAD gates slot
    issue; one word per i_PRELOAD_WR strobe (BL=1 semantics - padding beats
    are DQM-masked), i_PRELOAD_RD reads back for verification. The loader is
    responsible for writing ROM mirror content to BOTH banks of a pair.
    Keep pulsing i_RFSH during long downloads so refresh continues.

    v1 notes:
      - request address ports are full 23-bit in-chip word addresses; SLOTn_SA
        is added inside (per-slot AW reduction is a synthesis-time detail)
      - writes never truncate: trailing burst beats beyond SLOTn_DW/16 are
        DQM-masked padding
      - number of ENABLED slots is limited by FREQ: <=70MHz: 12, <=95MHz: 8,
        above: 6 (issue-cone timing closure rule; the preload port is not
        counted, it is quiescent during normal operation)
*/

module ikautil_sdram #(
    parameter integer FREQ       = 110,
    parameter integer DQM_SHARED = 1,
    parameter integer CAP_DELAY  = 1,       //extra DQ capture latency (board/phase dependent)
    parameter integer INIT_PAUSE = 20000,   //cycles of power-up NOP
    parameter integer RFSHCNT    = 9,       //refresh commands queued per i_RFSH edge (per chip)

    parameter         SLOT0_EN = 1, SLOT1_EN = 1, SLOT2_EN  = 0, SLOT3_EN  = 0,
                      SLOT4_EN = 1, SLOT5_EN = 1, SLOT6_EN  = 0, SLOT7_EN  = 0,
                      SLOT8_EN = 1, SLOT9_EN = 0, SLOT10_EN = 1, SLOT11_EN = 0,

    parameter [22:0]  SLOT0_SA = 23'h00_0000, SLOT1_SA = 23'h10_0000, SLOT2_SA  = 23'h20_0000, SLOT3_SA  = 23'h30_0000,
                      SLOT4_SA = 23'h00_0000, SLOT5_SA = 23'h10_0000, SLOT6_SA  = 23'h20_0000, SLOT7_SA  = 23'h30_0000,
                      SLOT8_SA = 23'h00_0000, SLOT9_SA = 23'h00_0000, SLOT10_SA = 23'h00_0000, SLOT11_SA = 23'h00_0000,

    parameter integer SLOT0_DW = 64, SLOT1_DW = 64, SLOT2_DW  = 64, SLOT3_DW  = 64,
                      SLOT4_DW = 64, SLOT5_DW = 64, SLOT6_DW  = 64, SLOT7_DW  = 64,
                      SLOT8_DW = 16, SLOT9_DW = 16, SLOT10_DW = 16, SLOT11_DW = 16
    ) (
    input   wire            i_CLK,
    input   wire            i_RST_n,

    input   wire            i_RFSH,         //refresh burst trigger, tie to hblank
    output  wire            o_INIT_DONE,

    //global preload/verify port (MiSTer IOCTL download; whole-SDRAM addressing)
    input   wire            i_PRELOAD,      //preload mode enable: gates slot issue
    input   wire    [25:0]  i_PRELOAD_A,    //{chip, ba[1:0], row[12:0], col[9:0]}
    input   wire    [15:0]  i_PRELOAD_DI,
    input   wire            i_PRELOAD_WR,   //1-cycle strobe: write one word (BL=1)
    input   wire            i_PRELOAD_RD,   //1-cycle strobe: read one word back
    output  wire            o_PRELOAD_BUSY,
    output  wire    [15:0]  o_PRELOAD_DO,

    //jtframe-style early read data (see header)
    output  wire    [15:0]  o_RDATA,

    //SDRAM bus (MiSTer emu port shape)
    inout   wire    [15:0]  io_SDRAM_DQ,
    output  reg     [12:0]  o_SDRAM_A,
    output  reg     [1:0]   o_SDRAM_BA,
    output  reg             o_SDRAM_nCS,    //chip address bit on the 128MB module
    output  reg             o_SDRAM_nRAS,
    output  reg             o_SDRAM_nCAS,
    output  reg             o_SDRAM_nWE,
    output  reg             o_SDRAM_DQML,
    output  reg             o_SDRAM_DQMH,
    output  wire            o_SDRAM_CKE,

    //SLOT0-7: read-only ROM ports
    output  wire            o_SLOT0_BUSY, o_SLOT1_BUSY, o_SLOT2_BUSY, o_SLOT3_BUSY,
                            o_SLOT4_BUSY, o_SLOT5_BUSY, o_SLOT6_BUSY, o_SLOT7_BUSY,
    output  wire            o_SLOT0_RDY,  o_SLOT1_RDY,  o_SLOT2_RDY,  o_SLOT3_RDY,
                            o_SLOT4_RDY,  o_SLOT5_RDY,  o_SLOT6_RDY,  o_SLOT7_RDY,
    output  wire            o_SLOT0_DST,  o_SLOT1_DST,  o_SLOT2_DST,  o_SLOT3_DST,
                            o_SLOT4_DST,  o_SLOT5_DST,  o_SLOT6_DST,  o_SLOT7_DST,
    input   wire            i_SLOT0_RD,   i_SLOT1_RD,   i_SLOT2_RD,   i_SLOT3_RD,
                            i_SLOT4_RD,   i_SLOT5_RD,   i_SLOT6_RD,   i_SLOT7_RD,
    input   wire    [22:0]  i_SLOT0_A,    i_SLOT1_A,    i_SLOT2_A,    i_SLOT3_A,
                            i_SLOT4_A,    i_SLOT5_A,    i_SLOT6_A,    i_SLOT7_A,
    output  wire    [SLOT0_DW-1:0]  o_SLOT0_DO,
    output  wire    [SLOT1_DW-1:0]  o_SLOT1_DO,
    output  wire    [SLOT2_DW-1:0]  o_SLOT2_DO,
    output  wire    [SLOT3_DW-1:0]  o_SLOT3_DO,
    output  wire    [SLOT4_DW-1:0]  o_SLOT4_DO,
    output  wire    [SLOT5_DW-1:0]  o_SLOT5_DO,
    output  wire    [SLOT6_DW-1:0]  o_SLOT6_DO,
    output  wire    [SLOT7_DW-1:0]  o_SLOT7_DO,

    //SLOT8-11: read/write ports
    output  wire            o_SLOT8_BUSY, o_SLOT9_BUSY, o_SLOT10_BUSY, o_SLOT11_BUSY,
    output  wire            o_SLOT8_RDY,  o_SLOT9_RDY,  o_SLOT10_RDY,  o_SLOT11_RDY,
    output  wire            o_SLOT8_DST,  o_SLOT9_DST,  o_SLOT10_DST,  o_SLOT11_DST,
    input   wire            i_SLOT8_RD,   i_SLOT9_RD,   i_SLOT10_RD,   i_SLOT11_RD,
    input   wire            i_SLOT8_WR,   i_SLOT9_WR,   i_SLOT10_WR,   i_SLOT11_WR,
    input   wire    [22:0]  i_SLOT8_A,    i_SLOT9_A,    i_SLOT10_A,    i_SLOT11_A,
    input   wire    [SLOT8_DW-1:0]   i_SLOT8_DI,
    input   wire    [SLOT9_DW-1:0]   i_SLOT9_DI,
    input   wire    [SLOT10_DW-1:0]  i_SLOT10_DI,
    input   wire    [SLOT11_DW-1:0]  i_SLOT11_DI,
    output  wire    [SLOT8_DW-1:0]   o_SLOT8_DO,
    output  wire    [SLOT9_DW-1:0]   o_SLOT9_DO,
    output  wire    [SLOT10_DW-1:0]  o_SLOT10_DO,
    output  wire    [SLOT11_DW-1:0]  o_SLOT11_DO
);


//
//  microcode tables (generated - includes UC_* timing localparams)
//

`include "ikautil_sdram_ucode.svh"

//ucode word fields
`define UC_CMD(w)    w[2:0]
`define UC_OE(w)     w[3]
`define UC_CAP(w)    w[4]
`define UC_BEAT(w)   w[7:5]
`define UC_LAST(w)   w[8]
`define UC_INH_SC(w) w[12:9]     //{actW, actR, colW, colR} same chip
`define UC_INH_DC(w) w[16:13]    //{actW, actR, colW, colR} other chip
`define UC_INHCMD(w) w[17]

localparam CMD_NOP = 3'd0, CMD_ACT = 3'd1, CMD_READ = 3'd2,
           CMD_WRITE = 3'd3, CMD_PRE = 3'd4, CMD_REF = 3'd5;

//elaboration checks
localparam integer SLOT_LIMIT = (FREQ <= 70) ? 12 : (FREQ <= 95) ? 8 : 6;
localparam integer NSLOT_EN = SLOT0_EN+SLOT1_EN+SLOT2_EN+SLOT3_EN+SLOT4_EN+SLOT5_EN
                            + SLOT6_EN+SLOT7_EN+SLOT8_EN+SLOT9_EN+SLOT10_EN+SLOT11_EN;
initial begin
    if (FREQ != UC_FREQ)         $error("FREQ parameter does not match generated ucode; rerun gen_ucode.py");
    if (NSLOT_EN > SLOT_LIMIT)   $error("too many enabled slots for this frequency (limit %0d)", SLOT_LIMIT);
    if (FREQ > 132)              $error("FREQ above supported ceiling (132)");
end


//
//  per-slot static properties
//

localparam integer NSLOT = 12;
localparam integer NUNIT = 3;
localparam integer PLIDX = 12;   //internal pseudo-slot index of the preload port

wire [NSLOT-1:0] slot_en = {SLOT11_EN[0], SLOT10_EN[0], SLOT9_EN[0], SLOT8_EN[0],
                            SLOT7_EN[0],  SLOT6_EN[0],  SLOT5_EN[0], SLOT4_EN[0],
                            SLOT3_EN[0],  SLOT2_EN[0],  SLOT1_EN[0], SLOT0_EN[0]};
wire [NSLOT-1:0] slot_rom = 12'h0FF;                      //slots 0-7 read-only mirror pairs
wire [NSLOT-1:0] slot_chip = 12'b1100_1111_0000;          //slots 4-7,10,11 on chip1

function automatic [1:0] slot_ba0(input integer s);       //primary bank within chip
    slot_ba0 = (s < 8) ? 2'd0 : (s == 8 || s == 10) ? 2'd2 : 2'd3;
endfunction

wire [22:0] slot_sa   [0:NSLOT-1];
assign slot_sa[0]=SLOT0_SA; assign slot_sa[1]=SLOT1_SA; assign slot_sa[2]=SLOT2_SA;  assign slot_sa[3]=SLOT3_SA;
assign slot_sa[4]=SLOT4_SA; assign slot_sa[5]=SLOT5_SA; assign slot_sa[6]=SLOT6_SA;  assign slot_sa[7]=SLOT7_SA;
assign slot_sa[8]=SLOT8_SA; assign slot_sa[9]=SLOT9_SA; assign slot_sa[10]=SLOT10_SA; assign slot_sa[11]=SLOT11_SA;

wire [3:0] slot_beats [0:NSLOT];    //real data beats = DW/16
assign slot_beats[0]=SLOT0_DW/16; assign slot_beats[1]=SLOT1_DW/16; assign slot_beats[2]=SLOT2_DW/16;  assign slot_beats[3]=SLOT3_DW/16;
assign slot_beats[4]=SLOT4_DW/16; assign slot_beats[5]=SLOT5_DW/16; assign slot_beats[6]=SLOT6_DW/16;  assign slot_beats[7]=SLOT7_DW/16;
assign slot_beats[8]=SLOT8_DW/16; assign slot_beats[9]=SLOT9_DW/16; assign slot_beats[10]=SLOT10_DW/16; assign slot_beats[11]=SLOT11_DW/16;
assign slot_beats[PLIDX] = 4'd1;    //preload: BL=1 semantics


//
//  frontend: request capture, one outstanding per slot
//

reg  [NSLOT:0]   pending, pend_wr;    //bit 12 = preload port
reg  [NSLOT:0]   in_flight;           //request issued to a unit, awaiting completion
reg  [22:0]      req_addr [0:NSLOT];
reg  [63:0]      req_di   [0:NSLOT];
reg  [63:0]      req_do   [0:NSLOT];
reg  [NSLOT:0]   rdy;
reg  [2:0]       pl_bank;             //preload target bank {chip, ba}

wire [NSLOT-1:0] rd_in = {i_SLOT11_RD, i_SLOT10_RD, i_SLOT9_RD, i_SLOT8_RD,
                          i_SLOT7_RD,  i_SLOT6_RD,  i_SLOT5_RD, i_SLOT4_RD,
                          i_SLOT3_RD,  i_SLOT2_RD,  i_SLOT1_RD, i_SLOT0_RD};
wire [NSLOT-1:0] wr_in = {i_SLOT11_WR, i_SLOT10_WR, i_SLOT9_WR, i_SLOT8_WR, 8'h00};
wire [22:0] a_in  [0:NSLOT-1];
assign a_in[0]=i_SLOT0_A; assign a_in[1]=i_SLOT1_A; assign a_in[2]=i_SLOT2_A;  assign a_in[3]=i_SLOT3_A;
assign a_in[4]=i_SLOT4_A; assign a_in[5]=i_SLOT5_A; assign a_in[6]=i_SLOT6_A;  assign a_in[7]=i_SLOT7_A;
assign a_in[8]=i_SLOT8_A; assign a_in[9]=i_SLOT9_A; assign a_in[10]=i_SLOT10_A; assign a_in[11]=i_SLOT11_A;
wire [63:0] di_in [0:NSLOT-1];
assign di_in[0]='0; assign di_in[1]='0; assign di_in[2]='0;  assign di_in[3]='0;
assign di_in[4]='0; assign di_in[5]='0; assign di_in[6]='0;  assign di_in[7]='0;
assign di_in[8]=64'(i_SLOT8_DI); assign di_in[9]=64'(i_SLOT9_DI);
assign di_in[10]=64'(i_SLOT10_DI); assign di_in[11]=64'(i_SLOT11_DI);

reg  [NSLOT-1:0] rd_z, wr_z;
wire [NSLOT:0]   slot_done;   //driven by op units below

genvar gs;
generate for (gs = 0; gs < NSLOT; gs = gs + 1) begin : g_frontend
    always @(posedge i_CLK) begin
        if (!i_RST_n) begin
            rd_z[gs] <= 1'b0; wr_z[gs] <= 1'b0;
            pending[gs] <= 1'b0; pend_wr[gs] <= 1'b0; rdy[gs] <= 1'b0;
        end
        else begin
            rd_z[gs] <= rd_in[gs];
            wr_z[gs] <= wr_in[gs];
            rdy[gs]  <= slot_done[gs];
            if (!pending[gs] && slot_en[gs]) begin
                if (wr_in[gs] & ~wr_z[gs]) begin
                    pending[gs] <= 1'b1; pend_wr[gs] <= 1'b1;
                    req_addr[gs] <= slot_sa[gs] + a_in[gs];
                    req_di[gs]   <= di_in[gs];
                end
                else if (rd_in[gs] & ~rd_z[gs]) begin
                    pending[gs] <= 1'b1; pend_wr[gs] <= 1'b0;
                    req_addr[gs] <= slot_sa[gs] + a_in[gs];
                end
            end
            else if (slot_done[gs]) pending[gs] <= 1'b0;
        end
    end
end endgenerate

//preload port frontend: WR/RD are direct 1-cycle strobes, no edge detector
always @(posedge i_CLK) begin
    if (!i_RST_n) begin
        pending[PLIDX] <= 1'b0; pend_wr[PLIDX] <= 1'b0; rdy[PLIDX] <= 1'b0;
    end
    else begin
        rdy[PLIDX] <= slot_done[PLIDX];
        if (!pending[PLIDX] && i_PRELOAD) begin
            if (i_PRELOAD_WR || i_PRELOAD_RD) begin
                pending[PLIDX]  <= 1'b1;
                pend_wr[PLIDX]  <= i_PRELOAD_WR;
                req_addr[PLIDX] <= i_PRELOAD_A[22:0];
                pl_bank         <= i_PRELOAD_A[25:23];
                req_di[PLIDX]   <= {48'd0, i_PRELOAD_DI};
            end
        end
        else if (slot_done[PLIDX]) pending[PLIDX] <= 1'b0;
    end
end

assign o_PRELOAD_BUSY = pending[PLIDX];
assign o_PRELOAD_DO   = req_do[PLIDX][15:0];


//
//  bank tracker: 8 global banks = {chip, ba}
//

reg  [7:0]  bk_open;
reg  [12:0] bk_row  [0:7];
reg  [1:0]  bk_ops  [0:7];   //ops in flight on this bank
reg  [3:0]  bk_rc   [0:7];   //ACT->ACT same bank
reg  [3:0]  bk_ras  [0:7];   //ACT->PRE
reg  [3:0]  bk_rp   [0:7];   //PRE->ACT
reg  [3:0]  bk_wr   [0:7];   //last write beat->PRE

wire [7:0] bk_can_act, bk_can_pre;
genvar gb;
generate for (gb = 0; gb < 8; gb = gb + 1) begin : g_bkguard
    assign bk_can_act[gb] = ~bk_open[gb] && bk_ops[gb] == 2'd0 && bk_rc[gb] == 4'd0 && bk_rp[gb] == 4'd0;
    assign bk_can_pre[gb] =  bk_open[gb] && bk_ops[gb] == 2'd0 && bk_ras[gb] == 4'd0 && bk_wr[gb] == 4'd0;
end endgenerate


//
//  operation units
//

reg             u_busy  [0:NUNIT-1];
reg  [4:0]      u_ctr   [0:NUNIT-1];
reg             u_chip  [0:NUNIT-1];
reg  [1:0]      u_type  [0:NUNIT-1];  //0 col, 1 act, 2 ref
reg             u_rw    [0:NUNIT-1];  //0 R, 1 W
reg  [2:0]      u_bank  [0:NUNIT-1];  //global bank
reg  [12:0]     u_row   [0:NUNIT-1];
reg  [9:0]      u_col   [0:NUNIT-1];
reg  [3:0]      u_slot  [0:NUNIT-1];
reg  [3:0]      u_beats [0:NUNIT-1];

//microcode lookup (LUTRAM async read); variant selected by DQM_SHARED
wire [17:0] u_word [0:NUNIT-1];
generate for (gb = 0; gb < NUNIT; gb = gb + 1) begin : g_uword
    wire [8:0] uaddr = {u_chip[gb], u_type[gb], u_rw[gb], u_ctr[gb]};
    assign u_word[gb] = !u_busy[gb] ? 18'd0 :
                        (DQM_SHARED != 0) ? UCODE_SHR[uaddr] : UCODE_DED[uaddr];
end endgenerate

//merged inhibit vectors per candidate chip: {actW, actR, colW, colR}
reg [3:0] inh_chip [0:1];
reg       inh_cmd;
integer mi;
always @(*) begin
    inh_chip[0] = 4'd0; inh_chip[1] = 4'd0; inh_cmd = 1'b0;
    for (mi = 0; mi < NUNIT; mi = mi + 1) begin
        inh_chip[0] = inh_chip[0] | (u_chip[mi] == 1'b0 ? `UC_INH_SC(u_word[mi]) : `UC_INH_DC(u_word[mi]));
        inh_chip[1] = inh_chip[1] | (u_chip[mi] == 1'b1 ? `UC_INH_SC(u_word[mi]) : `UC_INH_DC(u_word[mi]));
        inh_cmd     = inh_cmd | `UC_INHCMD(u_word[mi]);
    end
end

wire [NUNIT-1:0] u_idle;
generate for (gb = 0; gb < NUNIT; gb = gb + 1) begin : g_uidle
    assign u_idle[gb] = ~u_busy[gb];
end endgenerate
wire       unit_free = |u_idle;
wire [1:0] free_unit = u_idle[0] ? 2'd0 : u_idle[1] ? 2'd1 : 2'd2;

//per-chip: refresh in progress (blocks back-to-back REF, tRFC per chip)
wire ref_act_c0 = (u_busy[0] && u_type[0]==2'd2 && !u_chip[0]) || (u_busy[1] && u_type[1]==2'd2 && !u_chip[1]) || (u_busy[2] && u_type[2]==2'd2 && !u_chip[2]);
wire ref_act_c1 = (u_busy[0] && u_type[0]==2'd2 &&  u_chip[0]) || (u_busy[1] && u_type[1]==2'd2 &&  u_chip[1]) || (u_busy[2] && u_type[2]==2'd2 &&  u_chip[2]);


//
//  refresh engine: debt accumulates on i_RFSH edge, drains at top priority
//

reg  [7:0] rfsh_debt;   //counts single-chip refreshes remaining (2x RFSHCNT per trigger)
reg        rfsh_chip;
reg        rfsh_z;
wire       rfsh_busy = rfsh_debt != 8'd0;

wire       rfsh_all_closed = rfsh_chip ? (bk_open[7:4] == 4'd0 && bk_ops[4]==0 && bk_ops[5]==0 && bk_ops[6]==0 && bk_ops[7]==0
                                          && bk_rp[4]==0 && bk_rp[5]==0 && bk_rp[6]==0 && bk_rp[7]==0)
                                       : (bk_open[3:0] == 4'd0 && bk_ops[0]==0 && bk_ops[1]==0 && bk_ops[2]==0 && bk_ops[3]==0
                                          && bk_rp[0]==0 && bk_rp[1]==0 && bk_rp[2]==0 && bk_rp[3]==0);
//first open+precharge-able bank on the refresh target chip
reg  [2:0] rfsh_pre_bank;
reg        rfsh_pre_ok;
integer ri;
always @(*) begin
    rfsh_pre_ok = 1'b0; rfsh_pre_bank = 3'd0;
    for (ri = 3; ri >= 0; ri = ri - 1) begin
        if (bk_open[{rfsh_chip, 2'(ri)}] && bk_can_pre[{rfsh_chip, 2'(ri)}]) begin
            rfsh_pre_ok = 1'b1;
            rfsh_pre_bank = {rfsh_chip, 2'(ri)};
        end
    end
end


//
//  issue stage: parallel legality, static priority (refresh > slot 0..11)
//

//candidate classification per slot
wire [NSLOT-1:0] c_valid;
wire [2:0]  c_class [0:NSLOT-1];  //0 colR,1 colW,2 actR,3 actW,4 pre
wire [2:0]  c_bank  [0:NSLOT-1];
genvar gc;
generate for (gc = 0; gc < NSLOT; gc = gc + 1) begin : g_cand
    wire        chip = slot_chip[gc];
    wire [2:0]  b0 = {chip, slot_ba0(gc)};
    wire [2:0]  b1 = {chip, 2'd1};                       //mirror partner (ROM slots only)
    wire [12:0] row = req_addr[gc][22:10];
    wire        m0 = bk_open[b0] && bk_row[b0] == row;
    wire        m1 = slot_rom[gc] && bk_open[b1] && bk_row[b1] == row;
    wire        rw = pend_wr[gc];

    //bank & class selection: open-row hit > activate a closed bank > relatch
    wire        sel_col  = m0 | m1;
    wire [2:0]  col_bank = m0 ? b0 : b1;
    wire        sel_act  = !sel_col && (bk_can_act[b0] || (slot_rom[gc] && bk_can_act[b1]));
    wire [2:0]  act_bank = bk_can_act[b0] ? b0 : b1;
    wire        sel_pre  = !sel_col && !sel_act && (bk_can_pre[b0] || (slot_rom[gc] && bk_can_pre[b1]));
    wire [2:0]  pre_bank = bk_can_pre[b0] ? b0 : b1;

    //inhibit lookup for this candidate's class
    wire        inh = sel_col ? inh_chip[chip][{1'b0, rw}]
                              : inh_chip[chip][{1'b1, rw}];

    assign c_class[gc] = sel_col ? {2'b00, rw} : sel_act ? {2'b01, rw} : 3'd4;
    assign c_bank[gc]  = sel_col ? col_bank : sel_act ? act_bank : pre_bank;
    assign c_valid[gc] = pending[gc] && !in_flight[gc] && slot_en[gc] &&
                         !rfsh_busy && !i_PRELOAD &&
                         ( (sel_col && !inh && unit_free) ||
                           (sel_act && !inh && unit_free) ||
                           (sel_pre && !inh_cmd) );
end endgenerate

//preload candidate: explicit bank from the full address, otherwise identical
wire        pl_rw      = pend_wr[PLIDX];
wire        pl_m       = bk_open[pl_bank] && bk_row[pl_bank] == req_addr[PLIDX][22:10];
wire        pl_sel_col = pl_m;
wire        pl_sel_act = !pl_m && bk_can_act[pl_bank];
wire        pl_sel_pre = !pl_m && !pl_sel_act && bk_can_pre[pl_bank];
wire        pl_inh     = pl_sel_col ? inh_chip[pl_bank[2]][{1'b0, pl_rw}]
                                    : inh_chip[pl_bank[2]][{1'b1, pl_rw}];
wire [2:0]  pl_class   = pl_sel_col ? {2'b00, pl_rw} : pl_sel_act ? {2'b01, pl_rw} : 3'd4;
wire        pl_valid   = pending[PLIDX] && !in_flight[PLIDX] && !rfsh_busy &&
                         ( ((pl_sel_col || pl_sel_act) && !pl_inh && unit_free) ||
                           (pl_sel_pre && !inh_cmd) );

//grant: refresh first, then lowest slot index
reg        gr_valid;
reg  [3:0] gr_slot;
reg  [2:0] gr_class;   //0 colR,1 colW,2 actR,3 actW,4 pre,5 ref
reg  [2:0] gr_bank;
integer gi;
always @(*) begin
    gr_valid = 1'b0; gr_slot = 4'd0; gr_class = 3'd0; gr_bank = 3'd0;
    if (rfsh_busy && o_INIT_DONE) begin
        if (rfsh_all_closed && unit_free && !inh_cmd &&
            !(rfsh_chip ? ref_act_c1 : ref_act_c0)) begin
            gr_valid = 1'b1; gr_class = 3'd5; gr_bank = {rfsh_chip, 2'd0};
        end
        else if (!rfsh_all_closed && rfsh_pre_ok && !inh_cmd) begin
            gr_valid = 1'b1; gr_class = 3'd4; gr_bank = rfsh_pre_bank;
        end
    end
    else if (o_INIT_DONE) begin
        if (pl_valid) begin
            gr_valid = 1'b1; gr_slot = 4'(PLIDX);
            gr_class = pl_class; gr_bank = pl_bank;
        end
        else begin
            for (gi = NSLOT-1; gi >= 0; gi = gi - 1) begin
                if (c_valid[gi]) begin
                    gr_valid = 1'b1; gr_slot = 4'(gi);
                    gr_class = c_class[gi]; gr_bank = c_bank[gi];
                end
            end
        end
    end
end

//registered PRE micro-op (uniform 2-stage pipe with the op units)
reg        pre_pend;
reg  [2:0] pre_bank_r;

//unit load & PRE stage
integer ui;
always @(posedge i_CLK) begin
    if (!i_RST_n) begin
        pre_pend <= 1'b0;
        in_flight <= '0;
        for (ui = 0; ui < NUNIT; ui = ui + 1) begin
            u_busy[ui] <= 1'b0; u_ctr[ui] <= 5'd0;
        end
        rfsh_debt <= 8'd0; rfsh_chip <= 1'b0; rfsh_z <= 1'b0;
    end
    else begin
        pre_pend <= 1'b0;
        in_flight <= in_flight & ~slot_done;
        //advance running units
        for (ui = 0; ui < NUNIT; ui = ui + 1) begin
            if (u_busy[ui]) begin
                u_ctr[ui] <= u_ctr[ui] + 5'd1;
                if (`UC_LAST(u_word[ui])) u_busy[ui] <= 1'b0;
            end
        end
        //refresh debt
        rfsh_z <= i_RFSH;
        if (i_RFSH & ~rfsh_z) rfsh_debt <= rfsh_debt + 8'(2 * RFSHCNT);
        //grants
        if (gr_valid) begin
            case (gr_class)
                3'd4: begin
                    pre_pend   <= 1'b1;
                    pre_bank_r <= gr_bank;
                end
                3'd5: begin
                    u_busy[free_unit] <= 1'b1; u_ctr[free_unit] <= 5'd0;
                    u_chip[free_unit] <= gr_bank[2]; u_type[free_unit] <= 2'd2;
                    u_rw[free_unit]   <= 1'b0; u_bank[free_unit] <= gr_bank;
                    rfsh_debt <= rfsh_debt - 8'd1;
                    rfsh_chip <= ~rfsh_chip;
                end
                default: begin
                    u_busy[free_unit] <= 1'b1; u_ctr[free_unit] <= 5'd0;
                    u_chip[free_unit] <= gr_bank[2];
                    u_type[free_unit] <= {1'b0, gr_class[1]};   //0 col, 1 act
                    u_rw[free_unit]   <= gr_class[0];
                    u_bank[free_unit] <= gr_bank;
                    u_row[free_unit]  <= req_addr[gr_slot][22:10];
                    u_col[free_unit]  <= req_addr[gr_slot][9:0];
                    u_slot[free_unit] <= gr_slot;
                    u_beats[free_unit]<= slot_beats[gr_slot];
                    in_flight[gr_slot] <= 1'b1;
                end
            endcase
        end
    end
end

//bank tracker update
//per-bank op-count delta computed combinationally (multiple units may retire
//on the same bank in the same cycle as a new grant)
reg signed [2:0] bk_delta [0:7];
integer bd, bu;
always @(*) begin
    for (bd = 0; bd < 8; bd = bd + 1) begin
        bk_delta[bd] = 3'sd0;
        for (bu = 0; bu < NUNIT; bu = bu + 1) begin
            if (u_busy[bu] && `UC_LAST(u_word[bu]) && u_type[bu] != 2'd2 && u_bank[bu] == 3'(bd))
                bk_delta[bd] = bk_delta[bd] - 3'sd1;
        end
        if (gr_valid && gr_class < 3'd4 && gr_bank == 3'(bd))
            bk_delta[bd] = bk_delta[bd] + 3'sd1;
    end
end

integer bi;
always @(posedge i_CLK) begin
    if (!i_RST_n) begin
        bk_open <= 8'd0;
        for (bi = 0; bi < 8; bi = bi + 1) begin
            bk_ops[bi] <= 2'd0; bk_rc[bi] <= 4'd0; bk_ras[bi] <= 4'd0;
            bk_rp[bi] <= 4'd0; bk_wr[bi] <= 4'd0;
        end
    end
    else begin
        for (bi = 0; bi < 8; bi = bi + 1) begin
            bk_ops[bi] <= 2'(3'(bk_ops[bi]) + 3'(bk_delta[bi]));
            if (bk_rc[bi]  != 4'd0) bk_rc[bi]  <= bk_rc[bi]  - 4'd1;
            if (bk_ras[bi] != 4'd0) bk_ras[bi] <= bk_ras[bi] - 4'd1;
            if (bk_rp[bi]  != 4'd0) bk_rp[bi]  <= bk_rp[bi]  - 4'd1;
            if (bk_wr[bi]  != 4'd0) bk_wr[bi]  <= bk_wr[bi]  - 4'd1;
        end
        //write recovery: reload while any unit streams write beats to a bank
        for (bi = 0; bi < NUNIT; bi = bi + 1) begin
            if (u_busy[bi] && `UC_OE(u_word[bi])) bk_wr[u_bank[bi]] <= 4'(UC_tWR);
        end
        //grants
        if (gr_valid) begin
            case (gr_class)
                3'd4: begin
                    bk_open[gr_bank] <= 1'b0;
                    bk_rp[gr_bank]   <= 4'(UC_tRP);
                end
                3'd5: ;   //refresh occupancy enforced by ucode inhibits
                default: begin
                    if (gr_class[1]) begin  //act
                        bk_open[gr_bank] <= 1'b1;
                        bk_row[gr_bank]  <= req_addr[gr_slot][22:10];
                        bk_rc[gr_bank]   <= 4'(UC_tRC);
                        bk_ras[gr_bank]  <= 4'(UC_tRAS);
                    end
                end
            endcase
        end
    end
end

//slot completion strobes
generate for (gs = 0; gs <= NSLOT; gs = gs + 1) begin : g_done
    assign slot_done[gs] = (u_busy[0] && `UC_LAST(u_word[0]) && u_type[0] != 2'd2 && u_slot[0] == 4'(gs)) ||
                           (u_busy[1] && `UC_LAST(u_word[1]) && u_type[1] != 2'd2 && u_slot[1] == 4'(gs)) ||
                           (u_busy[2] && `UC_LAST(u_word[2]) && u_type[2] != 2'd2 && u_slot[2] == 4'(gs));
end endgenerate


//
//  init sequencer (runs once per chip: PALL, 8x AREF, MRS)
//

localparam [12:0] MRS_WORD = {3'b000, 1'b0, 2'b00, 3'(UC_CL), 1'b0,
                              (UC_BL0 == 1) ? 3'd0 : (UC_BL0 == 2) ? 3'd1 : (UC_BL0 == 4) ? 3'd2 : 3'd3};
localparam [12:0] MRS_WORD1 = {3'b000, 1'b0, 2'b00, 3'(UC_CL), 1'b0,
                              (UC_BL1 == 1) ? 3'd0 : (UC_BL1 == 2) ? 3'd1 : (UC_BL1 == 4) ? 3'd2 : 3'd3};

reg  [31:0] init_ctr;
reg  [4:0]  init_step;   //per chip: 0 PALL, 1..8 AREF, 9 MRS, 10 done
reg         init_chip;
reg         init_cs;     //chip select latched with each init command
reg         init_done_r;
reg  [2:0]  init_cmd;
reg  [12:0] init_a;
assign o_INIT_DONE = init_done_r;

always @(posedge i_CLK) begin
    if (!i_RST_n) begin
        init_ctr <= 32'd0; init_step <= 5'd0; init_chip <= 1'b0; init_cs <= 1'b0;
        init_done_r <= 1'b0; init_cmd <= CMD_NOP; init_a <= 13'd0;
    end
    else if (!init_done_r) begin
        init_cmd <= CMD_NOP;
        init_ctr <= init_ctr + 32'd1;
        if (init_ctr >= INIT_PAUSE && init_ctr[3:0] == 4'd0) begin   //one command per 16 cycles
            init_cs <= init_chip;
            if (init_step == 5'd0)      begin init_cmd <= CMD_PRE; init_a <= 13'h400; init_step <= 5'd1; end
            else if (init_step <= 5'd8) begin init_cmd <= CMD_REF; init_step <= init_step + 5'd1; end
            else if (init_step == 5'd9) begin
                init_cmd  <= 3'd6;   //MRS (encoded locally)
                init_a    <= init_chip ? MRS_WORD1 : MRS_WORD;
                init_step <= 5'd10;
            end
            else begin                   //post-MRS settle slot (keeps init mux active)
                if (init_chip) init_done_r <= 1'b1;
                else begin init_chip <= 1'b1; init_step <= 5'd0; end
            end
        end
    end
end


//
//  command merge and pin registers (OR of one-hot sources)
//

//data output path: which unit drives / captures this cycle
reg  [1:0]  oe_unit;
reg         oe_any;
integer oi;
always @(*) begin
    oe_any = 1'b0; oe_unit = 2'd0;
    for (oi = 0; oi < NUNIT; oi = oi + 1) begin
        if (u_busy[oi] && `UC_OE(u_word[oi])) begin oe_any = 1'b1; oe_unit = 2'(oi); end
    end
end
wire [2:0]  oe_beat  = `UC_BEAT(u_word[oe_unit]);
wire [15:0] oe_data  = req_di[u_slot[oe_unit]][oe_beat*16 +: 16];
wire        oe_mask  = oe_any && ({1'b0, oe_beat} >= u_beats[oe_unit]);

//merge
reg  [2:0]  m_cmd;
reg  [12:0] m_a;
reg  [1:0]  m_ba;
reg         m_cs;
integer ci;
always @(*) begin
    m_cmd = CMD_NOP; m_a = 13'd0; m_ba = 2'd0; m_cs = 1'b0;
    if (!init_done_r) begin
        m_cmd = init_cmd; m_a = init_a; m_cs = init_cs;
    end
    else begin
        for (ci = 0; ci < NUNIT; ci = ci + 1) begin
            if (u_busy[ci] && `UC_CMD(u_word[ci]) != CMD_NOP) begin
                m_cmd = `UC_CMD(u_word[ci]);
                m_ba  = u_bank[ci][1:0];
                m_cs  = u_chip[ci];
                case (`UC_CMD(u_word[ci]))
                    CMD_ACT:  m_a = u_row[ci];
                    default:  m_a = {2'b00, 1'b0, u_col[ci]};   //READ/WRITE: A10=0, no auto-precharge
                endcase
            end
        end
        if (pre_pend) begin
            m_cmd = CMD_PRE; m_ba = pre_bank_r[1:0]; m_cs = pre_bank_r[2];
            m_a   = 13'd0;   //A10=0: single bank
        end
    end
end

//DQM value (write padding mask; 00 otherwise - reads are never masked)
wire [1:0] dqm_val = oe_mask ? 2'b11 : 2'b00;

//A[12:11] carry the DQM value on the 128MB module except during ACT/MRS
wire [12:0] m_a_final = (DQM_SHARED != 0 && init_done_r && m_cmd != CMD_ACT)
                        ? {dqm_val, m_a[10:0]} : m_a;

reg  [15:0] dq_out;
reg         dq_oe;
reg  [15:0] rdata_reg;
assign io_SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
assign o_SDRAM_CKE = 1'b1;

//power-up state: NOP on the command pins before reset propagates
initial begin
    {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} = 3'b111;
    o_SDRAM_nCS = 1'b0; o_SDRAM_A = 13'd0; o_SDRAM_BA = 2'd0;
    {o_SDRAM_DQMH, o_SDRAM_DQML} = 2'b00;
    dq_oe = 1'b0;
end

always @(posedge i_CLK) begin
    if (!i_RST_n) begin
        {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b111;
        o_SDRAM_nCS <= 1'b0; o_SDRAM_A <= 13'd0; o_SDRAM_BA <= 2'd0;
        {o_SDRAM_DQMH, o_SDRAM_DQML} <= 2'b00;
        dq_oe <= 1'b0; dq_out <= 16'd0; rdata_reg <= 16'd0;
    end
    else begin
        case (m_cmd)
            CMD_ACT:   {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b011;
            CMD_READ:  {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b101;
            CMD_WRITE: {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b100;
            CMD_PRE:   {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b010;
            CMD_REF:   {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b001;
            3'd6:      {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b000;   //MRS
            default:   {o_SDRAM_nRAS, o_SDRAM_nCAS, o_SDRAM_nWE} <= 3'b111;
        endcase
        o_SDRAM_A   <= m_a_final;
        o_SDRAM_BA  <= m_ba;
        o_SDRAM_nCS <= m_cs;
        //DQML/DQMH mirror A[12:11] in shared mode so single-chip boards behave identically
        {o_SDRAM_DQMH, o_SDRAM_DQML} <= (DQM_SHARED != 0) ? m_a_final[12:11] : dqm_val;
        dq_oe  <= oe_any;
        dq_out <= oe_data;
        rdata_reg <= io_SDRAM_DQ;
    end
end

//read data capture routing. At most one unit captures per cycle (DQ bus is
//exclusive by construction). CAP_DELAY shifts the capture point to match the
//board's SDRAM_CLK phase: 0 = model/zero-phase, 1 = typical hardware.
reg        cap_v;
reg  [3:0] cap_slot;
reg  [2:0] cap_beat;
integer di_;
always @(*) begin
    cap_v = 1'b0; cap_slot = 4'd0; cap_beat = 3'd0;
    for (di_ = 0; di_ < NUNIT; di_ = di_ + 1) begin
        if (u_busy[di_] && `UC_CAP(u_word[di_]) &&
            {1'b0, `UC_BEAT(u_word[di_])} < u_beats[di_]) begin
            cap_v    = 1'b1;
            cap_slot = u_slot[di_];
            cap_beat = `UC_BEAT(u_word[di_]);
        end
    end
end

wire       cap_v_eff;
wire [3:0] cap_slot_eff;
wire [2:0] cap_beat_eff;
generate if (CAP_DELAY == 0) begin : g_cap0
    assign {cap_v_eff, cap_slot_eff, cap_beat_eff} = {cap_v, cap_slot, cap_beat};
end
else begin : g_capn
    reg [7:0] cap_pipe [0:CAP_DELAY-1];
    integer cp;
    always @(posedge i_CLK) begin
        cap_pipe[0] <= {cap_v, cap_slot, cap_beat};
        for (cp = 1; cp < CAP_DELAY; cp = cp + 1) cap_pipe[cp] <= cap_pipe[cp-1];
    end
    assign {cap_v_eff, cap_slot_eff, cap_beat_eff} = cap_pipe[CAP_DELAY-1];
end endgenerate

always @(posedge i_CLK) begin
    if (cap_v_eff) req_do[cap_slot_eff][cap_beat_eff*16 +: 16] <= rdata_reg;
end

//jtframe-style early data: the raw capture register plus first-beat strobes.
//No register between the SDRAM capture and the core - same latency as
//jtframe's dout/dst pair. Later beats follow on consecutive cycles.
assign o_RDATA = rdata_reg;
wire [NSLOT-1:0] dst_w;
generate for (gs = 0; gs < NSLOT; gs = gs + 1) begin : g_dst
    assign dst_w[gs] = cap_v_eff && cap_beat_eff == 3'd0 && cap_slot_eff == 4'(gs);
end endgenerate


//
//  user-side outputs
//

assign {o_SLOT11_BUSY, o_SLOT10_BUSY, o_SLOT9_BUSY, o_SLOT8_BUSY,
        o_SLOT7_BUSY,  o_SLOT6_BUSY,  o_SLOT5_BUSY, o_SLOT4_BUSY,
        o_SLOT3_BUSY,  o_SLOT2_BUSY,  o_SLOT1_BUSY, o_SLOT0_BUSY} = pending[NSLOT-1:0];
assign {o_SLOT11_RDY, o_SLOT10_RDY, o_SLOT9_RDY, o_SLOT8_RDY,
        o_SLOT7_RDY,  o_SLOT6_RDY,  o_SLOT5_RDY, o_SLOT4_RDY,
        o_SLOT3_RDY,  o_SLOT2_RDY,  o_SLOT1_RDY, o_SLOT0_RDY} = rdy[NSLOT-1:0];
assign {o_SLOT11_DST, o_SLOT10_DST, o_SLOT9_DST, o_SLOT8_DST,
        o_SLOT7_DST,  o_SLOT6_DST,  o_SLOT5_DST, o_SLOT4_DST,
        o_SLOT3_DST,  o_SLOT2_DST,  o_SLOT1_DST, o_SLOT0_DST} = dst_w;
assign o_SLOT0_DO  = req_do[0][SLOT0_DW-1:0];
assign o_SLOT1_DO  = req_do[1][SLOT1_DW-1:0];
assign o_SLOT2_DO  = req_do[2][SLOT2_DW-1:0];
assign o_SLOT3_DO  = req_do[3][SLOT3_DW-1:0];
assign o_SLOT4_DO  = req_do[4][SLOT4_DW-1:0];
assign o_SLOT5_DO  = req_do[5][SLOT5_DW-1:0];
assign o_SLOT6_DO  = req_do[6][SLOT6_DW-1:0];
assign o_SLOT7_DO  = req_do[7][SLOT7_DW-1:0];
assign o_SLOT8_DO  = req_do[8][SLOT8_DW-1:0];
assign o_SLOT9_DO  = req_do[9][SLOT9_DW-1:0];
assign o_SLOT10_DO = req_do[10][SLOT10_DW-1:0];
assign o_SLOT11_DO = req_do[11][SLOT11_DW-1:0];


//
//  simulation self-checks
//

`ifdef SIMULATION
integer chk, ncmd;
always @(posedge i_CLK) begin
    if (i_RST_n && init_done_r) begin
        ncmd = pre_pend ? 1 : 0;
        for (chk = 0; chk < NUNIT; chk = chk + 1)
            if (u_busy[chk] && `UC_CMD(u_word[chk]) != CMD_NOP) ncmd = ncmd + 1;
        if (ncmd > 1) begin
            $display("%m: at time %t ERROR: command bus collision (%0d drivers)", $time, ncmd);
            $stop;
        end
    end
end
`endif

endmodule

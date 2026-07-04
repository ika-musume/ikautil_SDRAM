`timescale 1ns/1ps
/*
    MiSTer 128MB dual-chip SDRAM module (behavioral, for simulation)

    Wiring proven from DECAfpga/MemTest and the jtframe MISTER mode:
      - two 64MB chips (13-bit row x 10-bit col x 4 banks x 16 bit), AS4C32M16SB
        geometry, modeled with the jtframe-adapted Micron mt48lc16m16a2 expanded
        via parameters (col_bits=10, mem_sizes=8M-1)
      - CS_n is a chip ADDRESS bit: low selects chip0, high selects chip1
        (the board inverts it for chip1); exactly one chip sees every command
      - the chips' DQM pins are wired to the A[12:11] traces; the connector's
        DQML/DQMH pins are not routed to the chips (accepted but ignored here)
      - timing parameters overridden to AS4C32M16SB-7 values so the model's
        checkers enforce the real part
*/
module mister_128mb (
    input  wire         clk,
    inout  wire [15:0]  dq,
    input  wire [12:0]  a,
    input  wire [1:0]   ba,
    input  wire         ncs,
    input  wire         nras,
    input  wire         ncas,
    input  wire         nwe,
    input  wire         dqml,   //unused: DQM comes from a[12:11] on this module
    input  wire         dqmh,   //unused
    input  wire         cke
);

wire _unused = dqml ^ dqmh;

`ifdef PROBE_ARRAYS
initial begin
    #1000;
    $display("wrapper-scope: c0.B0[63..66]=%h %h %h %h  c1.B0[8255..8257]=%h %h %h",
             chip0.Bank0[63], chip0.Bank0[64], chip0.Bank0[65], chip0.Bank0[66],
             chip1.Bank0[8255], chip1.Bank0[8256], chip1.Bank0[8257]);
end
`endif

mt48lc16m16a2 #(
    .col_bits   (10),
    .mem_sizes  (8388607),
    .tRCD       (21.0),
    .tRP        (21.0),
    .tRAS       (42.0),
    .tRC        (63.0),
    .tRFC       (63.0),
    .tWRm       (14.0)
) chip0 (
    .Dq(dq), .Addr(a), .Ba(ba), .Clk(clk), .Cke(cke),
    .Cs_n(ncs),
    .Ras_n(nras), .Cas_n(ncas), .We_n(nwe),
    .Dqm({a[12], a[11]}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
);

mt48lc16m16a2 #(
    .col_bits   (10),
    .mem_sizes  (8388607),
    .tRCD       (21.0),
    .tRP        (21.0),
    .tRAS       (42.0),
    .tRC        (63.0),
    .tRFC       (63.0),
    .tWRm       (14.0)
) chip1 (
    .Dq(dq), .Addr(a), .Ba(ba), .Clk(clk), .Cke(cke),
    .Cs_n(~ncs),
    .Ras_n(nras), .Cas_n(ncas), .We_n(nwe),
    .Dqm({a[12], a[11]}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
);

endmodule

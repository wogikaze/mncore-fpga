// sdr_gw_pll: Gowin rPLL for the SDRAM controller clock (clkout) and the SDRAM pin clock (clkoutp).
//
//   f(clkout) = f(clkin) * (FBDIV_SEL + 1) / (IDIV_SEL + 1);  VCO = f(clkout) * ODIV_SEL (500..1250 MHz)
//   clkoutp   = clkout delayed by phase * 22.5 degrees, phase = DYN_PHASE ? psda : PSDA
//   (phase as seen by the rPLL's dynamic PSDA input; see the note in the SYNTHESIS branch)
//
// Examples for a 27 MHz input (IDIV_SEL = 0):  54 MHz FBDIV 1 ODIV 16, 81 MHz FBDIV 2 ODIV 8,
// 108 MHz FBDIV 3 ODIV 8, 135 MHz FBDIV 4 ODIV 4.
//
// Synthesis (SYNTHESIS defined, yosys default) instantiates rPLL. Otherwise a behavioral model is
// used (free-running clocks, for iverilog), or plain wires for verilator lint.
`ifndef VERILATOR
`timescale 1ns/1ps
`endif
`default_nettype none

/* verilator lint_off UNUSEDPARAM */  // the lint view (plain wires) does not use the PLL settings
module sdr_gw_pll #(
    parameter integer IDIV_SEL  = 0,
    parameter integer FBDIV_SEL = 3,
    parameter integer ODIV_SEL  = 8,
    parameter integer DYN_PHASE = 0,
    parameter integer PSDA      = 8,       // static phase (0..15) when DYN_PHASE = 0
    parameter         FCLKIN    = "27.0",
    parameter real    SIM_FIN_MHZ = 27.0
) (
    input  wire       clkin,
    input  wire [3:0] psda,                // dynamic phase (DYN_PHASE = 1)
    output wire       clkout,
    output wire       clkoutp,
    output wire       lock
);
`ifdef SYNTHESIS
    // The rPLL always runs in dynamic phase/duty mode; with DYN_PHASE = 0 the PSDA pins are tied to
    // the PSDA parameter. Reason (measured on the board, 2026-11-24): the static fuse PSDA_SEL = 8
    // did not give the same phase as the dynamic PSDA = 8 that the SDRAM sweep had measured, so the
    // static encoding is not used.
    localparam [3:0] PS4 = PSDA;
    wire [3:0] ph = (DYN_PHASE != 0) ? psda : PS4;
    rPLL #(
        .FCLKIN(FCLKIN),
        .IDIV_SEL(IDIV_SEL),
        .FBDIV_SEL(FBDIV_SEL),
        .ODIV_SEL(ODIV_SEL),
        .PSDA_SEL(PSDA),
        .DUTYDA_SEL(8),
        .DYN_DA_EN("true"),
        .CLKFB_SEL("internal"),
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clkin), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(ph), .DUTYDA(ph + 4'd8), .FDLY(4'b0),
        .CLKOUT(clkout), .CLKOUTP(clkoutp), .CLKOUTD(), .CLKOUTD3(), .LOCK(lock)
    );
`elsif VERILATOR
    assign clkout  = clkin;
    assign clkoutp = clkin;
    assign lock    = 1'b1;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [3:0] unused_psda = psda;         // only used by the rPLL / simulation model
    /* verilator lint_on UNUSEDSIGNAL */
`else
    // behavioral model: free-running output, phase taken from psda/PSDA at each edge
    localparam real PER_NS = 1000.0 * (IDIV_SEL + 1) / (SIM_FIN_MHZ * (FBDIV_SEL + 1));
    reg co = 1'b0, cp = 1'b0, lk = 1'b0;
    integer n = 0;
    wire [3:0] ph = (DYN_PHASE != 0) ? psda : PSDA;
    always #(PER_NS / 2.0) co = ~co;
    always @(co) cp <= #(PER_NS * ph / 16.0) co;
    always @(posedge co) begin
        n = n + 1;
        if (n == 64) lk <= 1'b1;
    end
    assign clkout  = co;
    assign clkoutp = cp;
    assign lock    = lk;
    wire unused_clkin = clkin;
`endif
endmodule
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire

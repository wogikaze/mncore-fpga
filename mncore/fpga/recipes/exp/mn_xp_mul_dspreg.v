// WP07 experiment only (not a recipe): a directly instantiated MULT18X18 that uses the
// DSP-internal registers (UG287 4.2.2: AREG, BREG, PIPE_REG, OUT_REG). yosys inference never
// sets them, so this checks whether nextpnr-himbaechel places and times them and what Fmax
// they give compared with fabric registers (mn_mul_pipe).
// Unsigned 18 x 18. Latency = AREG|BREG + PREG + OREG clocks.
module mn_xp_mul_dspreg #(
    parameter AREG = 1,
    parameter BREG = 1,
    parameter PREG = 0,
    parameter OREG = 1
) (
    input  wire        clk,
    input  wire [17:0] a,
    input  wire [17:0] b,
    output wire [35:0] p
);
    /* verilator lint_off PINCONNECTEMPTY */
    MULT18X18 #(
        .AREG(AREG[0]), .BREG(BREG[0]), .OUT_REG(OREG[0]), .PIPE_REG(PREG[0]),
        .ASIGN_REG(1'b0), .BSIGN_REG(1'b0), .SOA_REG(1'b0), .MULT_RESET_MODE("SYNC")
    ) u_mul (
        .A(a), .SIA(18'd0), .B(b), .SIB(18'd0),
        .ASIGN(1'b0), .BSIGN(1'b0), .ASEL(1'b0), .BSEL(1'b0),
        .CE(1'b1), .CLK(clk), .RESET(1'b0),
        .DOUT(p), .SOA(), .SOB()
    );
    /* verilator lint_on PINCONNECTEMPTY */
endmodule

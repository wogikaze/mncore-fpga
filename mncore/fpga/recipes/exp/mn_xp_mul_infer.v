// WP07 experiment only (not a recipe): a plain "a * b" with an input register and NOUT
// output registers. Shows how yosys (mul2dsp + dsp_map) splits a wide multiplication and
// that extra output registers do not help Fmax (no retiming in yosys / nextpnr).
module mn_xp_mul_infer #(
    parameter WA   = 18,
    parameter WB   = 18,
    parameter SGN  = 0,   // 1: signed operands
    parameter NOUT = 1    // number of output register stages (>= 1)
) (
    input  wire             clk,
    input  wire [WA-1:0]    a,
    input  wire [WB-1:0]    b,
    output wire [WA+WB-1:0] p
);
    reg [WA-1:0] ar;
    reg [WB-1:0] br;
    always @(posedge clk) begin
        ar <= a;
        br <= b;
    end

    wire [WA+WB-1:0] prod;
    generate
        if (SGN != 0) begin : g_s
            assign prod = $signed(ar) * $signed(br);
        end else begin : g_u
            assign prod = ar * br;
        end
    endgenerate

    reg [WA+WB-1:0] q [0:NOUT-1];
    integer k;
    always @(posedge clk) begin
        q[0] <= prod;
        for (k = 1; k < NOUT; k = k + 1) q[k] <= q[k-1];
    end
    assign p = q[NOUT-1];
endmodule

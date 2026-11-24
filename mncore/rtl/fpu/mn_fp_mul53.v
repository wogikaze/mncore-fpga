// mn_fp_mul53: significand product of the MN-Core 2 MAU (SDM 4.3), for mn_fp_fma (WP12).
//
// p = (2^52 + a) * (2^52 + b) with the partial-product rule of SDM 4.3, bits [105:16].
//   a, b: mantissas without the hidden bit, MSB-aligned in 52 bits
//         (double: the 52-bit field; single: {m23, 29'b0}; half: {m9, 43'b0}).
//   md (double): the products of the low 16 mantissa bits (A0 x B0) are dropped and, if not
//                zero, replaced by 2^30 (SDM eq. 4.8, 4.9).
//   mf (single): the products of the low 5 mantissa bits are dropped and replaced by 2^8
//                (eq. 4.6, 4.7); with the MSB alignment that is the A1 x B1 tile below.
//   half: exact.
// The product is a multiple of 2^16 in all three modes, so bits [15:0] are not produced.
//
// Tiles: a = A2:A1:A0 with A0 = a[15:0], A1 = a[33:16], A2 = a[51:34] (b alike).
//   (2^52 + a)(2^52 + b) - A0*B0 = 2^104 + 2^52 (a + b) + sum of the other 8 tile products.
//   The A0 x B0 tile is never needed (dropped in double, zero in single and half), so the
//   multiplier uses 8 DSP tiles (mn_mul_pipe 18x18 or 16x18, one MULT18X18 each).
//   In single mode A0 = B0 = 0 and A1 x B1 is exactly the dropped term, so that tile's
//   inputs are zeroed outside double mode.
//
// Pipeline: 2 clocks for the tiles (register, DSP, register), then 3 adder levels, one
// register each. Latency 5: p is the product of the inputs presented 5 clocks earlier.
module mn_fp_mul53 (
    input  wire        clk,
    input  wire [51:0] a,
    input  wire [51:0] b,
    input  wire        md,
    input  wire        mf,
    output reg  [89:0] p
);
    wire [15:0] a0 = a[15:0];
    wire [17:0] a1 = a[33:16];
    wire [17:0] a2 = a[51:34];
    wire [15:0] b0 = b[15:0];
    wire [17:0] b1 = b[33:16];
    wire [17:0] b2 = b[51:34];

    // ---- tiles (latency 2: input register, DSP, output register) ----
    wire [33:0] t01, t10, t02, t20;
    wire [35:0] t11, t12, t21, t22;
    mn_mul_pipe #(.WA(16), .WB(18), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t01 (.clk(clk), .ce(1'b1), .a(a0), .b(b1), .p(t01));
    mn_mul_pipe #(.WA(18), .WB(16), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t10 (.clk(clk), .ce(1'b1), .a(a1), .b(b0), .p(t10));
    mn_mul_pipe #(.WA(16), .WB(18), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t02 (.clk(clk), .ce(1'b1), .a(a0), .b(b2), .p(t02));
    mn_mul_pipe #(.WA(18), .WB(16), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t20 (.clk(clk), .ce(1'b1), .a(a2), .b(b0), .p(t20));
    mn_mul_pipe #(.WA(18), .WB(18), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t11 (.clk(clk), .ce(1'b1), .a(a1 & {18{md}}), .b(b1 & {18{md}}), .p(t11));
    mn_mul_pipe #(.WA(18), .WB(18), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t12 (.clk(clk), .ce(1'b1), .a(a1), .b(b2), .p(t12));
    mn_mul_pipe #(.WA(18), .WB(18), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t21 (.clk(clk), .ce(1'b1), .a(a2), .b(b1), .p(t21));
    mn_mul_pipe #(.WA(18), .WB(18), .TW(18), .IREG(1), .PREG(0), .LVLS(0))
        u_t22 (.clk(clk), .ce(1'b1), .a(a2), .b(b2), .p(t22));

    // ---- side path: hidden-bit terms and the correction of the dropped products ----
    reg [51:0] a_1, b_1;
    reg        cd_1, cf_1, cd_2, cf_2;
    reg [53:0] hb_2;
    always @(posedge clk) begin
        a_1  <= a;
        b_1  <= b;
        cd_1 <= md & (|a[15:0]) & (|b[15:0]);
        cf_1 <= mf & (|a[33:29]) & (|b[33:29]);
        // 2^52 (a + b) + 2^104 = 2^52 (a + b + 2^52)
        hb_2 <= {2'b00, a_1} + {2'b00, b_1} + {2'b01, 52'd0};
        cd_2 <= cd_1;
        cf_2 <= cf_1;
    end

    // ---- rows, in units of 2^16 (bit k = product bit k + 16) ----
    // T01, T10 at 2^16; T02, T20 at 2^34; T11 at 2^32; T12, T21 at 2^50; T22 at 2^68.
    // corrections: double 2^30, single 2^66 (in single mode T20 = 0, so the OR is exact).
    wire [89:0] r1 = {20'd0, t12, t01};
    wire [89:0] r2 = {20'd0, t21, t10};
    wire [89:0] r3 = {2'd0, t22, t02, 18'd0};
    wire [89:0] r4 = {38'd0, t20, 18'd0} | ({89'd0, cd_2} << 14) | ({89'd0, cf_2} << 50);
    wire [89:0] r5 = {38'd0, t11, 16'd0};
    wire [89:0] r6 = {hb_2, 36'd0};

    reg [89:0] s1_3, s2_3, s3_3, s4_4, s5_4;
    always @(posedge clk) begin
        s1_3 <= r1 + r2;
        s2_3 <= r3 + r4;
        s3_3 <= r5 + r6;
        s4_4 <= s1_3 + s2_3;
        s5_4 <= s3_3;
        p    <= s4_4 + s5_4;
    end
endmodule

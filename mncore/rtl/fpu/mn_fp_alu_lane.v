// mn_fp_alu_lane: per-element decisions of the FP ALU instructions for one format (W, EB, M).
//
// Used by mn_fp_alu for each element of the MSB long word: 1 x double, 2 x single, 4 x half.
// Gives the small per-element results (conditions, exponent fields, shift amounts); mn_fp_alu
// assembles the wide results once for the whole long word (SIMD). Purely combinational.
// Formats (SDM 1.3): no subnormals, no NaN; exponent 0 is zero and all ones is infinity,
// whatever the mantissa.
//
// Semantics are those of the official emulator, which agree with viz/core/src/machine.rs
// (alu_lanes, float_rsqrt, float_floor, float_lrelu, float_ftoi) on every vector.
module mn_fp_alu_lane #(
    parameter W  = 64,  // element width
    parameter EB = 11,  // exponent bits
    parameter M  = 52   // mantissa bits
) (
    input  wire [W-1:0]  a,           // element of input x (condition / operand)
    input  wire [W-1:0]  b,           // element of input y
    input  wire [2:0]    sop,         // simple op: 0 passa, 1 packbit, 2 relu, 3 rsqrt, 4 lrelu
    input  wire [1:0]    sub,         // relu: k (relu0..3); lrelu: 00 lrelud, 01 lreluo, 10 ilrelud
    input  wire          is_ftoi,     // shift amount for ftoi (else for floor)
    input  wire          is_unsigned,
    output reg           sflag,       // mask-flag condition of the simple op
    output wire          alt,         // relu: -0 instead of b; lrelu: the transformed b
    // rsqrt (float_rsqrt): 0 | rs_e | rs_m << (M - 5)
    output wire [EB-1:0] rs_e,
    output wire [4:0]    rs_m,
    // lrelud / lreluo / ilrelud of b (float_lrelu): b with exponent lr_e, or b (lr_keep), or -0
    output wire [EB-1:0] lr_e,
    output wire          lr_keep,
    output wire          lr_uf,
    // ftoi (float_ftoi)
    output wire          ft_zero,     // |a| < 1 (or zero): result 0
    output wire          ft_sat,      // out of the integer range (or infinity): saturate
    output wire          ft_neg,      // negate the magnitude (signed, negative, in range)
    // floor (float_floor)
    output wire          fl_keep,     // zero, infinity or already an integer: unchanged
    output wire          fl_small,    // 0 < |a| < 1: +0 or -1.0
    // shared right shifter: ftoi shifts {1, mantissa, 0..} by W - 1 - E (the magnitude);
    // floor shifts all ones by W - M + E (mask of the fraction bits). E = ea - BIAS.
    output wire [5:0]    amt,
    // max / min
    output wire          ez_a,        // exponent of a is 0 (a is zero)
    output wire          ez_b
);
    localparam integer BIAS = (1 << (EB - 1)) - 1;
    localparam [EB-1:0] EMAXV = {EB{1'b1}};

    wire [EB-1:0] ea = a[W-2:M];
    wire [EB-1:0] eb = b[W-2:M];
    wire          sa = a[W-1];
    wire [31:0]   ea32 = {{(32 - EB){1'b0}}, ea};

    // v >= k for a constant k, as plain logic (a compare operator would become a carry chain)
    function automatic ge_k(input [EB-1:0] v, input [EB:0] k);
        integer i;
        reg r;
        begin
            r = 1'b1;
            for (i = 0; i < EB; i = i + 1)
                r = (v[i] & ~k[i]) | (~(v[i] ^ k[i]) & r);
            ge_k = ~k[EB] & r;  // v < 2^EB <= k
        end
    endfunction

    assign ez_a = (ea == {EB{1'b0}});
    assign ez_b = (eb == {EB{1'b0}});

    // ---- ftoi: truncation toward zero, saturating to the element's integer range.
    // magnitude = {1, mantissa, 0..} >> (W - 1 - E) for 0 <= E <= W - 1. Unsigned ignores the
    // sign (the magnitude is returned).
    localparam integer FT_SAT_S = BIAS + W - 1;  // E >= W - 1: signed overflow (or -2^(W-1))
    localparam integer FT_SAT_U = BIAS + W;      // E >= W: unsigned overflow
    wire below1 = ~ea[EB-1] & ~(&ea[EB-2:0]);    // ea < BIAS
    assign ft_zero = below1;
    localparam [EB:0] K_SAT_U = FT_SAT_U[EB:0], K_SAT_S = FT_SAT_S[EB:0];
    assign ft_sat  = is_unsigned ? ge_k(ea, K_SAT_U) : ge_k(ea, K_SAT_S);
    assign ft_neg  = sa & ~is_unsigned & ~ft_zero & ~ft_sat;

    // ---- floor: the fraction bits are the low M - E mantissa bits, 0 <= E < M.
    localparam integer FL_KEEP = BIAS + M;
    localparam [EB:0] K_KEEP = FL_KEEP[EB:0];
    assign fl_keep  = ez_a | (ea == EMAXV) | ge_k(ea, K_KEEP);
    assign fl_small = ~ez_a & below1;

    // ---- shift amount (low 6 bits; only used when it is in 0 .. W - 1):
    //   ftoi:  W - 1 - E = (BIAS + W - 1) - ea = ~ea + (BIAS + W)       (mod 64)
    //   floor: W - M + E = ea - (BIAS - W + M)                          (mod 64)
    localparam integer C_FT = (BIAS + W) % 64;
    localparam integer C_FL = (64 - ((BIAS - W + M) % 64)) % 64;
    localparam [5:0] C_FT6 = C_FT[5:0];
    localparam [5:0] C_FL6 = C_FL[5:0];
    wire [5:0] ea6 = ea32[5:0];
    assign amt = (is_ftoi ? ~ea6 : ea6) + (is_ftoi ? C_FT6 : C_FL6);

    // ---- rsqrt: table of the 5-bit mantissa by exponent parity and top 4 bits.
    // out_e = BIAS + (BIAS + 1) / 2 - 1 - ceil(ea / 2); sign 0; zero and infinity not special.
    // The value is in 0 .. 2^EB - 1 for every ea.
    localparam integer RS_C = BIAS + (BIAS + 1) / 2 - 1;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] rs_e32 = RS_C - ((ea32 + 32'd1) >> 1);
    /* verilator lint_on UNUSEDSIGNAL */
    assign rs_e = rs_e32[EB-1:0];
    reg [4:0] rs_mr;
    always @(*) begin
        case ({ea[0], a[M-1:M-4]})
            5'h00: rs_mr = 5'd13; 5'h01: rs_mr = 5'd11; 5'h02: rs_mr = 5'd10; 5'h03: rs_mr = 5'd9;
            5'h04: rs_mr = 5'd8;  5'h05: rs_mr = 5'd7;  5'h06: rs_mr = 5'd6;  5'h07: rs_mr = 5'd5;
            5'h08: rs_mr = 5'd4;  5'h09: rs_mr = 5'd4;  5'h0a: rs_mr = 5'd3;  5'h0b: rs_mr = 5'd2;
            5'h0c: rs_mr = 5'd2;  5'h0d: rs_mr = 5'd1;  5'h0e: rs_mr = 5'd1;  5'h0f: rs_mr = 5'd0;
            5'h10: rs_mr = 5'd31; 5'h11: rs_mr = 5'd30; 5'h12: rs_mr = 5'd28; 5'h13: rs_mr = 5'd26;
            5'h14: rs_mr = 5'd25; 5'h15: rs_mr = 5'd23; 5'h16: rs_mr = 5'd22; 5'h17: rs_mr = 5'd21;
            5'h18: rs_mr = 5'd20; 5'h19: rs_mr = 5'd19; 5'h1a: rs_mr = 5'd18; 5'h1b: rs_mr = 5'd17;
            5'h1c: rs_mr = 5'd16; 5'h1d: rs_mr = 5'd15; 5'h1e: rs_mr = 5'd14; default: rs_mr = 5'd13;
        endcase
    end
    assign rs_m = rs_mr;

    // ---- leaky relu of b: exponent -1 (lrelud), -3 (lreluo), +1 (ilrelud). Infinity is
    // unchanged; an underflow (exponent <= 1 / <= 3) gives -0 whatever the sign of b.
    localparam [EB-1:0] DM1 = {EB{1'b1}};                 // -1
    localparam [EB-1:0] DM3 = {{(EB - 2){1'b1}}, 2'b01};  // -3
    localparam [EB-1:0] DP1 = {{(EB - 1){1'b0}}, 1'b1};   // +1
    assign lr_e    = eb + ((sub == 2'b00) ? DM1 : (sub == 2'b01) ? DM3 : DP1);
    assign lr_keep = (eb == EMAXV);
    assign lr_uf   = (sub == 2'b00) ? ~|eb[EB-1:1] : (sub == 2'b01) ? ~|eb[EB-1:2] : 1'b0;

    // ---- relu0..3: condition bit W-1-k of a; a set bit gives -0, a clear bit passes b.
    reg relu_c;
    always @(*) begin
        case (sub)
            2'd0:    relu_c = a[W-1];
            2'd1:    relu_c = a[W-2];
            2'd2:    relu_c = a[W-3];
            default: relu_c = a[W-4];
        endcase
    end
    assign alt = (sop == 3'd2) ? relu_c : sa;

    always @(*) begin
        case (sop)
            3'd0:    sflag = (a == {W{1'b0}});  // passa
            3'd1:    sflag = ~b[W-1];           // packbit
            3'd2:    sflag = ~relu_c;           // relu
            default: sflag = ~sa;               // rsqrt, lrelu
        endcase
    end
endmodule

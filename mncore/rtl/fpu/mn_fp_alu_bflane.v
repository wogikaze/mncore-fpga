// mn_fp_alu_bflane: per-element preparation of the block-float conversion (bfn/bfe).
//
// Used by mn_fp_alu_bfn for each element of the 64-bit slot being converted: 1 double,
// 2 singles (also pseudo-single), 4 halves. Purely combinational.
// Semantics: SDM 3.6.12.12 and 4.4, as the official emulator (== viz/core float::block_float):
//   d     = common - e
//   flag  = bfe && (d > 6 + dr || (d == 6 + dr && top bits of the element not all ones))
//   shift = (flag ? d - 6 : d) + 1 + extra            (extra = 5 for pseudo-single)
//   r     = RNE(significand >> shift)                  (done by the caller's SIMD shifter)
//   result: common >= emax          -> sign | infinity
//           max exponent of block 0 -> sign
//           e == 0 or r == 0        -> bfe ? sign : sign | common
//           otherwise               -> sign | (flag ? 0 : common) | r (pseudo-single: r << 5)
module mn_fp_alu_bflane #(
    parameter W  = 64,  // element width
    parameter EB = 11,  // exponent bits
    parameter M  = 52   // mantissa bits
) (
    input  wire [W-1:0] v,
    input  wire [11:0]  common,  // common exponent of the element's block (may be >= emax)
    input  wire         inf,     // common >= emax
    input  wire         allz,    // the largest exponent of the block is 0
    input  wire         ext,     // bfe (extended representation, half only)
    input  wire [1:0]   dr,      // dropped mantissa bits (half: 9 - n; else 0)
    input  wire [2:0]   extra,   // added to the shift (pseudo-single: 5)
    output wire [W-1:0] lsig,    // significand << (W - 1 - M), the shifter input
    output wire [5:0]   sh,      // right shift, saturated at W - 1 (the result is then 0)
    output wire         csel,    // the result is cval
    output wire [W-1:0] cval,    // constant result (infinity, zero block, zero element)
    output wire [W-1:0] zval,    // result when the rounded mantissa is 0
    output wire [W-1:0] hval     // sign and exponent of a normal result (mantissa bits 0)
);
    localparam integer GB = W - 1 - M;  // guard bits below the significand
    localparam [EB-1:0] EMAXV = {EB{1'b1}};

    wire          s   = v[W-1];
    wire [EB-1:0] e   = v[W-2:M];
    wire [M-1:0]  man = v[M-1:0];
    wire          e0  = (e == {EB{1'b0}});

    // top kept mantissa bits all ones (man[M-1:dr])
    wire [2:0] lowm = {dr == 2'd3, dr[1], |dr};
    wire       top  = &(man[2:0] | lowm) & (&man[M-1:3]);

    // d = common - e >= 0. The two shift candidates and the saturation tests are computed
    // from d side by side (no chained carry chains): sh = min(d + 1 + extra or d - 5, W - 1).
    wire [11:0] d   = common - {{(12 - EB){1'b0}}, e};
    wire [3:0]  lim = 4'd6 + {2'b00, dr};                    // 6 .. 9
    wire        big = |d[11:4];                              // d >= 16 > lim
    wire        flag = ext & (big | (d[3:0] > lim) | ((d[3:0] == lim) & ~top));
    // low 6 bits suffice: they are used only when the shift is below W
    wire [5:0]  sh_n = d[5:0] + {3'd0, extra} + 6'd1;        // shift without flag
    wire [5:0]  sh_f = d[5:0] - 6'd5;                        // with flag: d - 6 + 1
    // saturation: sh_n >= W  <=>  d >= W - 1 - extra;  sh_f >= W  <=>  d >= W + 5
    // v >= k for a constant k, as plain logic (a compare operator would become a carry chain)
    function automatic ge_k(input [11:0] val, input [11:0] k);
        integer i;
        reg r;
        begin
            r = 1'b1;
            for (i = 0; i < 12; i = i + 1)
                r = (val[i] & ~k[i]) | (~(val[i] ^ k[i]) & r);
            ge_k = r;
        end
    endfunction
    localparam integer KN0I = W - 1, KN5I = W - 6, KFI = W + 5, SHMAXI = W - 1;
    localparam [11:0] KN0 = KN0I[11:0], KN5 = KN5I[11:0], KF = KFI[11:0];
    localparam [5:0] SHMAX = SHMAXI[5:0];
    wire sat_n = (extra == 3'd0) ? ge_k(d, KN0) : ge_k(d, KN5);  // extra is 0 or 5
    wire sat_f = ge_k(d, KF);
    assign sh = flag ? (sat_f ? SHMAX : sh_f) : (sat_n ? SHMAX : sh_n);

    assign lsig = {1'b1, man, {GB{1'b0}}};
    assign zval = ext ? {s, {(W - 1){1'b0}}} : {s, common[EB-1:0], {M{1'b0}}};
    assign cval = inf ? {s, EMAXV, {M{1'b0}}} : allz ? {s, {(W - 1){1'b0}}} : zval;
    assign csel = inf | allz | e0;
    assign hval = {s, flag ? {EB{1'b0}} : common[EB-1:0], {M{1'b0}}};
endmodule

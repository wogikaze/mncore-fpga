// mn_fp_fma: one element of the MN-Core 2 MAU vector FMA, z = round(a * b + c) (WP12).
//
// Behaviour (bit-exact to the official emulator gpfn3_package_main; details and evidence in
// mncore/rtl/fpu/SPEC.md):
//   prec  a, b    c       z (rnd = 0)  z (rnd = 1)
//   00 d  double  double  double       single
//   01 f  single  single  single       half
//   10 h  half    single  single       half
//   11 g  as f (the assembler has no gv* vector instructions)
//   - formats of SDM 1.3: no subnormals, no NaN; exponent 0 is zero, all ones is infinity.
//   - product: SDM 4.3 partial-product truncation for d and f (mn_fp_mul53), exact for h.
//     zero * anything = zero (also inf * 0), inf * finite = inf.
//   - c is aligned to the grid 2^(Ep - K), Ep = Ua + Ub (unbiased exponents), K = 88 (d),
//     41 (f), 28 (h): bits of c below the grid are jammed into the grid bit, and c is
//     dropped when Uc <= Ep - K - 2.
//   - the product is dropped when Uc - Ep >= 55 (d) or 26 (f, h).
//   - the exact sum is rounded once to nearest even in the output format; overflow gives
//     a signed infinity, underflow and exact zero give +0 (SDM 4.1).
//   - inf + inf = +inf unless both are -inf; inf + x = that inf.
//
// Fully pipelined: one element per clock. Latency 14: an element sampled with in_valid by
// clock edge t (into the input registers c0) is in z with out_valid after edge t + 14 (c14).
// 8 DSP tiles (MULT18X18), registered on both sides. Only the valid bits are reset.
//
// Datapath coordinates: the window holds bits [143:0] where bit i weighs
// 2^(i + Ep - 88) (the product's bit 105 is window bit 89, its leading one is at 88 or 89).
// c's leading one sits at 88 + d (d = Uc - Ep), the grid at window bit 0 (d), 47 (f), 60 (h).
// Without a product (zero, or dropped), c is placed as if d = 0 and Ep is taken as Uc.
module mn_fp_fma #(
    parameter TAGW = 1
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            in_valid,
    input  wire [1:0]      prec,
    input  wire            rnd,
    input  wire [63:0]     a,       // d [63:0], f [31:0], h [15:0]; upper bits ignored
    input  wire [63:0]     b,
    input  wire [63:0]     c,       // d [63:0], f/h [31:0]
    input  wire [TAGW-1:0] in_tag,
    output reg             out_valid,
    output reg  [63:0]     z,       // double [63:0], single [31:0], half [15:0]; rest 0
    output reg  [TAGW-1:0] out_tag
);
    // ================================================================== c0: inputs
    reg            v0;
    reg [1:0]      p0;
    reg            r0;
    reg [63:0]     a0, b0, c0;
    reg [TAGW-1:0] t0;
    always @(posedge clk) begin
        v0 <= in_valid & ~rst;
        p0 <= prec;
        r0 <= rnd;
        a0 <= a;
        b0 <= b;
        c0 <= c;
        t0 <= in_tag;
    end

    wire md0 = (p0 == 2'b00);
    wire mh0 = (p0 == 2'b10);
    wire mf0 = ~md0 & ~mh0;

    // decode a, b (operation format) and c (double for d, single otherwise)
    wire        sa0  = md0 ? a0[63] : mf0 ? a0[31] : a0[15];
    wire        sb0  = md0 ? b0[63] : mf0 ? b0[31] : b0[15];
    wire [10:0] ea0  = md0 ? a0[62:52] : mf0 ? {3'd0, a0[30:23]} : {5'd0, a0[14:9]};
    wire [10:0] eb0  = md0 ? b0[62:52] : mf0 ? {3'd0, b0[30:23]} : {5'd0, b0[14:9]};
    wire [51:0] ma0  = md0 ? a0[51:0] : mf0 ? {a0[22:0], 29'd0} : {a0[8:0], 43'd0};
    wire [51:0] mb0  = md0 ? b0[51:0] : mf0 ? {b0[22:0], 29'd0} : {b0[8:0], 43'd0};
    wire [10:0] emx0 = md0 ? 11'h7ff : mf0 ? 11'h0ff : 11'h03f;
    wire        sc0  = md0 ? c0[63] : c0[31];
    wire [10:0] ec0  = md0 ? c0[62:52] : {3'd0, c0[30:23]};
    wire [51:0] mc0  = md0 ? c0[51:0] : {c0[22:0], 29'd0};
    wire [10:0] emc0 = md0 ? 11'h7ff : 11'h0ff;
    wire        za0  = (ea0 == 11'd0);
    wire        zb0  = (eb0 == 11'd0);
    wire        ia0  = (ea0 == emx0);
    wire        ib0  = (eb0 == emx0);

    // product significand bits [105:16]: inputs at c0, result registered in c5
    wire [89:0] pl5;
    mn_fp_mul53 u_mul (.clk(clk), .a(ma0), .b(mb0), .md(md0), .mf(mf0), .p(pl5));

    // ================================================================== c1: decoded fields
    reg            v1, md1, mf1, r1;
    reg [TAGW-1:0] t1;
    reg            sp1, pz1, pi1, sc1, zc1, ic1;
    reg [10:0]     ea1, eb1, ec1;
    reg [51:0]     mc1;
    always @(posedge clk) begin
        v1  <= v0 & ~rst;
        md1 <= md0;
        mf1 <= mf0;
        r1  <= r0;
        t1  <= t0;
        sp1 <= sa0 ^ sb0;
        pz1 <= za0 | zb0;
        pi1 <= ~(za0 | zb0) & (ia0 | ib0);
        sc1 <= sc0;
        zc1 <= (ec0 == 11'd0);
        ic1 <= (ec0 == emc0);
        ea1 <= ea0;
        eb1 <= eb0;
        ec1 <= ec0;
        mc1 <= mc0;
    end

    // trailing zeros of c's significand {1, mc}, in two steps: per byte of mc (c1 -> c2),
    // then the lowest non-zero byte (c2 -> c3); 52 when mc = 0
    function [2:0] tz8;
        input [7:0] v;
        integer i;
        begin
            tz8 = 3'd7;
            for (i = 7; i >= 0; i = i - 1)
                if (v[i]) tz8 = i[2:0];
        end
    endfunction
    wire [6:0]  nzb1;
    wire [20:0] tzb1;
    genvar gb;
    generate
        for (gb = 0; gb < 7; gb = gb + 1) begin : g_tzb
            if (gb < 6) begin : g_full
                assign nzb1[gb] = |mc1[8*gb +: 8];
                assign tzb1[3*gb +: 3] = tz8(mc1[8*gb +: 8]);
            end else begin : g_top
                assign nzb1[gb] = |mc1[51:48];
                assign tzb1[3*gb +: 3] = tz8({4'd0, mc1[51:48]});
            end
        end
    endgenerate

    // ================================================================== c2: exponents
    reg            v2, md2, mf2, r2;
    reg [TAGW-1:0] t2;
    reg            sp2, pz2, pi2, sc2, zc2, ic2;
    reg signed [13:0] ep2, uc2;    // Ua + Ub, Uc (unbiased)
    reg signed [13:0] d2;          // Uc - Ep
    reg [51:0]     mc2;
    reg [6:0]      nzb2;
    reg [20:0]     tzb2;
    wire signed [13:0] bab1 = md1 ? 14'sd1023 : mf1 ? 14'sd127 : 14'sd31;
    wire signed [13:0] bc1  = md1 ? 14'sd1023 : 14'sd127;
    // d = Ec - Ea - Eb + (2 * bias_ab - bias_c), from the exponent fields
    wire signed [13:0] kd1  = md1 ? 14'sd1023 : mf1 ? 14'sd127 : -14'sd65;
    always @(posedge clk) begin
        v2  <= v1 & ~rst;
        md2 <= md1;
        mf2 <= mf1;
        r2  <= r1;
        t2  <= t1;
        sp2 <= sp1;
        pz2 <= pz1;
        pi2 <= pi1;
        sc2 <= sc1;
        zc2 <= zc1;
        ic2 <= ic1;
        ep2  <= $signed({3'd0, ea1}) + $signed({3'd0, eb1}) - (bab1 <<< 1);
        uc2  <= $signed({3'd0, ec1}) - bc1;
        d2   <= ($signed({3'd0, ec1}) + kd1) - ($signed({3'd0, ea1}) + $signed({3'd0, eb1}));
        mc2  <= mc1;
        nzb2 <= nzb1;
        tzb2 <= tzb1;
    end
    reg [2:0] kb2;    // lowest non-zero byte of mc (7 if none)
    integer q;
    always @* begin
        kb2 = 3'd7;
        for (q = 6; q >= 0; q = q - 1)
            if (nzb2[q]) kb2 = q[2:0];
    end
    wire [5:0] tz2 = (kb2 == 3'd7) ? 6'd52 : {kb2, tzb2[3*kb2 +: 3]};

    // alignment decisions
    wire signed [13:0] tdr2 = md2 ? 14'sd55 : 14'sd26;                     // product drop
    wire signed [13:0] kdr2 = md2 ? -14'sd90 : mf2 ? -14'sd43 : -14'sd30;  // c drop
    wire               pf2  = ~pz2 & ~pi2;
    wire               cf2  = ~zc2 & ~ic2;
    wire               dp2  = pf2 & cf2 & (d2 >= tdr2);
    wire               usp2 = pf2 & ~dp2;                       // the product takes part
    wire               usc2 = cf2 & ~(usp2 & (d2 <= kdr2));     // c takes part
    // right shift of c from the top of the window: 54 - d, in 0..143 when both take part
    wire [7:0]         rsr2 = 8'd54 - d2[7:0];
    // bit j of c's significand {1, mc} lands on window bit 90 + j - rs, below the grid g
    // when j < g - 36 - d; in -90..53 when both take part (g - 36 = -36, 11, 24)
    wire [7:0]         nj2  = (md2 ? 8'd220 : mf2 ? 8'd11 : 8'd24) - d2[7:0];
    // biased exponent of the result before normalization: window bit 143 weighs
    // 2^(Ep + 55); epx = Ep (or Uc) + 55 + output bias, minus the leading-zero count later
    wire signed [13:0] cx2  = md2 ? (r2 ? 14'sd182 : 14'sd1078) : (r2 ? 14'sd86 : 14'sd182);
    wire signed [13:0] exp2 = ep2 + cx2;
    wire signed [13:0] exc2 = uc2 + cx2;

    // ================================================================== c3 .. c12: carried fields
    localparam B_V    = 0;    // valid
    localparam B_MD   = 1;    // double
    localparam B_MF   = 2;    // single (else half)
    localparam B_RND  = 3;    // output rounding
    localparam B_SP   = 4;    // sign of the product
    localparam B_SC   = 5;    // sign of c
    localparam B_USP  = 6;    // the product takes part
    localparam B_USC  = 7;    // c takes part
    localparam B_INF  = 8;    // the result is infinite
    localparam B_INFS = 9;    // sign of that infinity
    localparam B_EX   = 10;   // [23:10] epx (see above)
    localparam B_TAG  = 24;
    localparam BW     = B_TAG + TAGW;
    wire [BW-1:0] bd2 = {t2, (usp2 ? exp2 : exc2),
                         ((pi2 & ic2) ? (sp2 & sc2) : pi2 ? sp2 : sc2), (pi2 | ic2),
                         usc2, usp2, sc2, sp2, r2, mf2, md2, v2};
    // bd[k] is the bundle of register stage k (packed: bd_q[(k-3)*BW +: BW])
    reg  [11*BW-1:0] bd_q;
    wire [BW-1:0]    bd [3:13];
    genvar gk;
    generate
        for (gk = 3; gk <= 13; gk = gk + 1) begin : g_bd
            assign bd[gk] = bd_q[(gk-3)*BW +: BW];
        end
    endgenerate
    integer k;
    always @(posedge clk) begin
        bd_q <= {bd_q[10*BW-1:0], bd2};
        if (rst) begin
            for (k = 0; k < 11; k = k + 1) bd_q[k*BW + B_V] <= 1'b0;
        end
    end

    // ================================================================== c3: shift amount
    reg [7:0]  rs3, nj3;
    reg [5:0]  tz3;
    reg [51:0] mc3;
    always @(posedge clk) begin
        rs3 <= (usp2 & usc2) ? rsr2 : 8'd54;
        nj3 <= nj2;
        tz3 <= tz2;
        mc3 <= mc2;
    end
    // coarse shift (multiples of 16)
    wire [52:0]  sig3 = {1'b1, mc3};
    wire [142:0] cw3  = {sig3, 90'd0} >> {rs3[7:4], 4'd0};
    // jam: some bit of c lands below the grid (a set bit j < nj, i.e. the lowest one)
    wire         jm3  = ($signed({2'b00, tz3}) < $signed(nj3));

    // ================================================================== c4: fine shift
    reg [142:0] cw4;
    reg [3:0]   rl4;
    reg         jm4;
    always @(posedge clk) begin
        cw4 <= cw3;
        rl4 <= rs3[3:0];
        jm4 <= jm3;
    end
    wire [142:0] cwf4 = cw4 >> rl4;

    // ================================================================== c5: grid jam
    reg [142:0] cw5;
    reg         jm5;
    always @(posedge clk) begin
        cw5 <= cwf4;
        jm5 <= jm4;
    end
    wire md5 = bd[5][B_MD];
    wire mf5 = bd[5][B_MF];
    // bits below the grid are cleared and summarized in the grid bit (only when c is aligned
    // to the product; without a product c sits at d = 0 and has no bits below the grid)
    wire [142:0] gm5  = md5 ? 143'd0 : mf5 ? {96'd0, {47{1'b1}}} : {83'd0, {60{1'b1}}};
    wire [142:0] gb5  = md5 ? 143'd1 : mf5 ? (143'd1 << 47) : (143'd1 << 60);
    wire [142:0] cwj5 = (cw5 & ~gm5) | ((jm5 & bd[5][B_USP]) ? gb5 : 143'd0);

    // ================================================================== c6: add / subtract
    // x = p + c or p - c (145-bit two's complement) = p + (c ^ sub) + sub. c is inverted
    // here already; the product only has bits [89:0], so the high part is c's high part
    // plus the carry of the low part (carry select), and the carry-in enters through an
    // extra LSB of the low adder.
    wire         sub5 = bd[5][B_USP] & bd[5][B_USC] & (bd[5][B_SP] ^ bd[5][B_SC]);
    reg [142:0] cx6;
    reg [89:0]  p6;
    reg         sub6;
    always @(posedge clk) begin
        cx6  <= (bd[5][B_USC] ? cwj5 : 143'd0) ^ {143{sub5}};
        p6   <= bd[5][B_USP] ? pl5 : 90'd0;
        sub6 <= sub5;
    end
    /* verilator lint_off UNUSEDSIGNAL */
    // lo6[0] is the carry-in helper bit
    wire [91:0]  lo6  = {1'b0, p6, 1'b1} + {1'b0, cx6[89:0], sub6};
    /* verilator lint_on UNUSEDSIGNAL */
    wire [54:0]  hb6  = {{2{sub6}}, cx6[142:90]};
    wire [54:0]  hc6  = hb6 + 55'd1;
    wire [144:0] x6   = {lo6[91] ? hc6 : hb6, lo6[90:1]};

    // ================================================================== c7: magnitude
    reg [143:0] x7;
    reg         neg7;     // x < 0 (only possible when subtracting)
    always @(posedge clk) begin
        x7   <= x6[143:0];
        neg7 <= sub6 & x6[144];
    end
    // |x| = neg ? ~x + 1 : x, in two 72-bit halves (the low half carries only when it is 0)
    wire [71:0]  ml7  = (x7[71:0] ^ {72{neg7}}) + {71'd0, neg7};
    wire [71:0]  mb7  = x7[143:72] ^ {72{neg7}};
    wire [71:0]  mi7  = mb7 + 72'd1;
    wire [143:0] m7   = {(neg7 & ~|x7[71:0]) ? mi7 : mb7, ml7};
    wire         s7   = neg7 ? bd[7][B_SC] : (bd[7][B_USP] ? bd[7][B_SP] : bd[7][B_SC]);

    // ================================================================== c8: LZC per 16 bits
    function [3:0] lzc16;
        input [15:0] v;
        integer i;
        begin
            lzc16 = 4'd15;
            for (i = 0; i < 16; i = i + 1)
                if (v[i]) lzc16 = 4'd15 - i[3:0];
        end
    endfunction

    reg [143:0] m8;
    reg         s8;
    always @(posedge clk) begin
        m8 <= m7;
        s8 <= s7;
    end
    wire [8:0]  nz8;      // chunk k = bits [143-16k -: 16]
    wire [35:0] lz8;
    genvar g;
    generate
        for (g = 0; g < 9; g = g + 1) begin : g_lz
            assign nz8[g] = |m8[143-16*g -: 16];
            assign lz8[4*g +: 4] = lzc16(m8[143-16*g -: 16]);
        end
    endgenerate

    // ================================================================== c9: coarse normalize
    reg [143:0] m9;
    reg         s9;
    reg [8:0]   nz9;
    reg [35:0]  lz9;
    always @(posedge clk) begin
        m9  <= m8;
        s9  <= s8;
        nz9 <= nz8;
        lz9 <= lz8;
    end
    reg [3:0] ck9;    // first non-zero chunk (9 if none)
    integer j;
    always @* begin
        ck9 = 4'd9;
        for (j = 8; j >= 0; j = j - 1)
            if (nz9[j]) ck9 = j[3:0];
    end
    /* verilator lint_off UNUSEDSIGNAL */
    // only bits [143:64] are kept; the bits below are summarized by sth9
    wire [143:0] mc9  = m9 << {ck9, 4'd0};
    /* verilator lint_on UNUSEDSIGNAL */
    wire [3:0]   fn9  = (ck9 == 4'd9) ? 4'd0 : lz9[4*ck9 +: 4];
    // bits that land on [63:0] after the coarse shift: the chunks k >= ck + 5
    wire [8:0]   hm9  = 9'h1ff << (ck9 + 4'd5);
    wire         sth9 = |(nz9 & hm9);

    // ================================================================== c10: fine normalize
    reg [79:0]  mt10;    // bits [143:64] after the coarse shift
    reg [3:0]   fn10, ck10;
    reg         sh10, s10, z10;
    always @(posedge clk) begin
        mt10 <= mc9[143:64];
        fn10 <= fn9;
        ck10 <= ck9;
        sh10 <= sth9;
        s10  <= s9;
        z10  <= ~|nz9;
    end
    /* verilator lint_off UNUSEDSIGNAL */
    // the bits shifted below the 56-bit field only matter through st10
    wire [79:0]  mn10 = mt10 << fn10;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [55:0]  tt10 = mn10[79:24];
    wire         st10 = sh10 | (|(mt10[23:0] & (24'hffffff >> fn10)));

    // ================================================================== c11: round
    reg [55:0] tt11;
    reg        st11, s11, z11;
    reg [7:0]  lzc11;
    always @(posedge clk) begin
        tt11  <= tt10;
        st11  <= st10;
        s11   <= s10;
        z11   <= z10;
        lzc11 <= {ck10, fn10};
    end
    wire md11 = bd[11][B_MD];
    wire r11  = bd[11][B_RND];
    // output format: 0 double, 1 single, 2 half
    wire [1:0]  of11 = md11 ? (r11 ? 2'd1 : 2'd0) : (r11 ? 2'd2 : 2'd1);
    wire [52:0] sg11 = (of11 == 2'd0) ? tt11[55:3] :
                       (of11 == 2'd1) ? {29'd0, tt11[55:32]} : {43'd0, tt11[55:46]};
    wire        rb11 = (of11 == 2'd0) ? tt11[2] : (of11 == 2'd1) ? tt11[31] : tt11[45];
    wire        sy11 = st11 | ((of11 == 2'd0) ? (|tt11[1:0]) :
                               (of11 == 2'd1) ? (|tt11[30:0]) : (|tt11[44:0]));
    wire        in11 = rb11 & (sy11 | sg11[0]);

    // ================================================================== c12: pack
    /* verilator lint_off UNUSEDSIGNAL */
    // bit 52 is the hidden bit of a double result, which is not stored
    reg [53:0] sr12;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [1:0]  of12;
    reg        s12, z12;
    reg signed [13:0] eb12;
    always @(posedge clk) begin
        sr12 <= {1'b0, sg11} + {53'd0, in11};
        of12 <= of11;
        s12  <= s11;
        z12  <= z11;
        eb12 <= $signed(bd[11][B_EX +: 14]) - $signed({6'd0, lzc11});
    end
    wire        cy12 = (of12 == 2'd0) ? sr12[53] : (of12 == 2'd1) ? sr12[24] : sr12[10];
    wire signed [13:0] ef12 = eb12 + $signed({13'd0, cy12});
    wire signed [13:0] em12 = (of12 == 2'd0) ? 14'sd2047 : (of12 == 2'd1) ? 14'sd255 : 14'sd63;
    wire        ov12 = (ef12 >= em12);
    wire        un12 = (ef12 <= 14'sd0);
    wire        inf12  = bd[12][B_INF];

    // ================================================================== c13: special values
    reg [1:0]  of13;
    reg        si13, oi13, oz13;
    reg [10:0] e13;
    reg [51:0] f13;
    always @(posedge clk) begin
        of13 <= of12;
        si13 <= inf12 ? bd[12][B_INFS] : s12;
        oi13 <= inf12 | (ov12 & ~z12);          // infinity
        oz13 <= ~inf12 & (z12 | un12);          // +0
        e13  <= ef12[10:0];
        f13  <= (of12 == 2'd0) ? sr12[51:0] : (of12 == 2'd1) ? {29'd0, sr12[22:0]} : {43'd0, sr12[8:0]};
    end
    reg [63:0] zz13;
    always @* begin
        case (of13)
            2'd0: zz13 = oz13 ? 64'd0 : oi13 ? {si13, 11'h7ff, 52'd0} : {si13, e13, f13};
            2'd1: zz13 = oz13 ? 64'd0 : oi13 ? {32'd0, si13, 8'hff, 23'd0} : {32'd0, si13, e13[7:0], f13[22:0]};
            default: zz13 = oz13 ? 64'd0 : oi13 ? {48'd0, si13, 6'h3f, 9'd0} : {48'd0, si13, e13[5:0], f13[8:0]};
        endcase
    end

    // ================================================================== c14: outputs
    always @(posedge clk) begin
        out_valid <= bd[13][B_V] & ~rst;
        z         <= zz13;
        out_tag   <= bd[13][B_TAG +: TAGW];
    end
endmodule

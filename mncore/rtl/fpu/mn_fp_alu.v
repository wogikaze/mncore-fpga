// mn_fp_alu: FP-side ALU instructions of one PE (WP13).
//
// Instructions (SDM 3.6.12): rsqrt, relu/relu0..3, lrelud/lreluo/ilrelud, max/min (floating
// point), floor, ftoi (signed and unsigned), on d (dmode 00), f (01) and h (10) elements, with
// the `r` input option (rounda/roundb: single -> half, mn_alu_rnd of WP11). passa and packbit
// (same machine code as the integer forms; mn_alu_cls sends them to mn_alu_int) are executed
// too. Block-float conversion (bfn/bfe) spans the four PEs of a MAB and is in mn_fp_alu_bfn.
// Rules: mncore/rtl/fpu/SPEC.md.
//
// Interface: the same as mn_alu_int (WP11) except that imm32 is not used and pe_aluc_iselb is
// added (it tells floor / ftoi / bfn apart). Routing: mn_alu_cls (WP11) gives cls_fp for this
// unit and mn_fp_alu_bfn; cls_bf (combinational, independent of in_valid) tells which one.
//
// Buses are 128 bits (two long words per cycle, bit 127 = MSB of the first word). Elements of
// the MSB long word are processed (1 double, 2 singles, 4 halves). The LSB long word of the
// result is the LSB long word of x (after rounding: 0), as in the official emulator.
// flags[3] belongs to the MSB-side element (a double sets all four, a single two).
// out_err = 1 (with z = 0, flags = 0) if the accepted ALUC is not executed by this unit.
//
// Handshake: valid/ready, fully pipelined (one bus per clock). A request accepted in cycle t
// is on the output in cycle t + 5 (t + 4 with RND = 0). The whole pipeline stalls while
// out_valid && !out_ready (in_ready = !out_valid || out_ready).
//
// RND = 0 removes the input rounding and its pipeline stage (rounda/roundb ignored): use it
// when the caller already rounds the operands for both ALUs.
//
// Pipeline: input register | rounding (RND only) | per-element decisions (mn_fp_alu_lane:
// 1 + 2 + 4 instances) and SIMD assembly of the cheap results | SIMD right shifter (ftoi
// magnitude / floor fraction mask) and segmented max/min comparison | incrementer (floor
// round-up, ftoi negation) and final selection | output register. The SIMD datapath is the
// MSB long word cut at element boundaries (groups of 16 bits: q = 0 is bits 15:0).
module mn_fp_alu #(
    parameter RND = 1
) (
    input  wire         clk,
    input  wire         rst,
    // request
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [1:0]   pe_aluc_dmode,
    input  wire [4:0]   pe_aluc_aluop,
    input  wire         pe_aluc_is_unsigned,
    input  wire         pe_aluc_rounda,
    input  wire         pe_aluc_roundb,
    input  wire [3:0]   pe_aluc_isela,
    input  wire [2:0]   pe_aluc_iselb,
    input  wire [127:0] x,
    input  wire [127:0] y,
    // dispatch (combinational): bfn / bfe, for mn_fp_alu_bfn (meaningful when cls_fp)
    output wire         cls_bf,
    // result
    output wire         out_valid,
    input  wire         out_ready,
    output wire [127:0] z,
    output wire [3:0]   flags,
    output wire         out_err
);
    /* verilator lint_off UNUSEDSIGNAL */
    // isela is part of the common ALU interface; no FP element instruction depends on it.
    wire unused_isela = ^pe_aluc_isela;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [1:0] dmode = pe_aluc_dmode;
    wire [4:0] aluop = pe_aluc_aluop;
    wire [2:0] iselb = pe_aluc_iselb;
    assign cls_bf = (aluop == 5'b11101) || ((aluop == 5'b11110) && (iselb[2:1] != 2'b11));

    genvar l;

    localparam [2:0] K_SIMPLE = 3'd0, K_MAX = 3'd1, K_MIN = 3'd2, K_FLOOR = 3'd3,
                     K_FTOI = 3'd4, K_NONE = 3'd5;

    // ---------------------------------------------------------------------------------------
    // pipeline control: all stages advance together
    // ---------------------------------------------------------------------------------------
    reg  v1, v2, v3, v4, v5;
    wire en = ~v5 | out_ready;
    assign in_ready  = en;
    assign out_valid = v5;

    // ---------------------------------------------------------------------------------------
    // stage 1: input register, decode
    // ---------------------------------------------------------------------------------------
    reg [2:0]   kind;
    reg [2:0]   sop;
    always @(*) begin
        sop = 3'd0;
        kind = K_SIMPLE;
        case (aluop)
            5'b01010: sop = 3'd0;                                      // passa
            5'b10011: sop = 3'd1;                                      // packbit
            5'b10100, 5'b10101, 5'b10110, 5'b10111: sop = 3'd2;        // relu0..3
            5'b10000: sop = 3'd3;                                      // rsqrt
            5'b11000, 5'b11001, 5'b11010: sop = 3'd4;                  // lrelud, lreluo, ilrelud
            5'b11011: kind = K_MAX;
            5'b11100: kind = K_MIN;
            5'b11110: kind = (iselb == 3'b110) ? K_FLOOR :
                             (iselb == 3'b111) ? K_FTOI : K_NONE;
            default:  kind = K_NONE;
        endcase
    end

    reg [2:0]   s1_kind, s1_sop;
    reg [1:0]   s1_sub;
    reg         s1_D, s1_F, s1_uns, s1_ra, s1_rb;
    reg [127:0] s1_x, s1_y;
    always @(posedge clk) begin
        if (en) begin
            s1_kind <= kind; s1_sop <= sop; s1_sub <= aluop[1:0];
            // element format: D (dmode 00), H (10), F (01; 11 pseudo-single, treated as single)
            s1_D <= (dmode == 2'b00); s1_F <= dmode[0];
            s1_uns <= pe_aluc_is_unsigned; s1_ra <= pe_aluc_rounda; s1_rb <= pe_aluc_roundb;
            s1_x <= x; s1_y <= y;
        end
    end

    // ---------------------------------------------------------------------------------------
    // stage 2: input rounding
    // ---------------------------------------------------------------------------------------
    reg [2:0]  s2_kind, s2_sop;
    reg [1:0]  s2_sub;
    reg        s2_D, s2_F, s2_uns;
    reg [63:0] s2_X, s2_Y, s2_lo;  // MSB long words of x and y, LSB long word of x
    generate
        if (RND != 0) begin : g_rnd
            wire [127:0] xh, yh;
            mn_alu_rnd u_rx (.d(s1_x), .q(xh));
            mn_alu_rnd u_ry (.d(s1_y), .q(yh));
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_rlo = ^{xh[63:0], yh[63:0], s1_y[63:0]};  // rounded LSB words are 0
            /* verilator lint_on UNUSEDSIGNAL */
            always @(posedge clk) begin
                if (en) begin
                    s2_kind <= s1_kind; s2_sop <= s1_sop; s2_sub <= s1_sub;
                    s2_D <= s1_D; s2_F <= s1_F; s2_uns <= s1_uns;
                    s2_X  <= s1_ra ? xh[127:64] : s1_x[127:64];
                    s2_lo <= s1_ra ? 64'd0 : s1_x[63:0];
                    s2_Y  <= s1_rb ? yh[127:64] : s1_y[127:64];
                end
            end
        end else begin : g_nornd
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_rnd = s1_ra ^ s1_rb ^ ^s1_y[63:0];
            /* verilator lint_on UNUSEDSIGNAL */
            always @(*) begin
                s2_kind = s1_kind; s2_sop = s1_sop; s2_sub = s1_sub;
                s2_D = s1_D; s2_F = s1_F; s2_uns = s1_uns;
                s2_X = s1_x[127:64]; s2_lo = s1_x[63:0]; s2_Y = s1_y[127:64];
            end
        end
    endgenerate

    // ---------------------------------------------------------------------------------------
    // stage 3: per-element decisions, cheap results (SIMD assembly), shifter input
    // ---------------------------------------------------------------------------------------
    wire isD = s2_D, isF = s2_F;  // else H
    wire is_ftoi = (s2_kind == K_FTOI);

    // element masks of the format: top (sign) bits, bottom bits, exponent fields
    wire [63:0] topm = isD ? 64'h8000_0000_0000_0000 :
                       isF ? 64'h8000_0000_8000_0000 : 64'h8000_8000_8000_8000;
    wire [63:0] botm = isD ? 64'h0000_0000_0000_0001 :
                       isF ? 64'h0000_0001_0000_0001 : 64'h0001_0001_0001_0001;
    wire [63:0] expm = isD ? 64'h7ff0_0000_0000_0000 :
                       isF ? 64'h7f80_0000_7f80_0000 : 64'h7e00_7e00_7e00_7e00;

    // per-format element logic; element l is the l-th from the LSB side
    wire        d_sflag, d_alt, d_lrk, d_lru, d_ftz, d_fts, d_ftn, d_flk, d_fls, d_eza, d_ezb;
    wire [10:0] d_rse, d_lre;
    wire [4:0]  d_rsm;
    wire [5:0]  d_amt;
    mn_fp_alu_lane #(.W(64), .EB(11), .M(52)) u_ld (
        .a(s2_X), .b(s2_Y), .sop(s2_sop), .sub(s2_sub), .is_ftoi(is_ftoi), .is_unsigned(s2_uns),
        .sflag(d_sflag), .alt(d_alt), .rs_e(d_rse), .rs_m(d_rsm), .lr_e(d_lre), .lr_keep(d_lrk),
        .lr_uf(d_lru), .ft_zero(d_ftz), .ft_sat(d_fts), .ft_neg(d_ftn), .fl_keep(d_flk),
        .fl_small(d_fls), .amt(d_amt), .ez_a(d_eza), .ez_b(d_ezb));

    wire [1:0]  f_sflag, f_alt, f_lrk, f_lru, f_ftz, f_fts, f_ftn, f_flk, f_fls, f_eza, f_ezb;
    wire [15:0] f_rse, f_lre;
    wire [9:0]  f_rsm;
    wire [11:0] f_amt;
    wire [3:0]  h_sflag, h_alt, h_lrk, h_lru, h_ftz, h_fts, h_ftn, h_flk, h_fls, h_eza, h_ezb;
    wire [23:0] h_rse, h_lre;
    wire [19:0] h_rsm;
    wire [23:0] h_amt;
    generate
        for (l = 0; l < 2; l = l + 1) begin : g_lf
            mn_fp_alu_lane #(.W(32), .EB(8), .M(23)) u_lf (
                .a(s2_X[32*l +: 32]), .b(s2_Y[32*l +: 32]), .sop(s2_sop), .sub(s2_sub),
                .is_ftoi(is_ftoi), .is_unsigned(s2_uns),
                .sflag(f_sflag[l]), .alt(f_alt[l]), .rs_e(f_rse[8*l +: 8]), .rs_m(f_rsm[5*l +: 5]),
                .lr_e(f_lre[8*l +: 8]), .lr_keep(f_lrk[l]), .lr_uf(f_lru[l]),
                .ft_zero(f_ftz[l]), .ft_sat(f_fts[l]), .ft_neg(f_ftn[l]), .fl_keep(f_flk[l]),
                .fl_small(f_fls[l]), .amt(f_amt[6*l +: 6]), .ez_a(f_eza[l]), .ez_b(f_ezb[l]));
        end
        for (l = 0; l < 4; l = l + 1) begin : g_lh
            mn_fp_alu_lane #(.W(16), .EB(6), .M(9)) u_lh (
                .a(s2_X[16*l +: 16]), .b(s2_Y[16*l +: 16]), .sop(s2_sop), .sub(s2_sub),
                .is_ftoi(is_ftoi), .is_unsigned(s2_uns),
                .sflag(h_sflag[l]), .alt(h_alt[l]), .rs_e(h_rse[6*l +: 6]), .rs_m(h_rsm[5*l +: 5]),
                .lr_e(h_lre[6*l +: 6]), .lr_keep(h_lrk[l]), .lr_uf(h_lru[l]),
                .ft_zero(h_ftz[l]), .ft_sat(h_fts[l]), .ft_neg(h_ftn[l]), .fl_keep(h_flk[l]),
                .fl_small(h_fls[l]), .amt(h_amt[6*l +: 6]), .ez_a(h_eza[l]), .ez_b(h_ezb[l]));
        end
    endgenerate
    /* verilator lint_off UNUSEDSIGNAL */
    // shift amounts above the element width are never used (single: 5 bits, half: 4 bits)
    wire unused_amt = ^{f_amt[11], f_amt[5], h_amt[23:22], h_amt[17:16], h_amt[11:10],
                        h_amt[5:4]};
    /* verilator lint_on UNUSEDSIGNAL */

    // per-group (16 bits) copies of the element signals: D -> all, F -> q/2, H -> q
    function automatic [3:0] grp(input fd, input ff, input d, input [1:0] f, input [3:0] h);
        grp = fd ? {4{d}} : ff ? {{2{f[1]}}, {2{f[0]}}} : h;
    endfunction
    function automatic [63:0] spread(input [3:0] g);
        spread = {{16{g[3]}}, {16{g[2]}}, {16{g[1]}}, {16{g[0]}}};
    endfunction
    reg  [3:0] g_sflag, g_alt, g_lrk, g_lru, g_ftz, g_fts, g_ftn, g_flk, g_fls, g_eza, g_ezb;
    always @(*) begin
        g_sflag = grp(isD, isF, d_sflag, f_sflag, h_sflag);
        g_alt   = grp(isD, isF, d_alt, f_alt, h_alt);
        g_lrk   = grp(isD, isF, d_lrk, f_lrk, h_lrk);
        g_lru   = grp(isD, isF, d_lru, f_lru, h_lru);
        g_ftz   = grp(isD, isF, d_ftz, f_ftz, h_ftz);
        g_fts   = grp(isD, isF, d_fts, f_fts, h_fts);
        g_ftn   = grp(isD, isF, d_ftn, f_ftn, h_ftn);
        g_flk   = grp(isD, isF, d_flk, f_flk, h_flk);
        g_fls   = grp(isD, isF, d_fls, f_fls, h_fls);
        g_eza   = grp(isD, isF, d_eza, f_eza, h_eza);
        g_ezb   = grp(isD, isF, d_ezb, f_ezb, h_ezb);
    end
    wire [23:0] g_amt  = isD ? {4{d_amt}} :
                         isF ? {{2{1'b0, f_amt[10:6]}}, {2{1'b0, f_amt[4:0]}}} :
                               {2'b00, h_amt[21:18], 2'b00, h_amt[15:12], 2'b00, h_amt[9:6],
                                2'b00, h_amt[3:0]};

    // wide per-format fields: rsqrt results, leaky-relu exponents, the left-aligned
    // significands of ftoi
    wire [63:0] rs64 = isD ? {1'b0, d_rse, d_rsm, 47'd0} :
                       isF ? {1'b0, f_rse[15:8], f_rsm[9:5], 18'd0, 1'b0, f_rse[7:0], f_rsm[4:0], 18'd0} :
                             {1'b0, h_rse[23:18], h_rsm[19:15], 4'd0, 1'b0, h_rse[17:12], h_rsm[14:10], 4'd0,
                              1'b0, h_rse[11:6], h_rsm[9:5], 4'd0, 1'b0, h_rse[5:0], h_rsm[4:0], 4'd0};
    wire [63:0] lre64 = isD ? {1'b0, d_lre, 52'd0} :
                        isF ? {1'b0, f_lre[15:8], 23'd0, 1'b0, f_lre[7:0], 23'd0} :
                              {1'b0, h_lre[23:18], 9'd0, 1'b0, h_lre[17:12], 9'd0,
                               1'b0, h_lre[11:6], 9'd0, 1'b0, h_lre[5:0], 9'd0};
    wire [63:0] ftsig = isD ? {1'b1, s2_X[51:0], 11'd0} :
                        isF ? {1'b1, s2_X[54:32], 8'd0, 1'b1, s2_X[22:0], 8'd0} :
                              {1'b1, s2_X[56:48], 6'd0, 1'b1, s2_X[40:32], 6'd0,
                               1'b1, s2_X[24:16], 6'd0, 1'b1, s2_X[8:0], 6'd0};

    // simple ops, assembled once for the long word. (The per-group masks are written out
    // rather than built with spread(): function calls in continuous assignments are slow in
    // iverilog.)
    wire [63:0] altm = {{16{g_alt[3]}}, {16{g_alt[2]}}, {16{g_alt[1]}}, {16{g_alt[0]}}};
    // packbit: x << 1 per element, with the MSB of y's element in its bottom bit
    wire [63:0] ytop_at_bot = isD ? {63'd0, s2_Y[63]} :
                              isF ? {31'd0, s2_Y[63], 31'd0, s2_Y[31]} :
                                    {15'd0, s2_Y[63], 15'd0, s2_Y[47], 15'd0, s2_Y[31], 15'd0, s2_Y[15]};
    wire [63:0] r_pack = ((s2_X << 1) & ~botm) | ytop_at_bot;
    wire [63:0] r_relu = (altm & topm) | (~altm & s2_Y);
    wire [63:0] lrkm = {{16{g_lrk[3]}}, {16{g_lrk[2]}}, {16{g_lrk[1]}}, {16{g_lrk[0]}}};
    wire [63:0] lrum = {{16{g_lru[3]}}, {16{g_lru[2]}}, {16{g_lru[1]}}, {16{g_lru[0]}}};
    wire [63:0] lr_val = (lrkm & s2_Y) | (~lrkm & lrum & topm) |
                         (~lrkm & ~lrum & ((s2_Y & ~expm) | lre64));
    wire [63:0] r_lrelu = (altm & lr_val) | (~altm & s2_Y);
    reg  [63:0] sres;
    always @(*) begin
        case (s2_sop)
            3'd0:    sres = s2_X;     // passa
            3'd1:    sres = r_pack;   // packbit
            3'd2:    sres = r_relu;   // relu0..3
            3'd3:    sres = rs64;     // rsqrt
            default: sres = r_lrelu;  // lrelud, lreluo, ilrelud
        endcase
    end

    // stage 3 registers. s3_B is the second operand of stage 4: the simple result, y (max /
    // min) or the shifter input (floor: all ones; ftoi: significands).
    reg [2:0]  s3_kind;
    reg        s3_D, s3_F, s3_uns;
    reg [63:0] s3_X, s3_B, s3_lo;
    reg [23:0] s3_amt;
    reg [3:0]  s3_sflag, s3_ftz, s3_fts, s3_ftn, s3_flk, s3_fls, s3_eza, s3_ezb;
    always @(posedge clk) begin
        if (en) begin
            s3_kind <= s2_kind; s3_D <= s2_D; s3_F <= s2_F; s3_uns <= s2_uns;
            s3_X <= s2_X; s3_lo <= s2_lo; s3_amt <= g_amt;
            s3_B <= (s2_kind == K_SIMPLE) ? sres :
                    (s2_kind == K_FLOOR) ? 64'hffff_ffff_ffff_ffff :
                    (s2_kind == K_FTOI) ? ftsig : s2_Y;
            s3_sflag <= g_sflag; s3_ftz <= g_ftz; s3_fts <= g_fts; s3_ftn <= g_ftn;
            s3_flk <= g_flk; s3_fls <= g_fls; s3_eza <= g_eza; s3_ezb <= g_ezb;
        end
    end

    // ---------------------------------------------------------------------------------------
    // stage 4: SIMD right shifter (per element, zero fill), max/min comparison
    // ---------------------------------------------------------------------------------------
    wire [63:0] topm3 = s3_D ? 64'h8000_0000_0000_0000 :
                        s3_F ? 64'h8000_0000_8000_0000 : 64'h8000_8000_8000_8000;

    // Stage k shifts the elements whose amount bit k is set by 2^k. okm keeps the bits whose
    // source (bit + 2^k) lies in the same element; selm spreads each group's amount bit.
    reg [63:0] sh6, sh_okm, sh_selm;
    integer sk;
    always @(*) begin
        sh6 = s3_B;
        for (sk = 0; sk < 6; sk = sk + 1) begin
            sh_okm = s3_D ? (64'hffff_ffff_ffff_ffff >> (1 << sk)) :
                     s3_F ? {2{32'hffff_ffff >> (1 << sk)}} : {4{16'hffff >> (1 << sk)}};
            sh_selm = spread({s3_amt[18 + sk], s3_amt[12 + sk], s3_amt[6 + sk], s3_amt[sk]});
            sh6 = (sh_selm & (sh6 >> (1 << sk)) & sh_okm) | (~sh_selm & sh6);
        end
    end

    // max/min: magnitude comparison per element (sign-magnitude keys; zero when the exponent
    // is 0). In ma + ~mb the carry out of an element is (ma > mb); the element's sign position
    // holds 0 + 0 so that it receives that carry and passes none to the next element.
    wire [63:0] zam = {{16{s3_eza[3]}}, {16{s3_eza[2]}}, {16{s3_eza[1]}}, {16{s3_eza[0]}}};
    wire [63:0] zbm = {{16{s3_ezb[3]}}, {16{s3_ezb[2]}}, {16{s3_ezb[1]}}, {16{s3_ezb[0]}}};
    wire [63:0] ma = s3_X & ~zam & ~topm3;
    wire [63:0] mb = s3_B & ~zbm & ~topm3;
    /* verilator lint_off UNUSEDSIGNAL */
    // only the bits at the element sign positions (the carries) are used
    wire [63:0] gt_sum = ma + (~mb & ~topm3);   // carry at the sign position: ma > mb
    wire [63:0] lt_sum = mb + (~ma & ~topm3);   // mb > ma
    /* verilator lint_on UNUSEDSIGNAL */
    // per group: the bit at the element's sign position (D: 63; F: 63 / 31; H: 16q + 15)
    wire [3:0] gt = s3_D ? {4{gt_sum[63]}} : s3_F ? {{2{gt_sum[63]}}, {2{gt_sum[31]}}} :
                           {gt_sum[63], gt_sum[47], gt_sum[31], gt_sum[15]};
    wire [3:0] lt = s3_D ? {4{lt_sum[63]}} : s3_F ? {{2{lt_sum[63]}}, {2{lt_sum[31]}}} :
                           {lt_sum[63], lt_sum[47], lt_sum[31], lt_sum[15]};
    wire [3:0] sx = s3_D ? {4{s3_X[63]}} : s3_F ? {{2{s3_X[63]}}, {2{s3_X[31]}}} :
                           {s3_X[63], s3_X[47], s3_X[31], s3_X[15]};
    wire [3:0] sy = s3_D ? {4{s3_B[63]}} : s3_F ? {{2{s3_B[63]}}, {2{s3_B[31]}}} :
                           {s3_B[63], s3_B[47], s3_B[31], s3_B[15]};
    wire [3:0] na = sx & ~s3_eza;  // key < 0
    wire [3:0] nb = sy & ~s3_ezb;
    wire [3:0] pick_max = (~na & ~nb & ~lt) | (na & nb & ~gt) | (~na & nb);
    wire [3:0] pick_min = (~na & ~nb & ~gt) | (na & nb & ~lt) | (na & ~nb);
    wire [3:0] pick = (s3_kind == K_MAX) ? pick_max : pick_min;
    wire       is_mm = (s3_kind == K_MAX) || (s3_kind == K_MIN);

    // Per-group selection of the stage 5 result, decided here (only the floor round-up waits
    // for the fraction test of stage 5):
    //   A       simple result; floor: zero / infinity / integer; max / min: x picked
    //   sh      ftoi: magnitude; max / min: y
    //   inc     ftoi: negated magnitude; floor mask path with round-up (negative, fraction)
    //   A & ~sh floor mask path without round-up
    //   const   floor: -1.0 (negative, |x| < 1); ftoi: saturation value
    wire       k_fl = (s3_kind == K_FLOOR), k_ft = (s3_kind == K_FTOI);
    wire [3:0] ft_in = {4{k_ft}} & ~s3_fts & ~s3_ftz;        // ftoi, in range
    wire [3:0] fl_mk = {4{k_fl}} & ~s3_flk & ~s3_fls;        // floor, mask path
    wire [3:0] c_selA   = {4{s3_kind == K_SIMPLE}} | ({4{k_fl}} & s3_flk) | ({4{is_mm}} & pick);
    wire [3:0] c_selsh  = (ft_in & ~s3_ftn) | ({4{is_mm}} & ~pick);
    wire [3:0] c_selinc = ft_in & s3_ftn;
    wire [3:0] c_selc   = ({4{k_fl}} & ~s3_flk & s3_fls & sx) | ({4{k_ft}} & s3_fts);
    // The +1 goes into the LSB of each element: bit 0 of group 0, and of group 2 (F) or of
    // every group (H). The carry never leaves the element (floor: the exponent keeps a 0 bit;
    // ftoi: only nonzero magnitudes are negated).
    wire [3:0] lsb_g = s3_D ? 4'b0001 : s3_F ? 4'b0101 : 4'b1111;
    wire [3:0] c_incg = lsb_g & ((fl_mk & sx) | (ft_in & s3_ftn));

    // stage 4 registers. s4_A: the simple result, else x. s4_sh: the shifter output, or y for
    // max / min.
    reg        s4_D, s4_F, s4_uns, s4_fl, s4_none;
    reg [63:0] s4_A, s4_sh, s4_lo;
    reg [3:0]  s4_flag, s4_sx, s4_ftn, s4_selA, s4_selsh, s4_selinc, s4_selc, s4_flmk, s4_incg;
    always @(posedge clk) begin
        if (en) begin
            s4_D <= s3_D; s4_F <= s3_F; s4_uns <= s3_uns;
            s4_fl <= k_fl; s4_none <= (s3_kind == K_NONE);
            s4_A  <= (s3_kind == K_SIMPLE) ? s3_B : s3_X;
            s4_sh <= is_mm ? s3_B : sh6; s4_lo <= s3_lo;
            s4_flag <= is_mm ? pick : (s3_kind == K_SIMPLE) ? s3_sflag : 4'b0000;
            s4_sx <= sx; s4_ftn <= s3_ftn & {4{k_ft}};
            s4_selA <= c_selA; s4_selsh <= c_selsh; s4_selinc <= c_selinc; s4_selc <= c_selc;
            s4_flmk <= fl_mk; s4_incg <= c_incg;
        end
    end

    // ---------------------------------------------------------------------------------------
    // stage 5: increment (floor round-up, ftoi negation), final selection
    // ---------------------------------------------------------------------------------------
    wire [63:0] ftnm  = {{16{s4_ftn[3]}}, {16{s4_ftn[2]}}, {16{s4_ftn[1]}}, {16{s4_ftn[0]}}};
    wire [63:0] inc_a = s4_fl ? (s4_A | s4_sh) : (s4_sh ^ ftnm);
    wire [63:0] inc_b = {15'd0, s4_incg[3], 15'd0, s4_incg[2], 15'd0, s4_incg[1],
                         15'd0, s4_incg[0]};
    wire [63:0] inc   = inc_a + inc_b;

    // fraction bits present (floor), per element; round up when negative
    wire [63:0] fracb = s4_A & s4_sh;
    wire [3:0]  fr16 = {|fracb[63:48], |fracb[47:32], |fracb[31:16], |fracb[15:0]};
    wire [3:0]  frac = s4_D ? {4{|fr16}} :
                       s4_F ? {{2{fr16[3] | fr16[2]}}, {2{fr16[1] | fr16[0]}}} : fr16;
    wire [3:0]  up   = s4_flmk & s4_sx & frac;

    // constants: floor -1.0; ftoi saturation: all ones (unsigned), 0111.. or 1000.. (signed)
    wire [63:0] topm4 = s4_D ? 64'h8000_0000_0000_0000 :
                        s4_F ? 64'h8000_0000_8000_0000 : 64'h8000_8000_8000_8000;
    wire [63:0] m1v = s4_D ? 64'hbff0_0000_0000_0000 :
                      s4_F ? 64'hbf80_0000_bf80_0000 : 64'hbe00_be00_be00_be00;
    wire [63:0] sxm = {{16{s4_sx[3]}}, {16{s4_sx[2]}}, {16{s4_sx[1]}}, {16{s4_sx[0]}}};
    wire [63:0] cv  = s4_fl ? m1v :
                      s4_uns ? 64'hffff_ffff_ffff_ffff : ((sxm & topm4) | (~sxm & ~topm4));

    wire [3:0]  g_inc = s4_selinc | up, g_ans = s4_flmk & ~up;
    wire [63:0] m_A   = {{16{s4_selA[3]}}, {16{s4_selA[2]}}, {16{s4_selA[1]}}, {16{s4_selA[0]}}};
    wire [63:0] m_sh  = {{16{s4_selsh[3]}}, {16{s4_selsh[2]}}, {16{s4_selsh[1]}}, {16{s4_selsh[0]}}};
    wire [63:0] m_inc = {{16{g_inc[3]}}, {16{g_inc[2]}}, {16{g_inc[1]}}, {16{g_inc[0]}}};
    wire [63:0] m_ans = {{16{g_ans[3]}}, {16{g_ans[2]}}, {16{g_ans[1]}}, {16{g_ans[0]}}};
    wire [63:0] m_c   = {{16{s4_selc[3]}}, {16{s4_selc[2]}}, {16{s4_selc[1]}}, {16{s4_selc[0]}}};
    wire [63:0] res = (m_A & s4_A) | (m_sh & s4_sh) | (m_inc & inc) | (m_ans & s4_A & ~s4_sh) |
                      (m_c & cv);

    reg [127:0] s5_z;
    reg [3:0]   s5_f;
    reg         s5_err;
    always @(posedge clk) begin
        if (en) begin
            s5_z <= {res, s4_none ? 64'd0 : s4_lo};
            s5_f <= s4_flag;
            s5_err <= s4_none;
        end
    end
    assign z = s5_z;
    assign flags = s5_f;
    assign out_err = s5_err;

    // valid bits (stage 2 is a wire stage when RND = 0)
    always @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0; v5 <= 1'b0;
        end else if (en) begin
            v1 <= in_valid;
            v2 <= v1;
            v3 <= (RND != 0) ? v2 : v1;
            v4 <= v3;
            v5 <= v4;
        end
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_v2 = v2;  // RND = 0: no stage 2 register
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

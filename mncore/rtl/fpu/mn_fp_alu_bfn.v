// mn_fp_alu_bfn: block-float conversion of one MAB (bfn / bfe, WP13).
//
// SDM 3.6.12.12 and 4.4: dbfn, fbfn, gbfn, hbfn/n and hbfe/n (n = 6..9). The conversion takes
// the ALU inputs of the four PEs of a MAB for one cycle and gives the four results. Blocks
// (the same as the official emulator and viz/core compute_bfn):
//   d: the MSB long words of PE 0..3 (4 doubles)
//   f: element 0 of the MSB long words (4 singles), and element 1 (4 singles): two blocks
//   g: both singles of the MSB long words (8 values, pseudo-single keeps 18 mantissa bits)
//   h: the 16 halves of the MSB long words, and the 16 halves of the LSB long words
// For d, f and g the LSB long word of every result is 0. The mask flags are always 0.
// ALUC: aluop 11110 (bfn) or 11101 (bfe, dmode 10 only); dmode 00 d, 01 f, 11 g, 10 h;
// for h, iselb = 9 - n. rounda (the `r` input option, h only) rounds the singles of each bus to
// halves first (mn_alu_rnd of WP11: MSB long word = 4 halves, LSB long word = 0).
// Routing: mn_alu_cls (WP11) cls_fp and mn_fp_alu cls_bf.
//
// Ports: x[128*p +: 128] and z[128*p +: 128] are the bus of PE p (subpeid p), bit 127 of a
// bus = MSB of its first word; flags[4*p +: 4] likewise. The ALUC ports are named as in
// mn_alu_int / mn_fp_alu. out_err = 1 if the accepted ALUC was not bfn / bfe (the result is
// then meaningless). Handshake valid/ready; one conversion at a time.
// Latency: a request accepted in cycle t is on the output in cycle t + 15 (1 + 4 block
// exponents + 10 conversion), t + 19 with rounda (4 rounding). in_ready only while idle.
//
// Datapath: the 8 long words are held in a ring (slots 0..3 = MSB long words of PE 0..3,
// 4..7 = LSB long words). The block exponents are found by a pipelined 16-input max tree, one
// block per clock. Then the ring rotates once through a 3-stage converter that handles one
// 64-bit slot per clock (SIMD over its 1/2/4 elements: preparation, right shift with sticky
// jamming, round to nearest even).
module mn_fp_alu_bfn #(
    parameter RND = 1
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [1:0]   pe_aluc_dmode,
    input  wire [4:0]   pe_aluc_aluop,
    input  wire         pe_aluc_rounda,
    input  wire [2:0]   pe_aluc_iselb,
    input  wire [511:0] x,
    output wire         out_valid,
    input  wire         out_ready,
    output wire [511:0] z,
    output wire [15:0]  flags,
    output reg          out_err
);
    genvar p, j, n, q;
    wire [1:0] dmode  = pe_aluc_dmode;
    wire [4:0] aluop  = pe_aluc_aluop;
    wire       rounda = pe_aluc_rounda;
    wire [2:0] iselb  = pe_aluc_iselb;

    localparam [2:0] S_IDLE = 3'd0, S_RND = 3'd1, S_INFO = 3'd2, S_CONV = 3'd3, S_DONE = 3'd4;
    reg [2:0] st;
    reg [3:0] cnt;

    // format of the accepted request
    reg c_D, c_F, c_G, c_H, c_ext;
    reg [1:0] c_dr;

    // ring of the 8 long words: slot s = ring[64*s +: 64]
    reg  [511:0] ring;
    wire [63:0]  slot [0:7];
    generate
        for (p = 0; p < 8; p = p + 1) begin : g_slot
            assign slot[p] = ring[64*p +: 64];
        end
        for (p = 0; p < 4; p = p + 1) begin : g_z
            assign z[128*p +: 128] = {slot[p], slot[4 + p]};
        end
    endgenerate
    assign flags = 16'd0;
    assign in_ready  = (st == S_IDLE);
    assign out_valid = (st == S_DONE);

    // ---------------------------------------------------------------------------------------
    // input rounding (r option): the ring rotates by one PE per clock through one rounder
    // ---------------------------------------------------------------------------------------
    wire [63:0] rnd_hi;
    generate
        if (RND != 0) begin : g_rnd
            wire [127:0] rnd_bus;
            mn_alu_rnd u_rnd (.d({slot[0], slot[4]}), .q(rnd_bus));
            assign rnd_hi = rnd_bus[127:64];
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_rlo = ^rnd_bus[63:0];  // always 0
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_nornd
            assign rnd_hi = slot[0];
        end
    endgenerate

    // ---------------------------------------------------------------------------------------
    // block exponents: max tree over 16 (exponent, top-bits-all-ones) pairs
    // ---------------------------------------------------------------------------------------
    wire        tb = cnt[0];  // block issued to the tree in S_INFO (cnt 0: block 0, 1: block 1)
    wire [10:0] te [0:15];
    wire        tt [0:15];
    // top kept mantissa bits all ones, for halves with dr dropped bits
    function automatic top_h(input [8:0] man, input [1:0] dr);
        top_h = &(man[2:0] | {dr == 2'd3, dr[1], |dr}) & (&man[8:3]);
    endfunction
    generate
        for (n = 0; n < 16; n = n + 1) begin : g_tin
            // half: PE n/4, element n%4 of the MSB (block 0) or LSB (block 1) long word
            localparam integer HT = 62 - 16 * (n % 4);  // exponent MSB of the half
            wire [14:0] hv = tb ? slot[4 + n / 4][HT -: 15] : slot[n / 4][HT -: 15];
            wire [10:0] he = {5'd0, hv[14:9]};
            wire        ht = top_h(hv[8:0], c_dr);
            // pseudo-single: PE n/2, element n%2 (exponent and the 18 kept mantissa bits)
            if (n < 4) begin : g_dfg
                localparam integer GT = (n % 2 == 1) ? 30 : 62;
                wire [25:0] gv = slot[n / 2][GT -: 26];
                // double: PE n; single: PE n, element tb
                wire [62:0] dv = slot[n][62:0];
                wire [30:0] fv = tb ? slot[n][30:0] : slot[n][62:32];
                assign te[n] = c_D ? dv[62:52] : c_G ? {3'd0, gv[25:18]} :
                               c_F ? {3'd0, fv[30:23]} : he;
                assign tt[n] = c_D ? &dv[51:0] : c_G ? &gv[17:0] : c_F ? &fv[22:0] : ht;
            end else if (n < 8) begin : g_gh
                localparam integer GT = (n % 2 == 1) ? 30 : 62;
                wire [25:0] gv = slot[n / 2][GT -: 26];
                assign te[n] = c_G ? {3'd0, gv[25:18]} : c_H ? he : 11'd0;
                assign tt[n] = c_G ? &gv[17:0] : c_H & ht;
            end else begin : g_h
                assign te[n] = c_H ? he : 11'd0;
                assign tt[n] = c_H & ht;
            end
        end
    endgenerate

    // tree node: larger exponent wins; equal exponents OR their top flags
    function automatic [11:0] tmax(input [11:0] a, input [11:0] b);
        if (a[11:1] == b[11:1])
            tmax = {a[11:1], a[0] | b[0]};
        else if (a[11:1] >= b[11:1])
            tmax = a;
        else
            tmax = b;
    endfunction

    // the tree is pipelined: level 1 | levels 2, 3 | level 4 and the block info
    reg [95:0] t1;  // 8 nodes of 12 bits
    reg [11:0] t2a, t2b;
    reg        t1_b, t1_v, t2_b, t2_v;
    integer tj;
    always @(posedge clk) begin
        for (tj = 0; tj < 8; tj = tj + 1)
            t1[12*tj +: 12] <= tmax({te[2*tj], tt[2*tj]}, {te[2*tj+1], tt[2*tj+1]});
        t1_b <= tb;
        t1_v <= (st == S_INFO) && (cnt < 4'd2);  // block 1 is unused for d and g
        t2a <= tmax(tmax(t1[11:0], t1[23:12]), tmax(t1[35:24], t1[47:36]));
        t2b <= tmax(tmax(t1[59:48], t1[71:60]), tmax(t1[83:72], t1[95:84]));
        t2_b <= t1_b;
        t2_v <= t1_v;
    end
    wire [11:0] tm    = tmax(t2a, t2b);
    wire [10:0] max_e = tm[11:1];
    wire [11:0] comm  = {1'b0, max_e} + {11'd0, tm[0]} + {10'd0, c_H ? c_dr : 2'd0};
    wire [11:0] emax  = c_D ? 12'd2047 : c_H ? 12'd63 : 12'd255;

    // block info: common exponent, common >= emax, block of zeros
    reg [11:0] i_comm0, i_comm1;
    reg        i_inf0, i_inf1, i_z0, i_z1;
    always @(posedge clk) begin
        if (t2_v) begin
            if (t2_b) begin
                i_comm1 <= comm; i_inf1 <= (comm >= emax); i_z1 <= (max_e == 11'd0);
            end else begin
                i_comm0 <= comm; i_inf0 <= (comm >= emax); i_z0 <= (max_e == 11'd0);
            end
        end
    end

    // ---------------------------------------------------------------------------------------
    // converter stage P: per-element preparation of slot 0 (the ring head)
    // ---------------------------------------------------------------------------------------
    wire [63:0] sv = slot[0];
    // during S_CONV, cnt (0..7) is the index of the slot at the ring head
    wire        hb = cnt[2];          // half: block 1 for the LSB long words
    wire [2:0]  gext = c_G ? 3'd5 : 3'd0;
    wire        ext = c_ext & c_H;

    // double
    wire [63:0] dl_sig, dl_cv, dl_zv, dl_hv;
    wire [5:0]  dl_sh;
    wire        dl_cs;
    mn_fp_alu_bflane #(.W(64), .EB(11), .M(52)) u_bd (
        .v(sv), .common(i_comm0), .inf(i_inf0), .allz(i_z0), .ext(1'b0), .dr(2'd0),
        .extra(3'd0), .lsig(dl_sig), .sh(dl_sh), .csel(dl_cs), .cval(dl_cv), .zval(dl_zv),
        .hval(dl_hv));
    // single / pseudo-single: element 1 (bits 31:0) belongs to block 1 for f, block 0 for g
    wire [63:0] fl_sig, fl_cv, fl_zv, fl_hv;
    wire [11:0] fl_sh;
    wire [1:0]  fl_cs;
    generate
        for (j = 0; j < 2; j = j + 1) begin : g_bf
            wire b1 = (j == 0) & ~c_G;
            mn_fp_alu_bflane #(.W(32), .EB(8), .M(23)) u_bf (
                .v(sv[32*j +: 32]), .common(b1 ? i_comm1 : i_comm0), .inf(b1 ? i_inf1 : i_inf0),
                .allz(b1 ? i_z1 : i_z0), .ext(1'b0), .dr(2'd0), .extra(gext),
                .lsig(fl_sig[32*j +: 32]), .sh(fl_sh[6*j +: 6]), .csel(fl_cs[j]),
                .cval(fl_cv[32*j +: 32]), .zval(fl_zv[32*j +: 32]), .hval(fl_hv[32*j +: 32]));
        end
    endgenerate
    // half
    wire [63:0] hl_sig, hl_cv, hl_zv, hl_hv;
    wire [23:0] hl_sh;
    wire [3:0]  hl_cs;
    generate
        for (j = 0; j < 4; j = j + 1) begin : g_bh
            mn_fp_alu_bflane #(.W(16), .EB(6), .M(9)) u_bh (
                .v(sv[16*j +: 16]), .common(hb ? i_comm1 : i_comm0), .inf(hb ? i_inf1 : i_inf0),
                .allz(hb ? i_z1 : i_z0), .ext(ext), .dr(c_dr), .extra(3'd0),
                .lsig(hl_sig[16*j +: 16]), .sh(hl_sh[6*j +: 6]), .csel(hl_cs[j]),
                .cval(hl_cv[16*j +: 16]), .zval(hl_zv[16*j +: 16]), .hval(hl_hv[16*j +: 16]));
        end
    endgenerate
    /* verilator lint_off UNUSEDSIGNAL */
    // shifts above the element width are saturated away (single: 5 bits, half: 4 bits)
    wire unused_sh = ^{fl_sh[11], fl_sh[5], hl_sh[23:22], hl_sh[17:16], hl_sh[11:10], hl_sh[5:4]};
    /* verilator lint_on UNUSEDSIGNAL */

    wire isD = c_D, isH = c_H;  // else single / pseudo-single
    wire [63:0] p_sig = isD ? dl_sig : isH ? hl_sig : fl_sig;
    wire [63:0] p_cv  = isD ? dl_cv  : isH ? hl_cv  : fl_cv;
    wire [63:0] p_zv  = isD ? dl_zv  : isH ? hl_zv  : fl_zv;
    wire [63:0] p_hv  = isD ? dl_hv  : isH ? hl_hv  : fl_hv;
    wire [23:0] p_sh;
    wire [3:0]  p_cs;
    generate
        for (q = 0; q < 4; q = q + 1) begin : g_pq
            assign p_sh[6*q +: 6] = isD ? dl_sh : isH ? {2'b00, hl_sh[6*q +: 4]}
                                                      : {1'b0, fl_sh[6*(q/2) +: 5]};
            assign p_cs[q] = isD ? dl_cs : isH ? hl_cs[q] : fl_cs[q/2];
        end
    endgenerate
    // the LSB long words of d / f / g results are 0
    wire p_zero = cnt[2] & ~isH;

    reg  [63:0] a_sig, a_cv, a_zv, a_hv;
    reg  [23:0] a_sh;
    reg  [3:0]  a_cs;
    reg         a_zero;
    always @(posedge clk) begin
        a_sig <= p_sig; a_cv <= p_cv; a_zv <= p_zv; a_hv <= p_hv;
        a_sh <= p_sh; a_cs <= p_cs; a_zero <= p_zero;
    end

    // ---------------------------------------------------------------------------------------
    // converter stage S: SIMD right shift; bits shifted out are jammed into the element LSB
    // ---------------------------------------------------------------------------------------
    // element bottoms: D bit 0; F/G bits 0, 32; H bits 0, 16, 32, 48
    wire [3:0] bot = isD ? 4'b0001 : isH ? 4'b1111 : 4'b0101;
    // Stage k shifts the elements whose amount bit k is set by 2^k: okm keeps the bits whose
    // source lies in the same element, selm spreads each group's amount bit, and the bits that
    // fall off an element (its low 2^k bits) are ORed into its bottom bit (jam).
    reg [63:0] sh6, sh_okm, sh_selm, sh_jam;
    reg [15:0] sh_low;
    integer sk, sq;
    always @(*) begin
        sh6 = a_sig;
        for (sk = 0; sk < 6; sk = sk + 1) begin
            sh_okm = isD ? (64'hffff_ffff_ffff_ffff >> (1 << sk)) :
                     isH ? {4{16'hffff >> (1 << sk)}} : {2{32'hffff_ffff >> (1 << sk)}};
            sh_selm = {{16{a_sh[18 + sk]}}, {16{a_sh[12 + sk]}},
                       {16{a_sh[6 + sk]}}, {16{a_sh[sk]}}};
            sh_low = (sk >= 4) ? 16'hffff : ((16'd1 << (1 << sk)) - 16'd1);
            sh_jam = 64'd0;
            for (sq = 0; sq < 4; sq = sq + 1)
                sh_jam[16 * sq] = bot[sq] & (|(sh6[16 * sq +: 16] & sh_low));
            if (sk == 5)  // shift by 32 (doubles only): bits 31:0 fall off
                sh_jam[0] = |sh6[31:0];
            sh6 = (sh_selm & (((sh6 >> (1 << sk)) & sh_okm) | sh_jam)) | (~sh_selm & sh6);
        end
    end

    reg [63:0] b_s, b_cv, b_zv, b_hv;
    reg [3:0]  b_cs;
    reg        b_zero;
    always @(posedge clk) begin
        b_s <= sh6; b_cv <= a_cv; b_zv <= a_zv; b_hv <= a_hv;
        b_cs <= a_cs; b_zero <= a_zero;
    end

    // ---------------------------------------------------------------------------------------
    // converter stage R: round to nearest even, assemble the elements
    // ---------------------------------------------------------------------------------------
    // guard bits below the significand: D 11, F/G 8, H 6. up = round & (sticky | lsb).
    wire [63:0] rinc;
    wire        upd = b_s[10] & ((|b_s[9:0]) | b_s[11]);
    wire [1:0]  upf;
    wire [3:0]  uph;
    generate
        for (j = 0; j < 2; j = j + 1) begin : g_uf
            assign upf[j] = b_s[32*j + 7] & ((|b_s[32*j +: 7]) | b_s[32*j + 8]);
        end
        for (j = 0; j < 4; j = j + 1) begin : g_uh
            assign uph[j] = b_s[16*j + 5] & ((|b_s[16*j +: 5]) | b_s[16*j + 6]);
        end
    endgenerate
    assign rinc = isD ? {52'd0, upd, 11'd0} :
                  isH ? {9'd0, uph[3], 15'd0, uph[2], 15'd0, uph[1], 15'd0, uph[0], 6'd0} :
                        {23'd0, upf[1], 31'd0, upf[0], 8'd0};
    /* verilator lint_off UNUSEDSIGNAL */
    // the guard bits and the element sign positions of the sum are not part of the result
    wire [63:0] rs = b_s + rinc;  // no carry leaves an element (the rounded value is < 2^M)
    /* verilator lint_on UNUSEDSIGNAL */

    // mantissa fields and r == 0
    wire [63:0] r_d = {12'd0, rs[62:11]};
    wire [63:0] r_f = c_G ? {9'd0, rs[57:40], 5'd0, 9'd0, rs[25:8], 5'd0}
                          : {9'd0, rs[62:40], 9'd0, rs[30:8]};
    wire [63:0] r_h = {7'd0, rs[62:54], 7'd0, rs[46:38], 7'd0, rs[30:22], 7'd0, rs[14:6]};
    wire [63:0] r_m = isD ? r_d : isH ? r_h : r_f;
    // r == 0 <=> the truncated value is 0 and there is no round-up (taken from b_s, not from
    // the sum, to keep it off the carry chain)
    wire [3:0]  rz_h = {~|b_s[63:54], ~|b_s[47:38], ~|b_s[31:22], ~|b_s[15:6]} & ~uph;
    wire [1:0]  rz_f = {~|b_s[63:40], ~|b_s[31:8]} & ~upf;
    wire        rz_d = ~|b_s[63:11] & ~upd;
    wire [63:0] conv;
    generate
        for (q = 0; q < 4; q = q + 1) begin : g_rq
            wire rz = isD ? rz_d : isH ? rz_h[q] : rz_f[q / 2];
            assign conv[16*q +: 16] = b_cs[q] ? b_cv[16*q +: 16] :
                                      rz ? b_zv[16*q +: 16] :
                                      (b_hv[16*q +: 16] | r_m[16*q +: 16]);
        end
    endgenerate
    wire [63:0] push = b_zero ? 64'd0 : conv;

    // ---------------------------------------------------------------------------------------
    // control
    // ---------------------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE;
            cnt <= 4'd0;
        end else begin
            case (st)
                S_IDLE: if (in_valid) begin
                    st <= (RND != 0 && rounda) ? S_RND : S_INFO;
                    cnt <= 4'd0;
                end
                S_RND: begin
                    cnt <= cnt + 4'd1;
                    if (cnt == 4'd3) begin
                        st <= S_INFO;
                        cnt <= 4'd0;
                    end
                end
                S_INFO: begin
                    cnt <= cnt + 4'd1;
                    if (cnt == 4'd3) begin
                        st <= S_CONV;
                        cnt <= 4'd0;
                    end
                end
                S_CONV: begin
                    cnt <= cnt + 4'd1;
                    if (cnt == 4'd9) begin
                        st <= S_DONE;
                        cnt <= 4'd0;
                    end
                end
                default: if (out_ready) st <= S_IDLE;
            endcase
        end
    end

    // request fields and the ring
    always @(posedge clk) begin
        if (st == S_IDLE && in_valid) begin
            c_D <= (dmode == 2'b00);
            c_F <= (dmode == 2'b01);
            c_G <= (dmode == 2'b11);
            c_H <= (dmode == 2'b10);
            c_ext <= (aluop == 5'b11101);
            c_dr <= iselb[1:0];
            out_err <= ~((aluop == 5'b11101) || ((aluop == 5'b11110) && (iselb[2:1] != 2'b11)));
            // slots 7..0 = LSB long words of PE 3..0, MSB long words of PE 3..0
            ring <= {x[447:384], x[319:256], x[191:128], x[63:0],
                     x[511:448], x[383:320], x[255:192], x[127:64]};
        end else if (st == S_RND) begin
            // rotate by one PE: slots 0..2 <- 1..3, slot 3 <- rounded PE 0; 4..6 <- 5..7, 7 <- 0
            ring <= {64'd0, ring[511:320], rnd_hi, ring[255:64]};
        end else if (st == S_CONV) begin
            ring <= {push, ring[511:64]};
        end
    end
endmodule

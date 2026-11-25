// mn_alu_int: MN-Core 2 integer and bitwise ALU (WP11). SDM 3.6.12, tables 3.9 and 3.11.
//
// Executes the operations of class cls_int (mn_alu_cls):
//   add sub inc dec not and or xor max min (integer) passa lsl lsr bsl bsr lnot packbit zero imm,
// with or without `u`, in the precisions l / i / s (dmode 00 / 01 / 10). passa and packbit have
// the same machine code for d / f / h and are executed here for those precisions too.
// msl / msr (WP30) and the float-only operations (WP13) are not executed; cls_* tells the
// caller where to send the operation.
//
// Data
//   x, y   : the two ALU inputs of one cycle, 2 long words each. Bit 127 is the MSB of the
//            first (MSB) long word; elements are packed from the MSB side (SDM 1.3).
//            Operand selection ($lr, $peid, $msb1, ...) is done by the caller.
//   imm32  : the 32-bit immediate payload (j_flat.yaml imm_layout), used when aluop = 11111.
//            For imm the pe_aluc_dmode / _rounda / _roundb / _isela inputs carry payload bits
//            and are ignored.
//   z      : result, 2 long words. flags: mask flags of the cycle (SDM 3.6.12.1); bit 3 is the
//            MSB-side element; a 64-bit result drives all 4 bits, a 32-bit result 2 bits each.
//   rounda / roundb: the `r` option (mn_alu_rnd). Valid only with dmode = 10 (cls_bad otherwise).
//
// Behaviour (checked against the WP03 vectors, which agree with the official emulator)
//   - All operations except passa / zero / imm work on the MSB long word only; the LSB long
//     word of z is the LSB long word of x (0 if x was rounded).
//   - Shift amounts: s0 = y mod 2w; barrel shifts rotate by s0 mod w; lsl / lsr shift out
//     everything when s0 >= w. lsr is arithmetic without `u`, logical with `u`.
//   - `u` changes only the flags of add / sub / inc / dec (no carry / no borrow instead of
//     "result >= 0"), lsr, and max / min (unsigned compare). Other `u` forms behave as without.
//
// Interface: valid / ready on both sides, throughput 1 per clock. All pipeline registers
// advance together (in_ready = !out_valid || out_ready). Latency = 1 + IREG + PREG + MREG clocks,
// except the shifts with PREG = 1 (below).
//
// Rotator (WP35, area): with PREG = 1 the lane rotation of the shifts is done in place in
// register P, by 8 or by 1 bit per clock and lane until the lane's amount is used up (up to
// 14 clocks for a 64-bit lane, 10 for 32 and 8 for 16); meanwhile the stages behind it wait
// (in_ready = 0) and the output drains. The results are those of the six-stage rotator, which
// is used with PREG = 0.
//   stage 0 | IREG | stage 1 | PREG | stage 2 | MREG | stage 3 | output register
//   stage 0: classification, decode, operand rounding (`r`), imm / zero bus
//   stage 1: adder and max / min comparison, shift amounts and keep mask, rotator stages 0..2
//   stage 2: rotator stages 3..5, result selection, flags other than "output is all 0"
//   stage 3: zero detection for the "output is all 0" flags
// out_err = 1 if the accepted operation was not of class cls_int (z and flags are then 0).
// RND = 0 (area option, WP21) leaves out the input rounding: rounda / roundb still classify
// (cls_bad) but x and y are taken as they are, so the caller must give them rounded (mn_pe_core
// rounds once for both ALUs when it has the FP ALU too).
module mn_alu_int #(
    parameter IREG = 1,
    parameter PREG = 1,
    parameter MREG = 1,
    parameter RND  = 1
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
    input  wire [31:0]  imm32,
    input  wire [127:0] x,
    input  wire [127:0] y,
    // dispatch (combinational from the pe_aluc_* inputs, independent of in_valid)
    output wire         cls_int,
    output wire         cls_fp,
    output wire         cls_xpe,
    output wire         cls_none,
    output wire         cls_bad,
    // result
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [127:0] z,
    output reg  [3:0]   flags,
    output reg          out_err
);
    wire rbusy;                             // PREG = 1: register P is rotating
    wire adv = (!out_valid || out_ready) && !rbusy;   // every pipeline register advances
    assign in_ready = adv;

    // ---------------------------------------------------------------------
    // Lane helpers. The long word is 4 segments of 16 bits; segment 3 is bits 63..48
    // (the MSB-side element). A lane is 1 (s, m16), 2 (i, m32) or 4 (l) segments.
    // ---------------------------------------------------------------------
    // broadcast a per-segment value from the top / bottom segment of each lane
    function [3:0] lane_top;
        input fm16, fm32;
        input [3:0] v;
        lane_top = fm16 ? v : fm32 ? {v[3], v[3], v[1], v[1]} : {4{v[3]}};
    endfunction
    // AND of the segments of each lane
    function [3:0] lane_all;
        input fm16, fm32;
        input [3:0] v;
        lane_all = fm16 ? v : fm32 ? {{2{v[3] & v[2]}}, {2{v[1] & v[0]}}} : {4{&v}};
    endfunction
    function [3:0] seg_zero;
        input [63:0] v;
        seg_zero = {~|v[63:48], ~|v[47:32], ~|v[31:16], ~|v[15:0]};
    endfunction
    /* verilator lint_off UNUSEDSIGNAL */   // only the top bit of each segment is read
    function [3:0] seg_msb;
        input [63:0] v;
        seg_msb = {v[63], v[47], v[31], v[15]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    function f_gt2;                   // a > b, 2 bits
        input [1:0] fa, fb;
        f_gt2 = (fa[1] & ~fb[1]) | (~(fa[1] ^ fb[1]) & fa[0] & ~fb[0]);
    endfunction

    genvar k, j, i;

    // =====================================================================
    // Stage 0: classify, decode, round the operands
    // =====================================================================
    mn_alu_cls u_cls (
        .dmode(pe_aluc_dmode), .aluop(pe_aluc_aluop), .is_unsigned(pe_aluc_is_unsigned),
        .rounda(pe_aluc_rounda), .roundb(pe_aluc_roundb), .isela(pe_aluc_isela),
        .cls_int(cls_int), .cls_fp(cls_fp), .cls_xpe(cls_xpe), .cls_none(cls_none), .cls_bad(cls_bad));

    wire [127:0] x_rnd;
    /* verilator lint_off UNUSEDSIGNAL */   // only the MSB long word of y is used; the rounded LSB long word is 0
    wire [127:0] y_rnd;
    /* verilator lint_on UNUSEDSIGNAL */
    generate
        if (RND != 0) begin : g_rnd
            mn_alu_rnd u_rnd_x (.d(x), .q(x_rnd));
            mn_alu_rnd u_rnd_y (.d(y), .q(y_rnd));
        end else begin : g_nornd
            assign x_rnd = x;   // the caller rounds
            assign y_rnd = y;
        end
    endgenerate

    wire [4:0] op      = pe_aluc_aluop;
    wire       op_imm  = (op == 5'b11111);
    wire       op_zero = (op == 5'b11101);
    wire       uns     = pe_aluc_is_unsigned;

    // operand A: x (rounded if `r`), the immediate bus, or 0; operand B: MSB long word of y
    wire [127:0] imm_bus = uns ? {imm32, 32'd0, imm32, 32'd0} : {4{imm32}};
    wire [127:0] x0 = op_imm ? imm_bus :
                      op_zero ? 128'd0 :
                      pe_aluc_rounda ? x_rnd : x;
    wire [63:0]  y0 = pe_aluc_roundb ? y_rnd[127:64] : y[127:64];

    // control word
    wire c_arith = (op[4:2] == 3'b000);                          // add sub inc dec
    wire c_sub   = (op == 5'b00001) || (op == 5'b00011) ||
                   (op == 5'b01000) || (op == 5'b01001);         // subtract: sub dec max min
    wire c_one   = (op == 5'b00010) || (op == 5'b00011);         // rhs = 1: inc dec
    wire c_mm    = (op == 5'b01000) || (op == 5'b01001);
    wire c_max   = (op == 5'b01000);
    wire c_logic = (op[4:2] == 3'b001);                          // not and or xor (op[1:0])
    wire c_pass  = (op == 5'b01010) || op_imm || op_zero;
    wire c_shift = (op == 5'b01011) || (op == 5'b01100) || (op == 5'b01101) || (op == 5'b01110);
    wire c_left  = (op == 5'b01011) || (op == 5'b01101);         // lsl bsl
    wire c_brl   = (op == 5'b01101) || (op == 5'b01110);         // bsl bsr
    wire c_sar   = (op == 5'b01100) && !uns;                     // arithmetic lsr
    wire c_lnot  = (op == 5'b01111);
    wire c_pack  = (op == 5'b10011);
    wire c_fzero = c_logic || c_shift || c_lnot || (op == 5'b01010);  // flag "output is all 0"
    wire c_fsign = c_arith && !uns;                               // flag "output is non-negative"
    wire c_fcarry = c_arith && uns;                               // flag "no overflow"
    wire c_m16   = (pe_aluc_dmode == 2'b10);
    wire c_m32   = (pe_aluc_dmode == 2'b01);

    localparam CW = 22;
    wire [CW-1:0] ctl0 = {
        ~cls_int, c_m16, c_m32, uns,
        c_arith, c_sub, c_one, c_mm, c_max, c_logic, op[1:0], c_pass,
        c_shift, c_left, c_brl, c_sar, c_lnot, c_pack,
        c_fzero, c_fsign, c_fcarry
    };

    // ---- register A ----
    localparam WA = 128 + 64 + CW;
    wire [WA-1:0] ra_d = {x0, y0, ctl0};
    wire [WA-1:0] ra_q;
    wire          va;
    generate
        if (IREG != 0) begin : g_ra
            reg [WA-1:0] q;
            reg          v;
            always @(posedge clk) begin
                if (rst)
                    v <= 1'b0;
                else if (adv)
                    v <= in_valid;
                if (adv)
                    q <= ra_d;
            end
            assign ra_q = q;
            assign va = v;
        end else begin : g_ra_n
            assign ra_q = ra_d;
            assign va = in_valid;
        end
    endgenerate

    // =====================================================================
    // Stage 1: adder and comparison, shift amounts, rotator stages 0..2
    // =====================================================================
    wire [63:0]   a1   = ra_q[WA-1 -: 64];
    wire [63:0]   xlo1 = ra_q[WA-65 -: 64];
    wire [63:0]   b1   = ra_q[CW +: 64];
    wire [CW-1:0] c1   = ra_q[CW-1:0];
    wire m16_1 = c1[20], m32_1 = c1[19], uns_1 = c1[18], sub_1 = c1[16], one_1 = c1[15];
    wire mx_1  = c1[13], left_1 = c1[7], brl_1 = c1[6], sar_1 = c1[5];
    wire fsign_1 = c1[1], fcarry_1 = c1[0];

    wire [2:0] brk1    = {m16_1, m16_1 | m32_1, m16_1};          // carry broken above segment k
    wire [3:0] lsbseg1 = {m16_1, m16_1 | m32_1, m16_1, 1'b1};    // segment k is the bottom of its lane
    wire [3:0] la1     = lane_top(m16_1, m32_1, seg_msb(a1));    // sign of the lane of a
    wire [3:0] lb1     = lane_top(m16_1, m32_1, seg_msb(b1));

    // ---- adder: add sub inc dec, compare for max min ----
    // Guard bits between the segments propagate the carry (1, 0) or break it and inject the
    // carry-in of the next lane (sub, sub). The bottom bit pair (1, sub) is the carry-in.
    wire [63:0] onel = {15'd0, lsbseg1[3], 15'd0, lsbseg1[2], 15'd0, lsbseg1[1], 15'd0, lsbseg1[0]};
    wire [63:0] rhs  = one_1 ? onel : b1;
    wire [63:0] rhsx = sub_1 ? ~rhs : rhs;
    wire [2:0]  ga   = ~brk1 | {3{sub_1}};
    wire [2:0]  gb   = brk1 & {3{sub_1}};
    wire [68:0] opa  = {1'b0, a1[63:48],   ga[2], a1[47:32],   ga[1], a1[31:16],   ga[0], a1[15:0],   1'b1};
    wire [68:0] opb  = {1'b0, rhsx[63:48], gb[2], rhsx[47:32], gb[1], rhsx[31:16], gb[0], rhsx[15:0], sub_1};
    /* verilator lint_off UNUSEDSIGNAL */   // sm[0] only produces the carry-in
    wire [68:0] sm   = opa + opb;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [63:0] sum1 = {sm[67:52], sm[50:35], sm[33:18], sm[16:1]};
    // carry out of each segment (the guard bit's sum is c when broken, ~c when propagating)
    wire [3:0]  co   = {sm[68], sm[51] ~^ brk1[2], sm[34] ~^ brk1[1], sm[17] ~^ brk1[0]};
    wire [3:0]  lco  = lane_top(m16_1, m32_1, co);
    wire [3:0]  lsum = lane_top(m16_1, m32_1, seg_msb(sum1));
    wire [3:0]  flar1 = ({4{fsign_1}} & ~lsum) | ({4{fcarry_1}} & (sub_1 ? lco : ~lco));

    // ---- max / min ----
    wire [3:0]  eq    = lane_all(m16_1, m32_1, seg_zero(a1 ^ b1));
    wire [3:0]  ge    = uns_1 ? lco : (((la1 ^ lb1) & lb1) | (~(la1 ^ lb1) & lco));   // a >= b
    wire [3:0]  pick1 = mx_1 ? ge : (eq | ~ge);                                    // x is output

    // ---- shifts: amounts and keep mask ----
    // Per lane: s0 = y mod 2w, sw = s0 mod w, big = (s0 >= w). The rotator rotates each lane
    // right by rr (= sw, or w - sw for a left shift); the keep mask then selects the rotated
    // bit or the fill bit. The amount is in the bottom segment of the lane.
    // lsl keeps the lane bits p >= sw, lsr keeps the bits with w - 1 - p >= sw. With
    // p = 16 * sl + p16 (sl: segment index inside the lane) and sw = 16 * sh + sw[3:0]:
    //   p >= sw  <=>  sl > sh  or  (sl = sh and p16 >= sw[3:0])
    // and lsr uses the mirrored position (sl' = segments - 1 - sl, 15 - p16).
    wire [5:0]  wm = m16_1 ? 6'h0f : m32_1 ? 6'h1f : 6'h3f;
    wire [23:0] rr1;                  // rotate-right amount of the lane of segment k: rr1[6k +: 6]
    wire [63:0] keep1;
    wire [3:0]  fill1 = la1 & {4{sar_1}};
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_amt
            localparam integer K32 = (k / 2) * 2;
            localparam [1:0] SL32 = k % 2;
            localparam [1:0] SR32 = 1 - k % 2;
            localparam [1:0] SL64 = k;
            localparam [1:0] SR64 = 3 - k;
            wire [6:0]  amt = m16_1 ? b1[16*k +: 7] : m32_1 ? b1[16*K32 +: 7] : b1[6:0];
            wire        big = m16_1 ? amt[4] : m32_1 ? amt[5] : amt[6];
            assign rr1[6*k +: 6] = (left_1 ? (~amt[5:0] + 6'd1) : amt[5:0]) & wm;
            wire [1:0]  sh = m16_1 ? 2'd0 : m32_1 ? {1'b0, amt[4]} : amt[5:4];
            wire [1:0]  sp = m16_1 ? 2'd0 : m32_1 ? (left_1 ? SL32 : SR32) : (left_1 ? SL64 : SR64);
            wire [15:0] th = 16'hffff << amt[3:0];       // th[p16] = (p16 >= sw[3:0])
            wire [15:0] thr;
            for (i = 0; i < 16; i = i + 1) begin : g_b
                assign thr[i] = th[15 - i];
            end
            wire        kg = brl_1 | (~big & f_gt2(sp, sh));    // whole segment kept
            wire        ke = ~big & (sp == sh);                 // kept where th says so
            assign keep1[16*k +: 16] = {16{kg}} | ({16{ke}} & (left_1 ? th : thr));
        end
    endgenerate

    // ---- register P ----
    // controls used in stage 2: err m16 m32 arith mm logic lsel[1:0] pass shift lnot pack fzero
    localparam C2W = 13;
    wire [C2W-1:0] c1s = {c1[21:19], c1[17], c1[14], c1[12:8], c1[4:2]};
    localparam WP = 64 * 5 + 4 + 4 + 4 + C2W;
    wire [WP-1:0] rp_d = {a1, b1, xlo1, sum1, keep1, pick1, flar1, fill1, c1s};
    wire [WP-1:0] rp_q;
    wire          vp;
    wire [63:0]   rot;    // a rotated right by rr in each lane (stage 2)

    // rotate right within the lanes by nsh (16-, 32- or 64-bit lanes)
    function [63:0] rotr;
        input [63:0] d;
        input integer nsh;
        input lm16, lm32;
        reg [63:0] r64, r32, r16;
        integer b, w;
        begin
            for (b = 0; b < 64; b = b + 1) begin
                r64[b] = d[(b + nsh) % 64];
                w = b - b % 32;
                r32[b] = d[w + (b - w + nsh) % 32];
                w = b - b % 16;
                r16[b] = d[w + (b - w + nsh) % 16];
            end
            rotr = lm16 ? r16 : lm32 ? r32 : r64;
        end
    endfunction

    generate
        if (PREG != 0) begin : g_rp
            reg [WP-1:0] q;
            reg          v;
            reg [63:0]   rq;     // a, rotated in place
            reg [23:0]   rrem;   // rotation still to do, per segment (the segments of a lane agree)
            wire         m16_p = rp_q[11], m32_p = rp_q[10];   // lane width of the instruction in P
            wire [3:0]   s8 = {|rrem[23:21], |rrem[17:15], |rrem[11:9], |rrem[5:3]};   // >= 8
            wire [3:0]   s1 = ~s8 & {|rrem[20:18], |rrem[14:12], |rrem[8:6], |rrem[2:0]};
            wire [63:0]  r8 = rotr(rq, 8, m16_p, m32_p);
            wire [63:0]  r1 = rotr(rq, 1, m16_p, m32_p);
            integer g;
            always @(posedge clk) begin
                if (rst)
                    v <= 1'b0;
                else if (adv)
                    v <= va;
                if (adv)
                    q <= rp_d;
                for (g = 0; g < 4; g = g + 1) begin
                    if (rst)
                        rrem[6*g +: 6] <= 6'd0;
                    else if (adv)
                        rrem[6*g +: 6] <= (va && c1[8]) ? rr1[6*g +: 6] : 6'd0;   // shifts only
                    else if (s8[g])
                        rrem[6*g + 3 +: 3] <= rrem[6*g + 3 +: 3] - 3'd1;
                    else if (s1[g])
                        rrem[6*g +: 3] <= rrem[6*g +: 3] - 3'd1;
                    if (adv)
                        rq[16*g +: 16] <= a1[16*g +: 16];
                    else if (s8[g] || s1[g])
                        rq[16*g +: 16] <= s8[g] ? r8[16*g +: 16] : r1[16*g +: 16];
                end
            end
            assign rp_q  = q;
            assign vp    = v;
            assign rot   = rq;
            assign rbusy = ((s8 | s1) != 4'd0);
        end else begin : g_rp_n
            // stage j rotates by 2^j
            wire [64*7-1:0] st;
            assign st[63:0] = a1;
            for (j = 0; j < 6; j = j + 1) begin : g_rs
                mn_alu_rot_stage #(.J(j)) u_stage (
                    .m16(m16_1), .m32(m32_1),
                    .c({rr1[18+j], rr1[12+j], rr1[6+j], rr1[j]}),
                    .d(st[64*j +: 64]), .q(st[64*(j+1) +: 64]));
            end
            assign rot   = st[64*6 +: 64];
            assign rp_q  = rp_d;
            assign vp    = va;
            assign rbusy = 1'b0;
        end
    endgenerate

    // =====================================================================
    // Stage 2: result selection, flags
    // =====================================================================
    wire [63:0]   a2, b2, xlo2, sum2, keep2;
    wire [3:0]    pick2, flar2, fill2;
    wire          err_2, m16_2, m32_2, arith_2, mm_2, logic_2, pass_2, shift_2, lnot_2, pack_2, fzero_2;
    wire [1:0]    lsel_2;
    assign {a2, b2, xlo2, sum2, keep2, pick2, flar2, fill2,
            err_2, m16_2, m32_2, arith_2, mm_2, logic_2, lsel_2, pass_2, shift_2,
            lnot_2, pack_2, fzero_2} = rp_q;

    wire [3:0] lsbseg2 = {m16_2, m16_2 | m32_2, m16_2, 1'b1};
    wire [3:0] lb2     = lane_top(m16_2, m32_2, seg_msb(b2));

    // ---- the keep mask ----
    wire [63:0] fil  = {{16{fill2[3]}}, {16{fill2[2]}}, {16{fill2[1]}}, {16{fill2[0]}}};
    wire [63:0] shr  = (keep2 & rot) | (~keep2 & fil);

    // ---- max / min ----
    wire [63:0] mmr  = {pick2[3] ? a2[63:48] : b2[63:48], pick2[2] ? a2[47:32] : b2[47:32],
                        pick2[1] ? a2[31:16] : b2[31:16], pick2[0] ? a2[15:0]  : b2[15:0]};

    // ---- not and or xor ----
    reg [63:0] lgr;
    always @* begin
        case (lsel_2)
            2'b00:   lgr = ~a2;
            2'b01:   lgr = a2 & b2;
            2'b10:   lgr = a2 | b2;
            default: lgr = a2 ^ b2;
        endcase
    end

    // ---- lnot ----
    wire [3:0]  az   = lane_all(m16_2, m32_2, seg_zero(a2)) & lsbseg2;
    wire [63:0] lnr  = {15'd0, az[3], 15'd0, az[2], 15'd0, az[1], 15'd0, az[0]};

    // ---- packbit: (x << 1) | MSB of y, per lane ----
    wire [3:0]  pin  = {lsbseg2[3] ? lb2[3] : a2[47], lsbseg2[2] ? lb2[2] : a2[31],
                        lsbseg2[1] ? lb2[1] : a2[15], lb2[0]};
    wire [63:0] pkr  = {a2[62:48], pin[3], a2[46:32], pin[2], a2[30:16], pin[1], a2[14:0], pin[0]};

    // ---- result and the flags that do not need the zero detection ----
    wire [63:0] res2 = ({64{arith_2}} & sum2) | ({64{mm_2}} & mmr) | ({64{logic_2}} & lgr) |
                       ({64{pass_2}} & a2) | ({64{shift_2}} & shr) | ({64{lnot_2}} & lnr) |
                       ({64{pack_2}} & pkr);
    wire [3:0]  flnz2 = flar2 | ({4{mm_2}} & pick2) | ({4{pack_2}} & ~lb2);

    // ---- register M ----
    localparam WM = 64 + 64 + 4 + 4;
    wire [WM-1:0] rm_d = {res2, xlo2, flnz2, err_2, fzero_2, m16_2, m32_2};
    wire [WM-1:0] rm_q;
    wire          vm;
    generate
        if (MREG != 0) begin : g_rm
            reg [WM-1:0] q;
            reg          v;
            always @(posedge clk) begin
                if (rst)
                    v <= 1'b0;
                else if (adv)
                    v <= vp;
                if (adv)
                    q <= rm_d;
            end
            assign rm_q = q;
            assign vm = v;
        end else begin : g_rm_n
            assign rm_q = rm_d;
            assign vm = vp;
        end
    endgenerate

    // =====================================================================
    // Stage 3: "output is all 0" flags, output register
    // =====================================================================
    wire [63:0] res3, xlo3;
    wire [3:0]  flnz3;
    wire        err_3, fzero_3, m16_3, m32_3;
    assign {res3, xlo3, flnz3, err_3, fzero_3, m16_3, m32_3} = rm_q;
    wire [3:0]  rz3 = lane_all(m16_3, m32_3, seg_zero(res3));

    always @(posedge clk) begin
        if (rst)
            out_valid <= 1'b0;
        else if (adv)
            out_valid <= vm;
        else if (out_ready)
            out_valid <= 1'b0;   // register P is rotating: the output drains
        if (adv) begin
            z       <= err_3 ? 128'd0 : {res3, xlo3};
            flags   <= err_3 ? 4'd0 : fzero_3 ? rz3 : flnz3;
            out_err <= err_3;
        end
    end
endmodule

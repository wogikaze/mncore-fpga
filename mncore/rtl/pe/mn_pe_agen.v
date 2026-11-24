// mn_pe_agen: PE local memory addresses for the 4 cycles of one step (WP14).
//
// Combinational. Takes the flat j word (contract section 2: jw[425-pos] is bit pos) and the
// PE state that addressing depends on, and returns the word address of every port in every
// cycle, aligned to the access length, with an in-range flag for the reduced memories.
//
// Address of a port in cycle c (SDM 3.6.1.6, viz/core machine.rs word_addrs):
//   GRF0/GRF1 read/write : the flat field of cycle c                         (9 bits, words)
//   LM0                  : $mb + (T[c] if tregadr) + adr_c + (WL if maadj and subpe <= madpe)
//   LM1                  : $nb + adr_c + (WL if maadj and subpe <= madpe)    (12 bits, words)
// LM sums wrap at 4096 words like the chip. WL is the access length in words (1, 2, 4).
// The result is aligned down to WL ("端数は切り捨てられる", SDM 3.6.1.6).
// T[c] is word 1 (bits [95:64] of the 128-bit T entry of cycle c, i.e. the low word of the
// MSB long word); only its low 12 bits matter after wrapping, so the caller passes those.
//
// In range: the long word address (and the second long word of a 2-long-word access, which
// cannot cross the end because the address is aligned to 4 words) is below the depth.
// LM is shared by read and write (one address per cycle); the GRF ports are separate.
// In an imm word (aluop = 11111) the LM0 fields carry the immediate; the caller ignores m0_*.
module mn_pe_agen #(
    parameter LM_AW  = 9,  // LM0/LM1 depth = 2**LM_AW long words (chip: 11)
    parameter GRF_AW = 8   // GRF0/GRF1 depth = 2**GRF_AW long words (chip: 8)
) (
    input  wire [425:0] jw,
    input  wire [1:0]   subpe,   // PE number in the MAB (p0..p3), for j<madpe>
    input  wire [11:0]  bar0,    // $mb
    input  wire [11:0]  bar1,    // $nb
    input  wire [47:0]  tind,    // T word 1 [11:0] of cycle c at tind[12*c +: 12]
    // aligned word addresses; cycle c at [9*c +: 9] (GRF) or [12*c +: 12] (LM)
    output wire [35:0]  g0r_a,
    output wire [35:0]  g0w_a,
    output wire [35:0]  g1r_a,
    output wire [35:0]  g1w_a,
    output wire [47:0]  m0_a,
    output wire [47:0]  m1_a,
    // in range of the reduced memory, one bit per cycle
    output wire [3:0]   g0r_ok,
    output wire [3:0]   g0w_ok,
    output wire [3:0]   g1r_ok,
    output wire [3:0]   g1w_ok,
    output wire [3:0]   m0_ok,
    output wire [3:0]   m1_ok
);
    // field positions (spec/isa/j_flat.yaml, cycle_addr)
    localparam P_G0_WWL = 37, P_G0_RWL = 39, P_G1_WWL = 62, P_G1_RWL = 64;
    localparam P_M0_TREG = 90, P_M0_MAADJ = 91, P_M0_MADPE = 92, P_M0_WL = 94;
    localparam P_M1_MAADJ = 111, P_M1_MADPE = 112, P_M1_WL = 114;

    localparam [11:0] LM_LIMIT  = 12'd1 << LM_AW;  // in long words
    localparam [8:0]  GRF_LIMIT = 9'd1 << GRF_AW;

    wire [1:0] g0_wwl = jw[425-P_G0_WWL -: 2];
    wire [1:0] g0_rwl = jw[425-P_G0_RWL -: 2];
    wire [1:0] g1_wwl = jw[425-P_G1_WWL -: 2];
    wire [1:0] g1_rwl = jw[425-P_G1_RWL -: 2];
    wire       m0_tr  = jw[425-P_M0_TREG];
    wire       m0_mj  = jw[425-P_M0_MAADJ];
    wire [1:0] m0_mp  = jw[425-P_M0_MADPE -: 2];
    wire [1:0] m0_wl  = jw[425-P_M0_WL -: 2];
    wire       m1_mj  = jw[425-P_M1_MAADJ];
    wire [1:0] m1_mp  = jw[425-P_M1_MADPE -: 2];
    wire [1:0] m1_wl  = jw[425-P_M1_WL -: 2];

    // flat address fields of cycle 0..3
    wire [8:0]  f_g0w [0:3];
    wire [8:0]  f_g0r [0:3];
    wire [8:0]  f_g1w [0:3];
    wire [8:0]  f_g1r [0:3];
    wire [11:0] f_m0  [0:3];
    wire [11:0] f_m1  [0:3];
    assign f_g0w[0] = jw[425-28  -: 9];  assign f_g0r[0] = jw[425-41  -: 9];
    assign f_g1w[0] = jw[425-53  -: 9];  assign f_g1r[0] = jw[425-66  -: 9];
    assign f_m0[0]  = jw[425-78  -: 12]; assign f_m1[0]  = jw[425-99  -: 12];
    assign f_g0w[1] = jw[425-246 -: 9];  assign f_g0r[1] = jw[425-255 -: 9];
    assign f_g1w[1] = jw[425-264 -: 9];  assign f_g1r[1] = jw[425-273 -: 9];
    assign f_m0[1]  = jw[425-282 -: 12]; assign f_m1[1]  = jw[425-294 -: 12];
    assign f_g0w[2] = jw[425-306 -: 9];  assign f_g0r[2] = jw[425-315 -: 9];
    assign f_g1w[2] = jw[425-324 -: 9];  assign f_g1r[2] = jw[425-333 -: 9];
    assign f_m0[2]  = jw[425-342 -: 12]; assign f_m1[2]  = jw[425-354 -: 12];
    assign f_g0w[3] = jw[425-366 -: 9];  assign f_g0r[3] = jw[425-375 -: 9];
    assign f_g1w[3] = jw[425-384 -: 9];  assign f_g1r[3] = jw[425-393 -: 9];
    assign f_m0[3]  = jw[425-402 -: 12]; assign f_m1[3]  = jw[425-414 -: 12];

    // access length in words: 00 -> 1, 01 -> 2, 10 (and 11) -> 4
    function [11:0] wl_words(input [1:0] wl);
        wl_words = (wl == 2'b00) ? 12'd1 : (wl == 2'b01) ? 12'd2 : 12'd4;
    endfunction
    function [11:0] align12(input [11:0] a, input [1:0] wl);
        align12 = (wl == 2'b00) ? a : (wl == 2'b01) ? {a[11:1], 1'b0} : {a[11:2], 2'b00};
    endfunction
    function [8:0] align9(input [8:0] a, input [1:0] wl);
        align9 = (wl == 2'b00) ? a : (wl == 2'b01) ? {a[8:1], 1'b0} : {a[8:2], 2'b00};
    endfunction

    // the base address register and the MAB adjust are the same in all 4 cycles
    wire [11:0] adj0 = (m0_mj && subpe <= m0_mp) ? wl_words(m0_wl) : 12'd0;
    wire [11:0] adj1 = (m1_mj && subpe <= m1_mp) ? wl_words(m1_wl) : 12'd0;
    (* keep *) wire [11:0] base0 = bar0 + adj0;
    (* keep *) wire [11:0] base1 = bar1 + adj1;

    genvar c;
    generate
        for (c = 0; c < 4; c = c + 1) begin : g_cyc
            // two-input adds (carry chains) rather than one 4-input sum (LUT compressor tree)
            (* keep *) wire [11:0] x0 = f_m0[c] + (m0_tr ? tind[12*c +: 12] : 12'd0);
            wire [11:0] s0  = base0 + x0;
            wire [11:0] s1  = base1 + f_m1[c];
            wire [11:0] a0  = align12(s0, m0_wl);
            wire [11:0] a1  = align12(s1, m1_wl);
            wire [8:0]  ag0w = align9(f_g0w[c], g0_wwl);
            wire [8:0]  ag0r = align9(f_g0r[c], g0_rwl);
            wire [8:0]  ag1w = align9(f_g1w[c], g1_wwl);
            wire [8:0]  ag1r = align9(f_g1r[c], g1_rwl);
            assign m0_a [12*c +: 12] = a0;
            assign m1_a [12*c +: 12] = a1;
            assign g0w_a[9*c +: 9]   = ag0w;
            assign g0r_a[9*c +: 9]   = ag0r;
            assign g1w_a[9*c +: 9]   = ag1w;
            assign g1r_a[9*c +: 9]   = ag1r;
            assign m0_ok[c]  = {1'b0, a0[11:1]} < LM_LIMIT;
            assign m1_ok[c]  = {1'b0, a1[11:1]} < LM_LIMIT;
            assign g0w_ok[c] = {1'b0, ag0w[8:1]} < GRF_LIMIT;
            assign g0r_ok[c] = {1'b0, ag0r[8:1]} < GRF_LIMIT;
            assign g1w_ok[c] = {1'b0, ag1w[8:1]} < GRF_LIMIT;
            assign g1r_ok[c] = {1'b0, ag1r[8:1]} < GRF_LIMIT;
        end
    endgenerate

    /* verilator lint_off UNUSEDSIGNAL */
    // Only the address fields of the j word are used here; the rest is decoded elsewhere.
    wire unused_jw = ^jw;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

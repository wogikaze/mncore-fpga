// mn_pe_core: the PE datapath (WP20), for one PE or, time-multiplexed, the 4 PEs of a MAB (WP30).
//
// Executes one PE word (a j word with ll = 01 normal or 11 noforward) per step on the PE's
// local memories (mn_pe_mem, WP14), with the decoder (mn_dec_j, WP10), the integer ALU
// (mn_alu_int, WP11), the FP-side ALU (mn_fp_alu, WP13) and the MAU vector unit (mn_mau_vec,
// WP12). mn_core (rtl/core) fetches the words and handles nop (ll = 00), wait and E_DECODE;
// mn_mab (rtl/mab) runs the steps of the PEs of a MAB.
//
// Step (one j word; jw must stay stable from start until done):
//   1. start: mn_pe_lsu range checks every access of the step and latches the LM addresses.
//      The word given to it in this clock has imr = 0, so that every enabled write is
//      checked, also where the write mask stops it (contract 06 section 3). Out of range:
//      done with st = E_RANGE, nothing is read or written.
//   2. READ: mn_pe_lsu reads the memories in rd_use (computed here from the selectors), one
//      memory after the other into its shared read buffer (RBS = 1, WP21).
//   3. EXEC, for cycle c = 0..3:
//        gather : the operands the units use (ALU x, y; MAU a, b, c) are picked one per clock
//                 from a shared source bus into port registers (opr_cycle = c, opr_mem = the
//                 memory of the source); the `r` option (rounda / roundb) is applied here, once
//                 for both ALUs, when there is an FP ALU or more than one PE (WP21);
//        issue  : the ALU (int or FP, by mn_alu_cls) and / or the MAU take cycle c;
//        collect: when the results of cycle c are there (ALU output register / MAU result
//                 buffer), they go to mn_pe_lsu (res_valid / res_ready), which writes them;
//                 the forwarding registers of cycle c are updated at the same time.
//      Gather and issue run ahead of collect (the ALU pipelines and a 4-entry MAU result
//      buffer hold the results), so the cycles overlap.
//   Every read of the step sees the state before the step (SDM 3.6.3.9): memory operands
//   come from mn_pe_lsu's read buffer, T entry c and the forwarding registers of cycle c are
//   only written when cycle c is collected, after it was gathered.
//
// N_PE = 4 (WP30): one datapath executes the 4 PEs of a MAB one after the other. The PE of a
// step is `pe` (taken at start); the state of every PE is kept apart: the memories, T, $omr
// and $mb / $nb in mn_mab_mem (rtl/mab), the forwarding registers here ({pe, cycle}). The
// fixed operands are those of PE pe (chip coordinates n POS_N, c POS_C, b POS_B, m POS_M,
// p = pe), and so is the MAU's PE position (dvfma u / d).
//   rd_only = 1 makes a check-only step (taken at start): mn_pe_lsu range checks the word as
//   above and then writes nothing; nothing is issued and the forwarding registers are kept.
//   For a word with msl / msr / bfn / bfe it gathers the ALU input x of every cycle and gives
//   it on xg_* (xg_valid one clock per cycle). mn_mab runs such a pass on every PE before
//   any PE writes (E_RANGE before any write, and the inputs of the other PEs for msl / msr /
//   bfn / bfe).
//   In the normal step of such a word the ALU result of cycle c is xz_z (mn_mab: the input of
//   the neighbour PE, or the block-float result), asked for with xz_cycle; its flags are 0.
//   xpe_op (combinational): 1 msl, 2 msr, 3 bfn / bfe, 0 otherwise; prechk: the word needs
//   that pass (it is an xpe_op word, or it accesses LM0 / LM1, whose addresses depend on the
//   PE through $mb / $nb, T-indirect and j<madpe>).
//
// Operand sources (one bus, code = the ALU isela values; the 3-bit selectors map 5/6/7 to
// 11/12/13): 0 $lr (GRF0), 1 $ls (GRF1), 2 $t, 3 $lm (LM0), 4 $ln (LM1), 5 $peid,
// 6 $l1bid, 7 $l2bid, 8 $msb1, 9 $subpeid, 10 $mabid, 11 $mauf, 12 $aluf, 13 $lbf,
// 14 $mreadf. Fixed operands are the chip coordinates of this PE (POS_*), replicated at the
// ALU lane width (viz/core machine.rs read_alu_input: d/l 64, f/i/g 32, h/s 16 bits);
// $msb1 has only the MSB of each lane set.
//
// Forwarding registers (SDM 3.6.1.15 - 3.6.1.18): the value of cycle c of the last step that
// had the unit, after its zero flush (mn_pe_lsu zf_*); ll = 11 (noforward) steps and nop
// steps (not sent here) leave them unchanged. Checked on the official emulator (WP20):
//   - $mreadf is updated by every step that is not nop / noforward: the MAUC fields always
//     encode a matrix register read (a word without ?mread reads `dmread $ly0`). The matrix
//     register is never written here (?mwrite is unsupported), so $mreadf is 0.
//   - $lbf only changes with an L1BM -> PE transfer (unsupported here): it stays 0.
//   - Reading $aluf / $mauf after a step without that unit is an error in the emulator, so
//     the old value is kept.
//   msl / msr / bfn / bfe write $aluf like the other ALU instructions (checked, WP30).
//
// Unsupported (st = E_UNSUPPORTED, st_field = MN_J_<field>_IDX; reported after the range
// check, contract 06 section 3): decoder errors (err_field), cls_bad of mn_alu_cls (rounda /
// roundb / dmode), msl / msr and bfn / bfe with N_PE = 1 (they need the other PEs of the MAB),
// bfn / bfe with BFN = 0, matrix MAU (mmode), ?mwrite (mw), L1BM (l1bm_bmode) and L2BM
// (l2bm_lwrite) expressions, and the instructions of a unit left out (FPALU = 0: every FP ALU
// instruction; FPALU = 2: floor / ftoi; FPALU = 3: also fmax / fmin; MAU = 0: the MAU;
// aluop / enfma). Such a word is not executed: after the start clock mn_pe_lsu gets the
// word with ll = 00, so its EXEC phase writes nothing.
// isel = 11 (matrix read) writes 0 and $lbf reads 0 (the matrix register and L1BM are empty).
//
// Host port: mn_pe_lsu's (WR_MEM / RD_MEM; PROTOCOL.md spaces 1..5, 0x10 OMR, 0x11 BAR),
// usable between steps; hp_pe is the PE (N_PE = 4).
`default_nettype none
module mn_pe_core #(
    parameter LM_AW  = 9,   // LM0/LM1 depth = 2**LM_AW long words per PE (contract LM_DEPTH; chip 11)
    parameter GRF_AW = 8,   // GRF0/GRF1 depth = 2**GRF_AW long words per PE
    parameter FPALU  = 1,   // FP-side ALU (mn_fp_alu): 1 all instructions; 0 none (its instructions
                            // are unsupported); 2 without floor / ftoi (mn_fp_alu LITE = 1);
                            // 3 also without fmax / fmin (LITE = 2: relu*, lrelu*, rsqrt) (WP21)
    parameter MAU    = 1,   // 0: no MAU (mn_mau_vec); its instructions are unsupported
    parameter N_PE   = 1,   // 1: one PE (M1); 4: the PEs of a MAB, time-multiplexed (WP30)
    parameter BFN    = 1,   // N_PE = 4: bfn / bfe are executed (mn_mab has mn_fp_alu_bfn)
    parameter integer POS_N = 0,   // chip coordinates of this PE (contract 06 section 3): group 0..3
    parameter integer POS_C = 0,   //   L2B 0..1
    parameter integer POS_B = 0,   //   L1B 0..7
    parameter integer POS_M = 0,   //   MAB 0..15
    parameter integer POS_P = 0    //   PE 0..3 in the MAB (N_PE = 1; with N_PE = 4 it is `pe`)
) (
    input  wire         clk,
    input  wire         rst,
    // ---- step
    input  wire         start,       // execute jw; taken when ready
    output wire         ready,
    input  wire [425:0] jw,
    input  wire [1:0]   pe,          // N_PE = 4: the PE of the step (taken at start)
    input  wire         rd_only,     // N_PE = 4: check-only step (taken at start)
    output reg          done,        // 1-clock pulse after the step
    output reg  [1:0]   st,          // with done: 0 OK, 1 E_RANGE, 2 E_UNSUPPORTED
    output reg  [6:0]   st_field,    // with st = E_UNSUPPORTED: field index (MN_J_<field>_IDX)
    output wire         trap_wr,     // with st = E_RANGE (mn_pe_lsu): write access,
    output wire [1:0]   trap_mem,    //   memory (0 GRF0, 1 GRF1, 2 LM0, 3 LM1),
    output wire [1:0]   trap_cycle,  //   cycle,
    output wire [11:0]  trap_addr,   //   word address
    // ---- MAB exchange (N_PE = 4)
    output wire [1:0]   xpe_op,      // the word: 1 msl, 2 msr, 3 bfn / bfe, 0 other
    output wire         prechk,      // the word needs a check-only pass on every PE first
    output wire         xg_valid,    // check-only step: ALU input x of cycle xg_cycle
    output wire [1:0]   xg_cycle,
    output wire [127:0] xg_x,
    output wire [1:0]   xz_cycle,    // normal step of an xpe_op word: its ALU result of
    input  wire [127:0] xz_z,        //   cycle xz_cycle
    // ---- host port (between steps)
    input  wire         hp_req_valid,
    output wire         hp_req_ready,
    input  wire         hp_req_we,
    input  wire [1:0]   hp_pe,
    input  wire [7:0]   hp_req_space,
    input  wire [22:0]  hp_req_addr,
    input  wire [63:0]  hp_req_wdata,
    input  wire [7:0]   hp_req_wmask,
    output wire         hp_req_err,
    output wire         hp_rsp_valid,
    output wire [63:0]  hp_rsp_rdata
);
`include "mn_jfields.vh"

    localparam MP   = (N_PE > 1);                  // more than one PE
    localparam GRND = (FPALU != 0) || MP;          // `r` applied at the gather (else in mn_alu_int)

    // ------------------------------------------------------------------ decoder
    wire [1:0]   d_ll;
    wire         d_noforward;
    wire [1:0]   mau_dmode;
    wire         mau_enfma, mau_mmode, mau_round_out, mau_mw, mau_passa, mau_zeroc, mau_mdw_side;
    wire         mau_signa, mau_signb, mau_signc, mau_exta, mau_extb, mau_extc;
    wire [2:0]   mau_isela, mau_iselb, mau_iselc;
    wire [1:0]   alu_dmode;
    wire [4:0]   alu_aluop;
    wire         alu_uns, alu_rounda, alu_roundb;
    wire [3:0]   alu_isela;
    wire [2:0]   alu_iselb;
    wire [2:0]   l1_isel;
    wire         d_lm0_wr, d_lm1_wr;
    wire         d_is_imm;
    wire [31:0]  d_imm32;
    wire [14:0]  d_grp;
    wire [1:0]   d_err_kind;
    wire [6:0]   d_err_field;
    /* verilator lint_off PINMISSING */
    // The decoder has an output for every field of the word; the PE core connects the fields
    // it uses (the memory fields are decoded by mn_pe_lsu from the same word).
    mn_dec_j u_dec (
        .jw(jw), .ll(d_ll), .noforward(d_noforward),
        .pe_mauc_dmode(mau_dmode), .pe_mauc_enfma(mau_enfma), .pe_mauc_mmode(mau_mmode),
        .pe_mauc_round_out(mau_round_out), .pe_mauc_mw(mau_mw), .pe_mauc_signa(mau_signa),
        .pe_mauc_signc(mau_signc), .pe_mauc_passa(mau_passa), .pe_mauc_zeroc(mau_zeroc),
        .pe_mauc_mdw_side(mau_mdw_side), .pe_mauc_exta(mau_exta), .pe_mauc_extb(mau_extb),
        .pe_mauc_extc(mau_extc), .pe_mauc_signb(mau_signb), .pe_mauc_isela(mau_isela),
        .pe_mauc_iselb(mau_iselb), .pe_mauc_iselc(mau_iselc),
        .pe_aluc_dmode(alu_dmode), .pe_aluc_aluop(alu_aluop), .pe_aluc_is_unsigned(alu_uns),
        .pe_aluc_rounda(alu_rounda), .pe_aluc_roundb(alu_roundb), .pe_aluc_isela(alu_isela),
        .pe_aluc_iselb(alu_iselb), .l1bm_isel(l1_isel),
        .pe_lm0_write(d_lm0_wr), .pe_lm1_write(d_lm1_wr),
        .is_imm(d_is_imm), .imm32(d_imm32), .grp(d_grp),
        .err_kind(d_err_kind), .err_field(d_err_field)
    );
    /* verilator lint_on PINMISSING */

    // ------------------------------------------------------------------ classification
    wire cls_int, cls_fp, cls_xpe, cls_none, cls_bad;   // mn_alu_cls inside mn_alu_int
    // bfn / bfe (the same decode as mn_fp_alu's cls_bf)
    wire cls_bf  = (alu_aluop == 5'b11101) | ((alu_aluop == 5'b11110) & (alu_iselb[2:1] != 2'b11));
    // FP instructions of the configured FP ALU (FPALU): floor / ftoi (aluop 11110, iselb 11x)
    // need FPALU = 1, fmax / fmin FPALU = 1 or 2, the others (rsqrt, relu*, lrelu*) any FPALU > 0
    wire fp_ft   = (alu_aluop == 5'b11110);
    wire fp_mm   = (alu_aluop == 5'b11011) | (alu_aluop == 5'b11100);
    wire fp_here = (FPALU == 1) | ((FPALU == 2) & ~fp_ft) | ((FPALU == 3) & ~fp_ft & ~fp_mm);
    wire alu_act = cls_int | (fp_here & cls_fp & ~cls_bf);   // the ALU runs this step
    wire alu_int = cls_int;                             // 1: mn_alu_int, 0: mn_fp_alu
    wire mau_vec = mau_enfma & ~mau_mmode;              // MAU vector instruction
    wire mau_act = (MAU != 0) & mau_vec;
    wire op_zero = (alu_aluop == 5'b11101) & alu_uns & (alu_isela == 4'b0101);
    // MAB instructions executed with the other PEs (N_PE = 4): msl / msr, and bfn / bfe (BFN)
    wire x_ms    = MP & cls_xpe;
    wire x_bf    = MP & (BFN != 0) & cls_fp & cls_bf;
    wire xpe     = x_ms | x_bf;
    assign xpe_op = x_bf ? 2'd3 : x_ms ? ((alu_aluop == 5'b10001) ? 2'd1 : 2'd2) : 2'd0;
    // ALU instructions with a second input (viz/core vsm.rs ALU_OPS): add sub and or xor
    // max min lsl lsr bsl bsr packbit relu* lrelud lreluo ilrelud fmax fmin
    reg two_in;
    always @* begin
        case (alu_aluop)
            5'b00000, 5'b00001, 5'b00101, 5'b00110, 5'b00111, 5'b01000, 5'b01001,
            5'b01011, 5'b01100, 5'b01101, 5'b01110, 5'b10011, 5'b10100, 5'b10101,
            5'b10110, 5'b10111, 5'b11000, 5'b11001, 5'b11010, 5'b11011, 5'b11100:
                two_in = 1'b1;
            default: two_in = 1'b0;
        endcase
    end
    // the ALU reads operands (also the unsupported classes, for the range check)
    wire alu_rd = ~cls_none & ~d_is_imm & ~op_zero;

    // ------------------------------------------------------------------ unsupported words
    wire u_der = (d_err_kind == `MN_DEC_E_UNSUPPORTED);
    wire u_xpe = (cls_xpe | (cls_fp & cls_bf)) & ~xpe;
    wire u_mat = mau_enfma & mau_mmode;
    wire u_l1  = d_grp[MN_J_GRP_L1BM];
    wire u_l2  = d_grp[MN_J_GRP_L2BM];
    wire u_nfp = ~fp_here & cls_fp & ~cls_bf;           // not in the FP ALU of this FPALU
    wire u_nma = (MAU == 0) & mau_vec;                  // MAU = 0
    wire unsup = u_der | cls_bad | u_xpe | u_mat | mau_mw | u_l1 | u_l2 | u_nfp | u_nma;
    localparam [31:0] F_ROUNDA = MN_J_PE_ALUC_ROUNDA_IDX, F_ROUNDB = MN_J_PE_ALUC_ROUNDB_IDX;
    localparam [31:0] F_ADMODE = MN_J_PE_ALUC_DMODE_IDX, F_ALUOP = MN_J_PE_ALUC_ALUOP_IDX;
    localparam [31:0] F_MMODE = MN_J_PE_MAUC_MMODE_IDX, F_MW = MN_J_PE_MAUC_MW_IDX;
    localparam [31:0] F_L1BM = MN_J_L1BM_BMODE_IDX, F_L2BM = MN_J_L2BM_LWRITE_IDX;
    localparam [31:0] F_ENFMA = MN_J_PE_MAUC_ENFMA_IDX;
    wire [6:0] ufield = u_der   ? d_err_field :
                        cls_bad ? ((alu_rounda & (alu_dmode != 2'b10)) ? F_ROUNDA[6:0] :
                                   (alu_roundb & (alu_dmode != 2'b10)) ? F_ROUNDB[6:0] : F_ADMODE[6:0]) :
                        (u_xpe | u_nfp) ? F_ALUOP[6:0] :
                        u_mat   ? F_MMODE[6:0] :
                        mau_mw  ? F_MW[6:0] :
                        u_l1    ? F_L1BM[6:0] :
                        u_l2    ? F_L2BM[6:0] : F_ENFMA[6:0];

    // ------------------------------------------------------------------ rd_use
    // memories read as an operand, {LM1, LM0, GRF1, GRF0}; selector values 0..4 are
    // $lr $ls $t $lm $ln (T needs no request). Only these are read and range checked.
    function [3:0] mem_of(input [3:0] s, input en);
        mem_of = !en ? 4'd0 : (s == 4'd0) ? 4'b0001 : (s == 4'd1) ? 4'b0010 :
                 (s == 4'd3) ? 4'b0100 : (s == 4'd4) ? 4'b1000 : 4'd0;
    endfunction
    wire [3:0] rd_use = mem_of(alu_isela, alu_rd) |
                        mem_of({1'b0, alu_iselb}, alu_rd & two_in) |
                        mem_of({1'b0, mau_isela}, mau_enfma | mau_mw) |
                        mem_of({1'b0, mau_iselb}, mau_enfma & ~mau_passa) |
                        mem_of({1'b0, mau_iselc}, mau_enfma & ~mau_zeroc) |
                        mem_of({1'b0, l1_isel}, 1'b1);
    // a check-only pass first (N_PE = 4): the LM addresses depend on the PE ($mb / $nb,
    // T-indirect, j<madpe>); GRF addresses do not, so the first PE's check stands for all
    assign prechk = MP & (xpe | rd_use[2] | rd_use[3] | d_lm0_wr | d_lm1_wr);

    // ------------------------------------------------------------------ step state
    localparam P_IDLE = 1'b0, P_RUN = 1'b1;
    reg         ph;
    reg         unsup_q;
    reg [6:0]   ufield_q;
    reg         rdo_q;      // check-only step
    reg         xpe_q;      // normal step of an xpe word: the ALU result is xz_z
    reg [1:0]   pe_q;       // PE of the step
    reg [1:0]   iss_c;      // cycle being gathered / issued
    reg         iss_fin;    // the 4 cycles are issued
    reg [4:0]   gpend;      // ports still to gather for iss_c: {c, b, a, y, x}
    reg         alu_isd, mau_isd;   // cycle iss_c taken by the ALU / MAU
    reg [1:0]   coll_c;     // cycle being collected (= mn_pe_lsu res_cycle)
    reg [2:0]   mau_cnt;    // MAU results received in this step

    wire        lsu_idle, lsu_opr_valid, lsu_res_ready, lsu_done, lsu_trap;
    wire [1:0]  lsu_res_cycle;
    wire        zf_en;
    wire [1:0]  zf_sel;
    wire [127:0] zf_mask;

    assign ready = (ph == P_IDLE) & lsu_idle;
    wire go = start & ready;
    wire rdo_in = MP & rd_only;
    // ports to gather per cycle: the check-only pass gathers x of an xpe word only; the
    // normal step of an xpe word gathers no ALU input (its result comes from mn_mab)
    wire [4:0] need_n = {mau_act & ~mau_zeroc, mau_act & ~mau_passa, mau_act,
                         alu_act & two_in, alu_act & ~d_is_imm};
    wire [4:0] need = rdo_in ? {4'd0, xpe} : need_n;
    reg  [4:0] need_q;
    // the units run in a normal step only
    wire alu_on = alu_act & ~rdo_q;
    wire mau_on = mau_act & ~rdo_q;

    // ------------------------------------------------------------------ operand gather
    function [3:0] code3(input [2:0] s);   // 3-bit selector -> source code
        code3 = (s == 3'd5) ? 4'd11 : (s == 3'd6) ? 4'd12 : (s == 3'd7) ? 4'd13 : {1'b0, s};
    endfunction
    wire [4:0] glow = gpend & (~gpend + 5'd1);          // lowest pending port, one-hot
    wire [3:0] gcode = glow[0] ? alu_isela : glow[1] ? code3(alu_iselb) :
                       glow[2] ? code3(mau_isela) : glow[3] ? code3(mau_iselb) : code3(mau_iselc);
    // the step reads T as an operand (mn_mab_mem restores T of the PE first)
    wire t_src = (need[0] & (alu_isela == 4'd2)) | (need[1] & (alu_iselb == 3'd2)) |
                 (need[2] & (mau_isela == 3'd2)) | (need[3] & (mau_iselb == 3'd2)) |
                 (need[4] & (mau_iselc == 3'd2));

    wire [127:0] opr_grf0, opr_grf1, opr_lm0, opr_lm1, opr_t;
    wire [127:0] aluf_rd, mauf_rd;

    // fixed operands: chip coordinates (contract 06 section 3, viz/core read_alu_input)
    wire [1:0] pos_p;
    generate
        if (MP) begin : g_pp
            assign pos_p = pe_q;
        end else begin : g_sp
            localparam [31:0] P32 = POS_P;
            assign pos_p = P32[1:0];
        end
    endgenerate
    localparam [31:0] V_MAB4  = POS_M * 4;
    localparam [31:0] V_L1BID = POS_B;
    localparam [31:0] V_L2BID = POS_N * 2 + POS_C;
    localparam [31:0] V_MABID = POS_M;
    wire [5:0] v_peid = {V_MAB4[5:2], pos_p};
    wire [5:0] fid = (gcode == 4'd5) ? v_peid : (gcode == 4'd6) ? V_L1BID[5:0] :
                     (gcode == 4'd7) ? V_L2BID[5:0] : (gcode == 4'd9) ? {4'd0, pos_p} :
                     (gcode == 4'd10) ? V_MABID[5:0] : 6'd0;
    wire       fmsb = (gcode == 4'd8);
    // lane width from the ALU dmode: 00 64 bits, 10 16 bits, 01 / 11 32 bits
    wire [63:0] flane = (alu_dmode == 2'b00) ? {fmsb, 57'd0, fid} :
                        (alu_dmode == 2'b10) ? {4{fmsb, 9'd0, fid}} : {2{fmsb, 25'd0, fid}};

    // mn_pe_lsu has one shared read buffer (RBS = 1): opr_mem selects the memory of the source
    // being gathered and opr_grf0 (= opr_grf1 = opr_lm0 = opr_lm1) gives it
    wire [1:0] opr_mem = (gcode == 4'd1) ? 2'd1 : (gcode == 4'd3) ? 2'd2 : (gcode == 4'd4) ? 2'd3 : 2'd0;
    reg [127:0] gbus;
    always @* begin
        case (gcode)
            4'd0, 4'd1, 4'd3, 4'd4: gbus = opr_grf0;   // $lr $ls $lm $ln
            4'd2:  gbus = opr_t;
            4'd5, 4'd6, 4'd7, 4'd8, 4'd9, 4'd10: gbus = {flane, flane};
            4'd11: gbus = mauf_rd;
            4'd12: gbus = aluf_rd;
            default: gbus = 128'd0;   // 13 $lbf, 14 $mreadf (always 0 here), 15 (E_UNSUPPORTED)
        endcase
    end

    // ALU inputs with the `r` option (rounda / roundb): with an FP ALU or more than one PE both
    // ALUs (and msl / msr / bfn) take them rounded from here (one mn_alu_rnd instead of two in
    // each ALU, WP21); otherwise the integer ALU rounds itself.
    wire [127:0] gbus_xy;
    generate
        if (GRND) begin : g_grnd
            wire [127:0] gbus_r;
            mn_alu_rnd u_rnd (.d(gbus), .q(gbus_r));
            wire use_r = glow[0] ? alu_rounda : alu_roundb;
            assign gbus_xy = use_r ? gbus_r : gbus;
        end else begin : g_nogrnd
            assign gbus_xy = gbus;
        end
    endgenerate

    reg [127:0] px, py, pa, pb, pc;   // port registers
    wire run_x = (ph == P_RUN) & lsu_opr_valid & ~unsup_q;   // executing the step
    wire g_on  = run_x & ~iss_fin & (gpend != 5'd0);
    always @(posedge clk) begin
        if (g_on & glow[0]) px <= gbus_xy;
        if (g_on & glow[1]) py <= gbus_xy;
        if (g_on & glow[2]) pa <= gbus;
        if (g_on & glow[3]) pb <= gbus;
        if (g_on & glow[4]) pc <= gbus;
    end
    // check-only pass of an xpe word: x of cycle iss_c, straight from the bus
    assign xg_valid = g_on & glow[0] & rdo_q;
    assign xg_cycle = iss_c;
    assign xg_x     = gbus_xy;

    // ------------------------------------------------------------------ units
    wire iss_on = run_x & ~iss_fin & (gpend == 5'd0);
    wire alu_iv = iss_on & alu_on & ~alu_isd;
    wire mau_iv = iss_on & mau_on & ~mau_isd;
    wire int_ir, fp_ir, mau_ir;
    wire mau_got;   // a MAU result arrives (one per cycle of the step)
    wire alu_ir = alu_int ? int_ir : fp_ir;
    wire alu_acc = alu_iv & alu_ir;
    wire mau_acc = mau_iv & mau_ir;
    wire iss_adv = iss_on & (~alu_on | alu_isd | alu_acc) & (~mau_on | mau_isd | mau_acc);

    wire         int_ov, fp_ov, int_err, fp_err;
    wire [127:0] int_z, fp_z;
    wire [3:0]   int_f, fp_f;
    wire         alu_ov = alu_int ? int_ov : fp_ov;
    // the ALU result of the cycle: the ALU's, or mn_mab's for an xpe word (flags 0)
    wire [127:0] alu_z  = xpe_q ? xz_z : alu_int ? int_z : fp_z;
    wire [3:0]   alu_f  = xpe_q ? 4'd0 : alu_int ? int_f : fp_f;
    assign xz_cycle = coll_c;

    wire         acc;   // cycle coll_c accepted by mn_pe_lsu
    wire         alu_pop = acc & alu_on & ~unsup_q;

    mn_alu_int #(.RND(GRND ? 0 : 1)) u_alu (
        .clk(clk), .rst(rst),
        .in_valid(alu_iv & alu_int), .in_ready(int_ir),
        .pe_aluc_dmode(alu_dmode), .pe_aluc_aluop(alu_aluop), .pe_aluc_is_unsigned(alu_uns),
        .pe_aluc_rounda(alu_rounda), .pe_aluc_roundb(alu_roundb), .pe_aluc_isela(alu_isela),
        .imm32(d_imm32), .x(px), .y(py),
        .cls_int(cls_int), .cls_fp(cls_fp), .cls_xpe(cls_xpe), .cls_none(cls_none), .cls_bad(cls_bad),
        .out_valid(int_ov), .out_ready(alu_pop & alu_int), .z(int_z), .flags(int_f), .out_err(int_err)
    );

    generate
        if (FPALU != 0) begin : g_fpalu
            /* verilator lint_off UNUSEDSIGNAL */
            wire fp_clsbf;   // the same decode as cls_bf above
            /* verilator lint_on UNUSEDSIGNAL */
            mn_fp_alu #(.RND(0), .LITE((FPALU == 1) ? 0 : FPALU - 1)) u_fpalu (
                .clk(clk), .rst(rst),
                .in_valid(alu_iv & ~alu_int), .in_ready(fp_ir),
                .pe_aluc_dmode(alu_dmode), .pe_aluc_aluop(alu_aluop), .pe_aluc_is_unsigned(alu_uns),
                .pe_aluc_rounda(alu_rounda), .pe_aluc_roundb(alu_roundb), .pe_aluc_isela(alu_isela),
                .pe_aluc_iselb(alu_iselb), .x(px), .y(py), .cls_bf(fp_clsbf),
                .out_valid(fp_ov), .out_ready(alu_pop & ~alu_int), .z(fp_z), .flags(fp_f), .out_err(fp_err)
            );
        end else begin : g_nofpalu
            assign fp_ir  = 1'b1;
            assign fp_ov  = 1'b0;
            assign fp_z   = 128'd0;
            assign fp_f   = 4'd0;
            assign fp_err = 1'b0;
        end
    endgenerate

    // MAU and its results of the step, by cycle (mn_mau_vec has no output stall)
    wire [131:0] maub_rd;
    generate
        if (MAU != 0) begin : g_mau
            wire         mau_ov;
            wire [127:0] mau_z;
            wire [3:0]   mau_f;
            wire [1:0]   mau_tag;
            mn_mau_vec #(.TAGW(2)) u_mau (
                .clk(clk), .rst(rst), .in_valid(mau_iv), .in_ready(mau_ir),
                .dmode(mau_dmode), .round_out(mau_round_out), .passa(mau_passa), .zeroc(mau_zeroc),
                .mdw_side(mau_mdw_side), .signa(mau_signa), .signb(mau_signb), .signc(mau_signc),
                .exta(mau_exta), .extb(mau_extb), .extc(mau_extc), .pe_sub(pos_p),
                .a_bus(pa), .b_bus(pb), .c_bus(pc), .in_tag(iss_c),
                .out_valid(mau_ov), .z_bus(mau_z), .flags(mau_f), .out_tag(mau_tag)
            );
            mn_ram_lut #(.W(132), .AW(2), .NR(1)) u_maub (
                .clk(clk), .we(mau_ov), .waddr(mau_tag), .wdata({mau_f, mau_z}),
                .raddr(coll_c), .rdata(maub_rd));
            assign mau_got = mau_ov;
        end else begin : g_nomau
            assign mau_ir  = 1'b1;
            assign mau_got = 1'b0;
            assign maub_rd = 132'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            // MAU = 0: the MAU fields and port registers have no reader (removed in synthesis)
            wire unused_mau = ^{mau_dmode, mau_round_out, mau_mdw_side, mau_signa, mau_signb, mau_signc,
                                mau_exta, mau_extb, mau_extc, pa, pb, pc, mau_iv};
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    // ------------------------------------------------------------------ collect
    // A cycle is collected after it was gathered and issued (c_iss; the units' results imply
    // it, but a check-only step has no unit and must not end before x of every cycle is out).
    wire alu_rdy = ~alu_on | alu_ov;
    wire mau_rdy = ~mau_on | (mau_cnt > {1'b0, coll_c});
    wire c_iss   = iss_fin | (iss_c > coll_c);
    wire res_valid = (ph == P_RUN) & lsu_opr_valid & (unsup_q | (c_iss & alu_rdy & mau_rdy));
    assign acc = res_valid & lsu_res_ready;

    // forwarding registers, written with the zero flush of the cycle (mn_pe_lsu zf_*), at
    // {PE, cycle} (N_PE = 4) or the cycle
    localparam FA = MP ? 4 : 2;
    wire [FA-1:0] f_wa, f_ra;
    generate
        if (MP) begin : g_fa4
            assign f_wa = {pe_q, coll_c};
            assign f_ra = {pe_q, iss_c};
        end else begin : g_fa1
            assign f_wa = coll_c;
            assign f_ra = iss_c;
        end
    endgenerate
    wire         fwd_on  = acc & ~unsup_q & ~rdo_q & ~d_noforward;
    wire [127:0] aluf_wd = (zf_en & (zf_sel == 2'b01)) ? (alu_z & zf_mask) : alu_z;
    wire [127:0] mauf_wd = (zf_en & (zf_sel == 2'b00)) ? (maub_rd[127:0] & zf_mask) : maub_rd[127:0];
    mn_ram_lut #(.W(128), .AW(FA), .NR(1)) u_aluf (
        .clk(clk), .we(fwd_on & (alu_act | xpe)), .waddr(f_wa), .wdata(aluf_wd),
        .raddr(f_ra), .rdata(aluf_rd));
    generate
        if (MAU != 0) begin : g_mauf
            mn_ram_lut #(.W(128), .AW(FA), .NR(1)) u_mauf (
                .clk(clk), .we(fwd_on & mau_act), .waddr(f_wa), .wdata(mauf_wd),
                .raddr(f_ra), .rdata(mauf_rd));
        end else begin : g_nomauf
            assign mauf_rd = 128'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_mauf = ^mauf_wd;
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    // ------------------------------------------------------------------ local memories
    wire         lsu_busy, lsu_unsup;
    generate
        if (!MP) begin : g_mem1
            // the word for mn_pe_lsu: imr = 0 in the start clock (check every enabled write),
            // then the word itself, or ll = 00 for an unsupported word (nothing is written)
            wire [425:0] jw_chk = {jw[425:424], 5'b00000, jw[418:0]};
            wire [425:0] jw_nul = {2'b00, jw[423:0]};
            wire [425:0] jw_lsu = (ph == P_IDLE) ? jw_chk : (unsup_q ? jw_nul : jw);
            localparam [31:0] P32 = POS_P;
            mn_pe_mem #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .RBS(1)) u_mem (
                .clk(clk), .rst(rst), .subpe(P32[1:0]),
                .start(go), .idle(lsu_idle), .jw(jw_lsu), .rd_use(rd_use), .busy(lsu_busy),
                .opr_valid(lsu_opr_valid), .opr_cycle(iss_c), .opr_mem(opr_mem),
                .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
                .res_valid(res_valid), .res_ready(lsu_res_ready), .res_cycle(lsu_res_cycle),
                .res_mau(maub_rd[127:0]), .res_alu(alu_z), .res_l1bm(128'd0), .res_mread(128'd0),
                .res_alu_flags(alu_f), .res_mau_flags(maub_rd[131:128]),
                .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
                .done(lsu_done), .trap(lsu_trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
                .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(lsu_unsup),
                .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we),
                .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr), .hp_req_wdata(hp_req_wdata),
                .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
                .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata)
            );
            /* verilator lint_off UNUSEDSIGNAL */
            // one PE: the PE inputs, the PE of the step and the T-source flag are not used
            wire unused_mp = ^{pe, hp_pe, t_src, pe_q};
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_memn
            // the memories of the PEs; the word itself, with nul for a check-only step or an
            // unsupported word (mn_mab_mem makes the start-clock and ll = 00 forms)
            mn_mab_mem #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .NPE(N_PE)) u_mem (
                .clk(clk), .rst(rst), .pe(pe),
                .start(go), .idle(lsu_idle), .jw(jw), .rd_use(rd_use), .nul(unsup | rdo_in),
                .ctx_t(t_src), .busy(lsu_busy),
                .opr_valid(lsu_opr_valid), .opr_cycle(iss_c), .opr_mem(opr_mem),
                .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
                .res_valid(res_valid), .res_ready(lsu_res_ready), .res_cycle(lsu_res_cycle),
                .res_mau(maub_rd[127:0]), .res_alu(alu_z), .res_l1bm(128'd0), .res_mread(128'd0),
                .res_alu_flags(alu_f), .res_mau_flags(maub_rd[131:128]),
                .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
                .done(lsu_done), .trap(lsu_trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
                .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(lsu_unsup),
                .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we),
                .hp_pe(hp_pe), .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr),
                .hp_req_wdata(hp_req_wdata), .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
                .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata)
            );
        end
    endgenerate

    // ------------------------------------------------------------------ sequencer
    always @(posedge clk) begin
        if (rst) begin
            ph       <= P_IDLE;
            done     <= 1'b0;
            st       <= 2'd0;
            st_field <= 7'd0;
            unsup_q  <= 1'b0;
            ufield_q <= 7'd0;
            rdo_q    <= 1'b0;
            xpe_q    <= 1'b0;
            pe_q     <= 2'd0;
            need_q   <= 5'd0;
            iss_c    <= 2'd0;
            iss_fin  <= 1'b0;
            gpend    <= 5'd0;
            alu_isd  <= 1'b0;
            mau_isd  <= 1'b0;
            coll_c   <= 2'd0;
            mau_cnt  <= 3'd0;
        end else begin
            done <= 1'b0;
            if (go) begin
                ph       <= P_RUN;
                unsup_q  <= unsup;
                ufield_q <= ufield;
                rdo_q    <= rdo_in;
                xpe_q    <= xpe & ~rdo_in;
                pe_q     <= MP ? pe : 2'd0;
                need_q   <= need;
                iss_c    <= 2'd0;
                iss_fin  <= 1'b0;
                gpend    <= need;
                alu_isd  <= 1'b0;
                mau_isd  <= 1'b0;
                coll_c   <= 2'd0;
                mau_cnt  <= 3'd0;
            end else if (ph == P_RUN) begin
                // gather / issue
                if (g_on) gpend <= gpend & ~glow;
                if (iss_adv) begin
                    iss_c   <= iss_c + 2'd1;
                    iss_fin <= (iss_c == 2'd3);
                    gpend   <= need_q;
                    alu_isd <= 1'b0;
                    mau_isd <= 1'b0;
                end else begin
                    alu_isd <= alu_isd | alu_acc;
                    mau_isd <= mau_isd | mau_acc;
                end
                // collect
                if (mau_got) mau_cnt <= mau_cnt + 3'd1;
                if (acc) coll_c <= coll_c + 2'd1;
                // end of the step
                if (lsu_done) begin
                    ph       <= P_IDLE;
                    done     <= 1'b1;
                    st       <= lsu_trap ? 2'd1 : unsup_q ? 2'd2 : 2'd0;
                    st_field <= ufield_q;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // simulation checks of the internal protocol
    always @(posedge clk) begin
        if (!rst && acc && !unsup_q && (lsu_res_cycle != coll_c))
            $display("mn_pe_core: ERROR res_cycle %0d != collected cycle %0d", lsu_res_cycle, coll_c);
        if (!rst && alu_pop && (alu_int ? int_err : fp_err))
            $display("mn_pe_core: ERROR the ALU did not execute the instruction (out_err)");
        if (!rst && go && (d_ll[0] == 1'b0))
            $display("mn_pe_core: ERROR start with a word that is not executed (ll = %b)", d_ll);
        if (!rst && go && !MP && rd_only)
            $display("mn_pe_core: ERROR check-only step with one PE");
    end
`endif

    /* verilator lint_off UNUSEDSIGNAL */
    // lsu_busy: the core uses idle; lsu_unsup (word length 11): the decoder reports it
    // (unsup_vec); int_err / fp_err: routing follows mn_alu_cls, checked in simulation only.
    // opr_grf1 / opr_lm0 / opr_lm1: the shared read buffer gives every memory on opr_grf0.
    wire unused = ^{lsu_busy, lsu_unsup, int_err, fp_err, d_ll, lsu_res_cycle, opr_grf1, opr_lm0, opr_lm1,
                    rd_only};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire

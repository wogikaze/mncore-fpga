// mn_l2bm: the L2BM of one L2B, the L2BM instructions (L2BM <-> L1BM transfers, internal
// multicast between L1BMs) and the DAR / DAR buffer of the group (WP32).
//
// Interface and semantics: mncore/rtl/l2bm/README.md (the port definition for WP37 / WP33).
// Short version:
//   - The core gives the L2BM fields of the j word (mn_dec_j: l1bm_gwrite, l1bm_gadr, l2bm_*)
//     and five L1BM fields of the same word, stable from start until done. act / chk_* are
//     combinational from them.
//   - Step (a word with act): start; the unit runs the part that must precede the L1BM
//     unit's commit (the L1BM reads of L1BM -> L2BM transfers and reductions, the L2BM writes,
//     l2bmdars / l2bmdarw) and raises pre_done; the core commits the L1BM unit (mn_l1bm), then
//     pulses commit here; the unit runs its L1BM writes (L2BM -> L1BM transfers, l2bmi) and
//     pulses done. A word with chk_trap / chk_unsup must not be executed. Every other executed
//     j word (act = 0, ll = 00 included; not the m words) pulses skip (for the l2bmdars rule).
//   - The L1BMs are reached through the master port lb_* (contract section 6 bus plus the L1B
//     number lb_req_l1b), to be connected to port B of mn_l1bm of that L1B.
//   - Port B: the L2BM through the contract section 6 bus (MV side of WP33, host space 7),
//     served in the clocks where the unit does not use the memory port it needs.
//   - dar_*: the DAR read port of the MV indirect transfers (WP33).
// Semantics (official emulator, probed with mncore/sim/tb/l2bm; the model is l2model.py):
//   gwrite = 1, lwrite = 0 (L2BM -> L1BM, to the L1Bs of the set l1adr / immode that exist):
//     bdmode 01 l2bmb   L1BM[g16 + 16 c + k]  <- L2BM[a + 16 c + k]
//            10 l2bmb2  L1BM[g16 + 16 c + k]  <- L2BM[a + 64 c + 16 (b >> 1) + k]
//            00 l2bmd   L1BM[g8 + 8 c + k]    <- L2BM[a + 64 c + 8 b + k]
//            11 nothing
//   lwrite = 1, gwrite = 0 (L1BM -> L2BM; L1Bs outside the set send the identity, absent ones 0):
//     bdmode 01 l2bmr / l2bm@n (= bor over {n})   L2BM[a + 16 c + k] <- reduce over the 8 L1Bs
//            10 l2bmr2                            L2BM[a + 64 c + 16 g + k] <- reduce L1Bs 2g, 2g+1
//                 of L1BM[g16 + 16 c + k], opcode / dmode (precision 64 / 32 / 16-bit lanes)
//            00 l2bmd (gather, only when immode = 111; else nothing)
//                 L2BM[a + 64 c + 8 b + k] <- L1BM of L1B b [g8 + 8 c + k]
//   gwrite = lwrite = 1, bdmode 00: l2bmi; L1B d outside the set gets, at L1BM[16 ladr + 16 c + k],
//     L1BM[g16 + 16 c + k] of the source L1B (l1adr & ~immode) | (d & immode); the sources are
//     not written. With immode = 111 it is the gather above.
//   with a = 16 ladr, g16 = 16 gadr[9:1] (gadr[0] is not used), g8 = 8 gadr, c = cycle 0..3.
//   l2bmdars: DAR buffer [128 c + 2 i] / [+ 1] <- MSB / LSB half of L2BM[a + 64 c + i] (L2B 0;
//     L2B 1 does not exist: 0); the 12 bits l1adr..opcode are {DAR address, L2B number (bit 0
//     used)}; the DAR write address is set, the DAR buffer read address cleared. In a run of
//     l2bmdars in consecutive j words, the later ones only refresh the buffer: the addresses and
//     the L2B stay those of the first. l2bmdarw (after l2bmdars in the same word): 4 times
//     DAR[w++ mod 1024] <- DAR buffer[r++ mod 512].
//   Order within a word: every read sees the state before the word; the L1BM writes go cycle
//   by cycle, the L1BM unit's PE -> L1BM writes of cycle c before the L2BM writes of cycle c
//   (so an L2BM write is dropped where the PE side writes the same address in a later cycle).
`default_nettype none
module mn_l2bm #(
    parameter N_L1B = 1,    // L1Bs of the L2B (1..8), L1B 0 .. N_L1B-1 exist (contract N_L1B)
    parameter AW    = 11,   // L2BM depth = 2**AW long words (contract L2BM_DEPTH = 2048; chip 15)
    parameter L1AW  = 10,   // L1BM depth 2**L1AW of the range checks (contract L1BM_DEPTH; chip 13)
    parameter RRN   = 1,    // 1: reductions on mn_l1bm_rrn (any N_L1B); 2: N_L1B = 1 only, one
                            // value with zeros / identities per lane (small); 0: bor only (l2bm@)
    parameter DAR   = 1,    // 1: DAR (1024 x 32) and DAR buffer (512 x 32); 0: none (E_UNSUPPORTED)
    parameter CLEAR = 1     // 1: after reset, clear the L2BM, the DAR and its buffer (idle = 0)
) (
    input  wire         clk,
    input  wire         rst,
    // ---- fields of the j word (mn_dec_j), stable from start until done
    input  wire [1:0]   ll,
    input  wire         l1bm_gwrite,
    input  wire [9:0]   l1bm_gadr,
    input  wire         l2bm_lwrite,
    input  wire [1:0]   l2bm_bdmode,
    input  wire [10:0]  l2bm_ladr,
    input  wire [2:0]   l2bm_l1adr,
    input  wire [2:0]   l2bm_immode,
    input  wire [1:0]   l2bm_dmode,
    input  wire [3:0]   l2bm_opcode,
    input  wire         l2bm_darsend,
    input  wire         l2bm_darwrite,
    //      the L1BM unit's PE -> L1BM writes of the same word (for the order of the L1BM writes)
    input  wire [1:0]   l1bm_bmode,
    input  wire         l1bm_lwrite,
    input  wire         l1bm_me,
    input  wire [12:0]  l1bm_ladr,
    input  wire         l1bm_wl,
    // ---- what the word does (combinational from the fields)
    output wire         act,         // the word has an L2BM instruction (start .. done needed)
    output wire         chk_trap,    // E_RANGE: an L2BM / L1BM access at or beyond the capacity
    output wire         chk_unsup,   // E_UNSUPPORTED
    output wire [6:0]   chk_field,   //   field index (MN_J_<field>_IDX)
    // ---- step
    input  wire         start,       // taken when idle
    output wire         idle,
    output wire         pre_done,    // level: the L1BM unit may commit now
    input  wire         commit,      // after the L1BM unit's commit (done); taken from start on
    output reg          done,        // 1-clock pulse
    input  wire         skip,        // 1-clock pulse per executed j word that does not start the
                                     // unit (act = 0, also ll = 00); not for m words
    // ---- L1BM master port: to port B of mn_l1bm of L1B lb_req_l1b (contract section 6 bus)
    output wire         lb_req_valid,
    input  wire         lb_req_ready,
    output wire [2:0]   lb_req_l1b,
    output wire         lb_req_we,
    output wire [22:0]  lb_req_addr,
    output wire [63:0]  lb_req_wdata,
    output wire [7:0]   lb_req_wmask,
    input  wire         lb_req_err,  // with the accept (address beyond the L1BM): read data 0
    input  wire         lb_rsp_valid,
    input  wire [63:0]  lb_rsp_rdata,
    // ---- port B: the L2BM as a memory (contract section 6 bus, long word addresses)
    input  wire         b_req_valid,
    output wire         b_req_ready,
    input  wire         b_req_we,
    input  wire [22:0]  b_req_addr,
    input  wire [63:0]  b_req_wdata,
    input  wire [7:0]   b_req_wmask, // a 32-bit half is written when its 4 bits are all 1
    output wire         b_req_err,   // with the accept: address at or beyond 2**AW (dropped)
    output reg          b_rsp_valid,
    output wire [63:0]  b_rsp_rdata,
    // ---- DAR read port (MV indirect transfers, WP33): dar_rdata = DAR[dar_raddr] of the clock
    //      where dar_re = 1, valid from the next clock, held while dar_re = 0
    input  wire         dar_re,
    input  wire [9:0]   dar_raddr,
    output wire [31:0]  dar_rdata
);
`include "mn_jfields.vh"

    localparam integer NLI = N_L1B;
    localparam [3:0]   NL  = NLI[3:0];

    // ------------------------------------------------------------------ word decode
    /* verilator lint_off UNUSEDSIGNAL */
    // ll: 01 normal and 11 noforward act alike here (probed); 00 nop, 10 is E_DECODE (core)
    wire [1:0] ll_u = ll;
    /* verilator lint_on UNUSEDSIGNAL */
    wire       ex   = ll_u[0];
    wire       gw   = l1bm_gwrite;
    wire       lw   = l2bm_lwrite;
    wire [1:0] bd   = l2bm_bdmode;
    wire       ds   = l2bm_darsend;
    wire       dw   = l2bm_darwrite;
    wire [2:0] keep = ~l2bm_immode;
    wire       im7  = (l2bm_immode == 3'b111);
    assign act = ex & (gw | lw | ds | dw);

    // the set (l1adr / immode) and the L1Bs that exist
    wire [7:0] mem;
    wire [7:0] pres;
    genvar gb;
    generate
        for (gb = 0; gb < 8; gb = gb + 1) begin : g_set
            localparam [2:0] B = gb;
            assign mem[gb]  = ((B & keep) == (l2bm_l1adr & keep));
            assign pres[gb] = (gb < N_L1B);
        end
    endgenerate
    wire [7:0] pm = pres & mem;                  // L1Bs of the set that exist
    wire [7:0] pd = pres & ~mem;                 // l2bmi: destinations that exist

    // operations of the word
    wire o_dars = ex & ds;
    wire o_darw = ex & dw;
    wire o_l2l1 = ex & ~ds & gw & ~lw & (bd != 2'b11);            // l2bmb / l2bmb2 / l2bmd
    wire o_gath = ex & ~ds & lw & (bd == 2'b00) & im7;            // l2bmd (gather), l2bmi with 111
    wire o_red  = ex & ~ds & lw & ~gw & (bd[1] ^ bd[0]);          // l2bmr, l2bm@, l2bmr2
    wire o_imc  = ex & ~ds & gw & lw & (bd == 2'b00) & ~im7;      // l2bmi

    // reduction operation (mn_l1bm_rrn): 0 fadd, 1 max, 2 min, 3 iadd, 4 band, 5 and, 6 bor, 7 or
    reg       op_ok;
    reg [2:0] rop;
    always @* begin
        op_ok = 1'b1;
        case (l2bm_opcode)
            4'b0000: rop = 3'd0;
            4'b0001: rop = 3'd1;
            4'b0010: rop = 3'd2;
            4'b1000: rop = 3'd3;
            4'b1001: rop = 3'd4;
            4'b1010: rop = 3'd5;
            4'b1100: rop = 3'd6;
            4'b1101: rop = 3'd7;
            default: begin rop = 3'd0; op_ok = 1'b0; end
        endcase
    end
    wire [1:0] rfmt = l2bm_dmode;                // lane: 0 64 bits, 1 32, 2 16 (3: unsupported)

    // ------------------------------------------------------------------ addresses
    wire [12:0] g16  = {l1bm_gadr[9:1], 4'd0};   // L1BM, 16 long words per cycle
    wire [12:0] g8   = {l1bm_gadr, 3'd0};        // L1BM, 8 long words per cycle
    wire [14:0] ac   = {l2bm_ladr, 4'd0};        // L2BM (l2bmi: the destination in the L1BMs)

    // the largest member that exists (bcast2 / distrib reads)
    reg [2:0] bmax;
    integer   ia;
    always @* begin
        bmax = 3'd0;
        for (ia = 0; ia < 8; ia = ia + 1)
            if (pm[ia]) bmax = ia[2:0];
    end
    // l2bmi: some destination that exists has a source that exists
    reg any_ps;
    reg [2:0] sd;
    integer   ib;
    always @* begin
        any_ps = 1'b0;
        sd     = 3'd0;
        for (ib = 0; ib < 8; ib = ib + 1) begin
            sd = (l2bm_l1adr & keep) | (ib[2:0] & l2bm_immode);
            if (pd[ib] && ({1'b0, sd} < NL)) any_ps = 1'b1;
        end
    end

    // l2bmdars state (see the sequencer)
    reg         ds_prev;    // the previous j word had l2bmdars
    reg         ds_first;   // ... seen at the start of this word: keep the DAR addresses
    reg         ds_l2b;     // the L2B of the first l2bmdars of the run (bit 0 of its L2B number)
    // l2bmdars: the L2B read (bit 0 of the L2B number; 1 is L2B 1, absent: zeros). In a run of
    // consecutive l2bmdars words it is the one of the first word (official, probed)
    wire dl2b_run = ds_first ? ds_l2b : l2bm_opcode[0];     // during the word
    wire dl2b_now = ds_prev ? ds_l2b : l2bm_opcode[0];      // before start (range check)

    // ------------------------------------------------------------------ range check
    // Only the accesses that happen (contract section 3): reads for L1Bs that exist, the writes
    // of every slot of an L1BM -> L2BM transfer (absent L1Bs give 0), the reads of l2bmdars of
    // L2B 0. Addresses are compared before wrapping (beyond the reduced capacity is E_RANGE).
    reg [16:0] l2max;
    reg        l2acc;
    always @* begin
        l2acc = 1'b0;
        l2max = {2'b00, ac};
        if (o_l2l1 & (|pm)) begin
            l2acc = 1'b1;
            case (bd)
                2'b01:   l2max = {2'b00, ac} + 17'd63;
                2'b10:   l2max = {2'b00, ac} + 17'd207 + {11'd0, bmax[2:1], 4'd0};
                default: l2max = {2'b00, ac} + 17'd199 + {11'd0, bmax, 3'd0};
            endcase
        end else if (o_dars & ~dl2b_now) begin
            l2acc = 1'b1;
            l2max = {2'b00, ac} + 17'd255;
        end else if (o_red | o_gath) begin
            l2acc = 1'b1;
            l2max = {2'b00, ac} + ((o_red & (bd == 2'b01)) ? 17'd63 : 17'd255);
        end
    end
    reg [15:0] l1max;
    reg        l1acc;
    always @* begin
        l1acc = 1'b0;
        l1max = {3'd0, g16};
        if (o_l2l1 & (|pm)) begin
            l1acc = 1'b1;
            l1max = (bd == 2'b00) ? ({3'd0, g8} + 16'd31) : ({3'd0, g16} + 16'd63);
        end else if (o_red & (|pm)) begin
            l1acc = 1'b1;
            l1max = {3'd0, g16} + 16'd63;
        end else if (o_gath) begin
            l1acc = 1'b1;
            l1max = {3'd0, g8} + 16'd31;
        end else if (o_imc & any_ps) begin
            l1acc = 1'b1;
            l1max = {3'd0, g16} + 16'd63;
        end
    end
    // l2bmi destination: 16 ladr does not wrap at the chip's 8192 (probed)
    wire [16:0] idmax = {2'b00, ac} + 17'd63;
    wire t_l2 = l2acc & (l2max >= (17'd1 << AW));
    wire t_l1 = l1acc & ({1'b0, l1max} >= (17'd1 << L1AW));
    wire t_id = o_imc & (|pd) & (idmax >= (17'd1 << L1AW));
    assign chk_trap = t_l2 | t_l1 | t_id;

    // ------------------------------------------------------------------ the L1BM unit's writes
    // PE -> L1BM with me = 1 writes, in cycle c, the block base + c * 2**lg .. + 2**lg - 1 of the
    // L1BM of each L1B (mn_l1bm: bmode 00 as 01; l1bmd: 64, l1bmm4@: 16 / 32, l1bmm@: 4 / 8).
    wire        pe_w   = ex & l1bm_lwrite & l1bm_me;
    wire [1:0]  p_bm   = (l1bm_bmode == 2'b00) ? 2'b01 : l1bm_bmode;
    wire [2:0]  p_lg   = (p_bm == 2'b11) ? 3'd6 : (p_bm == 2'b10) ? (l1bm_wl ? 3'd5 : 3'd4) : (l1bm_wl ? 3'd3 : 3'd2);
    wire [12:0] p_base = (p_bm == 2'b11) ? {l1bm_ladr[12:6], 6'd0} : l1bm_ladr;
    // the PE side (base, log2 of the block) writes long word a in a cycle after cl
    function pe_later(input [12:0] a, input [1:0] cl, input [12:0] base, input [2:0] lg);
        reg [13:0] o;
        reg [13:0] q;
        begin
            o = {1'b0, a} - {1'b0, base};
            q = o >> lg;
            pe_later = ~o[13] & (q < 14'd4) & (q[1:0] > cl);
        end
    endfunction
    // l2bmi with several L1Bs reads its sources after the L1BM unit's commit: unsupported when
    // the PE side writes them in the same word (with N_L1B = 1 l2bmi reads nothing)
    wire [13:0] p_end  = {1'b0, p_base} + ({11'd0, 3'd4} << p_lg);
    wire        imc_ov = (N_L1B > 1) & o_imc & any_ps & pe_w & ({1'b0, g16} < p_end) &
                         ({1'b0, p_base} < ({1'b0, g16} + 14'd64));

    // ------------------------------------------------------------------ unsupported words
    // (the emulator aborts on lwrite with bdmode 11, l2bmi with bdmode != 00, reductions with
    // dmode 11 or an opcode outside the table; l2bmdars shares its fields with the transfers)
    wire u_bd  = ex & ~ds & lw & ((bd == 2'b11) | (gw & (bd != 2'b00)));
    wire u_dm  = o_red & (l2bm_dmode == 2'b11);
    wire u_op  = o_red & (~op_ok | ((RRN == 0) & (l2bm_opcode != 4'b1100)));
    wire u_ds  = ex & ds & (gw | lw);
    wire u_dar = ex & (DAR == 0) & (ds | dw);
    assign chk_unsup = u_bd | u_dm | u_op | u_ds | u_dar | imc_ov;
    assign chk_field = u_bd  ? MN_J_L2BM_BDMODE_IDX[6:0] :
                       u_dm  ? MN_J_L2BM_DMODE_IDX[6:0] :
                       u_op  ? MN_J_L2BM_OPCODE_IDX[6:0] :
                       (u_ds | (u_dar & ds)) ? MN_J_L2BM_DARSEND_IDX[6:0] :
                       u_dar ? MN_J_L2BM_DARWRITE_IDX[6:0] : MN_J_L1BM_GWRITE_IDX[6:0];
    wire w_ok = ~chk_trap & ~chk_unsup;

    // ------------------------------------------------------------------ sequencer state
    localparam [2:0] P_IDLE = 3'd0, P_CLR = 3'd1, P_JOB = 3'd2, P_WAIT = 3'd3;
    localparam [2:0] J_DARS = 3'd0, J_DARW = 3'd1, J_GATH = 3'd2, J_RED = 3'd3, J_L2L1 = 3'd4, J_IMC = 3'd5;
    localparam [3:0] S_ITEM = 4'd0, S_L2R = 4'd1, S_L1Q = 4'd2, S_L1S = 4'd3, S_L1W = 4'd4, S_L2W = 4'd5,
                     S_DB0 = 4'd6, S_DB1 = 4'd7, S_DW = 4'd8, S_FET = 4'd9, S_RS = 4'd10, S_RW = 4'd11;
    reg  [2:0]  ph;
    reg  [2:0]  job;
    reg  [3:0]  st;
    reg         cpend;
    reg  [1:0]  c;          // cycle
    reg  [2:0]  u;          // L1B / group / 16-long-word slice
    reg  [3:0]  k;          // long word
    reg  [3:0]  fq;         // reduction input being fetched
    reg  [1:0]  lj;         // reduction lane
    reg  [63:0] wbuf;       // the long word being moved; the reduction result being assembled
    reg  [15:0] clr_a;
    reg  [9:0]  dw_a;       // DAR write address
    reg  [8:0]  db_r;       // DAR buffer read address
    assign idle     = (ph == P_IDLE);
    assign pre_done = (ph == P_WAIT);

    // loop bounds of the job
    wire [3:0] kmax = (job == J_DARW) ? 4'd3 :
                      ((job == J_GATH) | ((job == J_L2L1) & (bd == 2'b00))) ? 4'd7 : 4'd15;
    localparam integer ULI = N_L1B - 1;
    localparam [2:0] UL = ULI[2:0];
    wire [2:0] umax = (job == J_DARS) ? 3'd3 :
                      (job == J_RED)  ? ((bd == 2'b01) ? 3'd0 : 3'd3) :
                      (job == J_DARW) ? 3'd0 :
                      (job == J_GATH) ? 3'd7 : UL;
    wire k_last = (k == kmax);
    wire u_last = (u == umax);
    wire c_last = (job == J_DARW) | (c == 2'd3);

    // item addresses
    wire [14:0] a_bc  = ac + {7'd0, 2'b00, c, k};                // 16 c + k
    wire [14:0] a_b2  = ac + {7'd0, c, u[2:1], k};               // 64 c + 16 (b >> 1) + k
    wire [14:0] a_d8  = ac + {7'd0, c, u, k[2:0]};               // 64 c + 8 b + k
    wire [14:0] a_s16 = ac + {7'd0, c, u[1:0], k};               // 64 c + 16 u + k
    wire [12:0] l_16  = g16 + {7'd0, c, k};                      // L1BM 16 c + k
    wire [12:0] l_8   = g8 + {8'd0, c, k[2:0]};                  // L1BM 8 c + k
    /* verilator lint_off UNUSEDSIGNAL */
    // l2bmi destination: the bits above the L1BM address were checked by chk_trap
    wire [14:0] l_id  = ac + {7'd0, 2'b00, c, k};
    /* verilator lint_on UNUSEDSIGNAL */
    // L2BM read address (l2bmb / l2bmb2 / l2bmd, l2bmdars)
    wire [14:0] a2r   = (job == J_DARS) ? a_s16 : (bd == 2'b01) ? a_bc : (bd == 2'b10) ? a_b2 : a_d8;
    // L2BM write address (gather, reductions)
    wire [14:0] a2w   = (job == J_GATH) ? a_d8 : (bd == 2'b01) ? a_bc : a_s16;
    // L1BM write address and L1B (l2bmb / l2bmb2 / l2bmd, l2bmi)
    wire [12:0] a1w   = (job == J_IMC) ? l_id[12:0] : (bd == 2'b00) ? l_8 : l_16;
    // l2bmi source L1B of destination u
    wire [2:0]  i_src = (l2bm_l1adr & keep) | (u & l2bm_immode);
    // reduction: the input L1B being fetched
    wire [2:0]  f_b   = (bd == 2'b01) ? fq[2:0] : {u[1:0], fq[0]};
    wire [3:0]  f_last = (bd == 2'b01) ? {1'b0, UL} : 4'd1;
    // L1BM read: L1B and address
    wire [2:0]  q_l1b = (job == J_IMC) ? i_src : (job == J_RED) ? f_b : u;
    wire [12:0] q_adr = (job == J_GATH) ? l_8 : l_16;

    // ------------------------------------------------------------------ L2BM memory
    wire [1:0]    m_we;
    wire [AW-1:0] m_waddr;
    wire [63:0]   m_wdata;
    wire          m_re;
    wire [AW-1:0] m_raddr;
    wire [63:0]   m_rdata;
    mn_ram_1r1w #(.W(64), .AW(AW), .NWE(2), .OREG(0)) u_mem (
        .clk(clk), .we(m_we), .waddr(m_waddr), .wdata(m_wdata),
        .re(m_re), .raddr(m_raddr), .rdata(m_rdata));

    wire run     = (ph == P_JOB);
    wire clr_on  = (ph == P_CLR);
    wire it_skip = ((job == J_L2L1) & ~pm[u]) | ((job == J_IMC) & ~pd[u]);
    wire it_late = pe_w & pe_later(a1w, c, p_base, p_lg);
    wire seq_re  = run & (st == S_ITEM) & (((job == J_DARS) & ~dl2b_run) |
                                           ((job == J_L2L1) & ~it_skip & ~it_late));
    wire seq_we  = run & (st == S_L2W);

    // ------------------------------------------------------------------ port B
    wire b_ok  = (b_req_addr < (23'd1 << AW));
    assign b_req_ready = b_req_we ? ~(seq_we | clr_on) : ~seq_re;
    wire b_go  = b_req_valid & b_req_ready & b_ok;
    wire b_wgo = b_go & b_req_we;
    wire b_rgo = b_go & ~b_req_we;
    assign b_req_err = b_req_valid & b_req_ready & ~b_ok;
    assign b_rsp_rdata = m_rdata;

    /* verilator lint_off UNUSEDSIGNAL */
    // chip addresses (15 bits); only the low AW bits index the L2BM (chk_trap checked the rest)
    wire [14:0] a2r_c = a2r;
    wire [14:0] a2w_c = a2w;
    /* verilator lint_on UNUSEDSIGNAL */
    assign m_re    = seq_re | b_rgo;
    assign m_raddr = seq_re ? a2r_c[AW-1:0] : b_req_addr[AW-1:0];
    assign m_we    = clr_on ? 2'b11 : seq_we ? 2'b11 :
                     b_wgo ? {&b_req_wmask[7:4], &b_req_wmask[3:0]} : 2'b00;
    assign m_waddr = clr_on ? clr_a[AW-1:0] : seq_we ? a2w_c[AW-1:0] : b_req_addr[AW-1:0];
    assign m_wdata = (clr_on | seq_we) ? wbuf : b_req_wdata;     // wbuf = 0 while clearing

    // ------------------------------------------------------------------ L1BM master port
    assign lb_req_valid = run & ((st == S_L1Q) | (st == S_L1W));
    assign lb_req_we    = (st == S_L1W);
    assign lb_req_l1b   = (st == S_L1W) ? u : q_l1b;
    assign lb_req_addr  = {10'd0, (st == S_L1W) ? a1w : q_adr};
    assign lb_req_wdata = wbuf;
    assign lb_req_wmask = 8'hff;

    // ------------------------------------------------------------------ DAR buffer and DAR
    wire        db_we = run & ((st == S_DB0) | (st == S_DB1));
    wire [8:0]  db_wa = {c, u[1:0], k, (st == S_DB1)};
    wire [31:0] db_wd = (st == S_DB1) ? wbuf[31:0] : wbuf[63:32];
    wire        db_re = run & (st == S_ITEM) & (job == J_DARW);
    wire [31:0] db_rd;
    wire        dr_we = run & (st == S_DW);
    generate
        if (DAR != 0) begin : g_dar
            mn_ram_1r1w #(.W(32), .AW(9), .NWE(1), .OREG(0)) u_dbuf (
                .clk(clk), .we(clr_on | db_we), .waddr(clr_on ? clr_a[8:0] : db_wa),
                .wdata(db_wd), .re(db_re), .raddr(db_r), .rdata(db_rd));      // wbuf = 0 while clearing
            mn_ram_1r1w #(.W(32), .AW(10), .NWE(1), .OREG(0)) u_dar (
                .clk(clk), .we(clr_on | dr_we), .waddr(clr_on ? clr_a[9:0] : dw_a),
                .wdata(clr_on ? 32'd0 : db_rd), .re(dar_re), .raddr(dar_raddr), .rdata(dar_rdata));
        end else begin : g_nodar
            assign db_rd     = 32'd0;
            assign dar_rdata = 32'd0;
            wire unused_dar = ^{db_we, db_wa, db_wd, db_re, dr_we, dar_re, dar_raddr, db_rd};
        end
    endgenerate

    // ------------------------------------------------------------------ reductions
    // lane j of a long word (lane value in the low bits; lane 0 is the MSB side)
    function [63:0] lane_of(input [63:0] w, input [1:0] f, input [1:0] j);
        begin
            case (f)
                2'd0:    lane_of = w;
                2'd1:    lane_of = j[0] ? {32'd0, w[31:0]} : {32'd0, w[63:32]};
                default: lane_of = {48'd0, w[63 - 16 * j -: 16]};
            endcase
        end
    endfunction
    function [63:0] put_lane(input [63:0] w, input [1:0] f, input [1:0] j, input [63:0] v);
        begin
            put_lane = w;
            case (f)
                2'd0:    put_lane = v;
                2'd1:    if (j[0]) put_lane[31:0] = v[31:0]; else put_lane[63:32] = v[31:0];
                default: put_lane[63 - 16 * j -: 16] = v[15:0];
            endcase
        end
    endfunction
    // the identity element of an L1B outside the set: fadd / iadd / bor / or 0, max / band all
    // ones, min all ones but the sign, and 1 (official emulator, probed)
    function [63:0] ident(input [2:0] op, input [1:0] f);
        reg [63:0] m;
        begin
            m = (f == 2'd0) ? 64'hffffffffffffffff : (f == 2'd1) ? 64'h00000000ffffffff : 64'h000000000000ffff;
            case (op)
                3'd1, 3'd4: ident = m;
                3'd2:       ident = m >> 1;
                3'd5:       ident = 64'd1;
                default:    ident = 64'd0;
            endcase
        end
    endfunction
    wire [1:0] lj_last = (rfmt == 2'd0) ? 2'd0 : (rfmt == 2'd1) ? 2'd1 : 2'd3;

    // reduction inputs of the current output long word (the L1Bs of the set that exist)
    wire [2:0]  rr_idx;
    wire [2:0]  rr_b = (bd == 2'b01) ? rr_idx : {u[1:0], rr_idx[0]};
    wire [63:0] ib_rd;                  // input long word of L1B rr_b
    wire        ib_we = (RRN == 1) & run & (st == S_L1S) & (job == J_RED) & lb_rsp_valid;
    generate
        if ((N_L1B == 1) || (RRN != 1)) begin : g_ib1
            reg [63:0] ib0;
            always @(posedge clk) if (ib_we) ib0 <= lb_rsp_rdata;
            assign ib_rd = ib0;
        end else begin : g_ibn
            mn_ram_lut #(.W(64), .AW(3), .NR(1)) u_ib (
                .clk(clk), .we(ib_we), .waddr(f_b), .wdata(lb_rsp_rdata), .raddr(rr_b), .rdata(ib_rd));
        end
    endgenerate
    wire [63:0] rr_val = mem[rr_b] ? (pres[rr_b] ? lane_of(ib_rd, rfmt, lj) : 64'd0) : ident(rop, rfmt);

    wire        rr_start = run & (st == S_RS) & (job == J_RED);
    wire        rr_done;
    wire [63:0] rr_res;
    generate
        if (RRN == 1) begin : g_rrn
            wire [3:0] idx4;
            wire       rr_busy;
            mn_l1bm_rrn u_rrn (
                .clk(clk), .rst(rst), .start(rr_start), .op(rop), .fmt(rfmt), .out_half(1'b0),
                .two_stage(1'b0), .nin_m1((bd == 2'b01) ? 4'd7 : 4'd1), .zgrp(4'd0),
                .in_idx(idx4), .in_val(rr_val), .busy(rr_busy), .done(rr_done), .res(rr_res));
            assign rr_idx = idx4[2:0];
            wire unused_rr = rr_busy | idx4[3];
        end else if (RRN == 2) begin : g_rrn1
            // N_L1B = 1: the inputs are x0 (L1B 0, or 2g: its value (fetched into wbuf), 0 when
            // absent, the identity outside the set) and zeros (absent L1Bs of the set) or
            // identities; z: some zero. All lanes of the long word in one clock.
            wire [2:0]  b0 = (bd == 2'b01) ? 3'd0 : {u[1:0], 1'b0};
            wire [63:0] x0 = mem[b0] ? ((b0 == 3'd0) ? wbuf : 64'd0) : identw(rop, rfmt);
            wire        z  = (bd == 2'b01) ? (|mem[7:1]) : mem[{u[1:0], 1'b1}];
            assign rr_done = 1'b0;
            assign rr_idx  = 3'd0;
            assign rr_res  = red1w(rop, rfmt, x0, z);
            wire unused_rr = ^{rr_start, rr_val, lj_last};
        end else begin : g_norrn
            // bor only: the OR of the inputs, made while they are fetched
            assign rr_done = 1'b0;
            assign rr_idx  = 3'd0;
            assign rr_res  = 64'd0;
            wire unused_rr = ^{rr_start, rr_val, rop, lj_last};
        end
    endgenerate

    // RRN = 2: the identity of every lane of a long word
    function [63:0] identw(input [2:0] op, input [1:0] f);
        begin
            case (op)
                3'd1, 3'd4: identw = 64'hffffffffffffffff;
                3'd2:       identw = (f == 2'd0) ? 64'h7fffffffffffffff : (f == 2'd1) ? 64'h7fffffff7fffffff :
                                                   64'h7fff7fff7fff7fff;
                3'd5:       identw = (f == 2'd0) ? 64'd1 : (f == 2'd1) ? 64'h0000000100000001 : 64'h0001000100010001;
                default:    identw = 64'd0;
            endcase
        end
    endfunction
    // RRN = 2: every lane of the reduction of the long word x with zeros (zz) and identities
    // (viz/core rrn.rs with one value): fadd keeps the lane (0 for a zero exponent field, infinity
    // without mantissa for an all-ones one), max / min against +0, band with 0, and / or of the
    // lane and zeros (1 or 0). Lanes: f 0 one of 64 bits, 1 two of 32, 2 four of 16 (MSB first).
    function [63:0] red1w(input [2:0] op, input [1:0] f, input [63:0] x, input zz);
        integer    q;
        reg [3:0]  s, ez, ef, nz;      // per 16-bit chunk q: sign, exponent 0 / all ones, non-zero of its lane
        reg [15:0] ch, inf;
        reg        lo;                 // the chunk holds the LSB of its lane
        begin
            red1w = x;
            for (q = 0; q < 4; q = q + 1) begin
                case (f)
                    2'd0: begin
                        s[q] = x[63]; ez[q] = (x[62:52] == 11'd0); ef[q] = &x[62:52]; nz[q] = |x;
                    end
                    2'd1: begin
                        s[q]  = x[63 - 32 * (q / 2)];
                        ez[q] = (x[62 - 32 * (q / 2) -: 8] == 8'd0);
                        ef[q] = &x[62 - 32 * (q / 2) -: 8];
                        nz[q] = |x[63 - 32 * (q / 2) -: 32];
                    end
                    default: begin
                        s[q]  = x[63 - 16 * q];
                        ez[q] = (x[62 - 16 * q -: 6] == 6'd0);
                        ef[q] = &x[62 - 16 * q -: 6];
                        nz[q] = |x[63 - 16 * q -: 16];
                    end
                endcase
            end
            for (q = 0; q < 4; q = q + 1) begin
                ch  = x[63 - 16 * q -: 16];
                inf = (f == 2'd2) ? {s[q], 6'h3f, 9'd0} :
                      (f == 2'd1) ? (((q % 2) == 0) ? {s[q], 8'hff, 7'd0} : 16'd0) :
                                    ((q == 0) ? {s[q], 11'h7ff, 4'd0} : 16'd0);
                lo  = (f == 2'd2) | ((f == 2'd1) & ((q % 2) == 1)) | ((f == 2'd0) & (q == 3));
                case (op)
                    3'd0:    red1w[63 - 16 * q -: 16] = ez[q] ? 16'd0 : ef[q] ? inf : ch;   // fadd
                    3'd1:    red1w[63 - 16 * q -: 16] = (zz & s[q]) ? 16'd0 : ch;           // max
                    3'd2:    red1w[63 - 16 * q -: 16] = (zz & ~s[q]) ? 16'd0 : ch;          // min
                    3'd4:    red1w[63 - 16 * q -: 16] = zz ? 16'd0 : ch;                    // band
                    3'd5:    red1w[63 - 16 * q -: 16] = {15'd0, lo & ~zz & nz[q]};          // and
                    3'd7:    red1w[63 - 16 * q -: 16] = {15'd0, lo & nz[q]};                // or
                    default: red1w[63 - 16 * q -: 16] = ch;                                 // iadd, bor
                endcase
            end
        end
    endfunction

    // ------------------------------------------------------------------ sequencer
    wire [9:0]  dar_a   = {l2bm_l1adr, l2bm_immode, l2bm_dmode, l2bm_opcode[3:2]};
    localparam integer CLR_N = (AW > 10) ? (1 << AW) : 1024;
    localparam integer CLR_LI = CLR_N - 1;
    localparam [15:0]  CLR_LAST = CLR_LI[15:0];

    always @(posedge clk) begin
        if (rst) begin
            ph          <= (CLEAR != 0) ? P_CLR : P_IDLE;
            st          <= S_ITEM;
            job         <= J_DARS;
            cpend       <= 1'b0;
            clr_a       <= 16'd0;
            done        <= 1'b0;
            b_rsp_valid <= 1'b0;
            dw_a        <= 10'd0;
            db_r        <= 9'd0;
            ds_prev     <= 1'b0;
            ds_first    <= 1'b0;
            ds_l2b      <= 1'b0;
            c <= 2'd0; u <= 3'd0; k <= 4'd0; fq <= 4'd0; lj <= 2'd0;
            wbuf <= 64'd0;
        end else begin
            done        <= 1'b0;
            b_rsp_valid <= b_rgo;
            case (ph)
                P_CLR: begin
                    clr_a <= clr_a + 16'd1;
                    if (clr_a == CLR_LAST) ph <= P_IDLE;
                end
                P_IDLE: if (skip) begin
                    ds_prev <= 1'b0;
                end else if (start) begin
                    ds_first <= ds_prev;
                    ds_prev  <= o_dars & w_ok;
                    cpend <= commit;
                    c <= 2'd0; u <= 3'd0; k <= 4'd0; fq <= 4'd0; lj <= 2'd0;
                    st <= S_ITEM;
                    if (w_ok & o_dars)                begin ph <= P_JOB; job <= J_DARS; end
                    else if (w_ok & o_darw)           begin ph <= P_JOB; job <= J_DARW; end
                    else if (w_ok & o_gath)           begin ph <= P_JOB; job <= J_GATH; end
                    else if (w_ok & o_red)            begin ph <= P_JOB; job <= J_RED;  end
                    else                                    ph <= P_WAIT;
                end
                P_WAIT: if (commit || cpend) begin
                    cpend <= 1'b0;
                    c <= 2'd0; u <= 3'd0; k <= 4'd0;
                    st <= S_ITEM;
                    if (w_ok & o_l2l1)      begin ph <= P_JOB; job <= J_L2L1; end
                    else if (w_ok & o_imc)  begin ph <= P_JOB; job <= J_IMC;  end
                    else begin ph <= P_IDLE; done <= 1'b1; end
                end
                P_JOB: begin
                    if (commit && (job != J_L2L1) && (job != J_IMC)) cpend <= 1'b1;
                    case (st)
                        S_ITEM: begin
                            case (job)
                                J_DARS: if (dl2b_run) begin wbuf <= 64'd0; st <= S_DB0; end
                                        else st <= S_L2R;
                                J_DARW: st <= S_DW;
                                J_GATH: if (pres[u]) st <= S_L1Q;
                                        else begin wbuf <= 64'd0; st <= S_L2W; end
                                J_RED:  begin fq <= 4'd0; wbuf <= 64'd0; st <= S_FET; end
                                J_L2L1: if (it_skip) next_u;
                                        else if (it_late) next_k;
                                        else st <= S_L2R;
                                default: if (it_skip) next_u;                 // J_IMC
                                        else if (it_late) next_k;
                                        else if ({1'b0, i_src} < NL) st <= S_L1Q;
                                        else begin wbuf <= 64'd0; st <= S_L1W; end
                            endcase
                        end
                        S_L2R: begin
                            wbuf <= m_rdata;
                            st   <= (job == J_DARS) ? S_DB0 : S_L1W;
                        end
                        S_L1Q: if (lb_req_ready) begin
                            if (lb_req_err) begin
                                if (job != J_RED) wbuf <= 64'd0;
                                st   <= (job == J_RED) ? S_FET : (job == J_GATH) ? S_L2W : S_L1W;
                                if (job == J_RED) fq <= fq + 4'd1;
                            end else begin
                                st <= S_L1S;
                            end
                        end
                        S_L1S: if (lb_rsp_valid) begin
                            if (job == J_RED) begin
                                // RRN = 0: the bor of the inputs; RRN = 2: the one input (L1B 0);
                                // RRN = 1: the inputs are in the buffer ib
                                if (RRN != 1) wbuf <= wbuf | lb_rsp_rdata;
                                fq <= fq + 4'd1;
                                st <= S_FET;
                            end else begin
                                wbuf <= lb_rsp_rdata;
                                st <= (job == J_GATH) ? S_L2W : S_L1W;
                            end
                        end
                        S_L1W: if (lb_req_ready) next_k;
                        S_L2W: next_k;
                        S_DB0: st <= S_DB1;
                        S_DB1: next_k;
                        S_DW: begin
                            dw_a <= dw_a + 10'd1;
                            db_r <= db_r + 9'd1;
                            next_k;
                        end
                        S_FET: begin
                            if (fq > f_last) begin
                                lj <= 2'd0;
                                st <= (RRN == 0) ? S_L2W : S_RS;
                            end else if (pm[f_b]) begin
                                st <= S_L1Q;
                            end else begin
                                fq <= fq + 4'd1;
                            end
                        end
                        S_RS: if (RRN == 2) begin      // RRN = 2: the whole result now
                            wbuf <= rr_res;
                            st   <= S_L2W;
                        end else begin                 // RRN = 1: rr_start
                            st <= S_RW;
                        end
                        default: if (rr_done) begin   // S_RW (RRN = 1)
                            wbuf <= put_lane(wbuf, rfmt, lj, rr_res);
                            if (lj == lj_last) begin
                                st <= S_L2W;
                            end else begin
                                lj <= lj + 2'd1;
                                st <= S_RS;
                            end
                        end
                    endcase
                end
                default: ph <= P_IDLE;
            endcase
        end
    end

    // next item / next unit; at the end of the job, the next job of the word
    task next_k;
        begin
            st <= S_ITEM;
            if (!k_last) begin
                k <= k + 4'd1;
            end else begin
                k <= 4'd0;
                next_u2;
            end
        end
    endtask
    task next_u;
        begin
            st <= S_ITEM;
            k  <= 4'd0;
            next_u2;
        end
    endtask
    task next_u2;
        begin
            if (!u_last) begin
                u <= u + 3'd1;
            end else begin
                u <= 3'd0;
                if (!c_last) begin
                    c <= c + 2'd1;
                end else begin
                    c <= 2'd0;
                    job_end;
                end
            end
        end
    endtask
    task job_end;
        begin
            case (job)
                J_DARS: begin
                    // the addresses are set only when the previous j word had no l2bmdars
                    // (official: consecutive l2bmdars words refresh the buffer, keep the addresses)
                    if (!ds_first) begin
                        dw_a   <= dar_a;
                        db_r   <= 9'd0;
                        ds_l2b <= l2bm_opcode[0];
                    end
                    if (o_darw) job <= J_DARW; else ph <= P_WAIT;
                end
                J_DARW: if (o_gath)     job <= J_GATH;
                        else if (o_red) job <= J_RED;
                        else            ph <= P_WAIT;
                J_GATH, J_RED: ph <= P_WAIT;
                default: begin ph <= P_IDLE; done <= 1'b1; end      // J_L2L1, J_IMC
            endcase
        end
    endtask

`ifndef SYNTHESIS
    initial if ((RRN == 2) && (N_L1B != 1)) $display("mn_l2bm: ERROR RRN = 2 needs N_L1B = 1");
    always @(posedge clk) begin
        if (!rst && start && !idle)
            $display("mn_l2bm: ERROR start while not idle");
        if (!rst && run && (st == S_L1Q) && lb_req_ready && lb_req_err)
            $display("mn_l2bm: ERROR L1BM port error (L1B %0d address %0d)", lb_req_l1b, lb_req_addr);
    end
`endif
endmodule
`default_nettype wire

// mn_mab_mat: the matrix register of a MAB and its units (WP36): ?mwrite, the transposed read
// (?mread and $mreadf) and the matrix MAU (?mfma / ?mmul).
//
// Used by mn_mab (N_PE = 4, MAT = 1) next to the time-multiplexed PE datapath (mn_pe_core);
// every request names the PE of the current step (`pe`) and a cycle. The word (jw) must stay
// stable during the step. Semantics checked on the official emulator (WP36, rtl/mab/MATRIX.md):
//
// Matrix register: two faces X (0) and Y (1) of 16 physical rows x 8 words (32 bits), as in
//   viz/core: d element (row i, col j) = words 2j, 2j+1 of physical row 4i; f / g (row i, col j)
//   = word j of physical row 2i; h (row i, col j) = half j % 2 (0 = MSB) of word j / 2 of
//   physical row i. The faces are shared by the precisions (no separate storage).
// Faces and addresses of a word (MAUC fields; mw = pe_mauc_mw, readh = pe_mauc_readh):
//   write face        readh ? X : Y, row address ma
//   transposed read   mw = 0: readh ? X : Y, column ma;
//                     mw = 1: readh ? Y : X (the other face), column {signa, signc, passa, zeroc}
//   matrix MAU        readh ? Y : X
//   The precision is pe_mauc_dmode (11 g = f). h: the read column and the two-row write
//   (mdw_side = 1) row are even (bit 0 is ignored). mdw_side has no other effect on reads/writes.
//   Within a word the written face is never a face that is read, so the order of the writes
//   and reads of the 4 PEs does not matter.
// ?mwrite (cycle c, PE p, source = MAU port b, already rounded for h `r`): row (ma + c), the
//   elements of PE p at positions p*n .. (columns of the row): d: words 2p, 2p+1 <- the MSB long
//   word (e: from the single in [127:96]); f / g: words 2p, 2p+1 <- the 2 words (e: from 2
//   halves); h: words 2p, 2p+1 <- the 4 halves of the MSB long word; h with mdw_side: rows a, a+1
//   (a = (ma & ~1) + 2c) <- MSB / LSB long word. signb inverts the sign of every element.
// Transposed read (cycle c, PE p): d: element (row p, col (a + c) % 4) -> MSB long word;
//   f / g: elements (rows 2p, 2p+1, col (a + c) % 8) -> MSB long word; h: rows 4p..4p+3 at
//   column c0 = (a + 2c) % 16 -> MSB long word, at column c0 + 1 -> LSB long word.
//   Every step (not nop / noforward) writes it, zero-flushed (zero_sel 11), to $mreadf.
// ?mfma (cycle c, PE p, y = MAU port c): x = MAU port a of the 4 PEs of cycle c (gathered in the
//   check-only pass, xg_*): f: the word of PE j (j = 0..3, columns 0, 2, 4, 6 of the matrix);
//   g: the 2 words of PE j / 2 (8); h: the 4 halves of PE j / 4 (16). Output rows of PE p:
//   f / g: 2p, 2p+1 (two singles), h: 4p..4p+3 (four singles, or halves with round_out).
//   signa / signc invert x / y, extc extends y (half -> single), zeroc makes y 0 (?mmul).
//   Exact dot product of the block-float row and x (SDM 4.5: f drops the low 5 x 5 bits of every
//   product and adds 2^-38; g uses the top 18 bits of the mantissa field; h extended elements
//   (exponent 0) are common - 6, their products are shifted by 6 / 12 bits and rounded to
//   nearest even (the official rule is close to this but not identical: WP36 report)), then
//   mn_mab_mrnd. d (dmfma / dmmul) is not supported (mn_pe_core: E_UNSUPPORTED pe_mauc_dmode).
//
// Storage: one BSRAM 512 x 32: 0..255 the matrix {face, physical row, word}, 256..319 $mreadf
//   {pe, cycle, word}. x of the mfma: LUT RAM {pe, cycle} x 64. Reset clears the matrix and
//   $mreadf (busy for 320 clocks).
// Requests (level, from mn_pe_core; the operands stay stable until done / rdy):
//   mt_req -> mt_done (1 clock, mt_z / mt_flags valid with it), mw_req -> mw_done (1 clock),
//   mr_req -> mr_rdy (mr_val valid until mr_acc; mr_upd with mr_acc stores mr_val & mr_mask in
//   $mreadf), fr_req -> fr_rdy (fr_val valid until fr_acc).
`default_nettype none
module mn_mab_mat (
    input  wire         clk,
    input  wire         rst,
    output wire         busy,
    input  wire [425:0] jw,
    input  wire [1:0]   pe,
    // ---- check-only pass: x of an mfma word (MAU port a, MSB long word)
    input  wire         xg_valid,
    input  wire [1:0]   xg_cycle,
    input  wire [63:0]  xg_x,
    // ---- normal pass: mfma
    input  wire         mt_req,
    input  wire [1:0]   mt_cycle,
    input  wire [127:0] mt_y,
    output reg          mt_done,
    output reg  [127:0] mt_z,
    output reg  [3:0]   mt_flags,
    // ---- normal pass: mwrite
    input  wire         mw_req,
    input  wire [1:0]   mw_cycle,
    input  wire [127:0] mw_b,
    output reg          mw_done,
    // ---- normal pass: transposed read (collect)
    input  wire         mr_req,
    input  wire [1:0]   mr_cycle,
    output wire         mr_rdy,
    output wire [127:0] mr_val,
    input  wire         mr_acc,
    input  wire         mr_upd,
    input  wire [127:0] mr_mask,
    // ---- gather: $mreadf
    input  wire         fr_req,
    input  wire [1:0]   fr_cycle,
    output wire         fr_rdy,
    output wire [127:0] fr_val,
    input  wire         fr_acc
);
    // ------------------------------------------------------------------ word fields (j_flat.yaml)
    wire [1:0] w_dmode = jw[425-116 -: 2];
    wire       w_rnd   = jw[425-120];
    wire       w_mw    = jw[425-121];
    wire [3:0] w_ma    = jw[425-122 -: 4];
    wire       w_signa = jw[425-126];
    wire       w_signc = jw[425-127];
    wire       w_passa = jw[425-128];
    wire       w_zeroc = jw[425-129];
    wire       w_side  = jw[425-130];
    wire       w_readh = jw[425-131];
    wire       w_extb  = jw[425-133];
    wire       w_extc  = jw[425-134];
    wire       w_signb = jw[425-135];
    wire       p_d = (w_dmode == 2'b00);
    wire       p_h = (w_dmode == 2'b10);
    wire       f_w = ~w_readh;                               // write face (X = 0, Y = 1)
    wire       f_r = ~(w_readh ^ w_mw);                      // transposed-read face
    wire       f_m = w_readh;                                // matrix-MAU face
    wire [3:0] r_a = w_mw ? {w_signa, w_signc, w_passa, w_zeroc} : w_ma;   // read column

    // ------------------------------------------------------------------ storage
    reg        m_we;
    reg  [8:0] m_wa;
    reg [31:0] m_wd;
    reg        m_re;
    reg  [8:0] m_ra;
    wire [31:0] m_q;
    mn_ram_1r1w #(.W(32), .AW(9), .NWE(1), .OREG(0)) u_m (
        .clk(clk), .we(m_we), .waddr(m_wa), .wdata(m_wd), .re(m_re), .raddr(m_ra), .rdata(m_q));

    wire [3:0]  x_ra;
    wire [63:0] x_q;
    mn_ram_lut #(.W(64), .AW(4), .NR(1)) u_x (
        .clk(clk), .we(xg_valid), .waddr({pe, xg_cycle}), .wdata(xg_x), .raddr(x_ra), .rdata(x_q));

    function [8:0] madr(input f, input [3:0] prow, input [2:0] wd);
        madr = {1'b0, f, prow, wd};
    endfunction

    // exact widening
    function [31:0] h2s(input [15:0] x);
        h2s = {x[15], (x[14:9] == 6'd0) ? 8'd0 : (x[14:9] == 6'h3f) ? 8'hff : {2'd0, x[14:9]} + 8'd96,
               x[8:0], 14'd0};
    endfunction
    function [63:0] s2d(input [31:0] x);
        s2d = {x[31], (x[30:23] == 8'd0) ? 11'd0 : (x[30:23] == 8'hff) ? 11'h7ff : {3'd0, x[30:23]} + 11'd896,
               x[22:0], 29'd0};
    endfunction

    // ------------------------------------------------------------------ write process
    // clear after reset, $mreadf store (after mr_acc with mr_upd), mwrite
    reg        clr;
    reg  [8:0] clr_a;
    reg        st_pend;       // $mreadf store of cycle st_c
    reg  [1:0] st_c, st_k;
    reg  [1:0] st_pe;
    reg        mw_act;        // mwrite in progress
    reg  [1:0] mw_k;
    reg  [127:0] mrv;         // the transposed read value (mr_val)
    reg        mr_have;

    // mwrite data of word k (0..3) of the current request
    wire [63:0] mw_ed  = w_extb ? s2d(mw_b[127:96]) : mw_b[127:64];             // d element
    wire [31:0] mw_f0  = w_extb ? h2s(mw_b[127:112]) : mw_b[127:96];
    wire [31:0] mw_f1  = w_extb ? h2s(mw_b[111:96]) : mw_b[95:64];
    wire [63:0] sgn_d  = {w_signb, 63'd0};
    wire [31:0] sgn_f  = {w_signb, 31'd0};
    wire [31:0] sgn_h  = {w_signb, 15'd0, w_signb, 15'd0};
    wire [63:0] mw_d2  = mw_ed ^ sgn_d;
    reg  [31:0] mw_wd;
    reg  [3:0]  mw_prow;
    reg  [2:0]  mw_word;
    wire [1:0]  mw_n   = (p_h & w_side) ? 2'd3 : 2'd1;   // last word index
    wire [3:0]  mw_row = w_ma + {2'd0, mw_cycle};
    wire [3:0]  mw_a2  = {w_ma[3:1], 1'b0} + {1'b0, mw_cycle, 1'b0};   // h two rows
    always @* begin
        case (w_dmode)
            2'b00: begin
                mw_prow = {mw_row[1:0], 2'b00};
                mw_wd   = mw_k[0] ? mw_d2[31:0] : mw_d2[63:32];
            end
            2'b10: begin
                if (w_side) begin
                    mw_prow = mw_a2 + {3'd0, mw_k[1]};
                    mw_wd   = (mw_k[1] ? (mw_k[0] ? mw_b[31:0] : mw_b[63:32]) :
                                         (mw_k[0] ? mw_b[95:64] : mw_b[127:96])) ^ sgn_h;
                end else begin
                    mw_prow = mw_row;
                    mw_wd   = (mw_k[0] ? mw_b[95:64] : mw_b[127:96]) ^ sgn_h;
                end
            end
            default: begin
                mw_prow = {mw_row[2:0], 1'b0};
                mw_wd   = (mw_k[0] ? mw_f1 : mw_f0) ^ sgn_f;
            end
        endcase
        mw_word = {pe, mw_k[0]};
    end

    always @* begin
        m_we = 1'b0;
        m_wa = clr_a;
        m_wd = 32'd0;
        if (clr) begin
            m_we = 1'b1;
        end else if (st_pend) begin
            m_we = 1'b1;
            m_wa = {3'b100, st_pe, st_c, st_k};
            m_wd = mrv[127 - 32 * st_k -: 32];
        end else if (mw_act) begin
            m_we = 1'b1;
            m_wa = madr(f_w, mw_prow, mw_word);
            m_wd = mw_wd;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            clr     <= 1'b1;
            clr_a   <= 9'd0;
            st_pend <= 1'b0;
            st_k    <= 2'd0;
            mw_act  <= 1'b0;
            mw_k    <= 2'd0;
            mw_done <= 1'b0;
        end else begin
            mw_done <= 1'b0;
            if (clr) begin
                clr_a <= clr_a + 9'd1;
                if (clr_a == 9'd319) clr <= 1'b0;
            end else if (st_pend) begin
                st_k <= st_k + 2'd1;
                if (st_k == 2'd3) st_pend <= 1'b0;
            end else if (mw_act) begin
                mw_k <= mw_k + 2'd1;
                if (mw_k == mw_n) begin
                    mw_act  <= 1'b0;
                    mw_done <= 1'b1;
                end
            end else if (mw_req && !mw_done) begin
                mw_act <= 1'b1;
                mw_k   <= 2'd0;
            end
            if (mr_acc && mr_upd) begin
                st_pend <= 1'b1;
                st_k    <= 2'd0;
                st_c    <= mr_cycle;
                st_pe   <= pe;
            end
        end
    end
    assign busy = clr | st_pend | mw_act;

    // ------------------------------------------------------------------ read engine
    localparam [2:0] E_IDLE = 3'd0, E_MR = 3'd1, E_FR = 3'd2, E_MT = 3'd3;
    reg [2:0]   es;
    reg [2:0]   rk;          // reads issued (E_MR / E_FR)
    reg         cv;          // a read answers in this clock
    reg [1:0]   ck;          // ... its index
    reg [127:0] frv;
    reg         fr_have;
    assign mr_rdy = mr_have;
    assign mr_val = mrv;
    assign fr_rdy = fr_have;
    assign fr_val = frv;

    // transposed read addresses (PE pe, cycle mr_cycle), read k
    wire [3:0] rc_dfg = r_a + {2'd0, mr_cycle};                         // column, d / f / g
    wire [3:0] rc_h   = {r_a[3:1], 1'b0} + {1'b0, mr_cycle, 1'b0};      // first column, h
    reg  [8:0] mr_adr;
    always @* begin
        case (w_dmode)
            2'b00:   mr_adr = madr(f_r, {pe, 2'b00}, {rc_dfg[1:0], rk[0]});
            2'b10:   mr_adr = madr(f_r, {pe, rk[1:0]}, rc_h[3:1]);
            default: mr_adr = madr(f_r, {pe, rk[0], 1'b0}, rc_dfg[2:0]);
        endcase
    end
    wire [2:0] mr_n = p_h ? 3'd4 : 3'd2;   // words to read

    // ---- matrix MAU state
    // per output element k: terms j; per term: read (T_RD), word (T_X), operands (T_OP),
    // multiplier (T_M2..T_M4, latency 3), accumulate (T_AC; f: 3 passes); then the rounder (T_RQ)
    localparam [3:0] T_START = 4'd0, T_RD = 4'd1, T_X = 4'd2, T_OP = 4'd3, T_M2 = 4'd4, T_M3 = 4'd5,
                     T_M4 = 4'd6, T_AC = 4'd7, T_RQ = 4'd8, T_END = 4'd9;
    reg [3:0]   ts;
    reg [1:0]   tk;          // output element of the PE
    reg [3:0]   tj;          // term
    reg [1:0]   tp;          // pass (f: 0 hi*hi, 1 hi*lo, 2 lo*hi)
    reg [31:0]  tword;       // the matrix word read for the term (h: two terms)
    reg [47:0]  acc;
    reg [7:0]   tca, tcb;
    reg         tsg;         // sign of the term
    reg [17:0]  ta_hi, tb_hi;
    reg [4:0]   ta_lo, tb_lo;
    reg [3:0]   tsh;         // h: right shift of the product (0, 6, 12)
    reg [17:0]  mul_a, mul_b;
    wire [35:0] mul_p;
    mn_mul_pipe #(.WA(18), .WB(18), .TW(18), .IREG(1), .PREG(1), .LVLS(0)) u_mul (
        .clk(clk), .ce(1'b1), .a(mul_a), .b(mul_b), .p(mul_p));

    wire       mt_f   = (w_dmode == 2'b01);
    wire       mt_g   = (w_dmode == 2'b11);
    wire [3:0] t_last = p_h ? 4'd15 : mt_g ? 4'd7 : 4'd3;           // last term
    wire [1:0] k_last = p_h ? 2'd3 : 2'd1;                          // last output element
    // matrix row of output element tk and the word of term tj
    wire [3:0] t_row  = p_h ? {pe, tk} : {1'b0, pe, tk[0]};
    wire [3:0] t_prow = p_h ? t_row : {t_row[2:0], 1'b0};
    wire [2:0] t_wd   = p_h ? tj[3:1] : mt_f ? {tj[1:0], 1'b0} : tj[2:0];
    // x element of term tj: LUT RAM entry {PE, cycle}
    assign x_ra = {(p_h ? tj[3:2] : mt_f ? tj[1:0] : tj[2:1]), mt_cycle};
    wire [31:0] x_el = p_h ? {16'd0, x_q[63 - 16 * tj[1:0] -: 16]} :
                       (mt_g & tj[0]) ? x_q[31:0] : x_q[63:32];
    wire [31:0] a_el = p_h ? {16'd0, tj[0] ? tword[15:0] : tword[31:16]} : tword;
    // fields: sign, exponent field, mantissa field
    wire        a_s  = p_h ? a_el[15] : a_el[31];
    wire        x_s  = (p_h ? x_el[15] : x_el[31]) ^ w_signa;
    wire [7:0]  a_e  = p_h ? {2'd0, a_el[14:9]} : a_el[30:23];
    wire [7:0]  x_e  = p_h ? {2'd0, x_el[14:9]} : x_el[30:23];
    wire [22:0] a_m  = p_h ? {14'd0, a_el[8:0]} : a_el[22:0];
    wire [22:0] x_m  = p_h ? {14'd0, x_el[8:0]} : x_el[22:0];

    // the product of the pass, on the grid: f: hi*hi << 5, hi*lo, lo*hi (+ 8 if both low parts
    // are not zero, SDM 4.5); g: as is; h: rounded >> tsh, then << 10
    wire [35:0] pp   = mul_p;
    reg  [17:0] h_q;
    always @* begin
        case (tsh)
            4'd6:    h_q = {6'd0, pp[17:6]} + {17'd0, pp[5] & ((|pp[4:0]) | pp[6])};
            4'd12:   h_q = {12'd0, pp[17:12]} + {17'd0, pp[11] & ((|pp[10:0]) | pp[12])};
            default: h_q = pp[17:0];
        endcase
    end
    wire [47:0] t_val = p_h ? {20'd0, h_q, 10'd0} :
                        mt_f ? ((tp == 2'd0) ? {7'd0, pp, 5'd0} :
                                (tp == 2'd2) ? {12'd0, pp} + {44'd0, (|ta_lo) & (|tb_lo), 3'd0} : {12'd0, pp}) :
                        {12'd0, pp};

    // y element of output element tk (single), with e / sign / zeroc
    wire [31:0] y_raw = w_extc ? h2s(mt_y[127 - 16 * tk -: 16]) : mt_y[127 - 32 * tk -: 32];
    wire [31:0] y_el  = w_zeroc ? 32'd0 : (y_raw ^ {w_signc, 31'd0});

    // the rounder
    reg         rq_start;
    wire        rq_done;
    wire [31:0] rq_z;
    mn_mab_mrnd u_rnd (
        .clk(clk), .rst(rst), .start(rq_start), .prec(w_dmode), .rnd_h(w_rnd), .dsum(acc),
        .ca(tca), .cb(tcb), .c(y_el), .done(rq_done), .z(rq_z));
    wire hout = p_h & w_rnd;
    wire rq_pos = hout ? ~rq_z[15] : ~rq_z[31];

    always @* begin
        m_re = 1'b0;
        m_ra = mr_adr;
        if (es == E_MR) begin
            m_re = (rk < mr_n);
        end else if (es == E_FR) begin
            m_re = (rk < 3'd4);
            m_ra = {3'b100, pe, fr_cycle, rk[1:0]};
        end else if (es == E_MT && ts == T_RD) begin
            m_re = 1'b1;
            m_ra = madr(f_m, t_prow, t_wd);
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            es       <= E_IDLE;
            rk       <= 3'd0;
            cv       <= 1'b0;
            mr_have  <= 1'b0;
            fr_have  <= 1'b0;
            mt_done  <= 1'b0;
            ts       <= T_START;
            rq_start <= 1'b0;
        end else begin
            mt_done  <= 1'b0;
            rq_start <= 1'b0;
            cv <= m_re & (es == E_MR || es == E_FR);
            ck <= rk[1:0];
            if (mr_acc) begin
                mr_have <= 1'b0;
                if (mr_upd) mrv <= mrv & mr_mask;
            end
            if (fr_acc) fr_have <= 1'b0;
            case (es)
                E_IDLE: begin
                    rk <= 3'd0;
                    if (clr) begin
                        es <= E_IDLE;
                    end else if (mr_req && !mr_have && !mr_acc && !st_pend) begin
                        mrv <= 128'd0;
                        es  <= E_MR;
                    end else if (fr_req && !fr_have && !fr_acc) begin
                        es <= E_FR;
                    end else if (mt_req && !mt_done) begin
                        ts <= T_START;
                        es <= E_MT;
                    end
                end
                E_MR: begin
                    if (rk < mr_n) rk <= rk + 3'd1;
                    if (cv) begin
                        if (p_h) begin
                            mrv[127 - 16 * ck -: 16] <= m_q[31:16];
                            mrv[63 - 16 * ck -: 16]  <= m_q[15:0];
                        end else begin
                            mrv[127 - 32 * ck[0] -: 32] <= m_q;
                        end
                        if ({1'b0, ck} == mr_n - 3'd1) begin
                            mr_have <= 1'b1;
                            es      <= E_IDLE;
                        end
                    end
                end
                E_FR: begin
                    if (rk < 3'd4) rk <= rk + 3'd1;
                    if (cv) begin
                        frv[127 - 32 * ck -: 32] <= m_q;
                        if (ck == 2'd3) begin
                            fr_have <= 1'b1;
                            es      <= E_IDLE;
                        end
                    end
                end
                default: begin   // E_MT
                    case (ts)
                        T_START: begin
                            tk       <= 2'd0;
                            tj       <= 4'd0;
                            acc      <= 48'd0;
                            tca      <= 8'd0;
                            tcb      <= 8'd0;
                            mt_z     <= 128'd0;
                            mt_flags <= 4'd0;
                            ts       <= T_RD;
                        end
                        T_RD: ts <= T_X;       // the read of the term's matrix word is issued
                        T_X: begin
                            tword <= m_q;
                            ts    <= T_OP;
                        end
                        T_OP: begin
                            // operands of the term (matrix element from tword, x from the LUT RAM)
                            if (a_e > tca) tca <= a_e;
                            if (x_e > tcb) tcb <= x_e;
                            tsg   <= a_s ^ x_s;
                            tp    <= 2'd0;
                            ta_hi <= p_h ? {9'd0, a_m[8:0]} : a_m[22:5];
                            tb_hi <= p_h ? {9'd0, x_m[8:0]} : x_m[22:5];
                            ta_lo <= a_m[4:0];
                            tb_lo <= x_m[4:0];
                            tsh   <= (p_h && a_e == 8'd0 ? 4'd6 : 4'd0) + (p_h && x_e == 8'd0 ? 4'd6 : 4'd0);
                            mul_a <= p_h ? {9'd0, a_m[8:0]} : a_m[22:5];
                            mul_b <= p_h ? {9'd0, x_m[8:0]} : x_m[22:5];
                            ts    <= T_M2;
                        end
                        T_M2: ts <= T_M3;
                        T_M3: ts <= T_M4;
                        T_M4: ts <= T_AC;
                        T_AC: begin
                            acc <= tsg ? acc - t_val : acc + t_val;
                            if (mt_f && tp != 2'd2) begin
                                // next pass of f
                                tp    <= tp + 2'd1;
                                mul_a <= (tp == 2'd0) ? ta_hi : {13'd0, ta_lo};
                                mul_b <= (tp == 2'd0) ? {13'd0, tb_lo} : tb_hi;
                                ts    <= T_M2;
                            end else if (tj != t_last) begin
                                tj <= tj + 4'd1;
                                ts <= T_RD;
                            end else begin
                                rq_start <= 1'b1;
                                ts       <= T_RQ;
                            end
                        end
                        T_RQ: if (rq_done) begin
                            if (hout) mt_z[127 - 16 * tk -: 16] <= rq_z[15:0];
                            else      mt_z[127 - 32 * tk -: 32] <= rq_z;
                            if (p_h) mt_flags[3 - tk] <= rq_pos;
                            else     mt_flags[3 - 2 * tk[0] -: 2] <= {2{rq_pos}};
                            if (tk != k_last) begin
                                tk  <= tk + 2'd1;
                                tj  <= 4'd0;
                                acc <= 48'd0;
                                tca <= 8'd0;
                                tcb <= 8'd0;
                                ts  <= T_RD;
                            end else begin
                                ts <= T_END;
                            end
                        end
                        default: begin   // T_END
                            mt_done <= 1'b1;
                            ts      <= T_START;
                            es      <= E_IDLE;
                        end
                    endcase
                end
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // p_d: d words never reach the matrix MAU (mn_pe_core makes dmfma E_UNSUPPORTED)
    wire unused_mat = p_d;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire

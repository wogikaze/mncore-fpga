// mn_mab_mat: the matrix register of a MAB and its units (WP36): ?mwrite, the transposed read
// (?mread and $mreadf) and the matrix MAU (?mfma / ?mmul).
//
// Used by mn_mab (N_PE = 4, MAT = 1) next to the time-multiplexed PE datapath (mn_pe_core);
// every request names the PE of the current step (`pe`) and a cycle. The word (jw) must stay
// stable during the step. Semantics checked on the official emulator (WP36: mncore/status/WP-36.md,
// mncore/sim/tb/mat/probe_mat.py, reference model mncore/sim/tb/mat/matref.py):
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
//   e of a zero or an infinity keeps its sign and clears the mantissa.
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
// Storage: BSRAM 512 x 32: 0..255 the matrix {face, physical row, word}, 256..319 $mreadf and
//   (MAUF = 1) 320..383 $mauf of the matrix MAU, both {pe, cycle, word}. x of the mfma: BSRAM
//   {pe, cycle} x 64 (read next to the matrix word). Reset clears the matrix and $mreadf (busy
//   for 384 clocks).
// Requests (level, from mn_pe_core; the operands stay stable until done / rdy):
//   mt_req -> mt_done (1 clock); mt_z / mt_flags then hold the result until the next mt_req (with
//   MAUF = 1 mn_pe_core uses them as the MAU result of the cycle, so it asks for the next cycle
//   only after collecting this one). mw_req -> mw_done (1 clock).
//   mr_req -> mr_rdy (mr_val valid until mr_acc; mr_upd with mr_acc stores it as $mreadf of the
//   cycle, with the half-word enables mr_hen of the zero flush). ma_upd with mr_acc (MAUF = 1)
//   stores mt_z as $mauf of the cycle (enables ma_hen).
//   fr_req -> fr_rdy (fr_val = $mreadf, or $mauf with fr_sel = 1, valid until fr_acc).
`default_nettype none
module mn_mab_mat #(
    parameter MAUF = 0   // 1: keep the matrix MAU's $mauf here (a core without the vector MAU)
) (
    input  wire         clk,
    input  wire         rst,
    output wire         busy,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [425:0] jw,           // only the MAUC fields are used
    /* verilator lint_on UNUSEDSIGNAL */
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
    input  wire [7:0]   mr_hen,
    input  wire         ma_upd,
    input  wire [7:0]   ma_hen,
    // ---- gather: $mreadf / $mauf
    input  wire         fr_req,
    input  wire         fr_sel,
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
    wire       p_h  = (w_dmode == 2'b10);
    wire       p_f  = (w_dmode == 2'b01);
    wire       p_g  = (w_dmode == 2'b11);
    wire       f_w  = ~w_readh;                               // write face (X = 0, Y = 1)
    wire       f_r  = ~(w_readh ^ w_mw);                      // transposed-read face
    wire       f_m  = w_readh;                                // matrix-MAU face
    wire [3:0] r_a  = w_mw ? {w_signa, w_signc, w_passa, w_zeroc} : w_ma;   // read column
    wire       hout = p_h & w_rnd;                            // half results

    // ------------------------------------------------------------------ storage
    reg        m_we;
    reg  [8:0] m_wa;
    reg [31:0] m_wd;
    reg        m_re;
    reg  [8:0] m_ra;
    wire [31:0] m_q;
    mn_ram_1r1w #(.W(32), .AW(9), .NWE(1), .OREG(0)) u_m (
        .clk(clk), .we(m_we), .waddr(m_wa), .wdata(m_wd), .re(m_re), .raddr(m_ra), .rdata(m_q));
    // x of the mfma: {pe, cycle} (deep enough to be a BSRAM, the rest is unused)
    reg  [3:0]  x_ra;
    wire [63:0] x_q;
    mn_ram_1r1w #(.W(64), .AW(9), .NWE(1), .OREG(0)) u_x (
        .clk(clk), .we(xg_valid), .waddr({5'd0, pe, xg_cycle}), .wdata(xg_x), .re(m_re), .raddr({5'd0, x_ra}),
        .rdata(x_q));

    function [8:0] madr(input f, input [3:0] prow, input [2:0] wd);
        madr = {1'b0, f, prow, wd};
    endfunction

    // widening (e): a zero or an infinity keeps its sign and gets a zero mantissa (the matrix
    // register keeps the bits, so this shows: checked on the emulator)
    function [31:0] h2s(input [15:0] x);
        h2s = (x[14:9] == 6'd0) ? {x[15], 31'd0} : (x[14:9] == 6'h3f) ? {x[15], 8'hff, 23'd0} :
              {x[15], {2'd0, x[14:9]} + 8'd96, x[8:0], 14'd0};
    endfunction
    function [63:0] s2d(input [31:0] x);
        s2d = (x[30:23] == 8'd0) ? {x[31], 63'd0} : (x[30:23] == 8'hff) ? {x[31], 11'h7ff, 52'd0} :
              {x[31], {3'd0, x[30:23]} + 11'd896, x[22:0], 29'd0};
    endfunction

    // ------------------------------------------------------------------ write process
    // clear after reset, the forwarding stores (after mr_acc), mwrite
    reg        clr;
    reg  [8:0] clr_a;
    reg        st_r, st_a;    // $mreadf / $mauf store pending
    reg  [1:0] st_k;
    reg  [1:0] st_c, st_pe;
    reg  [7:0] st_hr, st_ha;  // their half-word enables
    reg        mw_act;
    reg  [1:0] mw_k;
    reg [63:0] mr_hi, mr_lo;  // the transposed read value (mr_val)

    wire [63:0] mw_ed = w_extb ? s2d(mw_b[127:96]) : mw_b[127:64];             // d element
    wire [31:0] mw_f0 = w_extb ? h2s(mw_b[127:112]) : mw_b[127:96];
    wire [31:0] mw_f1 = w_extb ? h2s(mw_b[111:96]) : mw_b[95:64];
    reg  [31:0] mw_wd;
    reg  [3:0]  mw_prow;
    wire [1:0]  mw_n   = (p_h & w_side) ? 2'd3 : 2'd1;   // last word index
    wire [3:0]  mw_row = w_ma + {2'd0, mw_cycle};
    wire [3:0]  mw_a2  = {w_ma[3:1] + {1'b0, mw_cycle}, 1'b0} | {3'd0, mw_k[1]};   // h two rows
    always @* begin
        case (w_dmode)
            2'b00: begin
                mw_prow = {mw_row[1:0], 2'b00};
                mw_wd   = (mw_k[0] ? mw_ed[31:0] : mw_ed[63:32]) ^ {w_signb & ~mw_k[0], 31'd0};
            end
            2'b10: begin
                mw_prow = w_side ? mw_a2 : mw_row;
                mw_wd   = mw_b[127 - 32 * mw_k -: 32] ^ {w_signb, 15'd0, w_signb, 15'd0};
            end
            default: begin
                mw_prow = {mw_row[2:0], 1'b0};
                mw_wd   = (mw_k[0] ? mw_f1 : mw_f0) ^ {w_signb, 31'd0};
            end
        endcase
    end
    // store data: word k of $mreadf / $mauf with its two half-word enables
    wire [127:0] mrv  = {mr_hi, mr_lo};
    wire [31:0]  st_wr = mrv[127 - 32 * st_k -: 32];
    wire [31:0]  st_wa = mt_z[127 - 32 * st_k -: 32];
    wire [1:0]   st_er = st_hr[7 - 2 * st_k -: 2];
    wire [1:0]   st_ea = st_ha[7 - 2 * st_k -: 2];

    always @* begin
        m_we = 1'b0;
        m_wa = clr_a;
        m_wd = 32'd0;
        if (clr) begin
            m_we = 1'b1;
        end else if (st_r) begin
            m_we = 1'b1;
            m_wa = {3'b100, st_pe, st_c, st_k};
            m_wd = st_wr & {{16{st_er[1]}}, {16{st_er[0]}}};
        end else if (st_a) begin
            m_we = 1'b1;
            m_wa = {3'b101, st_pe, st_c, st_k};
            m_wd = st_wa & {{16{st_ea[1]}}, {16{st_ea[0]}}};
        end else if (mw_act) begin
            m_we = 1'b1;
            m_wa = madr(f_w, mw_prow, {pe, mw_k[0]});
            m_wd = mw_wd;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            clr     <= 1'b1;
            clr_a   <= 9'd0;
            st_r    <= 1'b0;
            st_a    <= 1'b0;
            st_k    <= 2'd0;
            mw_act  <= 1'b0;
            mw_k    <= 2'd0;
            mw_done <= 1'b0;
        end else begin
            mw_done <= 1'b0;
            if (clr) begin
                clr_a <= clr_a + 9'd1;
                if (clr_a == 9'd383) clr <= 1'b0;
            end else if (st_r | st_a) begin
                st_k <= st_k + 2'd1;
                if (st_k == 2'd3) begin
                    if (st_r) st_r <= 1'b0;
                    else      st_a <= 1'b0;
                end
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
            if (mr_acc) begin
                st_r  <= mr_upd;
                st_a  <= (MAUF != 0) & ma_upd;
                st_k  <= 2'd0;
                st_c  <= mr_cycle;
                st_pe <= pe;
                st_hr <= mr_hen;
                st_ha <= ma_hen;
            end
        end
    end
    assign busy = clr | st_r | st_a | mw_act;

    // ------------------------------------------------------------------ read engine
    localparam [1:0] E_IDLE = 2'd0, E_MR = 2'd1, E_FR = 2'd2, E_MT = 2'd3;
    reg [1:0]   es;
    reg [2:0]   rk;          // reads issued (E_MR / E_FR)
    reg         cv;          // a read answers in this clock
    reg [1:0]   ck;          // ... its index
    reg [127:0] frv;
    reg         fr_have, mr_have;
    assign mr_rdy = mr_have;
    assign mr_val = mrv;
    assign fr_rdy = fr_have;
    assign fr_val = frv;

    // transposed read addresses (PE pe, cycle mr_cycle), read k
    wire [2:0] rc_dfg = r_a[2:0] + {1'b0, mr_cycle};                    // column, d / f / g
    wire [2:0] rc_h   = r_a[3:1] + {1'b0, mr_cycle};                    // first column / 2, h
    reg  [8:0] mr_adr;
    always @* begin
        case (w_dmode)
            2'b00:   mr_adr = madr(f_r, {pe, 2'b00}, {rc_dfg[1:0], rk[0]});
            2'b10:   mr_adr = madr(f_r, {pe, rk[1:0]}, rc_h);
            default: mr_adr = madr(f_r, {pe, rk[0], 1'b0}, rc_dfg);
        endcase
    end
    wire [2:0] rd_n  = (es == E_FR | p_h) ? 3'd4 : 3'd2;   // words to read
    wire       rd_go = ~rk[2] & (rd_n[2] | ~rk[1]);         // rk < rd_n

    // ---- matrix MAU
    // per output element k: terms j; per term: read the matrix word and x (T_RD), take them
    // (T_X), operands (T_OP), multiplier (T_M2..T_M4, latency 3), accumulate (T_AC; f: 3 passes);
    // then the rounder (T_RQ) and the result shifted into mt_z (T_SH)
    localparam [3:0] T_START = 4'd0, T_RD = 4'd1, T_X = 4'd2, T_OP = 4'd3, T_M2 = 4'd4, T_M3 = 4'd5,
                     T_M4 = 4'd6, T_AC = 4'd7, T_RQ = 4'd8, T_SH = 4'd9, T_PAD = 4'd10, T_END = 4'd11;
    reg [3:0]   ts;
    reg [1:0]   tk;          // output element of the PE
    reg [3:0]   tj;          // term
    reg [1:0]   tp;          // pass (f: 0 hi*hi, 1 hi*lo, 2 lo*hi)
    reg [1:0]   tsc;         // T_SH / T_PAD: halves still to shift
    reg [31:0]  tword, txw;  // the matrix word and the x word of the term
    reg [47:0]  acc;
    reg [7:0]   tca, tcb;
    reg         tsg;         // sign of the term
    reg [17:0]  ta_hi, tb_hi;
    reg [4:0]   ta_lo, tb_lo;
    reg [1:0]   tsh;         // h: right shift of the product (0, 6, 12) / 6
    reg [17:0]  mul_a, mul_b;
    wire [35:0] mul_p;
    mn_mul_pipe #(.WA(18), .WB(18), .TW(18), .IREG(1), .PREG(1), .LVLS(0)) u_mul (
        .clk(clk), .ce(1'b1), .a(mul_a), .b(mul_b), .p(mul_p));

    wire [3:0] t_last = p_h ? 4'd15 : p_g ? 4'd7 : 4'd3;            // last term
    wire [1:0] k_last = p_h ? 2'd3 : 2'd1;                          // last output element
    wire [3:0] t_prow = p_h ? {pe, tk} : {pe, tk[0], 1'b0};         // physical row of the output row
    wire [2:0] t_wd   = p_h ? tj[3:1] : p_f ? {tj[1:0], 1'b0} : tj[2:0];
    always @* x_ra = {(p_h ? tj[3:2] : p_f ? tj[1:0] : tj[2:1]), mt_cycle};
    // the elements of the term (txw: the x word of term tj)
    wire [15:0] a_h = tj[0] ? tword[15:0] : tword[31:16];
    wire [15:0] x_h = tj[0] ? txw[15:0] : txw[31:16];
    wire        a_s = p_h ? a_h[15] : tword[31];
    wire        x_s = (p_h ? x_h[15] : txw[31]) ^ w_signa;
    wire [7:0]  a_e = p_h ? {2'd0, a_h[14:9]} : tword[30:23];
    wire [7:0]  x_e = p_h ? {2'd0, x_h[14:9]} : txw[30:23];
    wire [17:0] a_m = p_h ? {9'd0, a_h[8:0]} : tword[22:5];
    wire [17:0] x_m = p_h ? {9'd0, x_h[8:0]} : txw[22:5];

    // the product of the pass, on the grid: f: hi*hi << 5 (+ 8 if both low parts are not zero,
    // SDM 4.5: it fills the zero low bits), hi*lo, lo*hi; g: as is; h: rounded >> 6 * tsh, << 10
    wire [35:0] pp = mul_p;
    reg  [17:0] h_q;
    always @* begin
        case (tsh)
            2'd1:    h_q = {6'd0, pp[17:6]} + {17'd0, pp[5] & ((|pp[4:0]) | pp[6])};
            2'd2:    h_q = {12'd0, pp[17:12]} + {17'd0, pp[11] & ((|pp[10:0]) | pp[12])};
            default: h_q = pp[17:0];
        endcase
    end
    wire [47:0] t_val = p_h ? {20'd0, h_q, 10'd0} :
                        (p_f & (tp == 2'd0)) ? {7'd0, pp, 1'b0, (|ta_lo) & (|tb_lo), 3'd0} :
                        {12'd0, pp};

    // y element of output element tk (single), with e / sign / zeroc
    wire [31:0] y_raw = w_extc ? h2s(mt_y[127 - 16 * tk -: 16]) : mt_y[127 - 32 * tk -: 32];
    wire [31:0] y_el  = w_zeroc ? 32'd0 : (y_raw ^ {w_signc, 31'd0});

    // the rounder
    reg         rq_start;
    wire        rq_done;
    wire [31:0] rq_z;
    reg  [31:0] rq_q;
    mn_mab_mrnd u_rnd (
        .clk(clk), .rst(rst), .start(rq_start), .prec(w_dmode), .rnd_h(w_rnd), .dsum(acc),
        .ca(tca), .cb(tcb), .c(y_el), .done(rq_done), .z(rq_z));

    always @* begin
        m_re = 1'b0;
        m_ra = mr_adr;
        if (es == E_MR || es == E_FR) begin
            m_re = rd_go;
            if (es == E_FR) m_ra = {2'b10, fr_sel, pe, fr_cycle, rk[1:0]};
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
            if (mr_acc) mr_have <= 1'b0;
            if (fr_acc) fr_have <= 1'b0;
            case (es)
                E_IDLE: begin
                    rk <= 3'd0;
                    if (clr) begin
                        es <= E_IDLE;
                    end else if (mr_req && !mr_have && !mr_acc && !st_r && !st_a) begin
                        mr_lo <= 64'd0;
                        es    <= E_MR;
                    end else if (fr_req && !fr_have && !fr_acc) begin
                        es <= E_FR;
                    end else if (mt_req && !mt_done && !st_a) begin
                        ts <= T_START;
                        es <= E_MT;
                    end
                end
                E_MR, E_FR: begin
                    if (rd_go) rk <= rk + 3'd1;
                    if (cv) begin
                        // the read words are shifted in: h: the halves of 4 rows (MSB / LSB long
                        // word), d / f / g: 2 words (MSB long word); $mreadf / $mauf: 4 words
                        if (es == E_FR) begin
                            frv <= {frv[95:0], m_q};
                        end else if (p_h) begin
                            mr_hi <= {mr_hi[47:0], m_q[31:16]};
                            mr_lo <= {mr_lo[47:0], m_q[15:0]};
                        end else begin
                            mr_hi <= {mr_hi[31:0], m_q};
                        end
                        if ({1'b0, ck} == rd_n - 3'd1) begin
                            if (es == E_FR) fr_have <= 1'b1;
                            else            mr_have <= 1'b1;
                            es <= E_IDLE;
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
                            ts       <= T_RD;
                        end
                        T_RD: ts <= T_X;       // the matrix word and the x entry are read
                        T_X: begin
                            tword <= m_q;
                            txw   <= (p_h ? tj[1] : (p_g & tj[0])) ? x_q[31:0] : x_q[63:32];
                            ts    <= T_OP;
                        end
                        T_OP: begin
                            if (a_e > tca) tca <= a_e;
                            if (x_e > tcb) tcb <= x_e;
                            tsg   <= a_s ^ x_s;
                            tp    <= 2'd0;
                            ta_hi <= a_m;
                            tb_hi <= x_m;
                            ta_lo <= tword[4:0];
                            tb_lo <= txw[4:0];
                            tsh   <= {p_h & (a_e == 8'd0) & (x_e == 8'd0), p_h & ((a_e == 8'd0) ^ (x_e == 8'd0))};
                            mul_a <= a_m;
                            mul_b <= x_m;
                            ts    <= T_M2;
                        end
                        T_M2: ts <= T_M3;
                        T_M3: ts <= T_M4;
                        T_M4: ts <= T_AC;
                        T_AC: begin
                            acc <= acc + (t_val ^ {48{tsg}}) + {47'd0, tsg};
                            if (p_f && tp != 2'd2) begin
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
                            rq_q     <= rq_z;
                            mt_flags <= {mt_flags[2:0], ~(hout ? rq_z[15] : rq_z[31])};
                            tsc      <= hout ? 2'd0 : 2'd1;
                            ts       <= T_SH;
                        end
                        T_SH: begin
                            // the result into mt_z, 16 bits at a time (MSB half first)
                            mt_z <= {mt_z[111:0], (tsc[0] & ~hout) ? rq_q[31:16] : rq_q[15:0]};
                            tsc  <= tsc - 2'd1;
                            if (tsc == 2'd0) begin
                                if (tk != k_last) begin
                                    tk  <= tk + 2'd1;
                                    tj  <= 4'd0;
                                    acc <= 48'd0;
                                    tca <= 8'd0;
                                    tcb <= 8'd0;
                                    ts  <= T_RD;
                                end else begin
                                    // f / g (2 singles) and h half results: zero the LSB long word
                                    tsc <= 2'd3;
                                    ts  <= (p_h & ~w_rnd) ? T_END : T_PAD;
                                end
                            end
                        end
                        T_PAD: begin
                            mt_z <= {mt_z[111:0], 16'd0};
                            tsc  <= tsc - 2'd1;
                            if (tsc == 2'd0) ts <= T_END;
                        end
                        default: begin   // T_END
                            // flags: f / g {p0, p0, p1, p1} from the 2 bits shifted in
                            if (!p_h) mt_flags <= {{2{mt_flags[1]}}, {2{mt_flags[0]}}};
                            mt_done <= 1'b1;
                            ts      <= T_START;
                            es      <= E_IDLE;
                        end
                    endcase
                end
            endcase
        end
    end
endmodule
`default_nettype wire

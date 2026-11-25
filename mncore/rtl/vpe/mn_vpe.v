// mn_vpe: the virtual PEs (WP34): N_MAB MABs of 4 PEs (up to the 16 MABs = 64 PEs of one L1B) on the one
// time-multiplexed MAB datapath (mn_mab, WP30), with the state of every PE in the SDRAM.
//
// mn_core sees the interface of mn_mab (start / ready / jw / done / st / trap_*, ugo and the L1BM unit's
// ports), plus cur_mab (the MAB of the step, for mn_l1bm) and a bus to the SDRAM (sd_*, contract 06
// section 6). Where the state is (rtl/vpe/README.md):
//   - LM0 / LM1 / GRF0 / GRF1 of PE {m, p}: in the SDRAM, used in place (mn_mab_mem VPE = 1: mn_vpe_store).
//   - T, $omr1..15, $mb / $nb, $aluf, $mauf ("the context"): in the SDRAM (64 long words per PE). The
//     datapath holds the context of the 4 PEs of one MAB (mn_pe_lsu NPE = 4, mn_pe_core); around each
//     MAB pass mn_vpe_ctx loads what the word reads and saves what it writes (cx_use of mn_pe_core, or
//     everything but the OMR entries with CXALL = 1).
//   - $lbf, $lbi, the L1BM (mn_l1bm with N_MAB MABs), the matrix register (MAT, N_MAB = 1 only): in their
//     units.
// One j word (jw stable from start until done):
//   for m = 0 .. N_MAB-1: load the context of MAB m; run the word on its 4 PEs (mn_mab with vm = m);
//   save the context. ugo (the units start) is that of MAB 0; done after the last MAB.
//   A stop (E_RANGE / E_UNSUPPORTED) is reported at once, before anything of that MAB is saved. MAB 0
//   finds E_UNSUPPORTED (a word property) before any write; so the MABs after it leave out mn_mab's
//   check-only pass unless the word needs it for its data (nochk). The range of an LM access can
//   differ from PE to PE: with LM_AW < 11 and N_MAB > 1 a word with an LM access first gets a check-only
//   pass on every MAB (chk_only), so that an E_RANGE of any of the 64 PEs stops the word before any PE
//   wrote (contract 06 section 3); with LM_AW = 11 (the chip's LM) no LM / GRF access is out of range.
// Host port (between RUNs; hp_pe = {MAB, PE}): the PE spaces go straight to the SDRAM, in the formats of
//   mn_pe_lsu's host port: 0x01 LM0, 0x02 LM1 (2**LM_AW), 0x03 GRF0, 0x04 GRF1 (2**GRF_AW), 0x05 T (8),
//   0x10 OMR (16: entry 0 reads as ffff, a write to it is ignored), 0x11 BAR (2, 12 bits), and also
//   0x12 $aluf, 0x13 $mauf (8: 2c + k). Write masks as mn_pe_lsu: 32-bit lanes for LM / GRF, 16-bit lanes
//   for the MSB long word of T, 32-bit for its LSB one; OMR by byte (2 nibbles); BAR whole when either
//   of its two bytes is enabled. The SDRAM holds the official initial state (all 0) after mn_core's
//   clear (SDCLR) or the testbench's.
`default_nettype none
module mn_vpe #(
    parameter LM_AW  = 11,
    parameter GRF_AW = 8,
    parameter FPALU  = 0,
    parameter MAU    = 0,
    parameter BFN    = 0,
    parameter MAT    = 0,
    parameter BM     = 0,
    parameter N_MAB  = 16,         // 1 .. 16 (a power of 2 for the L1BM's replica rule)
    parameter integer POS_N = 0,   // chip coordinates of MAB 0
    parameter integer POS_C = 0,
    parameter integer POS_B = 0,
    parameter integer POS_M = 0,
    parameter [19:0] GRF_BASE = 20'hA0000,   // the VPE region of the SDRAM (aligned bases)
    parameter [19:0] CTX_BASE = 20'hA8000,
    parameter [19:0] LM_BASE  = 20'hC0000,
    parameter CXALL  = 0           // 1: load / save T, BAR, $aluf, $mauf around every MAB pass (a check)
) (
    input  wire         clk,
    input  wire         rst,
    // ---- the word (as mn_mab)
    input  wire         start,
    output wire         ready,
    input  wire [425:0] jw,
    output wire         done,
    output wire [1:0]   st,
    output wire [6:0]   st_field,
    output wire         trap_wr,
    output wire [1:0]   trap_mem,
    output wire [1:0]   trap_cycle,
    output wire [11:0]  trap_addr,
    output wire [1:0]   trap_pe,
    output wire [3:0]   trap_mab,
    // ---- L1BM / L2BM units of mn_core (as mn_mab) and the MAB of the step
    output wire         ugo,
    output wire [1:0]   cur_pe,
    output wire [3:0]   cur_mab,
    input  wire         x_act,
    input  wire         x_unsup,
    input  wire [6:0]   x_field,
    input  wire         lu_src,
    input  wire         lu_lbf,
    output wire         ls_we,
    output wire [1:0]   ls_cycle,
    output wire [127:0] ls_data,
    output wire         lr_req,
    input  wire         lr_ready,
    output wire [1:0]   lr_cycle,
    input  wire         lr_valid,
    input  wire [127:0] lr_data,
    output wire [1:0]   lb_rcycle,
    input  wire [127:0] lb_rdata,
    output wire         lb_we,
    output wire [1:0]   lb_wcycle,
    output wire [127:0] lb_wdata,
    // ---- host port of the PE spaces (between RUNs)
    input  wire         hp_req_valid,
    output wire         hp_req_ready,
    input  wire         hp_req_we,
    input  wire [5:0]   hp_pe,
    input  wire [7:0]   hp_req_space,
    input  wire [22:0]  hp_req_addr,
    input  wire [63:0]  hp_req_wdata,
    input  wire [7:0]   hp_req_wmask,
    output wire         hp_req_err,
    output wire         hp_rsp_valid,
    output wire [63:0]  hp_rsp_rdata,
    // ---- the bus to the SDRAM
    output wire         sd_req_valid,
    input  wire         sd_req_ready,
    output wire         sd_req_we,
    output wire [22:0]  sd_req_addr,
    output wire [63:0]  sd_req_wdata,
    output wire [7:0]   sd_req_wmask,
    input  wire         sd_rsp_valid,
    input  wire [63:0]  sd_rsp_rdata
);
    localparam [31:0] LAST32 = N_MAB - 1;
    localparam [3:0]  LAST   = LAST32[3:0];
    localparam [2:0]  V_IDLE = 3'd0, V_LD = 3'd1, V_GO = 3'd2, V_RUN = 3'd3, V_SV = 3'd4;

    reg  [2:0]  v;
    reg  [3:0]  vm;
    reg         gpass;     // the check-only passes of all MABs (chk_only) are running
    reg         gchk;      // the word had them
    reg  [9:0]  cx_q;
    reg  [3:0]  imr_q, omr_q;
    reg         d_q;
    reg  [1:0]  st_q;
    reg  [6:0]  fld_q;
    reg  [3:0]  tmab_q;
    reg         c_go, c_save;
    // mn_mab's check-only pass is left out (unless the word needs it for its data) when it cannot find
    // anything new: on the MABs after the first (E_UNSUPPORTED is a property of the word; the LM ranges
    // were checked by the passes over all MABs, or cannot fail), and on MAB 0 too when no PE access can
    // be out of range (LM_AW = 11) and the word has no unit part (whose E_UNSUPPORTED must be known before
    // the units start: mn_mab's ugo)
    wire        nochk = gchk | (vm != 4'd0) | ((LM_AW >= 11) & ~x_act);

    // ------------------------------------------------------------------ the MAB datapath
    wire        m_ready, m_done, m_ugo;
    wire [1:0]  m_st;
    wire [6:0]  m_field;
    wire [9:0]  cx_use;
    wire        mh_valid, mh_ready, mh_we, mh_err, mh_rsp;
    wire [1:0]  mh_pe;
    wire [7:0]  mh_space, mh_mask;
    wire [22:0] mh_addr;
    wire [63:0] mh_wdata, mh_rdata;
    wire        vs_valid, vs_ready, vs_we, vs_rsp;
    wire [22:0] vs_addr;
    wire [63:0] vs_wdata;
    wire [7:0]  vs_wmask;
    // with more than one MAB the L1BM unit keeps $lbf in BSRAM (mn_core: mn_l1bm BS = 1)
    mn_mab #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .FPALU(FPALU), .MAU(MAU), .N_PE(4), .BFN(BFN), .MAT(MAT),
             .BM(BM), .VPE(1), .LBS((N_MAB > 1) ? 1 : 0), .LM_BASE(LM_BASE), .GRF_BASE(GRF_BASE),
             .POS_N(POS_N), .POS_C(POS_C), .POS_B(POS_B), .POS_M(POS_M), .POS_P(0)) u_mab (
        .clk(clk), .rst(rst),
        .start((v == V_GO) & m_ready), .ready(m_ready), .jw(jw), .vm(vm), .chk_only(gpass),
        .nochk(nochk), .cx_use(cx_use),
        .done(m_done), .st(m_st), .st_field(m_field),
        .trap_wr(trap_wr), .trap_mem(trap_mem), .trap_cycle(trap_cycle), .trap_addr(trap_addr),
        .trap_pe(trap_pe),
        .ugo(m_ugo), .cur_pe(cur_pe), .x_act(x_act), .x_unsup(x_unsup), .x_field(x_field),
        .lu_src(lu_src), .lu_lbf(lu_lbf), .ls_we(ls_we), .ls_cycle(ls_cycle), .ls_data(ls_data),
        .lr_req(lr_req), .lr_ready(lr_ready), .lr_cycle(lr_cycle), .lr_valid(lr_valid), .lr_data(lr_data),
        .lb_rcycle(lb_rcycle), .lb_rdata(lb_rdata), .lb_we(lb_we), .lb_wcycle(lb_wcycle),
        .lb_wdata(lb_wdata),
        .hp_req_valid(mh_valid), .hp_req_ready(mh_ready), .hp_req_we(mh_we), .hp_pe(mh_pe),
        .hp_req_space(mh_space), .hp_req_addr(mh_addr), .hp_req_wdata(mh_wdata), .hp_req_wmask(mh_mask),
        .hp_req_err(mh_err), .hp_rsp_valid(mh_rsp), .hp_rsp_rdata(mh_rdata),
        .vs_req_valid(vs_valid), .vs_req_ready(vs_ready), .vs_req_we(vs_we), .vs_req_addr(vs_addr),
        .vs_req_wdata(vs_wdata), .vs_req_wmask(vs_wmask), .vs_rsp_valid(vs_rsp), .vs_rsp_rdata(sd_rsp_rdata));

    // ------------------------------------------------------------------ the context engine
    wire        c_idle, c_fin;
    wire        cb_valid, cb_ready, cb_we, cb_rsp;
    wire [22:0] cb_addr;
    wire [63:0] cb_wdata;
    wire [7:0]  cb_wmask;
    mn_vpe_ctx #(.CTX_BASE(CTX_BASE), .MAU(MAU)) u_ctx (
        .clk(clk), .rst(rst), .go(c_go), .save(c_save), .cx(cx_q), .imr_e(imr_q), .omr_e(omr_q), .vm(vm),
        .idle(c_idle), .fin(c_fin),
        .hp_req_valid(mh_valid), .hp_req_ready(mh_ready), .hp_req_we(mh_we), .hp_pe(mh_pe),
        .hp_req_space(mh_space), .hp_req_addr(mh_addr), .hp_req_wdata(mh_wdata), .hp_req_wmask(mh_mask),
        .hp_req_err(mh_err), .hp_rsp_valid(mh_rsp), .hp_rsp_rdata(mh_rdata),
        .b_req_valid(cb_valid), .b_req_ready(cb_ready), .b_req_we(cb_we), .b_req_addr(cb_addr),
        .b_req_wdata(cb_wdata), .b_req_wmask(cb_wmask), .b_rsp_valid(cb_rsp), .b_rsp_rdata(sd_rsp_rdata));

    // ------------------------------------------------------------------ sequencer
    wire [3:0]  w_imr = jw[425-3 -: 4];      // imr[3:0] (cx_use[2] is set only for imr[4] = 0, imr != 0)
    wire [3:0]  w_omr = jw[425-17 -: 4];
    wire [9:0]  cx_full = (MAU != 0) ? 10'h3f3 : 10'h0f3;   // T, BAR, $aluf, ($mauf) both ways
    wire [9:0]  cx_sel  = (CXALL != 0) ? (cx_full | cx_use) : cx_use;
    // a word that could find an LM access out of range on some MAB after MAB 0 wrote
    wire        gchk_n  = (N_MAB > 1) && (LM_AW < 11) && cx_use[4];
    reg         h_busy;  // the host engine is answering a read
    assign ready    = (v == V_IDLE) & m_ready & c_idle & ~h_busy;
    assign done     = d_q;
    assign st       = st_q;
    assign st_field = fld_q;
    assign trap_mab = tmab_q;
    assign ugo      = m_ugo & ~gpass & (vm == 4'd0);
    assign cur_mab  = vm;

    always @(posedge clk) begin
        if (rst) begin
            v      <= V_IDLE;
            vm     <= 4'd0;
            gpass  <= 1'b0;
            gchk   <= 1'b0;
            cx_q   <= 10'd0;
            imr_q  <= 4'd0;
            omr_q  <= 4'd0;
            d_q    <= 1'b0;
            st_q   <= 2'd0;
            fld_q  <= 7'd0;
            tmab_q <= 4'd0;
            c_go   <= 1'b0;
            c_save <= 1'b0;
        end else begin
            d_q  <= 1'b0;
            c_go <= 1'b0;
            case (v)
                V_IDLE: if (start && ready) begin
                    cx_q   <= cx_sel;
                    imr_q  <= w_imr;
                    omr_q  <= w_omr;
                    gchk   <= gchk_n;
                    gpass  <= gchk_n;
                    vm     <= 4'd0;
                    c_go   <= 1'b1;
                    c_save <= 1'b0;
                    v      <= V_LD;
                end
                V_LD: if (c_fin) v <= V_GO;
                V_GO: if (m_ready) v <= V_RUN;
                V_RUN: if (m_done) begin
                    if (m_st != 2'd0) begin
                        // E_RANGE / E_UNSUPPORTED: report at once (this MAB wrote nothing)
                        d_q    <= 1'b1;
                        st_q   <= m_st;
                        fld_q  <= m_field;
                        tmab_q <= vm;
                        v      <= V_IDLE;
                    end else if (gpass) begin
                        // the check-only pass of MAB vm passed: the next MAB, or the normal passes
                        if (vm == LAST) begin
                            gpass <= 1'b0;
                            vm    <= 4'd0;
                        end else begin
                            vm <= vm + 4'd1;
                        end
                        c_go   <= 1'b1;
                        c_save <= 1'b0;
                        v      <= V_LD;
                    end else begin
                        c_go   <= 1'b1;
                        c_save <= 1'b1;
                        v      <= V_SV;
                    end
                end
                V_SV: if (c_fin) begin
                    if (vm == LAST) begin
                        d_q  <= 1'b1;
                        st_q <= 2'd0;
                        v    <= V_IDLE;
                    end else begin
                        vm     <= vm + 4'd1;
                        c_go   <= 1'b1;
                        c_save <= 1'b0;
                        v      <= V_LD;
                    end
                end
                default: v <= V_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ host engine
    wire [7:0]  hs   = hp_req_space;
    wire [22:0] ha   = hp_req_addr;
    wire [7:0]  hm   = hp_req_wmask;
    wire        h_lm  = (hs == 8'h01) | (hs == 8'h02);
    wire        h_grf = (hs == 8'h03) | (hs == 8'h04);
    wire        h_t   = (hs == 8'h05);
    wire        h_omr = (hs == 8'h10);
    wire        h_bar = (hs == 8'h11);
    wire        h_fw  = (hs == 8'h12) | (hs == 8'h13);
    wire        h_in  = (h_lm & ((ha >> LM_AW) == 23'd0)) | (h_grf & ((ha >> GRF_AW) == 23'd0)) |
                        ((h_t | h_fw) & (ha[22:3] == 20'd0)) | (h_omr & (ha[22:4] == 19'd0)) |
                        (h_bar & (ha[22:1] == 22'd0));
    wire [5:0]  h_slot = h_t ? {3'b000, ha[2:0]} : h_bar ? {5'd4, ha[0]} : h_omr ? {2'b01, ha[3:0]} :
                         {2'b10, hs[0], ha[2:0]};
    wire [19:0] h_sa  = h_lm  ? (LM_BASE  | {2'd0, hp_pe, hs[1], ha[10:0]}) :
                        h_grf ? (GRF_BASE | {5'd0, hp_pe, hs[2], ha[7:0]}) :
                                (CTX_BASE | {8'd0, hp_pe, h_slot});
    wire [7:0]  h_l32 = {{4{|hm[7:4]}}, {4{|hm[3:0]}}};
    wire [7:0]  h_wm  = (h_lm | h_grf) ? h_l32 :
                        h_t   ? (ha[0] ? h_l32 : {{2{|hm[7:6]}}, {2{|hm[5:4]}}, {2{|hm[3:2]}}, {2{|hm[1:0]}}}) :
                        h_omr ? {6'd0, hm[1:0]} :
                        h_bar ? {6'd0, {2{|hm[1:0]}}} : 8'hff;
    wire [63:0] h_wd  = h_bar ? {52'd0, hp_req_wdata[11:0]} : hp_req_wdata;
    wire        h_e0  = h_omr & (ha[3:0] == 4'd0);                     // OMR entry 0
    wire        h_nob = hp_req_we ? (h_e0 | (h_wm == 8'd0)) : h_e0;    // no SDRAM access
    reg         h_r0;                                                  // the answer of an entry-0 read
    wire        ph_h  = (v == V_IDLE) & c_idle;
    wire        hb_ready;
    wire        h_free = ph_h & ~h_busy & ~h_r0;
    assign hp_req_err   = ~h_in;
    assign hp_req_ready = h_free & (~h_in | h_nob | hb_ready);
    wire        h_acc  = hp_req_valid & hp_req_ready;
    wire        hb_valid = h_free & hp_req_valid & h_in & ~h_nob;
    always @(posedge clk) begin
        if (rst) begin
            h_busy <= 1'b0;
            h_r0   <= 1'b0;
        end else begin
            h_r0 <= h_acc & h_in & ~hp_req_we & h_e0;
            if (h_acc && hb_valid && !hp_req_we) h_busy <= 1'b1;
            else if (h_busy && sd_rsp_valid) h_busy <= 1'b0;
        end
    end
    assign hp_rsp_valid = h_r0 | (h_busy & sd_rsp_valid);
    assign hp_rsp_rdata = h_r0 ? 64'h000000000000ffff : sd_rsp_rdata;

    // ------------------------------------------------------------------ the SDRAM bus: one user at a time
    // the store during a MAB pass, the context engine around it, the host engine between RUNs
    wire ph_st = (v == V_RUN);
    wire ph_cx = ~c_idle;
    assign sd_req_valid = ph_st ? vs_valid : ph_cx ? cb_valid : hb_valid;
    assign sd_req_we    = ph_st ? vs_we : ph_cx ? cb_we : hp_req_we;
    assign sd_req_addr  = ph_st ? vs_addr : ph_cx ? cb_addr : {3'd0, h_sa};
    assign sd_req_wdata = ph_st ? vs_wdata : ph_cx ? cb_wdata : h_wd;
    assign sd_req_wmask = ph_st ? vs_wmask : ph_cx ? cb_wmask : h_wm;
    assign vs_ready = ph_st & sd_req_ready;
    assign cb_ready = ph_cx & sd_req_ready;
    assign hb_ready = ph_h & sd_req_ready;
    assign vs_rsp   = ph_st & sd_rsp_valid;
    assign cb_rsp   = ph_cx & sd_rsp_valid;

`ifndef SYNTHESIS
    // clocks spent per phase (read by the testbench for the speed figures; simulation only, counted over
    // the whole simulation)
    /* verilator lint_off PROCASSINIT */
    integer n_words = 0, n_ld = 0, n_go = 0, n_run = 0, n_sv = 0, n_gpass = 0, n_sd = 0;
    /* verilator lint_on PROCASSINIT */
    always @(posedge clk) begin
        if (!rst) begin
            if (v == V_IDLE && start && ready) n_words <= n_words + 1;
            if (v == V_LD) n_ld <= n_ld + 1;
            if (v == V_GO) n_go <= n_go + 1;
            if (v == V_RUN) n_run <= n_run + 1;
            if (v == V_SV) n_sv <= n_sv + 1;
            if (gpass && v != V_IDLE) n_gpass <= n_gpass + 1;
            if (sd_req_valid && sd_req_ready) n_sd <= n_sd + 1;
        end
    end
    initial begin
        if (N_MAB < 1 || N_MAB > 16) $display("mn_vpe: ERROR N_MAB must be 1 .. 16");
        if (MAT != 0 && N_MAB > 1) $display("mn_vpe: ERROR the matrix register needs N_MAB = 1");
        if (LM_AW > 11) $display("mn_vpe: ERROR LM_AW must be 11 or less (2048 long words)");
    end
    always @(posedge clk) begin
        if (!rst && sd_rsp_valid && !(ph_st || ph_cx || h_busy))
            $display("mn_vpe: ERROR an SDRAM answer outside a read (v %0d)", v);
        if (!rst && vs_valid && !ph_st)
            $display("mn_vpe: ERROR a store request outside a MAB pass");
    end
`endif
endmodule
`default_nettype wire

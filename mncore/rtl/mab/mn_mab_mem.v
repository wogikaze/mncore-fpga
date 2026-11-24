// mn_mab_mem: the local memories of the NPE PEs of a time-multiplexed MAB (WP30).
//
// One mn_pe_lsu (WP14, unchanged) executes the memory side of the step of one PE at a time.
// The state of the NPE PEs:
//   - GRF0, GRF1, LM0, LM1: mn_pe_store with NPE PEs stacked in the BSRAM ({pe, long word});
//     the store channels of mn_pe_lsu are used as they are, the PE number goes beside them.
//   - T, the mask registers $omr1..15 and $mb / $nb (inside mn_pe_lsu, one PE's worth): a
//     context store (BSRAM, 64 bits x 128) holds them for every PE; it is the reference copy.
//     Before a step, what the step uses is loaded into mn_pe_lsu through its host port
//     ("restore"), and after it, what the step wrote is read back ("save"):
//       restore $mb, $nb         always (2 clocks)
//       restore T (8 long words) the step reads T as an operand (ctx_t), uses T-indirect
//                                addressing ($lmt...), or writes T under a mask
//       restore $omr<imr>        the write mask is $imr<n> (n = 1..15)
//       save T                   the step writes T (8 reads, 2 clocks each)
//       save $omr<omr>           the step writes a mask register
//       save $mb, $nb            the step writes $mb or $nb
//     Unmasked T writes cover all of T (2 long words x 4 cycles) and a mask register write
//     all 16 bits of the entry (mn_pe_lsu), so the old value is not needed for them.
//     Nothing is saved after a check-only step (nul) or a trap (nothing was written).
//   The change of PE therefore costs nothing in mn_pe_lsu; mn_pe_lsu with a PE index on its
//   T / mask / base registers would make the context store unnecessary (WP30 report).
//
// Step protocol (the caller is mn_pe_core): like mn_pe_mem, but
//   - jw is the word itself: the start-clock form (imr = 0, so that every enabled write is
//     range checked, contract 06 section 3) and the ll = 00 form for nul are made here;
//   - pe, nul (check only: range check, then nothing is written) and ctx_t are taken at start;
//   - start is accepted when idle; then come the restore, the step of mn_pe_lsu (opr_* /
//     res_* as in mn_pe_lsu) and the save, and done pulses at the end (trap / trap_* are
//     mn_pe_lsu's, valid with done). jw and rd_use must stay stable until done.
//
// Host port (between steps; hp_pe = the PE): spaces 1..4 (LM0, LM1, GRF0, GRF1) go to
//   mn_pe_lsu's host port and the store of PE hp_pe. T (5), OMR (0x10) and BAR (0x11) are
//   served from the context store (read latency 1), with mn_pe_lsu's ranges (T 8 long words,
//   OMR 16 entries, entry 0 reads ffff and ignores writes, BAR 2). Differences from mn_pe_lsu:
//   T is written in 32-bit halves (a 16-bit write lane of the MSB long word writes its 32-bit
//   half), an OMR write takes all 16 bits when wmask[1:0] != 0. The host tools write T and OMR
//   in whole long words.
// Reset clears the sequencers and the registers of mn_pe_lsu; the context store is RAM and is
// cleared through the host port (mn_core CLEAR).
`default_nettype none
module mn_mab_mem #(
    parameter LM_AW  = 8,   // LM0/LM1 depth per PE = 2**LM_AW long words
    parameter GRF_AW = 8,   // GRF0/GRF1 depth per PE = 2**GRF_AW long words
    parameter NPE    = 4    // PEs (4)
) (
    input  wire         clk,
    input  wire         rst,
    // ---- step
    input  wire [1:0]   pe,
    input  wire         start,
    output wire         idle,
    input  wire [425:0] jw,
    input  wire [3:0]   rd_use,
    input  wire         nul,
    input  wire         ctx_t,
    output wire         busy,
    output wire         opr_valid,
    input  wire [1:0]   opr_cycle,
    input  wire [1:0]   opr_mem,
    output wire [127:0] opr_grf0,
    output wire [127:0] opr_grf1,
    output wire [127:0] opr_lm0,
    output wire [127:0] opr_lm1,
    output wire [127:0] opr_t,
    input  wire         res_valid,
    output wire         res_ready,
    output wire [1:0]   res_cycle,
    input  wire [127:0] res_mau,
    input  wire [127:0] res_alu,
    input  wire [127:0] res_l1bm,
    input  wire [127:0] res_mread,
    input  wire [3:0]   res_alu_flags,
    input  wire [3:0]   res_mau_flags,
    output wire         zf_en,
    output wire [1:0]   zf_sel,
    output wire [127:0] zf_mask,
    output reg          done,
    output wire         trap,
    output wire         trap_wr,
    output wire [1:0]   trap_mem,
    output wire [1:0]   trap_cycle,
    output wire [11:0]  trap_addr,
    output wire         unsup,
    // ---- host port
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
    localparam [7:0] SP_T = 8'h05, SP_OMR = 8'h10, SP_BAR = 8'h11;

    // ------------------------------------------------------------------ word fields (j_flat.yaml)
    wire [4:0] w_imr   = jw[425-2 -: 5];
    wire       w_tgt_t = jw[425-10];
    wire [3:0] w_omr   = jw[425-17 -: 4];
    wire       w_t_wr  = jw[425-22];
    wire       w_m0_wr = jw[425-75];
    wire       w_m0_tr = jw[425-90];
    wire       w_m0_mj = jw[425-91];
    wire [1:0] w_m0_mp = jw[425-92 -: 2];
    wire       w_m1_wr = jw[425-96];
    wire       w_m1_mj = jw[425-111];
    wire [1:0] w_m1_mp = jw[425-112 -: 2];
    wire [4:0] w_aluop = jw[425-147 -: 5];
    wire       w_imm   = (w_aluop == 5'b11111);   // the LM0 fields carry the immediate
    wire       w_mask  = (w_imr != 5'd0);
    wire       w_barw  = (w_m0_wr & ~w_m0_mj & (w_m0_mp == 2'b11) & ~w_imm) |
                         (w_m1_wr & ~w_m1_mj & (w_m1_mp == 2'b11));

    // ------------------------------------------------------------------ sequencer state
    localparam [2:0] Q_IDLE = 3'd0, Q_RRD = 3'd1, Q_RWR = 3'd2, Q_GO = 3'd3, Q_RUN = 3'd4,
                     Q_SRD = 3'd5, Q_SWT = 3'd6;
    reg  [2:0] q;
    reg  [1:0] pe_q;
    reg        nul_q;
    reg        r_t, r_o, s_t, s_o, s_b;   // restore / save plan of the step
    reg  [3:0] e_r, e_s;                  // mask register entries to restore / save
    reg  [3:0] k;                         // item: 0..1 BAR, 2..9 T long word 0..7, 10 OMR
    localparam [3:0] K_END = 4'd15;

    // next items of the restore / save plans
    function [3:0] nxt_r(input [3:0] i, input rt, input ro);
        nxt_r = (i == 4'd0) ? 4'd1 :
                (i == 4'd1) ? (rt ? 4'd2 : ro ? 4'd10 : K_END) :
                (i == 4'd9) ? (ro ? 4'd10 : K_END) :
                (i == 4'd10) ? K_END : i + 4'd1;
    endfunction
    function [3:0] nxt_s(input [3:0] i, input so, input sb);
        nxt_s = (i == 4'd9) ? (so ? 4'd10 : sb ? 4'd0 : K_END) :
                (i == 4'd10) ? (sb ? 4'd0 : K_END) :
                (i == 4'd0) ? 4'd1 :
                (i == 4'd1) ? K_END : i + 4'd1;
    endfunction
    wire [3:0] k_nr = nxt_r(k, r_t, r_o);
    wire [3:0] k_ns = nxt_s(k, s_o, s_b);
    wire [3:0] s_first = s_t ? 4'd2 : s_o ? 4'd10 : s_b ? 4'd0 : K_END;

    // item -> mn_pe_lsu host space / address, context store entry {pe, 5 bits}
    function [7:0] it_sp(input [3:0] i);
        it_sp = (i <= 4'd1) ? SP_BAR : (i <= 4'd9) ? SP_T : SP_OMR;
    endfunction
    function [4:0] it_ce(input [3:0] i, input [3:0] e);   // context entry of the item
        it_ce = (i <= 4'd1) ? {4'b0100, i[0]} : (i <= 4'd9) ? {2'b00, i[2:0] - 3'd2} : {1'b1, e};
    endfunction
    wire [3:0] e_cur = (q == Q_SRD || q == Q_SWT) ? e_s : e_r;
    wire [22:0] it_ad = (k <= 4'd1) ? {22'd0, k[0]} : (k <= 4'd9) ? {20'd0, k[2:0] - 3'd2} : {19'd0, e_cur};

    // ------------------------------------------------------------------ mn_pe_lsu + store
    wire         l_idle, l_busy, l_done, l_trap;
    wire         l_hp_valid, l_hp_ready, l_hp_we, l_hp_err, l_hp_rsp_valid;
    wire [7:0]   l_hp_space, l_hp_wmask;
    wire [22:0]  l_hp_addr;
    wire [63:0]  l_hp_wdata, l_hp_rsp_rdata;
    wire [3:0]   st_req_valid, st_req_ready, st_req_we, st_rsp_valid;
    wire [91:0]  st_req_addr;
    wire [255:0] st_req_wdata, st_rsp_rdata;
    wire [31:0]  st_req_wmask;

    // the start-clock form (imr = 0) and the check-only form (ll = 00) of the word
    wire [425:0] jw_chk = {jw[425:424], 5'b00000, jw[418:0]};
    wire [425:0] jw_nul = {2'b00, jw[423:0]};
    wire [425:0] l_jw   = (q == Q_GO) ? jw_chk : (nul_q ? jw_nul : jw);

    mn_pe_lsu #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .RBS(1)) u_lsu (
        .clk(clk), .rst(rst), .subpe(pe_q),
        .start(q == Q_GO), .idle(l_idle), .jw(l_jw), .rd_use(rd_use), .busy(l_busy),
        .opr_valid(opr_valid), .opr_cycle(opr_cycle), .opr_mem(opr_mem),
        .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
        .res_valid(res_valid), .res_ready(res_ready), .res_cycle(res_cycle),
        .res_mau(res_mau), .res_alu(res_alu), .res_l1bm(res_l1bm), .res_mread(res_mread),
        .res_alu_flags(res_alu_flags), .res_mau_flags(res_mau_flags),
        .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
        .done(l_done), .trap(l_trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
        .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(unsup),
        .hp_req_valid(l_hp_valid), .hp_req_ready(l_hp_ready), .hp_req_we(l_hp_we),
        .hp_req_space(l_hp_space), .hp_req_addr(l_hp_addr), .hp_req_wdata(l_hp_wdata),
        .hp_req_wmask(l_hp_wmask), .hp_req_err(l_hp_err),
        .hp_rsp_valid(l_hp_rsp_valid), .hp_rsp_rdata(l_hp_rsp_rdata),
        .st_req_valid(st_req_valid), .st_req_ready(st_req_ready), .st_req_we(st_req_we),
        .st_req_addr(st_req_addr), .st_req_wdata(st_req_wdata), .st_req_wmask(st_req_wmask),
        .st_rsp_valid(st_rsp_valid), .st_rsp_rdata(st_rsp_rdata)
    );
    assign trap = l_trap;

    wire q_idle = (q == Q_IDLE);
    mn_pe_store #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .NPE(NPE)) u_store (
        .clk(clk), .rst(rst), .pe(q_idle ? hp_pe : pe_q),
        .req_valid(st_req_valid), .req_ready(st_req_ready), .req_we(st_req_we),
        .req_addr(st_req_addr), .req_wdata(st_req_wdata), .req_wmask(st_req_wmask),
        .rsp_valid(st_rsp_valid), .rsp_rdata(st_rsp_rdata)
    );

    // ------------------------------------------------------------------ context store
    // entry {pe, 5 bits}: 0..7 T long word 0..7, 8 $mb, 9 $nb, 16..31 $omr0..15
    wire [63:0] c_q;
    reg  [1:0]  c_we;
    reg  [6:0]  c_wa, c_ra;
    reg  [63:0] c_wd;
    reg         c_re;
    mn_ram_1r1w #(.W(64), .AW(7), .NWE(2), .OREG(0)) u_ctx (
        .clk(clk), .we(c_we), .waddr(c_wa), .wdata(c_wd), .re(c_re), .raddr(c_ra), .rdata(c_q));

    // host access to T / OMR / BAR
    wire        h_ctx   = (hp_req_space == SP_T) | (hp_req_space == SP_OMR) | (hp_req_space == SP_BAR);
    wire [22:0] h_lim   = (hp_req_space == SP_T) ? 23'd8 : (hp_req_space == SP_OMR) ? 23'd16 : 23'd2;
    wire        h_in    = (hp_req_addr < h_lim);
    wire [4:0]  h_ce    = (hp_req_space == SP_T) ? {2'b00, hp_req_addr[2:0]} :
                          (hp_req_space == SP_OMR) ? {1'b1, hp_req_addr[3:0]} : {4'b0100, hp_req_addr[0]};
    // a context read answers in the next clock; it is not taken while mn_pe_lsu has a host
    // read outstanding (l_idle = 0), so the two answers never meet
    wire        h_rdy   = q_idle & (h_ctx ? l_idle : l_hp_ready);
    wire        h_acc   = hp_req_valid & h_rdy;
    wire        h_cacc  = h_acc & h_ctx & h_in;
    reg         h_crsp;          // a context read answers in this clock
    reg         h_comr0;         // ... of OMR entry 0 (reads ffff)
    assign hp_req_ready = h_rdy;
    assign hp_req_err   = h_ctx ? ~h_in : l_hp_err;
    assign hp_rsp_valid = h_crsp | (l_hp_rsp_valid & q_idle);
    assign hp_rsp_rdata = h_crsp ? (h_comr0 ? 64'h000000000000ffff : c_q) : l_hp_rsp_rdata;

    always @* begin
        // writes: the host (between steps) or the save of a step
        c_we = 2'b00;
        c_wa = {hp_pe, h_ce};
        c_wd = hp_req_wdata;
        if (q_idle) begin
            if (h_cacc && hp_req_we) begin
                if (hp_req_space == SP_T) begin
                    c_we = {|hp_req_wmask[7:4], |hp_req_wmask[3:0]};
                end else if (hp_req_space == SP_OMR) begin
                    c_we = {2{(hp_req_addr[3:0] != 4'd0) & (|hp_req_wmask[1:0])}};
                    c_wd = {48'd0, hp_req_wdata[15:0]};
                end else begin
                    c_we = {2{|hp_req_wmask[1:0]}};
                    c_wd = {52'd0, hp_req_wdata[11:0]};
                end
            end
        end else if (q == Q_SWT) begin
            c_we = {2{l_hp_rsp_valid}};
            c_wa = {pe_q, it_ce(k, e_s)};
            c_wd = l_hp_rsp_rdata;
        end
        // reads: the host (between steps) or the restore (the next item while one is written)
        c_re = 1'b0;
        c_ra = {hp_pe, h_ce};
        if (q_idle) begin
            c_re = h_cacc & ~hp_req_we;
        end else if (q == Q_RRD) begin
            c_re = 1'b1;
            c_ra = {pe_q, it_ce(k, e_r)};
        end else if (q == Q_RWR) begin
            c_re = l_hp_ready & (k_nr != K_END);
            c_ra = {pe_q, it_ce(k_nr, e_r)};
        end
    end

    // mn_pe_lsu host port: the host between steps (spaces 1..4), else the restore / save
    assign l_hp_valid = q_idle ? (hp_req_valid & ~h_ctx) : ((q == Q_RWR) | (q == Q_SRD));
    assign l_hp_we    = q_idle ? hp_req_we : (q == Q_RWR);
    assign l_hp_space = q_idle ? hp_req_space : it_sp(k);
    assign l_hp_addr  = q_idle ? hp_req_addr : it_ad;
    assign l_hp_wdata = q_idle ? hp_req_wdata : c_q;
    assign l_hp_wmask = q_idle ? hp_req_wmask : 8'hff;

    // ------------------------------------------------------------------ sequencer
    assign idle = q_idle & l_idle & ~h_crsp;
    assign busy = ~q_idle | l_busy;

    always @(posedge clk) begin
        if (rst) begin
            q       <= Q_IDLE;
            done    <= 1'b0;
            h_crsp  <= 1'b0;
            h_comr0 <= 1'b0;
            pe_q    <= 2'd0;
            nul_q   <= 1'b0;
            k       <= 4'd0;
        end else begin
            done    <= 1'b0;
            h_crsp  <= h_cacc & ~hp_req_we;
            h_comr0 <= (hp_req_space == SP_OMR) && (hp_req_addr[3:0] == 4'd0);
            case (q)
                Q_IDLE: if (start && idle) begin
                    pe_q  <= pe;
                    nul_q <= nul;
                    r_t   <= ctx_t | (w_m0_tr & ~w_imm) | (~nul & w_t_wr & w_tgt_t & w_mask);
                    r_o   <= ~nul & w_mask & ~w_imr[4] & (w_imr[3:0] != 4'd0);
                    s_t   <= ~nul & w_t_wr;
                    s_o   <= ~nul & (w_omr != 4'd0);
                    s_b   <= ~nul & w_barw;
                    e_r   <= w_imr[3:0];
                    e_s   <= w_omr;
                    k     <= 4'd0;
                    q     <= Q_RRD;
                end
                Q_RRD: q <= Q_RWR;
                Q_RWR: if (l_hp_ready) begin
                    if (k_nr == K_END) q <= Q_GO;
                    else               k <= k_nr;
                end
                Q_GO: if (l_idle) q <= Q_RUN;   // mn_pe_lsu takes the start (it is idle here)
                Q_RUN: if (l_done) begin
                    if (l_trap || s_first == K_END) begin
                        q    <= Q_IDLE;
                        done <= 1'b1;
                    end else begin
                        k <= s_first;
                        q <= Q_SRD;
                    end
                end
                Q_SRD: if (l_hp_ready) q <= Q_SWT;
                default: if (l_hp_rsp_valid) begin   // Q_SWT
                    if (k_ns == K_END) begin
                        q    <= Q_IDLE;
                        done <= 1'b1;
                    end else begin
                        k <= k_ns;
                        q <= Q_SRD;
                    end
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && q == Q_GO && !l_idle)
            $display("mn_mab_mem: ERROR mn_pe_lsu not idle at the start of a step");
        if (!rst && (q == Q_RWR || q == Q_SRD) && l_hp_valid && l_hp_ready && l_hp_err)
            $display("mn_mab_mem: ERROR context item %0d rejected by mn_pe_lsu", k);
    end
`endif
endmodule
`default_nettype wire

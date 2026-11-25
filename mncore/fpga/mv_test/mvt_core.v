// mvt_core: the core of the MV test design (WP33): instruction memory, sequencer, the MV unit
// (mn_mv), the L2BM unit (mn_l2bm) and the L1BM of L1B 0 as a plain memory (mvt_l1mem). It runs
// the m words and the L2BM part of the j words, the way WP37 is expected to run them in mn_core
// (mncore/rtl/mv/README.md "the core side"); it has no PE and no L1BM instruction unit.
//
// The ports are the core side of brd_host_if (rtl/board/PROTOCOL.md section 5) and the SDRAM bus
// of sdr_bus64 (contract section 6). Single clock (with sdr_bus64 ASYNC = 1 the SDRAM runs on its
// own clock).
//
// Spaces (loc 0 only: n0c0b0 / n0c0 / n0): 0x00 IMEM (entry * 8 + lane, written lane 6 last, as
// mn_core), 0x06 L1BM (2**10 long words), 0x07 L2BM, 0x08 PDM, 0x09 DRAM (mn_mv). Served while the
// core is not running.
//
// RUN(start, count) executes the entries in order:
//   - j word: ll = 10 E_DECODE. A wait (wd != 0, any ll): after the MV unit is idle, 0
//     completions of the tag stop the RUN with reason 4 (WAIT: the official blocks for ever, the
//     rest of the program does not run; info = the tag), 2 or more stop with E_UNSUPPORTED
//     wd (the official aborts), 1 is taken and the word runs. ll = 00: nothing (mn_l2bm skip).
//     A word with an L2BM instruction: E_RANGE / E_UNSUPPORTED from mn_l2bm's checks, else it
//     runs on mn_l2bm when the MV unit is idle (the official completes an MV at its issue); the
//     L1BM unit's commit is given right after pre_done (there is none). Other j words: nothing
//     (mn_l2bm skip); their PE / L1BM parts are not run.
//   - m word: valid = 0 is skipped; else started on mn_mv when it is ready; its check gives OK
//     (the transfer goes on in the background), E_RANGE (info = entry) or E_UNSUPPORTED (info =
//     0x80 | m field).
//   - the RUN ends (core_busy = 0) when the MV unit is idle.
// Stop record as mn_core: core_reason 0 OK / 1 E_RANGE / 2 E_UNSUPPORTED / 3 E_DECODE / 4 WAIT,
// core_pc, core_steps, core_info.
`default_nettype none
module mvt_core #(
    parameter IMEM_AW = 9,
    parameter L2AW    = 11,
    parameter PDM_AW  = 17,
    parameter DRAM_AW = 19,
    parameter [19:0] PDM_BASE  = 20'h80000,
    parameter [19:0] DRAM_BASE = 20'h00000,
    parameter L2_RRN  = 2,
    parameter L2_DAR  = 1
) (
    input  wire         clk,
    input  wire         rst,
    // memory write / read ports (brd_host_if)
    input  wire         mw_valid,
    output wire         mw_ready,
    output wire         mw_err,
    input  wire [7:0]   mw_space,
    input  wire [15:0]  mw_loc,
    input  wire [22:0]  mw_addr,
    input  wire [63:0]  mw_data,
    input  wire [7:0]   mw_mask,
    input  wire         mr_valid,
    output wire         mr_ready,
    output wire         mr_err,
    input  wire [7:0]   mr_space,
    input  wire [15:0]  mr_loc,
    input  wire [22:0]  mr_addr,
    output wire         mr_rsp_valid,
    output wire [63:0]  mr_rsp_data,
    // run control / status
    input  wire         run_start,
    input  wire [15:0]  run_pc,
    input  wire [31:0]  run_count,
    output wire         core_busy,
    output wire [7:0]   core_reason,
    output wire [31:0]  core_info,
    output wire [15:0]  core_pc,
    output wire [31:0]  core_steps,
    // SDRAM (sdr_bus64)
    output wire         sd_req_valid,
    input  wire         sd_req_ready,
    output wire         sd_req_we,
    output wire [22:0]  sd_req_addr,
    output wire [63:0]  sd_req_wdata,
    output wire [7:0]   sd_req_wmask,
    input  wire         sd_rsp_valid,
    input  wire [63:0]  sd_rsp_rdata,
    input  wire         sd_err_addr,
    // indicators
    output wire         mv_busy_o,
    output wire         mv_err_o
);
`include "mn_jfields.vh"
`include "mn_mfields.vh"

    localparam [2:0] R_OK = 3'd0, R_RANGE = 3'd1, R_UNSUP = 3'd2, R_DECODE = 3'd3, R_WAIT = 3'd4;
    localparam [16:0] DEPTH = 17'd1 << IMEM_AW;

    // ------------------------------------------------------------------ state
    localparam [3:0] S_IDLE = 4'd0, S_FETCH = 4'd1, S_DEC = 4'd2, S_WT = 4'd3, S_JX = 4'd4, S_L2 = 4'd5,
                     S_L2D = 4'd6, S_MS = 4'd7, S_MA = 4'd8, S_END = 4'd9;
    reg  [3:0]  s;
    reg  [15:0] pc;
    reg  [31:0] left;
    reg  [15:0] steps;
    reg  [2:0]  reason;
    reg  [15:0] info;
    reg         run_pend;
    wire        busy = (s != S_IDLE);
    assign core_busy   = busy | run_pend;
    assign core_reason = {5'd0, reason};
    assign core_info   = {16'd0, info};
    assign core_pc     = pc;
    assign core_steps  = {16'd0, steps};

    // ------------------------------------------------------------------ instruction memory (as mn_core)
    wire [19:0] depth20 = {3'd0, DEPTH};
    wire [2:0]  w_lane  = mw_addr[2:0];
    wire [19:0] w_entry = mw_addr[22:3];
    wire        w_im    = (mw_space == 8'h00);
    wire        w_im_ok = (mw_loc == 16'd0) && (w_lane != 3'd7) && (w_entry < depth20) && (mw_mask == 8'hFF);
    reg [383:0] stage;
    wire        im_wr   = mw_valid & ~busy & w_im & w_im_ok;
    genvar      gl;
    generate
        for (gl = 0; gl < 6; gl = gl + 1) begin : g_stage
            always @(posedge clk) if (im_wr && (w_lane == gl)) stage[64*gl +: 64] <= mw_data;
        end
    endgenerate
    wire [427:0] imem_q;
    mn_ram_1r1w #(.W(428), .AW(IMEM_AW), .NWE(1), .OREG(0)) u_imem (
        .clk(clk), .we(im_wr & (w_lane == 3'd6)), .waddr(w_entry[IMEM_AW-1:0]),
        .wdata({mw_data[63:62], mw_data[41:0], stage}),
        .re(s == S_FETCH), .raddr(pc[IMEM_AW-1:0]), .rdata(imem_q));
    wire [1:0]   e_type = imem_q[427:426];
    wire [425:0] jw     = imem_q[425:0];
    wire [81:0]  mword  = imem_q[81:0];
    wire [1:0]   e_ll   = `MN_J_LL(jw);
    wire [7:0]   e_wd   = `MN_J_WD(jw);
    wire         e_mval = `MN_M_VALID(mword);

    // ------------------------------------------------------------------ decoder (the L2BM fields)
    wire [1:0]  ll, bdmode, l2_dmode, bmode;
    wire        gwrite, l2_lwrite, darsend, darwrite, l1_wl, l1_me;
    wire [9:0]  gadr;
    wire [10:0] l2_ladr;
    wire [2:0]  l1adr, immode;
    wire [3:0]  l2_opcode;
    wire [12:0] l1_ladr;
    /* verilator lint_off PINMISSING */
    mn_dec_j u_dec (
        .jw(jw), .ll(ll), .l1bm_bmode(bmode), .l1bm_me(l1_me), .l1bm_ladr(l1_ladr), .l1bm_wl(l1_wl),
        .l1bm_gwrite(gwrite), .l1bm_gadr(gadr), .l2bm_lwrite(l2_lwrite), .l2bm_bdmode(bdmode),
        .l2bm_ladr(l2_ladr), .l2bm_l1adr(l1adr), .l2bm_immode(immode), .l2bm_dmode(l2_dmode),
        .l2bm_opcode(l2_opcode), .l2bm_darsend(darsend), .l2bm_darwrite(darwrite));
    /* verilator lint_on PINMISSING */

    // ------------------------------------------------------------------ L2BM unit
    wire        l2_act, l2_trap, l2_unsup, l2_idle, l2_pre, l2_done;
    wire [6:0]  l2_field;
    reg         l2_start, l2_commit, l2_skip;
    wire        lb_req_valid, lb_req_we, lb_req_ready, lb_req_err, lb_rsp_valid;
    wire [2:0]  lb_req_l1b;
    wire [22:0] lb_req_addr;
    wire [63:0] lb_req_wdata, lb_rsp_rdata;
    wire [7:0]  lb_req_wmask;
    wire        cb_req_valid, cb_req_ready, cb_req_we, cb_req_err, cb_rsp_valid;
    wire [22:0] cb_req_addr;
    wire [63:0] cb_req_wdata, cb_rsp_rdata;
    wire [7:0]  cb_req_wmask;
    wire        dar_re;
    wire [9:0]  dar_raddr;
    wire [31:0] dar_rdata;
    mn_l2bm #(.N_L1B(1), .AW(L2AW), .L1AW(10), .RRN(L2_RRN), .DAR(L2_DAR), .CLEAR(1)) u_l2 (
        .clk(clk), .rst(rst),
        .ll(ll), .l1bm_gwrite(gwrite), .l1bm_gadr(gadr), .l2bm_lwrite(l2_lwrite), .l2bm_bdmode(bdmode),
        .l2bm_ladr(l2_ladr), .l2bm_l1adr(l1adr), .l2bm_immode(immode), .l2bm_dmode(l2_dmode),
        .l2bm_opcode(l2_opcode), .l2bm_darsend(darsend), .l2bm_darwrite(darwrite),
        // no L1BM unit: no PE -> L1BM write competes with the L2BM unit's L1BM writes
        .l1bm_bmode(bmode), .l1bm_lwrite(1'b0), .l1bm_me(l1_me), .l1bm_ladr(l1_ladr), .l1bm_wl(l1_wl),
        .act(l2_act), .chk_trap(l2_trap), .chk_unsup(l2_unsup), .chk_field(l2_field),
        .start(l2_start), .idle(l2_idle), .pre_done(l2_pre), .commit(l2_commit), .done(l2_done), .skip(l2_skip),
        .lb_req_valid(lb_req_valid), .lb_req_ready(lb_req_ready), .lb_req_l1b(lb_req_l1b),
        .lb_req_we(lb_req_we), .lb_req_addr(lb_req_addr), .lb_req_wdata(lb_req_wdata),
        .lb_req_wmask(lb_req_wmask), .lb_req_err(lb_req_err), .lb_rsp_valid(lb_rsp_valid),
        .lb_rsp_rdata(lb_rsp_rdata),
        .b_req_valid(cb_req_valid), .b_req_ready(cb_req_ready), .b_req_we(cb_req_we), .b_req_addr(cb_req_addr),
        .b_req_wdata(cb_req_wdata), .b_req_wmask(cb_req_wmask), .b_req_err(cb_req_err),
        .b_rsp_valid(cb_rsp_valid), .b_rsp_rdata(cb_rsp_rdata),
        .dar_re(dar_re), .dar_raddr(dar_raddr), .dar_rdata(dar_rdata));
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_lb = ^{lb_req_l1b, lb_req_wmask};     // one L1B; the L2BM unit writes whole long words
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------ the L1BM (L1B 0) and the hosts' routing
    wire w_l1 = (mw_space == 8'h06), r_l1 = (mr_space == 8'h06);
    wire w_mv = (mw_space == 8'h07) | (mw_space == 8'h08) | (mw_space == 8'h09);
    wire r_mv = (mr_space == 8'h07) | (mr_space == 8'h08) | (mr_space == 8'h09);
    wire r_im = (mr_space == 8'h00);
    wire l1_hw_ready, l1_hw_err, l1_hr_ready, l1_hr_err, l1_hr_rsp;
    wire [63:0] l1_hr_data;
    mvt_l1mem #(.AW(10)) u_l1 (
        .clk(clk), .rst(rst),
        .lb_req_valid(lb_req_valid), .lb_req_ready(lb_req_ready), .lb_req_we(lb_req_we),
        .lb_req_addr(lb_req_addr), .lb_req_wdata(lb_req_wdata), .lb_req_err(lb_req_err),
        .lb_rsp_valid(lb_rsp_valid), .lb_rsp_rdata(lb_rsp_rdata),
        .hw_valid(mw_valid & ~busy & w_l1), .hw_ready(l1_hw_ready), .hw_err(l1_hw_err), .hw_loc(mw_loc),
        .hw_addr(mw_addr), .hw_data(mw_data), .hw_mask(mw_mask),
        .hr_valid(mr_valid & ~busy & r_l1), .hr_ready(l1_hr_ready), .hr_err(l1_hr_err), .hr_loc(mr_loc),
        .hr_addr(mr_addr), .hr_rsp_valid(l1_hr_rsp), .hr_rsp_data(l1_hr_data));

    // ------------------------------------------------------------------ MV unit
    wire        mv_ready, mv_acc, mv_busy, mv_err;
    wire [1:0]  mv_acc_st, mv_wt_cnt;
    wire [3:0]  mv_acc_field;
    reg         mv_start, wt_take;
    wire        mv_hw_ready, mv_hw_err, mv_hr_ready, mv_hr_err, mv_hr_rsp;
    wire [63:0] mv_hr_data;
    mn_mv #(.L2AW(L2AW), .PDM_AW(PDM_AW), .DRAM_AW(DRAM_AW), .PDM_BASE(PDM_BASE), .DRAM_BASE(DRAM_BASE)) u_mv (
        .clk(clk), .rst(rst),
        .start(mv_start), .mw(mword), .ready(mv_ready), .acc(mv_acc), .acc_st(mv_acc_st),
        .acc_field(mv_acc_field), .busy(mv_busy),
        .wt_tag(e_wd), .wt_cnt(mv_wt_cnt), .wt_take(wt_take),
        .cb_req_valid(cb_req_valid), .cb_req_ready(cb_req_ready), .cb_req_we(cb_req_we),
        .cb_req_addr(cb_req_addr), .cb_req_wdata(cb_req_wdata), .cb_req_wmask(cb_req_wmask),
        .cb_req_err(cb_req_err), .cb_rsp_valid(cb_rsp_valid), .cb_rsp_rdata(cb_rsp_rdata),
        .dar_re(dar_re), .dar_raddr(dar_raddr), .dar_rdata(dar_rdata),
        .sd_req_valid(sd_req_valid), .sd_req_ready(sd_req_ready), .sd_req_we(sd_req_we),
        .sd_req_addr(sd_req_addr), .sd_req_wdata(sd_req_wdata), .sd_req_wmask(sd_req_wmask),
        .sd_rsp_valid(sd_rsp_valid), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(sd_err_addr), .err_sdr(mv_err),
        .hw_valid(mw_valid & ~busy & w_mv), .hw_ready(mv_hw_ready), .hw_err(mv_hw_err), .hw_space(mw_space),
        .hw_loc(mw_loc), .hw_addr(mw_addr), .hw_data(mw_data), .hw_mask(mw_mask),
        .hr_valid(mr_valid & ~busy & r_mv), .hr_ready(mv_hr_ready), .hr_err(mv_hr_err), .hr_space(mr_space),
        .hr_loc(mr_loc), .hr_addr(mr_addr), .hr_rsp_valid(mv_hr_rsp), .hr_rsp_data(mv_hr_data));
    assign mv_busy_o = mv_busy;
    assign mv_err_o  = mv_err;

    // host port responses (only while the core is idle)
    assign mw_ready = ~busy & (w_im ? 1'b1 : w_l1 ? l1_hw_ready : w_mv ? mv_hw_ready : 1'b1);
    assign mw_err   = w_im ? ~w_im_ok : w_l1 ? l1_hw_err : w_mv ? mv_hw_err : 1'b1;
    assign mr_ready = ~busy & (r_l1 ? l1_hr_ready : r_mv ? mv_hr_ready : 1'b1);
    assign mr_err   = r_l1 ? l1_hr_err : r_mv ? mv_hr_err : 1'b1;      // IMEM is not read back
    assign mr_rsp_valid = l1_hr_rsp | mv_hr_rsp;
    assign mr_rsp_data  = l1_hr_rsp ? l1_hr_data : mv_hr_data;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_r = r_im;
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------ sequencer
    wire       pc_ok = ({1'b0, pc} < DEPTH);
    localparam [31:0] I_LL32 = MN_J_LL_IDX, I_WD32 = MN_J_WD_IDX, I_MV32 = 32'h80;
    localparam [15:0] I_LL = I_LL32[15:0], I_WD = I_WD32[15:0], I_MV = I_MV32[15:0];
    wire units_ready = l2_idle & mv_ready;

    always @(posedge clk) begin
        if (rst) begin
            s <= S_IDLE; pc <= 16'd0; left <= 32'd0; steps <= 16'd0; reason <= R_OK; info <= 16'd0;
            run_pend <= 1'b0; l2_start <= 1'b0; l2_commit <= 1'b0; l2_skip <= 1'b0;
            mv_start <= 1'b0; wt_take <= 1'b0;
        end else begin
            l2_start <= 1'b0; l2_commit <= 1'b0; l2_skip <= 1'b0; mv_start <= 1'b0; wt_take <= 1'b0;
            case (s)
                S_IDLE: begin
                    // after a reset the units clear their memories first (the RUN waits)
                    if ((run_start || run_pend) && !units_ready) begin
                        run_pend <= 1'b1;
                    end else if (run_start || run_pend) begin
                        run_pend <= 1'b0;
                        pc <= run_pc; left <= run_count; steps <= 16'd0; reason <= R_OK; info <= 16'd0;
                        if (run_count != 32'd0) s <= S_FETCH;
                    end
                end
                S_FETCH: begin
                    if (pc_ok) s <= S_DEC;
                    else begin reason <= R_DECODE; info <= 16'h200; s <= S_END; end
                end
                S_DEC: begin
                    if (e_type == 2'b01) begin
                        if (e_ll == 2'b10)           begin reason <= R_DECODE; info <= I_LL; s <= S_END; end
                        else if (e_wd != 8'd0)       s <= S_WT;
                        else                         s <= S_JX;
                    end else if (e_type == 2'b10) begin
                        if (e_mval) s <= S_MS;
                        else        next_entry;
                    end else begin
                        reason <= R_DECODE; info <= 16'h100 | {14'd0, e_type}; s <= S_END;
                    end
                end
                S_WT: if (!mv_busy) begin
                    // the wait: after the MVs before it completed (the official completes them at issue)
                    if (mv_wt_cnt == 2'd0)      begin reason <= R_WAIT; info <= {8'd0, e_wd}; s <= S_END; end
                    else if (mv_wt_cnt != 2'd1) begin reason <= R_UNSUP; info <= I_WD; s <= S_END; end
                    else                        begin wt_take <= 1'b1; s <= S_JX; end
                end
                S_JX: begin
                    if (e_ll == 2'b00 || !l2_act) begin
                        l2_skip <= 1'b1;
                        next_entry;
                    end else if (l2_trap) begin
                        reason <= R_RANGE; info <= pc; s <= S_END;
                    end else if (l2_unsup) begin
                        reason <= R_UNSUP; info <= {9'd0, l2_field}; s <= S_END;
                    end else if (!mv_busy && l2_idle) begin
                        l2_start <= 1'b1; s <= S_L2;
                    end
                end
                S_L2:  if (l2_pre) begin l2_commit <= 1'b1; s <= S_L2D; end
                S_L2D: if (l2_done) next_entry;
                S_MS:  if (mv_ready) begin mv_start <= 1'b1; s <= S_MA; end
                S_MA:  if (mv_acc) begin
                    if (mv_acc_st == 2'd0)      next_entry;
                    else if (mv_acc_st == 2'd1) begin reason <= R_RANGE; info <= pc; s <= S_END; end
                    else begin reason <= R_UNSUP; info <= I_MV | {12'd0, mv_acc_field}; s <= S_END; end
                end
                default: if (!mv_busy) s <= S_IDLE;      // S_END: the MV in flight completes
            endcase
        end
    end
    task next_entry;
        begin
            steps <= steps + 16'd1;
            pc    <= pc + 16'd1;
            left  <= left - 32'd1;
            s     <= (left == 32'd1) ? S_END : S_FETCH;
        end
    endtask
endmodule
`default_nettype wire

// mn_mab_mem: the local memories of the NPE PEs of a time-multiplexed MAB (WP30; WP37: on the
// PE-numbered mn_pe_lsu of WP35).
//
// One mn_pe_lsu with NPE = 4 executes the memory side of the step of one PE at a time. The state of
// the NPE PEs:
//   - GRF0, GRF1, LM0, LM1: mn_pe_store with NPE PEs stacked in the BSRAM ({pe, long word}); the
//     store channels of mn_pe_lsu are used as they are, the PE number goes beside them.
//   - T, the mask registers $omr1..15 and $mb / $nb: inside mn_pe_lsu, kept per PE (its NPE
//     parameter; the PE is its subpe input: taken at start for the step, and the PE of the host's
//     T / OMR / BAR accesses between steps).
//   WP30 kept T / $omr / $mb, $nb of the 4 PEs in a context store (BSRAM 2) and loaded / saved them
//   around every step through mn_pe_lsu's host port; with WP35's mn_pe_lsu that is not needed (no
//   BSRAM, 3 to 35 clocks less per PE step).
//
// Step protocol (the caller is mn_pe_core): like mn_pe_mem, but
//   - jw is the word itself: the start-clock form (imr = 0, so that every enabled write is range
//     checked, contract 06 section 3) and the ll = 00 form for nul are made here;
//   - pe and nul (check only: range check, then nothing is written) are taken at start;
//   - start is accepted when idle, in the same clock by mn_pe_lsu; opr_* / res_* as in mn_pe_lsu;
//     done is mn_pe_lsu's (trap / trap_* valid with it). jw and rd_use must stay stable until done.
//
// Host port (between steps; hp_pe = the PE): mn_pe_lsu's host port for every space (1..5 LM0 LM1
//   GRF0 GRF1 T, 0x10 OMR, 0x11 BAR) with its ranges and byte masks; the store and the per-PE
//   registers of mn_pe_lsu are those of PE hp_pe.
// Reset clears the sequencers and the registers of mn_pe_lsu ($mb / $nb); the memories, T and the
// mask registers are RAM and are cleared through the host port (mn_core CLEAR).
//
// VPE = 1 (WP34, the virtual PEs): the GRF0 / GRF1 / LM0 / LM1 of the PEs are in the SDRAM; the store
// is mn_vpe_store (rtl/vpe) on the bus vs_* (contract 06 section 6) instead of mn_pe_store's BSRAM. The
// PE of a request is {vm, the PE in the MAB}: vm is the (virtual) MAB whose 4 PEs this MAB runs now
// (rtl/vpe/mn_vpe.v keeps it stable during a step). LM_AW may then be up to 11 (the chip's 2048 long
// words). VPE = 0: vm and vs_* are not used (vs_req_valid = 0).
`default_nettype none
module mn_mab_mem #(
    parameter LM_AW  = 8,   // LM0/LM1 depth per PE = 2**LM_AW long words
    parameter GRF_AW = 8,   // GRF0/GRF1 depth per PE = 2**GRF_AW long words
    parameter NPE    = 4,   // PEs (4)
    parameter VPE    = 0,   // 1: the memories are in the SDRAM (mn_vpe_store on vs_*)
    /* verilator lint_off UNUSEDPARAM */
    // read only by the VPE = 1 generate block
    parameter [19:0] LM_BASE  = 20'hC0000,   // VPE: SDRAM long word bases (mn_vpe_store)
    parameter [19:0] GRF_BASE = 20'hA0000
    /* verilator lint_on UNUSEDPARAM */
) (
    input  wire         clk,
    input  wire         rst,
    // ---- step
    input  wire [3:0]   vm,          // VPE: the MAB of the PEs (the upper part of the PE number)
    input  wire [1:0]   pe,
    input  wire         start,
    output wire         idle,
    input  wire [425:0] jw,
    input  wire [3:0]   rd_use,
    input  wire         nul,
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
    output wire         done,
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
    output wire [63:0]  hp_rsp_rdata,
    // ---- VPE: the store's bus to the SDRAM
    output wire         vs_req_valid,
    input  wire         vs_req_ready,
    output wire         vs_req_we,
    output wire [22:0]  vs_req_addr,
    output wire [63:0]  vs_req_wdata,
    output wire [7:0]   vs_req_wmask,
    input  wire         vs_rsp_valid,
    input  wire [63:0]  vs_rsp_rdata
);
    // ------------------------------------------------------------------ sequencer
    reg        run_q;      // a step is running
    reg  [1:0] pe_q;       // ... of PE pe_q
    reg        nul_q;      // ... check only
    wire       l_idle;
    wire       go = start & idle;

    // the PE of mn_pe_lsu's per-PE state and of the store: the step's (taken at start; in the start
    // clock pe itself), the host's between steps
    wire [1:0] cur_pe = run_q ? pe_q : (start ? pe : hp_pe);

    // the start-clock form (imr = 0) and the check-only form (ll = 00) of the word
    wire [425:0] jw_chk = {jw[425:424], 5'b00000, jw[418:0]};
    wire [425:0] jw_nul = {2'b00, jw[423:0]};
    wire [425:0] l_jw   = run_q ? (nul_q ? jw_nul : jw) : jw_chk;

    // ------------------------------------------------------------------ mn_pe_lsu + store
    wire [3:0]   st_req_valid, st_req_ready, st_req_we, st_rsp_valid;
    wire [91:0]  st_req_addr;
    wire [255:0] st_req_wdata, st_rsp_rdata;
    wire [31:0]  st_req_wmask;
    wire         l_done;

    mn_pe_lsu #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .RBS(1), .NPE(NPE)) u_lsu (
        .clk(clk), .rst(rst), .subpe(cur_pe),
        .start(go), .idle(l_idle), .jw(l_jw), .rd_use(rd_use), .busy(busy),
        .opr_valid(opr_valid), .opr_cycle(opr_cycle), .opr_mem(opr_mem),
        .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
        .res_valid(res_valid), .res_ready(res_ready), .res_cycle(res_cycle),
        .res_mau(res_mau), .res_alu(res_alu), .res_l1bm(res_l1bm), .res_mread(res_mread),
        .res_alu_flags(res_alu_flags), .res_mau_flags(res_mau_flags),
        .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
        .done(l_done), .trap(trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
        .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(unsup),
        .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we),
        .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr), .hp_req_wdata(hp_req_wdata),
        .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
        .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata),
        .st_req_valid(st_req_valid), .st_req_ready(st_req_ready), .st_req_we(st_req_we),
        .st_req_addr(st_req_addr), .st_req_wdata(st_req_wdata), .st_req_wmask(st_req_wmask),
        .st_rsp_valid(st_rsp_valid), .st_rsp_rdata(st_rsp_rdata)
    );

    generate
        if (VPE != 0) begin : g_vstore
            // the virtual PEs: the memories of PE {vm, cur_pe} in the SDRAM
            mn_vpe_store #(.LM_BASE(LM_BASE), .GRF_BASE(GRF_BASE)) u_store (
                .clk(clk), .rst(rst), .pe({vm, cur_pe}),
                .req_valid(st_req_valid), .req_ready(st_req_ready), .req_we(st_req_we),
                .req_addr(st_req_addr), .req_wdata(st_req_wdata), .req_wmask(st_req_wmask),
                .rsp_valid(st_rsp_valid), .rsp_rdata(st_rsp_rdata),
                .b_req_valid(vs_req_valid), .b_req_ready(vs_req_ready), .b_req_we(vs_req_we),
                .b_req_addr(vs_req_addr), .b_req_wdata(vs_req_wdata), .b_req_wmask(vs_req_wmask),
                .b_rsp_valid(vs_rsp_valid), .b_rsp_rdata(vs_rsp_rdata));
        end else begin : g_store
            // the store registers the PE with each request (mn_pe_store)
            mn_pe_store #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .NPE(NPE)) u_store (
                .clk(clk), .rst(rst), .pe(cur_pe),
                .req_valid(st_req_valid), .req_ready(st_req_ready), .req_we(st_req_we),
                .req_addr(st_req_addr), .req_wdata(st_req_wdata), .req_wmask(st_req_wmask),
                .rsp_valid(st_rsp_valid), .rsp_rdata(st_rsp_rdata)
            );
            assign vs_req_valid = 1'b0;
            assign vs_req_we    = 1'b0;
            assign vs_req_addr  = 23'd0;
            assign vs_req_wdata = 64'd0;
            assign vs_req_wmask = 8'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            // VPE = 0: no SDRAM store, the MAB number is not used
            wire unused_vs = ^{vm, vs_req_ready, vs_rsp_valid, vs_rsp_rdata};
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    assign idle = ~run_q & l_idle;
    assign done = l_done;

    always @(posedge clk) begin
        if (rst) begin
            run_q <= 1'b0;
            pe_q  <= 2'd0;
            nul_q <= 1'b0;
        end else if (go) begin
            run_q <= 1'b1;
            pe_q  <= pe;
            nul_q <= nul;
        end else if (l_done) begin
            run_q <= 1'b0;
        end
    end
endmodule
`default_nettype wire

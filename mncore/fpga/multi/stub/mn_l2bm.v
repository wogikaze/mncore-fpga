// mn_l2bm (stub, WP38): the L2BM unit left out of a bitstream of the set (mn_top_multi UNITS = 1).
//
// Same parameters and ports as mncore/rtl/l2bm/mn_l2bm.v, so that mn_core (M2 = 1) builds with the
// L1BM unit only: mncore/fpga/multi/files_l1.txt lists this file instead of the real unit. A word
// with an L2BM instruction is E_UNSUPPORTED (l2bm_lwrite, like a core without the unit: mn_pe_core
// u_l2) after the range checks of the PEs; nothing runs. There is no L2BM (port B rejects every
// address: the host space 0x07 has depth 0 in INFO) and no DAR (reads 0).
`default_nettype none
module mn_l2bm #(
    /* verilator lint_off UNUSEDPARAM */
    parameter N_L1B = 1,
    parameter AW    = 11,
    parameter L1AW  = 10,
    parameter RRN   = 1,
    parameter DAR   = 1,
    parameter CLEAR = 1,
    parameter REPLICA = 0
    /* verilator lint_on UNUSEDPARAM */
) (
    input  wire         clk,
    input  wire         rst,
    /* verilator lint_off UNUSEDSIGNAL */
    // ll[1] (01 normal and 11 noforward act alike) and the fields of an L2BM instruction: only
    // whether there is one matters here
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
    input  wire [1:0]   l1bm_bmode,
    input  wire         l1bm_lwrite,
    input  wire         l1bm_me,
    input  wire [12:0]  l1bm_ladr,
    input  wire         l1bm_wl,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         act,
    output wire         chk_trap,
    output wire         chk_unsup,
    output wire [6:0]   chk_field,
    input  wire         start,
    output wire         idle,
    output wire         pre_done,
    input  wire         commit,
    output reg          done,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         skip,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         lb_req_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         lb_req_ready,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [2:0]   lb_req_l1b,
    output wire         lb_req_we,
    output wire [22:0]  lb_req_addr,
    output wire [63:0]  lb_req_wdata,
    output wire [7:0]   lb_req_wmask,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         lb_req_err,
    input  wire         lb_rsp_valid,
    input  wire [63:0]  lb_rsp_rdata,
    input  wire         b_req_valid,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         b_req_ready,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         b_req_we,
    input  wire [22:0]  b_req_addr,
    input  wire [63:0]  b_req_wdata,
    input  wire [7:0]   b_req_wmask,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         b_req_err,
    output reg          b_rsp_valid,
    output wire [63:0]  b_rsp_rdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         dar_re,
    input  wire [9:0]   dar_raddr,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [31:0]  dar_rdata
);
`include "mn_jfields.vh"

    // an L2BM instruction (mn_l2bm act): E_UNSUPPORTED, so the core never starts the unit
    assign act       = ll[0] & (l1bm_gwrite | l2bm_lwrite | l2bm_darsend | l2bm_darwrite);
    assign chk_trap  = 1'b0;
    assign chk_unsup = act;
    localparam [31:0] F_LW = MN_J_L2BM_LWRITE_IDX;
    assign chk_field = F_LW[6:0];
    assign idle      = 1'b1;
    // (never used: a step would end at once)
    reg pre;
    always @(posedge clk) begin
        if (rst) begin
            pre  <= 1'b0;
            done <= 1'b0;
        end else begin
            pre  <= start | (pre & ~commit);
            done <= commit;
        end
    end
    assign pre_done     = pre;
    assign lb_req_valid = 1'b0;
    assign lb_req_l1b   = 3'd0;
    assign lb_req_we    = 1'b0;
    assign lb_req_addr  = 23'd0;
    assign lb_req_wdata = 64'd0;
    assign lb_req_wmask = 8'd0;
    assign b_req_ready  = 1'b1;
    assign b_req_err    = 1'b1;          // no L2BM: every address is beyond it
    always @(posedge clk) b_rsp_valid <= 1'b0;
    assign b_rsp_rdata  = 64'd0;
    assign dar_rdata    = 32'd0;
endmodule
`default_nettype wire

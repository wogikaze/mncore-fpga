// mn_mv (stub, WP38): the MV unit left out of a bitstream of the set (mn_top_multi UNITS = 1).
//
// Same parameters and ports as mncore/rtl/mv/mn_mv.v, so that mn_core (M2 = 1) builds with the
// L1BM unit only: mncore/fpga/multi/files_l1.txt lists this file instead of the real unit. A valid m
// word is E_UNSUPPORTED (m field valid: info 0x80); a wait finds no completion (stop reason WAIT),
// so mnrun.py runs the m words and the waits on a member with the MV unit. The host spaces 0x07,
// 0x08 and 0x09 are rejected here (mn_top_multi serves 0x08 / 0x09 itself with UNITS = 1).
`default_nettype none
module mn_mv #(
    /* verilator lint_off UNUSEDPARAM */
    parameter L2AW    = 11,
    parameter PDM_AW  = 17,
    parameter DRAM_AW = 19,
    parameter [19:0] PDM_BASE  = 20'h80000,
    parameter [19:0] DRAM_BASE = 20'h00000
    /* verilator lint_on UNUSEDPARAM */
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [81:0]  mw,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         ready,
    output reg          acc,
    output reg  [1:0]   acc_st,
    output reg  [3:0]   acc_field,
    output wire         busy,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]   wt_tag,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [1:0]   wt_cnt,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         wt_take,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         cb_req_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         cb_req_ready,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         cb_req_we,
    output wire [22:0]  cb_req_addr,
    output wire [63:0]  cb_req_wdata,
    output wire [7:0]   cb_req_wmask,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         cb_req_err,
    input  wire         cb_rsp_valid,
    input  wire [63:0]  cb_rsp_rdata,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         dar_re,
    output wire [9:0]   dar_raddr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0]  dar_rdata,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         sd_req_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         sd_req_ready,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         sd_req_we,
    output wire [22:0]  sd_req_addr,
    output wire [63:0]  sd_req_wdata,
    output wire [7:0]   sd_req_wmask,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         sd_rsp_valid,
    input  wire [63:0]  sd_rsp_rdata,
    input  wire         sd_err_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         err_sdr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire         hw_valid,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         hw_ready,
    output wire         hw_err,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]   hw_space,
    input  wire [15:0]  hw_loc,
    input  wire [22:0]  hw_addr,
    input  wire [63:0]  hw_data,
    input  wire [7:0]   hw_mask,
    input  wire         hr_valid,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         hr_ready,
    output wire         hr_err,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]   hr_space,
    input  wire [15:0]  hr_loc,
    input  wire [22:0]  hr_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    output wire         hr_rsp_valid,
    output wire [63:0]  hr_rsp_data
);
`include "mn_mfields.vh"

    // an m word is checked at once: E_UNSUPPORTED (field valid)
    localparam [31:0] F_VALID = MN_M_VALID_IDX;
    always @(posedge clk) begin
        if (rst) begin
            acc       <= 1'b0;
            acc_st    <= 2'd0;
            acc_field <= 4'd0;
        end else begin
            acc       <= start;
            acc_st    <= 2'd2;
            acc_field <= F_VALID[3:0];
        end
    end
    assign ready        = 1'b1;
    assign busy         = 1'b0;
    assign wt_cnt       = 2'd0;
    assign cb_req_valid = 1'b0;
    assign cb_req_we    = 1'b0;
    assign cb_req_addr  = 23'd0;
    assign cb_req_wdata = 64'd0;
    assign cb_req_wmask = 8'd0;
    assign dar_re       = 1'b0;
    assign dar_raddr    = 10'd0;
    assign sd_req_valid = 1'b0;
    assign sd_req_we    = 1'b0;
    assign sd_req_addr  = 23'd0;
    assign sd_req_wdata = 64'd0;
    assign sd_req_wmask = 8'd0;
    assign err_sdr      = 1'b0;
    assign hw_ready     = 1'b1;
    assign hw_err       = 1'b1;
    assign hr_ready     = 1'b1;
    assign hr_err       = 1'b1;
    assign hr_rsp_valid = 1'b0;
    assign hr_rsp_data  = 64'd0;
endmodule
`default_nettype wire

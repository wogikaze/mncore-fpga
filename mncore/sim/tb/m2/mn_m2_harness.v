// mn_m2_harness: the lint / synth top of the unit m2 (WP37): mn_core in the M2 configuration of
// the board (N_PE = 4, LM_AW = 8, M2 = 1: the L1BM, L2BM and MV units; FPALU = 0, MAU = 1, BFN = 0)
// with its ports passed through. mncore/sim/tb/m2/lint_cfg.py lints the other configurations.
`default_nettype none
module mn_m2_harness #(
    parameter FPALU   = 0,
    parameter MAU     = 1,
    parameter BFN     = 0,
    parameter MAT     = 0,
    parameter REPLICA = 0,
    parameter SDCLR   = 1
) (
    input  wire         clk,
    input  wire         rst,
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
    input  wire         run_start,
    input  wire [15:0]  run_pc,
    input  wire [31:0]  run_count,
    output wire         core_busy,
    output wire [7:0]   core_reason,
    output wire [31:0]  core_info,
    output wire [15:0]  core_pc,
    output wire [31:0]  core_steps,
    output wire [16:0]  core_trap,
    output wire         sd_req_valid,
    input  wire         sd_req_ready,
    output wire         sd_req_we,
    output wire [22:0]  sd_req_addr,
    output wire [63:0]  sd_req_wdata,
    output wire [7:0]   sd_req_wmask,
    input  wire         sd_rsp_valid,
    input  wire [63:0]  sd_rsp_rdata,
    input  wire         sd_err_addr,
    output wire         unit_busy,
    output wire         unit_err
);
    mn_core #(.IMEM_AW(9), .IMEM_RD(0), .LM_AW(8), .GRF_AW(8), .CLEAR(1), .FPALU(FPALU), .MAU(MAU),
              .N_PE(4), .BFN(BFN), .MAT(MAT), .M2(1), .REPLICA(REPLICA), .SDCLR(SDCLR)) u_core (
        .clk(clk), .rst(rst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space),
        .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space),
        .mr_loc(mr_loc), .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps), .core_trap(core_trap),
        .sd_req_valid(sd_req_valid), .sd_req_ready(sd_req_ready), .sd_req_we(sd_req_we),
        .sd_req_addr(sd_req_addr), .sd_req_wdata(sd_req_wdata), .sd_req_wmask(sd_req_wmask),
        .sd_rsp_valid(sd_rsp_valid), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(sd_err_addr),
        .unit_busy(unit_busy), .unit_err(unit_err));
endmodule
`default_nettype wire

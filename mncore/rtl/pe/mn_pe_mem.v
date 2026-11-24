// mn_pe_mem: one PE's local memories (GRF0, GRF1, LM0, LM1, T, $omr, $mb/$nb) in BSRAM (WP14).
//
// mn_pe_lsu (sequencer, address generation, write path, T, mask and base registers)
// + mn_pe_store (BSRAM). See mn_pe_lsu.v for the step protocol and the host port.
// For a virtual PE (WP34) instantiate mn_pe_lsu with another store on the same channels.
//
// BSRAM: 8 blocks for LM_AW <= 9 and GRF_AW <= 8 (64 bits wide, 32-bit lanes; WP07 budget).
module mn_pe_mem #(
    parameter LM_AW  = 9,  // LM0/LM1 depth = 2**LM_AW long words (contract LM_DEPTH; chip 11)
    parameter GRF_AW = 8,  // GRF0/GRF1 depth = 2**GRF_AW long words (chip 8)
    parameter RBS    = 0   // 1: shared read buffer, opr_* give memory opr_mem (mn_pe_lsu, WP21)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [1:0]   subpe,
    input  wire         start,
    output wire         idle,
    input  wire [425:0] jw,
    input  wire [3:0]   rd_use,
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
    input  wire         hp_req_valid,
    output wire         hp_req_ready,
    input  wire         hp_req_we,
    input  wire [7:0]   hp_req_space,
    input  wire [22:0]  hp_req_addr,
    input  wire [63:0]  hp_req_wdata,
    input  wire [7:0]   hp_req_wmask,
    output wire         hp_req_err,
    output wire         hp_rsp_valid,
    output wire [63:0]  hp_rsp_rdata
);
    wire [3:0]   st_req_valid, st_req_ready, st_req_we, st_rsp_valid;
    wire [91:0]  st_req_addr;
    wire [255:0] st_req_wdata, st_rsp_rdata;
    wire [31:0]  st_req_wmask;

    mn_pe_lsu #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .RBS(RBS)) u_lsu (
        .clk(clk), .rst(rst), .subpe(subpe),
        .start(start), .idle(idle), .jw(jw), .rd_use(rd_use), .busy(busy),
        .opr_valid(opr_valid), .opr_cycle(opr_cycle), .opr_mem(opr_mem),
        .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
        .res_valid(res_valid), .res_ready(res_ready), .res_cycle(res_cycle),
        .res_mau(res_mau), .res_alu(res_alu), .res_l1bm(res_l1bm), .res_mread(res_mread),
        .res_alu_flags(res_alu_flags), .res_mau_flags(res_mau_flags),
        .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
        .done(done), .trap(trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
        .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(unsup),
        .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we),
        .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr), .hp_req_wdata(hp_req_wdata),
        .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
        .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata),
        .st_req_valid(st_req_valid), .st_req_ready(st_req_ready), .st_req_we(st_req_we),
        .st_req_addr(st_req_addr), .st_req_wdata(st_req_wdata), .st_req_wmask(st_req_wmask),
        .st_rsp_valid(st_rsp_valid), .st_rsp_rdata(st_rsp_rdata)
    );

    mn_pe_store #(.LM_AW(LM_AW), .GRF_AW(GRF_AW)) u_store (
        .clk(clk), .rst(rst),
        .req_valid(st_req_valid), .req_ready(st_req_ready), .req_we(st_req_we),
        .req_addr(st_req_addr), .req_wdata(st_req_wdata), .req_wmask(st_req_wmask),
        .rsp_valid(st_rsp_valid), .rsp_rdata(st_rsp_rdata)
    );
endmodule

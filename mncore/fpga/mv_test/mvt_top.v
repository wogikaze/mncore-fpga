// mvt_top: the MV test design for the Tang Nano 20K (WP33).
//
// brd_host_if (UART host protocol, rtl/board/PROTOCOL.md) + mvt_core (instruction memory,
// sequencer, mn_mv, mn_l2bm, the L1BM of L1B 0) + sdr_bus64 on the embedded SDRAM (the PDM and the
// DRAM of group 0). The core runs on the 27 MHz board clock; the SDRAM controller on the rPLL's
// 99 MHz (CL2, PSDA 8, cfg_rdx 1: WP05's recommended setting) with sdr_bus64 ASYNC = 1.
// The core is reset by the system reset and by the RESET command (core_rst); the SDRAM controller
// only by the system reset (the SDRAM keeps its contents across RESET).
//
// INFO: design ID 0x33 (this test design), topology 1/1/1/0/0 (one group, L2B, L1B; no MAB / PE),
// space depths 0x00 IMEM 8 * 2**IMEM_AW, 0x06 L1BM 1024, 0x07 L2BM 2**L2AW, 0x08 PDM 2**PDM_AW,
// 0x09 DRAM 2**DRAM_AW (long words). The test programs are run by mncore/fpga/mv_test/hwrun.py.
//
// LEDs (active low): 0 heartbeat, 1 UART RX activity, 2 UART TX activity, 3 link error, 4 core
// running, 5 SDRAM address error (sdr_bus64 err_addr; never expected).
// Button S1 (pin 88) resets the whole design, including the baud rate.
`default_nettype none
module mvt_top #(
    parameter CLK_HZ        = 27000000,
    parameter BAUD          = 1000000,
    parameter TIMEOUT_CYC   = CLK_HZ / 50,
    parameter PROBATION_CYC = CLK_HZ,
    parameter IMEM_AW       = 9,
    parameter L2AW          = 11,
    parameter PDM_AW        = 17,
    parameter DRAM_AW       = 19,
    parameter [19:0] PDM_BASE  = 20'h80000,
    parameter [19:0] DRAM_BASE = 20'h00000,
    parameter integer SDR_HZ    = 99000000,
    parameter integer IDIV_SEL  = 2,
    parameter integer FBDIV_SEL = 10,
    parameter integer ODIV_SEL  = 8,
    parameter integer PSDA      = 8,
    parameter integer CL        = 2,
    parameter integer RDX       = 1,
    parameter LED_STRETCH   = 22
) (
    input  wire        clk,
    input  wire        btn_rst,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire [5:0]  led,
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    localparam [15:0]  IMEM_DEPTH = 16'd1 << IMEM_AW;
    localparam [31:0]  D_IMEM = 32'd8 << IMEM_AW;
    localparam [31:0]  D_L1 = 32'd1024;
    localparam [31:0]  D_L2 = 32'd1 << L2AW;
    localparam [31:0]  D_P  = 32'd1 << PDM_AW;
    localparam [31:0]  D_D  = 32'd1 << DRAM_AW;
    localparam [511:0] SPACE_DEPTH = {192'd0, D_D, D_P, D_L2, D_L1, 160'd0, D_IMEM};

    // ---------------------------------------------------------------- clocks and reset
    wire sclk, pclk, lock;
    sdr_gw_pll #(.IDIV_SEL(IDIV_SEL), .FBDIV_SEL(FBDIV_SEL), .ODIV_SEL(ODIV_SEL), .DYN_PHASE(0), .PSDA(PSDA)) u_pll (
        .clkin(clk), .psda(4'd0), .clkout(sclk), .clkoutp(pclk), .lock(lock));
    sdr_gw_clkout u_ck (.clk(pclk), .q(O_sdram_clk));

    // Power-on reset from the FPGA configuration init values; held until the PLL locks
    /* verilator lint_off PROCASSINIT */
    reg [5:0] por_cnt = 6'd0;
    reg [1:0] btn_sync = 2'b00;
    reg [1:0] lock_sync = 2'b00;
    reg       rst = 1'b1;
    reg [2:0] srst_sync = 3'b111;
    /* verilator lint_on PROCASSINIT */
    always @(posedge clk) begin
        btn_sync  <= {btn_sync[0], btn_rst};
        lock_sync <= {lock_sync[0], lock};
        if (btn_sync[1] || !lock_sync[1]) por_cnt <= 6'd0;
        else if (por_cnt != 6'h3f) por_cnt <= por_cnt + 1'b1;
        rst <= (por_cnt != 6'h3f);
    end
    // the controller's reset: the system reset seen in the SDRAM clock (asserted with rst)
    always @(posedge sclk) srst_sync <= {srst_sync[1:0], rst};
    wire srst = srst_sync[2] | rst;

    // ---------------------------------------------------------------- host interface
    wire        mw_valid, mw_ready, mw_err;
    wire [7:0]  mw_space, mw_mask;
    wire [15:0] mw_loc;
    wire [22:0] mw_addr;
    wire [63:0] mw_data;
    wire        mr_valid, mr_ready, mr_err;
    wire [7:0]  mr_space;
    wire [15:0] mr_loc;
    wire [22:0] mr_addr;
    wire        mr_rsp_valid;
    wire [63:0] mr_rsp_data;
    wire        run_start;
    wire [15:0] run_pc;
    wire [31:0] run_count;
    wire        core_rst;
    wire        core_busy;
    wire [7:0]  core_reason;
    wire [31:0] core_info;
    wire [15:0] core_pc;
    wire [31:0] core_steps;
    wire        dbg_rx_byte, dbg_tx_byte, dbg_err, dbg_probation;
    brd_host_if #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_CYC(TIMEOUT_CYC), .PROBATION_CYC(PROBATION_CYC),
        .DESIGN_ID(8'h33), .INFO_FLAGS(8'h01), .IMEM_DEPTH(IMEM_DEPTH),
        .TOPO(40'h00_00_01_01_01),       // byte0 n .. byte4 p: 1 group, 1 L2B, 1 L1B, no MAB / PE
        .SPACE_DEPTH(SPACE_DEPTH)
    ) u_host (
        .clk(clk), .rst(rst),
        .uart_rxd(uart_rx), .uart_txd(uart_tx),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err),
        .mw_space(mw_space), .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err),
        .mr_space(mr_space), .mr_loc(mr_loc), .mr_addr(mr_addr),
        .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count), .core_rst(core_rst),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps),
        .dbg_rx_byte(dbg_rx_byte), .dbg_tx_byte(dbg_tx_byte), .dbg_err(dbg_err),
        .dbg_probation(dbg_probation));

    // ---------------------------------------------------------------- SDRAM
    wire        sd_req_valid, sd_req_ready, sd_req_we, sd_rsp_valid, init_done, err_addr;
    wire [22:0] sd_req_addr;
    wire [63:0] sd_req_wdata, sd_rsp_rdata;
    wire [7:0]  sd_req_wmask;
    wire [31:0] dq_o, dq_oe;
    sdr_bus64 #(.ASYNC(1), .FREQ_HZ(SDR_HZ), .CL(CL)) u_sdr (
        .clk(clk), .rst(rst), .sclk(sclk), .srst(srst), .cfg_rdx(RDX[1:0]),
        .init_done(init_done), .err_addr(err_addr),
        .req_valid(sd_req_valid), .req_ready(sd_req_ready), .req_we(sd_req_we), .req_addr(sd_req_addr),
        .req_wdata(sd_req_wdata), .req_wmask(sd_req_wmask), .rsp_valid(sd_rsp_valid), .rsp_rdata(sd_rsp_rdata),
        .sdr_cke(O_sdram_cke), .sdr_cs_n(O_sdram_cs_n), .sdr_ras_n(O_sdram_ras_n), .sdr_cas_n(O_sdram_cas_n),
        .sdr_we_n(O_sdram_wen_n), .sdr_ba(O_sdram_ba), .sdr_a(O_sdram_addr), .sdr_dqm(O_sdram_dqm),
        .sdr_dq_o(dq_o), .sdr_dq_oe(dq_oe), .sdr_dq_i(IO_sdram_dq));
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : g_dq
            assign IO_sdram_dq[g] = dq_oe[g] ? dq_o[g] : 1'bz;
        end
    endgenerate

    // ---------------------------------------------------------------- core
    wire mv_busy, mv_err;
    mvt_core #(.IMEM_AW(IMEM_AW), .L2AW(L2AW), .PDM_AW(PDM_AW), .DRAM_AW(DRAM_AW), .PDM_BASE(PDM_BASE),
               .DRAM_BASE(DRAM_BASE)) u_core (
        .clk(clk), .rst(rst | core_rst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space), .mw_loc(mw_loc),
        .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space), .mr_loc(mr_loc),
        .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info), .core_pc(core_pc),
        .core_steps(core_steps),
        .sd_req_valid(sd_req_valid), .sd_req_ready(sd_req_ready), .sd_req_we(sd_req_we),
        .sd_req_addr(sd_req_addr), .sd_req_wdata(sd_req_wdata), .sd_req_wmask(sd_req_wmask),
        .sd_rsp_valid(sd_rsp_valid), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(err_addr),
        .mv_busy_o(mv_busy), .mv_err_o(mv_err));

    // ---------------------------------------------------------------- LEDs
    localparam [LED_STRETCH-1:0] S_ZERO = {LED_STRETCH{1'b0}};
    localparam [LED_STRETCH-1:0] S_FULL = {LED_STRETCH{1'b1}};
    reg [24:0] hb;
    reg [LED_STRETCH-1:0] s_rx, s_tx, s_err, s_run;
    always @(posedge clk) begin
        if (rst) begin
            hb <= 25'd0; s_rx <= S_ZERO; s_tx <= S_ZERO; s_err <= S_ZERO; s_run <= S_ZERO;
        end else begin
            hb <= hb + 1'b1;
            s_rx  <= dbg_rx_byte ? S_FULL : (s_rx != S_ZERO) ? s_rx - 1'b1 : S_ZERO;
            s_tx  <= dbg_tx_byte ? S_FULL : (s_tx != S_ZERO) ? s_tx - 1'b1 : S_ZERO;
            s_err <= dbg_err     ? S_FULL : (s_err != S_ZERO) ? s_err - 1'b1 : S_ZERO;
            s_run <= (core_busy | mv_busy) ? S_FULL : (s_run != S_ZERO) ? s_run - 1'b1 : S_ZERO;
        end
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_top = dbg_probation | init_done;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [5:0] on = {mv_err, s_run != S_ZERO, s_err != S_ZERO, s_tx != S_ZERO, s_rx != S_ZERO, hb[24]};
    assign led = ~on;
endmodule
`default_nettype wire

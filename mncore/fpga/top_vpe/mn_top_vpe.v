// mn_top_vpe: the virtual PEs on the Tang Nano 20K (WP34): N_MAB MABs of 4 PEs (16 = the 64 PEs of one
// L1B) on the one time-multiplexed MAB datapath, with the state of every PE (LM0 / LM1 up to the chip's
// 2048 long words, GRF0 / GRF1, T, OMR, BAR, $aluf, $mauf) in the embedded SDRAM (rtl/vpe).
//
// brd_host_if (UART host protocol, rtl/board/PROTOCOL.md) + mn_core (N_PE = 4, VPE = 1: instruction memory,
// sequencer, mn_vpe (mn_mab and the context / host engines), and with M2 = 1 the L1BM of the N_MAB MABs,
// the L2BM and the MV unit) + sdr_bus64 on the embedded SDRAM. The core runs on the 27 MHz board clock; the
// SDRAM controller on the rPLL's 54 MHz (CL2, PSDA 11, cfg_rdx 1: WP05's 54 MHz setting, as mn_top_m2) with
// sdr_bus64 ASYNC = 1. The core is reset by the system reset and by the RESET command (core_rst): with
// SDCLR = 1 it then writes 0 to the DRAM / PDM (M2) and to the VPE region of the SDRAM (the PE state: the
// official initial state), and the units clear their memories.
//
// INFO (PROTOCOL.md section 3): design ID 0x05 (proposed: mn_top_vpe); flags as mn_top_m2 (bit0 a real
// core, bits 3..2 FPALU, bit 4 MAU, bit 5 BFN, bit 6 MAT (0 here), bit 7 REPLICA); topology 1/1/1/N_MAB/4;
// the depths of the spaces 0x00 IMEM, 0x01 LM0 / 0x02 LM1 2**LM_AW, 0x03 GRF0 / 0x04 GRF1 2**GRF_AW, 0x05
// T 8, and with M2 = 1 0x06 L1BM, 0x07 L2BM, 0x08 PDM, 0x09 DRAM. OMR (0x10), BAR (0x11) and the forwarding
// registers 0x12 $aluf / 0x13 $mauf (8 long words, 2c + k) are served at every PE location.
//
// Function-specific bitstreams (mncore/wp/WP-3x.md): FPALU / MAU / BFN select the arithmetic units, M2 the
// L1BM / L2BM / MV units (L2MV = 0: the L1BM only; the depths of the spaces 7..9 are then 0), N_MAB and LM_AW
// the virtual PEs.
//
// LED: only LED 0, steadily on at the lowest brightness (contract 06 section 7). Button S1 (pin 88) resets
// the whole design, including the baud rate.
`default_nettype none
module mn_top_vpe #(
    parameter CLK_HZ        = 27000000,
    parameter BAUD          = 1000000,
    parameter TIMEOUT_CYC   = CLK_HZ / 50,
    parameter PROBATION_CYC = CLK_HZ,
    parameter IMEM_AW       = 9,
    parameter N_MAB         = 16,
    parameter LM_AW         = 11,
    parameter GRF_AW        = 8,
    parameter FPALU         = 0,
    parameter MAU           = 0,
    parameter BFN           = 0,
    parameter M2            = 0,          // 1: the L1BM (N_MAB MABs), L2BM and MV units
    parameter L2MV          = 1,          // M2: 0 the L1BM unit only (no L2BM / MV)
    parameter REPLICA       = 0,
    parameter L1_RRN        = 2,
    parameter L2_RRN        = 2,
    parameter L2_DAR        = 0,
    parameter L1_AW         = 10,
    parameter L2_AW         = 11,
    parameter PDM_AW        = 17,
    parameter DRAM_AW       = 19,
    parameter [19:0] PDM_BASE  = 20'h80000,
    parameter [19:0] DRAM_BASE = 20'h00000,
    parameter SDCLR         = 1,
    parameter integer SDR_HZ    = 54000000,   // SDRAM clock: 27 MHz * (FBDIV_SEL + 1) / (IDIV_SEL + 1)
    parameter integer IDIV_SEL  = 0,
    parameter integer FBDIV_SEL = 1,
    parameter integer ODIV_SEL  = 16,
    parameter integer PSDA      = 11,         // the PLL phase of the SDRAM clock (rtl/sdram/README.md)
    parameter integer CL        = 2,
    parameter integer RDX       = 1,
    parameter LED_DIM_BITS  = 10            // LED 0 duty = 1 / 2**LED_DIM_BITS
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
    localparam [31:0]  D_LM   = 32'd1 << LM_AW;
    localparam [31:0]  D_GRF  = 32'd1 << GRF_AW;
    localparam [31:0]  D_T    = 32'd8;
    localparam [31:0]  D_L1   = (M2 != 0) ? (32'd1 << L1_AW) : 32'd0;
    localparam [31:0]  D_L2   = (M2 != 0 && L2MV != 0) ? (32'd1 << L2_AW) : 32'd0;
    localparam [31:0]  D_P    = (M2 != 0 && L2MV != 0) ? (32'd1 << PDM_AW) : 32'd0;
    localparam [31:0]  D_D    = (M2 != 0 && L2MV != 0) ? (32'd1 << DRAM_AW) : 32'd0;
    localparam [511:0] SPACE_DEPTH = {192'd0, D_D, D_P, D_L2, D_L1, D_T, D_GRF, D_GRF, D_LM, D_LM, D_IMEM};
    // INFO flags: bit0 a real core; bits 3..2 FPALU, bit 4 MAU, bit 5 BFN, bit 6 MAT, bit 7 REPLICA
    localparam [31:0]  FLAGS32 = 32'h01 + ((FPALU % 4) * 4) + ((MAU != 0) ? 16 : 0) + ((BFN != 0) ? 32 : 0) +
                                 ((REPLICA != 0) ? 128 : 0);
    localparam [7:0]   INFO_FL = FLAGS32[7:0];
    localparam [31:0]  NM32 = N_MAB;
    localparam [39:0]  TOPO = {8'h04, NM32[7:0], 8'h01, 8'h01, 8'h01};   // byte0 n .. byte4 p

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
        .DESIGN_ID(8'h05), .INFO_FLAGS(INFO_FL), .IMEM_DEPTH(IMEM_DEPTH),
        .TOPO(TOPO), .SPACE_DEPTH(SPACE_DEPTH)
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
    /* verilator lint_off UNUSEDSIGNAL */
    wire [16:0] core_trap;   // E_RANGE detail: not reported by protocol version 1
    /* verilator lint_on UNUSEDSIGNAL */
    wire        unit_busy, unit_err;
    mn_core #(
        .IMEM_AW(IMEM_AW), .IMEM_RD(0), .LM_AW(LM_AW), .GRF_AW(GRF_AW), .CLEAR(1),
        .FPALU(FPALU), .MAU(MAU), .N_PE(4), .BFN(BFN), .MAT(0), .M2(M2),
        .L1_RRN(L1_RRN), .L2_RRN(L2_RRN), .L2_DAR(L2_DAR), .REPLICA(REPLICA), .L1_AW(L1_AW), .L2_AW(L2_AW),
        .PDM_AW(PDM_AW), .DRAM_AW(DRAM_AW), .PDM_BASE(PDM_BASE), .DRAM_BASE(DRAM_BASE), .SDCLR(SDCLR),
        .VPE(1), .N_MAB(N_MAB), .L2MV(L2MV), .PE_LOC(16'h0000)
    ) u_core (
        .clk(clk), .rst(rst | core_rst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space),
        .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space),
        .mr_loc(mr_loc), .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps), .core_trap(core_trap),
        .sd_req_valid(sd_req_valid), .sd_req_ready(sd_req_ready), .sd_req_we(sd_req_we),
        .sd_req_addr(sd_req_addr), .sd_req_wdata(sd_req_wdata), .sd_req_wmask(sd_req_wmask),
        .sd_rsp_valid(sd_rsp_valid), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(err_addr),
        .unit_busy(unit_busy), .unit_err(unit_err));

    // ---------------------------------------------------------------- LED
    // Only LED 0 is lit, steadily, at the lowest brightness (duty 1 / 2**LED_DIM_BITS): it just shows
    // that the design is loaded and running. The other LEDs stay off (contract 06 section 7, the
    // user's request of 2026-11-25; the same LED section as mn_top_1pe / mn_top_mab / mn_top_m2).
    /* verilator lint_off UNUSEDSIGNAL */
    wire led_unused = dbg_rx_byte ^ dbg_tx_byte ^ dbg_err ^ dbg_probation ^ init_done ^ unit_busy ^ unit_err;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [LED_DIM_BITS-1:0] dim;
    always @(posedge clk) begin
        if (rst) dim <= {LED_DIM_BITS{1'b0}};
        else     dim <= dim + 1'b1;
    end
    assign led = {5'b11111, ~(dim == {LED_DIM_BITS{1'b0}})};
endmodule
`default_nettype wire

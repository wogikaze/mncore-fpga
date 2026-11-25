// mn_top_mab: one MAB of 4 PEs (time-multiplexed) on the Tang Nano 20K (WP30).
//
// brd_host_if (UART host protocol, rtl/board/PROTOCOL.md) + mn_core with N_PE = 4 (instruction
// memory, sequencer, mn_mab: one PE datapath executing PEs n0c0b0m0p0..p3 in turn; WP30). The
// same board wiring as mn_top_1pe (WP21): the two are connected port to port, the core is reset
// by the system reset and by the RESET command (core_rst), after which it clears the state of
// the 4 PEs (mn_core CLEAR = 1). Single clock (the 27 MHz board oscillator by default).
//
// INFO (PROTOCOL.md section 3): design ID 0x03, flags bit0 (a real core is attached), the
// instruction memory depth, topology 1/1/1/1/4 (n/c/b/m/p) and the depth of the spaces the core
// serves at each of the 4 locations: 0x00 IMEM 8 * 2**IMEM_AW long words (entry * 8 + lane),
// 0x01 LM0 / 0x02 LM1 2**LM_AW, 0x03 GRF0 / 0x04 GRF1 2**GRF_AW, 0x05 T 8. The design-specific
// spaces 0x10 OMR (16 entries, entry 0 read-only) and 0x11 BAR (2) are served too.
//
// Function-specific bitstreams (mncore/wp/WP-3x.md): FPALU / MAU / BFN select the arithmetic
// units (mn_core): FPALU = 1 the full FP ALU, 2 without floor / ftoi, 3 also without fmax / fmin,
// 0 none; MAU = 0 leaves out the MAU vector unit; BFN = 0 leaves out bfn / bfe. Instructions of a
// unit that is left out stop with E_UNSUPPORTED. msl / msr are always there. INFO reports the
// units in its flags byte (offset 19; bits 0..1 as PROTOCOL.md version 1): bits 3..2 FPALU,
// bit 4 MAU, bit 5 BFN (WP30; proposed for PROTOCOL.md, design ID 0x03), bit 6 MAT (WP36: the
// matrix register with ?mwrite / ?mread / the matrix MAU in f / g / h; proposed as well).
//
// LED: only LED 0, steadily on at the lowest brightness (connection / alive check).
// Button S1 (pin 88) resets the whole design, including the baud rate.
`default_nettype none
module mn_top_mab #(
    parameter CLK_HZ        = 27000000,
    parameter BAUD          = 1000000,
    parameter TIMEOUT_CYC   = CLK_HZ / 50,
    parameter PROBATION_CYC = CLK_HZ,
    parameter IMEM_AW       = 9,
    parameter LM_AW         = 8,
    parameter GRF_AW        = 8,
    parameter FPALU         = 0,
    parameter MAU           = 1,
    parameter BFN           = 0,
    parameter MAT           = 0,            // the matrix register and matrix MAU (WP36)
    /* verilator lint_off UNUSEDPARAM */
    parameter LED_STRETCH   = 22,           // unused (kept for existing testbenches)
    /* verilator lint_on UNUSEDPARAM */
    parameter LED_DIM_BITS  = 10            // LED 0 duty = 1 / 2**LED_DIM_BITS
) (
    input  wire       clk,
    input  wire       btn_rst,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);
    localparam [15:0] IMEM_DEPTH = 16'd1 << IMEM_AW;
    localparam [31:0] D_IMEM = 32'd8 << IMEM_AW;
    localparam [31:0] D_LM   = 32'd1 << LM_AW;
    localparam [31:0] D_GRF  = 32'd1 << GRF_AW;
    localparam [31:0] D_T    = 32'd8;
    localparam [511:0] SPACE_DEPTH = {320'd0, D_T, D_GRF, D_GRF, D_LM, D_LM, D_IMEM};
    // INFO flags: bit0 a real core; bits 3..2 FPALU, bit 4 MAU, bit 5 BFN, bit 6 MAT (the units of
    // this bitstream)
    localparam [31:0]  FLAGS32 = 32'h01 + ((FPALU % 4) * 4) + ((MAU != 0) ? 16 : 0) + ((BFN != 0) ? 32 : 0) +
                                 ((MAT != 0) ? 64 : 0);
    localparam [7:0]   INFO_FL = FLAGS32[7:0];

    // ---------------------------------------------------------------- reset
    // Power-on reset uses FPGA configuration init values: the reset generator itself has no reset.
    /* verilator lint_off PROCASSINIT */
    reg [5:0] por_cnt = 6'd0;
    reg [1:0] btn_sync = 2'b00;
    reg       rst = 1'b1;
    /* verilator lint_on PROCASSINIT */
    always @(posedge clk) begin
        btn_sync <= {btn_sync[0], btn_rst};
        if (btn_sync[1]) por_cnt <= 6'd0;
        else if (por_cnt != 6'h3f) por_cnt <= por_cnt + 1'b1;
        rst <= (por_cnt != 6'h3f);
    end

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
        .CLK_HZ        (CLK_HZ),
        .BAUD          (BAUD),
        .TIMEOUT_CYC   (TIMEOUT_CYC),
        .PROBATION_CYC (PROBATION_CYC),
        .DESIGN_ID     (8'h03),
        .INFO_FLAGS    (INFO_FL),
        .IMEM_DEPTH    (IMEM_DEPTH),
        .TOPO          (40'h04_01_01_01_01),   // byte0 n .. byte4 p: 1 group, 1 L2B, 1 L1B, 1 MAB, 4 PEs
        .SPACE_DEPTH   (SPACE_DEPTH)
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
        .dbg_probation(dbg_probation)
    );

    // ---------------------------------------------------------------- core
    /* verilator lint_off UNUSEDSIGNAL */
    wire [16:0] core_trap;   // E_RANGE detail: not reported by protocol version 1
    // no L1BM / L2BM / MV units (mn_core M2 = 0): the SDRAM bus and the indicators are unused
    wire        u_sd_valid, u_sd_we, u_busy, u_err;
    wire [22:0] u_sd_addr;
    wire [63:0] u_sd_wdata;
    wire [7:0]  u_sd_wmask;
    /* verilator lint_on UNUSEDSIGNAL */
    mn_core #(
        .IMEM_AW(IMEM_AW), .IMEM_RD(0), .LM_AW(LM_AW), .GRF_AW(GRF_AW), .CLEAR(1),
        .FPALU(FPALU), .MAU(MAU), .N_PE(4), .BFN(BFN), .MAT(MAT), .PE_LOC(16'h0000)
    ) u_core (
        .clk(clk), .rst(rst | core_rst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space),
        .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space),
        .mr_loc(mr_loc), .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps), .core_trap(core_trap),
        .sd_req_valid(u_sd_valid), .sd_req_ready(1'b0), .sd_req_we(u_sd_we), .sd_req_addr(u_sd_addr),
        .sd_req_wdata(u_sd_wdata), .sd_req_wmask(u_sd_wmask), .sd_rsp_valid(1'b0), .sd_rsp_rdata(64'd0),
        .sd_err_addr(1'b0), .unit_busy(u_busy), .unit_err(u_err)
    );

    // ---------------------------------------------------------------- LED
    // Only LED 0 is lit, steadily, at the lowest brightness (duty 1 / 2**LED_DIM_BITS): it just shows
    // that the design is loaded and running. The other LEDs stay off (lead decision 2026-11-25).
    /* verilator lint_off UNUSEDSIGNAL */
    wire led_unused = dbg_rx_byte ^ dbg_tx_byte ^ dbg_err ^ dbg_probation;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [LED_DIM_BITS-1:0] dim;
    always @(posedge clk) begin
        if (rst) dim <= {LED_DIM_BITS{1'b0}};
        else     dim <= dim + 1'b1;
    end
    assign led = {5'b11111, ~(dim == {LED_DIM_BITS{1'b0}})};
endmodule
`default_nettype wire

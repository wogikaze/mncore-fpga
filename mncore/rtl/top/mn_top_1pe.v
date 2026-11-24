// mn_top_1pe: the 1-PE MN-Core on the Tang Nano 20K (WP21, milestone M1).
//
// brd_host_if (UART host protocol, rtl/board/PROTOCOL.md) + mn_core (instruction memory,
// sequencer, one PE at n0c0b0m0p0; WP20). The two are connected port to port; the core is
// reset by the system reset and by the RESET command (core_rst), after which it clears the PE
// state (mn_core CLEAR = 1). Single clock (the 27 MHz board oscillator by default).
//
// INFO (PROTOCOL.md section 3): design ID 0x02, flags bit0 (a real core is attached), the
// instruction memory depth, topology 1/1/1/1/1 and the depth of the spaces the core serves:
//   0x00 IMEM 8 * 2**IMEM_AW long words (entry * 8 + lane), 0x01 LM0 / 0x02 LM1 2**LM_AW,
//   0x03 GRF0 / 0x04 GRF1 2**GRF_AW, 0x05 T 8. The design-specific spaces 0x10 OMR (16 entries,
//   entry 0 read-only) and 0x11 BAR (2) are served too; INFO only lists spaces 0..15.
//
// FPALU / MAU select the arithmetic units of the PE (mn_core): FPALU = 2 is the light FP ALU
// (relu, relu1..3, lrelud, lreluo, ilrelud only; WP21 area option), 1 the full one, 0 none.
// Instructions of a unit that is left out stop with E_UNSUPPORTED.
//
// LEDs (active low): 0 heartbeat, 1 UART RX activity, 2 UART TX activity, 3 link error
// (CRC / framing / overrun / timeout), 4 core running, 5 the last RUN stopped with an error
// (E_RANGE / E_UNSUPPORTED / E_DECODE).
// Button S1 (pin 88) resets the whole design, including the baud rate.
`default_nettype none
module mn_top_1pe #(
    parameter CLK_HZ        = 27000000,
    parameter BAUD          = 1000000,
    parameter TIMEOUT_CYC   = CLK_HZ / 50,
    parameter PROBATION_CYC = CLK_HZ,
    parameter IMEM_AW       = 9,
    parameter IMEM_RD       = 0,
    parameter LM_AW         = 9,
    parameter GRF_AW        = 8,
    parameter FPALU         = 0,
    parameter MAU           = 1,
    parameter LED_STRETCH   = 22            // activity LEDs stay on for 2**LED_STRETCH clocks
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
        .DESIGN_ID     (8'h02),
        .INFO_FLAGS    (8'h01),
        .IMEM_DEPTH    (IMEM_DEPTH),
        .TOPO          (40'h01_01_01_01_01),
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
    /* verilator lint_on UNUSEDSIGNAL */
    mn_core #(
        .IMEM_AW(IMEM_AW), .IMEM_RD(IMEM_RD), .LM_AW(LM_AW), .GRF_AW(GRF_AW), .CLEAR(1),
        .FPALU(FPALU), .MAU(MAU), .PE_LOC(16'h0000)
    ) u_core (
        .clk(clk), .rst(rst | core_rst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space),
        .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space),
        .mr_loc(mr_loc), .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps), .core_trap(core_trap)
    );

    // ---------------------------------------------------------------- LEDs
    localparam [LED_STRETCH-1:0] S_ZERO = {LED_STRETCH{1'b0}};
    localparam [LED_STRETCH-1:0] S_FULL = {LED_STRETCH{1'b1}};
    localparam [LED_STRETCH-1:0] S_ONE  = {{(LED_STRETCH-1){1'b0}}, 1'b1};
    reg [24:0] hb;
    reg [LED_STRETCH-1:0] s_rx, s_tx, s_err, s_run;
    always @(posedge clk) begin
        if (rst) begin
            hb    <= 25'd0;
            s_rx  <= S_ZERO;
            s_tx  <= S_ZERO;
            s_err <= S_ZERO;
            s_run <= S_ZERO;
        end else begin
            hb <= hb + 1'b1;
            if (dbg_rx_byte)         s_rx <= S_FULL;
            else if (s_rx != S_ZERO) s_rx <= s_rx - S_ONE;
            if (dbg_tx_byte)         s_tx <= S_FULL;
            else if (s_tx != S_ZERO) s_tx <= s_tx - S_ONE;
            if (dbg_err)             s_err <= S_FULL;
            else if (s_err != S_ZERO) s_err <= s_err - S_ONE;
            if (core_busy)           s_run <= S_FULL;
            else if (s_run != S_ZERO) s_run <= s_run - S_ONE;
        end
    end
    wire stop_err = ~core_busy & (core_reason != 8'd0);
    wire [5:0] led_on = {stop_err, s_run != S_ZERO, (s_err != S_ZERO) | dbg_probation, s_tx != S_ZERO,
                         s_rx != S_ZERO, hb[24]};
    assign led = ~led_on;
endmodule
`default_nettype wire

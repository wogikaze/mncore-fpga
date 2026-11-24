// Board test design for Tang Nano 20K: brd_host_if + BSRAM test memories + a RUN stub.
//
//   space 0x00 IMEM : 64 entries x 8 lanes = 512 long words (full-word writes only)
//   space 0x0F TEST : 8192 long words = 64 KiB, byte mask supported
//   other spaces, loc != 0 or addresses past the end -> E_RANGE
//
// LEDs (active low): 0 heartbeat, 1 UART RX activity, 2 UART TX activity, 3 error (CRC / framing /
// overrun / timeout), 4 SET_BAUD probation, 5 run stub busy.
// Button S1 (pin 88) resets the whole design, including the baud rate.
module brd_board_test #(
    parameter CLK_HZ        = 27000000,
    parameter BAUD          = 1000000,
    parameter TIMEOUT_CYC   = CLK_HZ / 50,
    parameter PROBATION_CYC = CLK_HZ,
    parameter RUN_TICK      = 1,
    parameter LED_STRETCH   = 22            // activity LEDs stay on for 2**LED_STRETCH clocks
) (
    input  wire       clk,
    input  wire       btn_rst,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);
    localparam [7:0]  SP_IMEM    = 8'h00;
    localparam [7:0]  SP_TEST    = 8'h0F;
    localparam        IMEM_AW    = 9;
    localparam        TEST_AW    = 13;
    localparam [15:0] IMEM_DEPTH = 16'd64;
    localparam [511:0] SPACE_DEPTH = (512'd8192 << (32 * 15)) | 512'd512;

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
        .DESIGN_ID     (8'h01),
        .INFO_FLAGS    (8'h02),
        .IMEM_DEPTH    (IMEM_DEPTH),
        .TOPO          (40'h0),
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

    // ---------------------------------------------------------------- address decode
    wire w_imem = (mw_space == SP_IMEM) && (mw_loc == 16'd0) && (mw_addr[22:IMEM_AW] == 0) &&
                  (mw_mask == 8'hFF);
    wire w_test = (mw_space == SP_TEST) && (mw_loc == 16'd0) && (mw_addr[22:TEST_AW] == 0);
    wire r_imem = (mr_space == SP_IMEM) && (mr_loc == 16'd0) && (mr_addr[22:IMEM_AW] == 0);
    wire r_test = (mr_space == SP_TEST) && (mr_loc == 16'd0) && (mr_addr[22:TEST_AW] == 0);

    assign mw_ready = 1'b1;               // both stores are always ready
    assign mw_err   = !(w_imem || w_test);
    assign mr_ready = 1'b1;
    assign mr_err   = !(r_imem || r_test);

    // host_if never drives a write and a read request in the same cycle
    wire        imem_req = (mw_valid && w_imem) || (mr_valid && r_imem);
    wire        test_req = (mw_valid && w_test) || (mr_valid && r_test);
    wire [22:0] req_addr = mw_valid ? mw_addr : mr_addr;
    wire        imem_rsp, test_rsp;
    wire [63:0] imem_rdata, test_rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        imem_ready, test_ready;   // brd_test_mem is always ready (mw_ready / mr_ready tied to 1)
    /* verilator lint_on UNUSEDSIGNAL */

    brd_test_mem #(.AW(IMEM_AW), .BYTE_EN(0)) u_imem (
        .clk(clk), .rst(rst),
        .req_valid(imem_req), .req_ready(imem_ready), .req_we(mw_valid), .req_addr(req_addr),
        .req_wmask(mw_mask), .req_wdata(mw_data),
        .rsp_valid(imem_rsp), .rsp_rdata(imem_rdata)
    );

    brd_test_mem #(.AW(TEST_AW), .BYTE_EN(1)) u_test (
        .clk(clk), .rst(rst),
        .req_valid(test_req), .req_ready(test_ready), .req_we(mw_valid), .req_addr(req_addr),
        .req_wmask(mw_mask), .req_wdata(mw_data),
        .rsp_valid(test_rsp), .rsp_rdata(test_rdata)
    );

    assign mr_rsp_valid = imem_rsp || test_rsp;
    assign mr_rsp_data  = imem_rsp ? imem_rdata : test_rdata;

    // ---------------------------------------------------------------- RUN stub
    brd_run_stub #(.IMEM_DEPTH(IMEM_DEPTH), .TICK(RUN_TICK)) u_stub (
        .clk(clk), .rst(rst || core_rst),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .busy(core_busy), .reason(core_reason), .info(core_info), .pc(core_pc), .steps(core_steps)
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
            if (dbg_rx_byte)      s_rx <= S_FULL;
            else if (s_rx != S_ZERO) s_rx <= s_rx - S_ONE;
            if (dbg_tx_byte)      s_tx <= S_FULL;
            else if (s_tx != S_ZERO) s_tx <= s_tx - S_ONE;
            if (dbg_err)          s_err <= S_FULL;
            else if (s_err != S_ZERO) s_err <= s_err - S_ONE;
            if (core_busy)        s_run <= S_FULL;
            else if (s_run != S_ZERO) s_run <= s_run - S_ONE;
        end
    end

    wire [5:0] led_on = {s_run != S_ZERO, dbg_probation, s_err != S_ZERO, s_tx != S_ZERO,
                         s_rx != S_ZERO, hb[24]};
    assign led = ~led_on;
endmodule

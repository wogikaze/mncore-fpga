// sdram_test_top: Tang Nano 20K test design for the embedded SDRAM (WP05).
//
// 27 MHz -> rPLL -> controller clock (FREQ_HZ) and the phase-shifted SDRAM pin clock.
// sdr_test_ctl sweeps the SDRAM clock phase and the read capture delay, picks the middle of the
// passing window, then runs the full 8 MiB test forever. Results go to the UART (pin 69, 1 Mbaud 8N1)
// and to the LEDs (on = low):
//   led[0] heartbeat            led[1] controller initialized   led[2] sweep finished
//   led[3] full test passed     led[4] error seen               led[5] toggles every full iteration
// S1 (pin 88) restarts the test.
// The UART only sends while the host is present: any falling edge on uart_rx (pin 70) within the
// last 0.25 s. The host sends a byte (e.g. 0x00, never 0x18 / 0x03) about every 50 ms while reading;
// the test waits at each line until then. (The BL616 bridge stops relaying FPGA -> PC when the FPGA
// sends while nobody reads; it then needs a BL616 reboot.)
//
// The O_sdram_* / IO_sdram_dq port names are the ones nextpnr (apicula) binds to the embedded SDRAM.
`default_nettype none

module sdram_test_top #(
    parameter integer IDIV_SEL  = 0,
    parameter integer FBDIV_SEL = 3,
    parameter integer ODIV_SEL  = 8,
    parameter integer FREQ_HZ   = 108000000,
    parameter integer CL        = 3,
    parameter integer DYN_PHASE = 1,
    parameter integer PSDA      = 8,
    parameter integer SWEEP     = 1,
    parameter integer FIX_K     = 1,
    parameter integer AW        = 20,
    parameter integer QAW       = 14,
    parameter integer BAUD      = 1000000,
    parameter integer INIT_CYC  = 0,
    parameter integer BOOT_CYC  = 100000,
    parameter integer SETTLE_CYC = 4096,
    parameter integer HOST_CYC  = FREQ_HZ / 4  // host-present hold time (0.25 s)
) (
    input  wire        clk,
    input  wire        btn_s1,
    output wire [5:0]  led,
    input  wire        uart_rx,
    output wire        uart_tx,

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
    // ------------------------------------------------------------------ clocks and reset
    wire       sclk, pclk, lock;
    wire [3:0] psda;

    sdr_gw_pll #(
        .IDIV_SEL(IDIV_SEL), .FBDIV_SEL(FBDIV_SEL), .ODIV_SEL(ODIV_SEL),
        .DYN_PHASE(DYN_PHASE), .PSDA(PSDA)
    ) u_pll (
        .clkin(clk), .psda(psda), .clkout(sclk), .clkoutp(pclk), .lock(lock)
    );

    sdr_gw_clkout u_ck (.clk(pclk), .q(O_sdram_clk));

    /* verilator lint_off PROCASSINIT */  // power-up values (FPGA init state) are intended
    reg [2:0] btn_s = 3'd0;
    reg [7:0] por = 8'd0;
    reg       rst = 1'b1;
    reg [26:0] hb = 27'd0;
    reg [2:0]  rx_s = 3'b111;
    reg [27:0] host_t = 28'd0;
    /* verilator lint_on PROCASSINIT */
    always @(posedge sclk) begin
        btn_s <= {btn_s[1:0], btn_s1};
        if (!lock || btn_s[2]) por <= 8'd0;
        else if (por != 8'hff) por <= por + 8'd1;
        rst <= (por != 8'hff);
    end

    // host present: a falling edge on uart_rx within the last HOST_CYC cycles
    localparam [27:0] HOST_T = HOST_CYC[27:0];
    always @(posedge sclk) begin
        rx_s <= {rx_s[1:0], uart_rx};
        if (rx_s[2] && !rx_s[1]) host_t <= HOST_T;
        else if (host_t != 28'd0) host_t <= host_t - 28'd1;
    end
    wire host_ok = (host_t != 28'd0);

    // ------------------------------------------------------------------ SDRAM controller
    wire        crst;
    wire [1:0]  cfg_rdx;
    wire        init_done, err_addr;
    wire        req_valid, req_ready, req_we;
    wire [22:0] req_addr;
    wire [63:0] req_wdata;
    wire [7:0]  req_wmask;
    wire        rsp_valid;
    wire [63:0] rsp_rdata;
    wire [31:0] dq_o, dq_oe;

    sdr_bus64 #(.ASYNC(0), .FREQ_HZ(FREQ_HZ), .CL(CL), .INIT_CYC(INIT_CYC)) u_sdr (
        .clk(sclk), .rst(rst | crst), .sclk(sclk), .srst(rst | crst), .cfg_rdx(cfg_rdx),
        .init_done(init_done), .err_addr(err_addr),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_wmask(req_wmask), .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .sdr_cke(O_sdram_cke), .sdr_cs_n(O_sdram_cs_n), .sdr_ras_n(O_sdram_ras_n),
        .sdr_cas_n(O_sdram_cas_n), .sdr_we_n(O_sdram_wen_n), .sdr_ba(O_sdram_ba), .sdr_a(O_sdram_addr),
        .sdr_dqm(O_sdram_dqm), .sdr_dq_o(dq_o), .sdr_dq_oe(dq_oe), .sdr_dq_i(IO_sdram_dq)
    );

    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : g_dq
            assign IO_sdram_dq[g] = dq_oe[g] ? dq_o[g] : 1'bz;
        end
    endgenerate

    // ------------------------------------------------------------------ test sequencer and report
    wire         pr_start, pr_busy;
    wire [1:0]   pr_kind;
    wire [287:0] pr_fields;
    wire         st_init, st_sweep_done, st_pass, st_fail, st_iter;

    sdr_test_ctl #(
        .FREQ_HZ(FREQ_HZ), .CL(CL), .AW(AW), .QAW(QAW), .SWEEP(SWEEP), .DYN_PHASE(DYN_PHASE),
        .FIX_PH(PSDA), .FIX_K(FIX_K), .BOOT_CYC(BOOT_CYC), .SETTLE_CYC(SETTLE_CYC)
    ) u_test (
        .clk(sclk), .rst(rst),
        .crst(crst), .cfg_rdx(cfg_rdx), .psda(psda), .init_done(init_done),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_wmask(req_wmask), .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .pr_start(pr_start), .pr_kind(pr_kind), .pr_fields(pr_fields), .pr_busy(pr_busy),
        .st_init(st_init), .st_sweep_done(st_sweep_done), .st_pass(st_pass), .st_fail(st_fail),
        .st_iter(st_iter)
    );

    sdr_test_print #(.CLKDIV(FREQ_HZ / BAUD)) u_pr (
        .clk(sclk), .rst(rst), .start(pr_start), .kind(pr_kind), .fields(pr_fields),
        .host_ok(host_ok), .busy(pr_busy), .tx(uart_tx)
    );

    // ------------------------------------------------------------------ LEDs (active low)
    always @(posedge sclk) hb <= hb + 27'd1;
    wire [5:0] on = {st_iter, st_fail | err_addr, st_pass & !st_fail, st_sweep_done, st_init, hb[26]};
    assign led = ~on;
endmodule

`default_nettype wire

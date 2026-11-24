// tb_sdram_systest: runs the whole sdram_test design (PLL model, sweep, full test, UART report) with a
// reduced memory size against the SDRAM model, and decodes the UART output into the log.
// PASS: the sweep found a window, the first full iteration had no errors, and the SDRAM model saw
// no protocol / timing error from the chosen setting onwards.
// The model has no board delays here, so the passing phases differ from the board.
`timescale 1ns/1ps

module tb_sdram_systest;
    localparam integer FREQ_HZ = 108000000;
    localparam integer CLKDIV  = 8;
    localparam real    P_NS    = 1000.0 / 108.0;

    reg clk27 = 1'b0;
    always #18.519 clk27 = ~clk27;

    wire [5:0]  led;
    wire        uart_tx;
    reg         uart_rx = 1'b1;              // host present: one falling edge keeps it for 0.25 s
    initial begin
        #20000 uart_rx = 1'b0;
        #1000  uart_rx = 1'b1;
    end
    wire        s_clk, s_cke, s_cs_n, s_cas_n, s_ras_n, s_we_n;
    wire [3:0]  s_dqm;
    wire [10:0] s_a;
    wire [1:0]  s_ba;
    wire [31:0] s_dq;

    sdram_test_top #(
        .FREQ_HZ(FREQ_HZ), .CL(3), .DYN_PHASE(1), .SWEEP(1), .AW(12), .QAW(8),
        .BAUD(FREQ_HZ / CLKDIV), .INIT_CYC(1100), .BOOT_CYC(200), .SETTLE_CYC(64)
    ) dut (
        .clk(clk27), .btn_s1(1'b0), .led(led), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .O_sdram_clk(s_clk), .O_sdram_cke(s_cke), .O_sdram_cs_n(s_cs_n), .O_sdram_cas_n(s_cas_n),
        .O_sdram_ras_n(s_ras_n), .O_sdram_wen_n(s_we_n), .O_sdram_dqm(s_dqm), .O_sdram_addr(s_a),
        .O_sdram_ba(s_ba), .IO_sdram_dq(s_dq)
    );

    tb_sdr_model #(.T_INIT(5000.0), .GAP_NS(9000.0), .MAXMSG(0), .JUNK(1), .NAME("sys")) mdl (
        .clk(s_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n), .we_n(s_we_n),
        .ba(s_ba), .a(s_a), .dqm(s_dqm), .dq(s_dq)
    );

    // an undriven bus reads as junk, not Z (the design's checker cannot see X/Z)
    reg [31:0] flt = 32'h0;
    always @(posedge clk27) flt = $random;
    assign (weak0, weak1) s_dq = flt;

    // UART receiver: print the report lines
    integer b;
    reg [7:0] ch;
    initial begin
        forever begin
            @(negedge uart_tx);
            #(P_NS * CLKDIV * 1.5);
            for (b = 0; b < 8; b = b + 1) begin
                ch[b] = uart_tx;
                #(P_NS * CLKDIV);
            end
            if (ch != 8'h0d) $write("%c", ch);
        end
    end

    integer err0 = 0;
    initial begin
        // from the reset that applies the chosen phase on (the controller keeps running at the
        // last sweep point while the "C" line is printed)
        wait (dut.u_test.st_sweep_done === 1'b1);
        wait (dut.u_test.crst === 1'b1);
        #200;                               // the controller's reset reaches the pins one cycle later
        err0 = mdl.errors;
        mdl.nmsg = 0;
        mdl.maxmsg = 20;
        wait (dut.u_test.iter == 16'd1);
        #1000;
        if (dut.u_test.best_n == 5'd0)
            $display("FAIL sweep found no passing setting");
        else if (dut.u_test.st_fail !== 1'b0 || dut.u_test.st_pass !== 1'b1)
            $display("FAIL full test reported errors");
        else if (mdl.errors != err0)
            $display("FAIL SDRAM model: %0d errors with the chosen setting", mdl.errors - err0);
        else
            $display("PASS (model errors during the sweep: %0d)", err0);
        $finish;
    end

    initial begin
        #30_000_000;
        $display("FAIL timeout");
        $finish;
    end
endmodule

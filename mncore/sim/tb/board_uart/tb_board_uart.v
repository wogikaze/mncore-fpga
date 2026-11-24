`timescale 1ns/1ps
// Unit test for brd_uart_tx / brd_uart_rx:
//  1. tx -> rx loopback for several dividers (integer and fractional, down to 4 clocks per bit)
//  2. tx average bit period == div_q8 / 256 clocks
//  3. rx against an ideal sender that is 3 % fast / slow
//  4. framing error (stop bit 0) and overrun (FIFO full) reporting
module tb_board_uart;
    localparam real CLK_NS = 1000.0 / 27.0;
    reg clk = 1'b0;
    always #(CLK_NS / 2.0) clk = ~clk;
    reg rst = 1'b1;

    reg  [23:0] div = 24'd2304;
    reg         sel_model = 1'b0;     // 0: rx listens to tx, 1: rx listens to the TB model
    reg         model_line = 1'b1;
    wire        txd;
    wire        rxd = sel_model ? model_line : txd;

    reg         s_valid = 1'b0;
    wire        s_ready;
    reg  [7:0]  s_data = 8'd0;
    wire        tx_idle, tx_pulse;
    wire        m_valid;
    reg         m_ready = 1'b1;
    wire [7:0]  m_data;
    wire        ferr, ovr, rx_pulse;
    wire [15:0] meas;

    brd_uart_tx #(.DIVW(24), .FIFO_AW(4)) u_tx (
        .clk(clk), .rst(rst), .div_q8(div), .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .txd(txd), .idle(tx_idle), .byte_pulse(tx_pulse));
    brd_uart_rx #(.DIVW(24), .FIFO_AW(4)) u_rx (
        .clk(clk), .rst(rst), .rxd(rxd), .div_q8(div), .m_valid(m_valid), .m_ready(m_ready),
        .m_data(m_data), .err_frame(ferr), .err_overrun(ovr), .byte_pulse(rx_pulse), .meas(meas));

    integer errors = 0;
    integer ferr_cnt = 0, ovr_cnt = 0;
    always @(posedge clk) begin
        if (ferr) ferr_cnt = ferr_cnt + 1;
        if (ovr)  ovr_cnt  = ovr_cnt + 1;
    end

    // receive side scoreboard
    reg [7:0] exp_q [0:1023];
    integer   eq_w = 0, eq_r = 0, got = 0, bad = 0;
    always @(posedge clk) begin
        if (m_valid && m_ready) begin
            if (eq_r >= eq_w || m_data !== exp_q[eq_r[9:0]]) bad = bad + 1;
            eq_r = eq_r + 1;
            got = got + 1;
        end
    end

    // measure first falling edge to last stop bit end of the tx line
    integer clk_cnt = 0;
    integer last_busy = 0;      // last clock at which the transmitter was not idle
    always @(posedge clk) begin
        clk_cnt = clk_cnt + 1;
        if (!tx_idle) last_busy = clk_cnt;
    end

    task send_tx(input [7:0] b);
        begin
            @(posedge clk);
            while (!s_ready) @(posedge clk);
            s_valid <= 1'b1; s_data <= b;
            @(posedge clk);
            s_valid <= 1'b0;
        end
    endtask

    task model_put(input [7:0] b, input real bit_ns, input stop);
        integer i;
        begin
            model_line = 1'b0; #(bit_ns);
            for (i = 0; i < 8; i = i + 1) begin model_line = b[i]; #(bit_ns); end
            model_line = stop; #(bit_ns);
            model_line = 1'b1;
        end
    endtask

    task loopback(input [23:0] d, input integer nbytes);
        integer i, t0, t1;
        real ideal, got_cyc;
        begin
            div = d;
            repeat (20) @(posedge clk);
            got = 0; bad = 0;
            @(posedge clk);
            fork
                begin
                    for (i = 0; i < nbytes; i = i + 1) begin
                        exp_q[eq_w[9:0]] = $random;
                        send_tx(exp_q[eq_w[9:0]]);
                        eq_w = eq_w + 1;
                    end
                end
                begin
                    @(negedge txd); t0 = clk_cnt;
                    wait (got == nbytes);
                end
            join
            wait (tx_idle);
            @(posedge clk);
            t1 = last_busy;
            ideal = nbytes * 10.0 * d / 256.0;
            got_cyc = t1 - t0;
            // bit edges are the ideal fractional times rounded up to a clock: the total is within one clock
            if (bad != 0) begin errors = errors + 1; $display("  div=%0d: %0d bad bytes", d, bad); end
            if (got_cyc < ideal - 1.0 || got_cyc > ideal + 2.0) begin
                errors = errors + 1;
                $display("  div=%0d: tx took %0.1f clocks, ideal %0.1f", d, got_cyc, ideal);
            end
            $display("  div=%0d (%0.3f clk/bit): %0d bytes ok, tx %0.1f / ideal %0.1f clocks",
                     d, d / 256.0, got, got_cyc, ideal);
        end
    endtask

    task model_burst(input [23:0] d, input real ratio, input integer nbytes);
        integer i;
        real bit_ns;
        begin
            div = d;
            sel_model = 1'b1;
            repeat (20) @(posedge clk);
            got = 0; bad = 0;
            bit_ns = CLK_NS * d / 256.0 / ratio;
            for (i = 0; i < nbytes; i = i + 1) begin
                exp_q[eq_w[9:0]] = $random;
                eq_w = eq_w + 1;
                model_put(exp_q[(eq_w - 1) % 1024], bit_ns, 1'b1);
            end
            repeat (50) @(posedge clk);
            if (bad != 0 || got != nbytes) begin
                errors = errors + 1;
                $display("  model ratio %0.3f: got %0d of %0d, %0d bad", ratio, got, nbytes, bad);
            end else begin
                $display("  model ratio %0.3f at div=%0d: %0d bytes ok", ratio, d, got);
            end
            sel_model = 1'b0;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);

        $display("[1] tx -> rx loopback");
        loopback(24'd1024, 64);   // 4.0 clocks per bit (minimum)
        loopback(24'd1100, 64);   // 4.297
        loopback(24'd2304, 100);  // 9.0   (3 Mbaud @ 27 MHz)
        loopback(24'd2400, 100);  // 9.375
        loopback(24'd3456, 100);  // 13.5  (2 Mbaud)
        loopback(24'd6912, 50);   // 27.0  (1 Mbaud)
        loopback(24'd60000, 10);  // 234.4

        $display("[2] rx against an ideal sender with rate error");
        model_burst(24'd2304, 1.03, 100);
        model_burst(24'd2304, 0.97, 100);
        model_burst(24'd3456, 1.035, 100);
        model_burst(24'd3456, 0.965, 100);

        $display("[3] auto-baud measurement");
        div = 24'd3456; sel_model = 1'b1;
        repeat (20) @(posedge clk);
        exp_q[eq_w[9:0]] = 8'h55; eq_w = eq_w + 1;
        model_put(8'h55, 500.0, 1'b1);      // exactly 2 Mbaud
        repeat (50) @(posedge clk);
        if (meas < 16'd120 || meas > 16'd123) begin
            errors = errors + 1;
            $display("  meas=%0d, expected about 121.5", meas);
        end else $display("  meas=%0d for 9 bits of 13.5 clocks", meas);

        $display("[4] framing error and overrun");
        ferr_cnt = 0; ovr_cnt = 0;
        got = 0; bad = 0;
        model_put(8'h12, 500.0, 1'b0);      // stop bit 0 -> dropped
        model_line = 1'b1; #(2000.0);
        if (ferr_cnt != 1 || got != 0) begin errors = errors + 1; $display("  framing: ferr=%0d got=%0d", ferr_cnt, got); end
        // fill the FIFO (16 + 1 output register) and overflow it
        m_ready = 1'b0;
        eq_r = eq_w;
        for (integer i = 0; i < 20; i = i + 1) begin
            exp_q[eq_w[9:0]] = i[7:0]; eq_w = eq_w + 1;
            model_put(i[7:0], 500.0, 1'b1);
        end
        repeat (50) @(posedge clk);
        if (ovr_cnt != 3) begin errors = errors + 1; $display("  overrun count %0d, expected 3", ovr_cnt); end
        got = 0; bad = 0;
        eq_w = eq_r + 17;                   // only the first 17 bytes were kept
        m_ready = 1'b1;
        repeat (50) @(posedge clk);
        if (got != 17 || bad != 0) begin errors = errors + 1; $display("  after overrun: got %0d bad %0d", got, bad); end
        else $display("  framing error dropped 1 byte, overrun dropped 3 of 20, 17 kept in order");
        sel_model = 1'b0;

        if (errors == 0) $display("PASS");
        else             $display("FAIL %0d errors", errors);
        $finish;
    end

    initial begin
        #(50.0e6);
        $display("FAIL watchdog timeout");
        $finish;
    end
endmodule

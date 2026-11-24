`timescale 1ns/1ps
// Protocol testbench for brd_board_test (brd_host_if + test memories + run stub).
// Drives the UART pin with a bit-level model and checks every response frame byte by byte.
module tb_board;
    // ------------------------------------------------------------------ clock / DUT
    localparam real CLK_NS = 1000.0 / 27.0;   // 27 MHz
    localparam integer CLK_HZ = 27000000;
    localparam integer TIMEOUT_CYC = 4000;
    localparam integer PROBATION_CYC = 30000;
    localparam integer RUN_TICK = 2000;

    reg clk = 1'b0;
    always #(CLK_NS / 2.0) clk = ~clk;

    reg  uart_rx = 1'b1;
    wire uart_tx;
    wire [5:0] led;
    reg  btn = 1'b0;

    brd_board_test #(
        .CLK_HZ(CLK_HZ), .BAUD(3000000), .TIMEOUT_CYC(TIMEOUT_CYC),
        .PROBATION_CYC(PROBATION_CYC), .RUN_TICK(RUN_TICK), .LED_STRETCH(4)
    ) dut (
        .clk(clk), .btn_rst(btn), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led)
    );

    // ------------------------------------------------------------------ bookkeeping
    integer errors = 0;
    integer checks = 0;
    task check(input cond, input [8*64-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  CHECK FAILED: %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    function [7:0] crc8(input [7:0] c, input [7:0] d);
        integer i;
        reg [7:0] x;
        begin
            x = c ^ d;
            for (i = 0; i < 8; i = i + 1) x = x[7] ? ((x << 1) ^ 8'h07) : (x << 1);
            crc8 = x;
        end
    endfunction

    // ------------------------------------------------------------------ UART models
    real drv_bit_ns = 1.0e9 / 3000000.0;   // host -> FPGA
    real mon_bit_ns = 1.0e9 / 3000000.0;   // FPGA -> host

    task uart_put(input [7:0] b);
        integer i;
        begin
            uart_rx = 1'b0; #(drv_bit_ns);
            for (i = 0; i < 8; i = i + 1) begin uart_rx = b[i]; #(drv_bit_ns); end
            uart_rx = 1'b1; #(drv_bit_ns);
        end
    endtask

    reg [7:0] rxq [0:65535];
    integer   rq_w = 0, rq_r = 0;
    integer   mon_ferr = 0;
    initial begin : monitor
        reg [7:0] b;
        integer i;
        forever begin
            @(negedge uart_tx);
            #(mon_bit_ns * 1.5);
            for (i = 0; i < 8; i = i + 1) begin b[i] = uart_tx; #(mon_bit_ns); end
            if (uart_tx !== 1'b1) mon_ferr = mon_ferr + 1;
            rxq[rq_w[15:0]] = b;
            rq_w = rq_w + 1;
        end
    end

    // ------------------------------------------------------------------ frame helpers
    reg [7:0] pl [0:4095];      // request payload
    integer   pl_len;
    reg [7:0] rp [0:4095];      // response payload (rp[0] = status)
    integer   rp_len;
    reg [7:0] rp_cmd;

    task pl_clear; begin pl_len = 0; end endtask
    task put8(input [7:0] v);   begin pl[pl_len] = v; pl_len = pl_len + 1; end endtask
    task put16(input [15:0] v); begin put8(v[7:0]); put8(v[15:8]); end endtask
    task put32(input [31:0] v); begin put16(v[15:0]); put16(v[31:16]); end endtask
    task put64(input [63:0] v); begin put32(v[31:0]); put32(v[63:32]); end endtask
    function [15:0] get16(input integer i); get16 = {rp[i+1], rp[i]}; endfunction
    function [31:0] get32(input integer i); get32 = {rp[i+3], rp[i+2], rp[i+1], rp[i]}; endfunction
    function [63:0] get64(input integer i); get64 = {get32(i+4), get32(i)}; endfunction

    task send_frame(input [7:0] cmd, input bad_crc);
        reg [7:0] c;
        integer i;
        begin
            c = crc8(8'd0, cmd);
            uart_put(8'hA5);
            uart_put(cmd);
            c = crc8(c, pl_len[7:0]);  uart_put(pl_len[7:0]);
            c = crc8(c, pl_len[15:8]); uart_put(pl_len[15:8]);
            for (i = 0; i < pl_len; i = i + 1) begin c = crc8(c, pl[i]); uart_put(pl[i]); end
            uart_put(bad_crc ? (c ^ 8'h01) : c);
        end
    endtask

    task get_byte(output [7:0] b, output reg ok);
        real waited;
        begin
            waited = 0.0;
            while (rq_r == rq_w && waited < 20.0e6) begin #(200.0); waited = waited + 200.0; end
            ok = (rq_r != rq_w);
            b  = ok ? rxq[rq_r[15:0]] : 8'hxx;
            if (ok) rq_r = rq_r + 1;
        end
    endtask

    // receive one frame; returns ok=0 on timeout / bad framing / bad CRC
    task recv_frame(output reg ok);
        reg [7:0] b, c;
        reg g;
        integer i;
        begin
            ok = 1'b0;
            get_byte(b, g);
            if (g && b == 8'hA5) begin
                get_byte(rp_cmd, g); c = crc8(8'd0, rp_cmd);
                get_byte(b, g); c = crc8(c, b); rp_len = b;
                get_byte(b, g); c = crc8(c, b); rp_len = rp_len + 256 * b;
                for (i = 0; i < rp_len && g; i = i + 1) begin get_byte(rp[i], g); c = crc8(c, rp[i]); end
                get_byte(b, g);
                ok = g && (b == c);
                if (!ok) $display("  bad response frame (crc %02x vs %02x)", b, c);
            end else begin
                $display("  no response / bad sync byte");
            end
        end
    endtask

    // full transaction: send, receive, check response cmd and status
    task xact(input [7:0] cmd, input [7:0] want_status, input [8*48-1:0] name);
        reg ok;
        begin
            send_frame(cmd, 1'b0);
            recv_frame(ok);
            check(ok, {name, ": response frame"});
            check(rp_cmd == (cmd | 8'h80), {name, ": response cmd"});
            check(rp_len >= 1 && rp[0] == want_status, {name, ": status"});
            if (rp[0] !== want_status) $display("    %0s: status %02x, want %02x", name, rp[0], want_status);
        end
    endtask

    task set_rates(input real baud_drv, input real baud_mon);
        begin
            drv_bit_ns = 1.0e9 / baud_drv;
            mon_bit_ns = 1.0e9 / baud_mon;
        end
    endtask

    // ------------------------------------------------------------------ model of the TEST space
    reg [63:0] model [0:8191];
    reg        mvalid [0:8191];
    integer i, j, k, n, base;
    reg [63:0] w, mk;
    reg        ok;
    reg [7:0]  st8;

    task wr_test(input integer addr, input integer cnt, input [7:0] mask);
        begin
            pl_clear; put8(8'h0F); put8(mask); put16(16'd0); put32(addr);
            for (k = 0; k < cnt; k = k + 1) begin
                w = {$random, $random};
                put64(w);
                mk = {{8{mask[7]}}, {8{mask[6]}}, {8{mask[5]}}, {8{mask[4]}},
                      {8{mask[3]}}, {8{mask[2]}}, {8{mask[1]}}, {8{mask[0]}}};
                model[addr + k]  = (model[addr + k] & ~mk) | (w & mk);
                mvalid[addr + k] = mvalid[addr + k] | (mask == 8'hFF);
            end
            xact(8'h04, 8'h00, "WR_MEM TEST");
        end
    endtask

    task rd_test(input integer addr, input integer cnt);
        integer bad;
        begin
            pl_clear; put8(8'h0F); put8(8'h00); put16(16'd0); put32(addr); put16(cnt);
            xact(8'h05, 8'h00, "RD_MEM TEST");
            check(rp_len == 1 + 8 * cnt, "RD_MEM length");
            bad = 0;
            for (k = 0; k < cnt; k = k + 1)
                if (mvalid[addr + k] && get64(1 + 8 * k) !== model[addr + k]) bad = bad + 1;
            check(bad == 0, "RD_MEM data matches model");
            if (bad) $display("    %0d mismatching words at %0d", bad, addr);
        end
    endtask

    task status_req;
        begin
            pl_clear;
            xact(8'h07, 8'h00, "STATUS");
            check(rp_len == 28, "STATUS length");
        end
    endtask

    // ------------------------------------------------------------------ test sequence
    initial begin
        for (i = 0; i < 8192; i = i + 1) begin model[i] = 64'd0; mvalid[i] = 1'b0; end
        repeat (200) @(posedge clk);

        // CRC-8/SMBUS known answer: "123456789" -> 0xF4
        st8 = 8'd0;
        st8 = crc8(st8, "1"); st8 = crc8(st8, "2"); st8 = crc8(st8, "3");
        st8 = crc8(st8, "4"); st8 = crc8(st8, "5"); st8 = crc8(st8, "6");
        st8 = crc8(st8, "7"); st8 = crc8(st8, "8"); st8 = crc8(st8, "9");
        check(st8 == 8'hF4, "crc8 check value 0xF4");

        $display("[1] PING / INFO at 3 Mbaud");
        pl_clear; xact(8'h01, 8'h00, "PING empty");
        check(rp_len == 1, "PING empty length");
        pl_clear; for (i = 0; i < 100; i = i + 1) put8($random);
        xact(8'h01, 8'h00, "PING 100");
        check(rp_len == 101, "PING echo length");
        n = 0; for (i = 0; i < 100; i = i + 1) if (rp[i + 1] !== pl[i]) n = n + 1;
        check(n == 0, "PING echo data");

        pl_clear; xact(8'h02, 8'h00, "INFO");
        check(rp_len == 89, "INFO length");
        check(rp[1] == 8'd1, "INFO proto version");
        check(rp[2] == 8'd1, "INFO design id");
        check(get16(3) == 16'd2048, "INFO pbuf");
        check(get32(5) == 32'd27000000, "INFO clk_hz");
        check(get32(9) == 32'd2304, "INFO div (3 Mbaud = 9.0 clk)");
        check(get16(13) == 16'd64, "INFO imem depth");
        check(rp[20] == 8'h02, "INFO flags");
        check(get32(21) == 32'd512, "INFO depth space 0");
        check(get32(21 + 4 * 15) == 32'd8192, "INFO depth space 15");
        check(get32(21 + 4 * 1) == 32'd0, "INFO depth space 1");
        check(get16(85) == 16'd2048 && get16(87) == 16'd2048, "INFO fifo sizes");

        $display("[2] WR_MEM / RD_MEM");
        wr_test(0, 64, 8'hFF);
        rd_test(0, 64);
        wr_test(1, 3, 8'h0F);                   // partial write keeps the upper half
        rd_test(0, 8);
        wr_test(8192 - 255, 255, 8'hFF);        // largest WR_MEM (len = 2048)
        rd_test(8192 - 256, 256);               // largest RD_MEM (256 words)

        $display("[3] error responses");
        pl_clear; put8(8'h0F); put8(8'h00); put16(16'd0); put32(8190); put16(4);
        xact(8'h05, 8'h05, "RD_MEM past end -> E_RANGE");
        check(rp_len == 5 && get32(1) == 32'd2, "E_RANGE info = failing word index");
        pl_clear; put8(8'h05); put8(8'hFF); put16(16'd0); put32(0); put64(64'h1);
        xact(8'h04, 8'h05, "WR_MEM bad space -> E_RANGE");
        check(get32(1) == 32'd0, "E_RANGE info 0");
        pl_clear; put8(8'h0F); put8(8'hFF); put16(16'd1); put32(0); put64(64'h1);
        xact(8'h04, 8'h05, "WR_MEM loc!=0 -> E_RANGE");
        pl_clear; put8(8'h0F); put8(8'hFF); put16(16'd0); put32(32'h0080_0000); put64(64'h1);
        xact(8'h04, 8'h05, "WR_MEM addr >= 2^23 -> E_RANGE");
        pl_clear; put8(8'h0F); put8(8'h00); put16(16'd0); put32(0); put16(257);
        xact(8'h05, 8'h06, "RD_MEM n too large -> E_ARG");
        pl_clear; put8(8'h0F); put8(8'hFF); put16(16'd0); put32(0); for (i = 0; i < 5; i = i + 1) put8(i);
        xact(8'h04, 8'h03, "WR_MEM ragged -> E_LEN");
        pl_clear; put8(1);
        xact(8'h07, 8'h03, "STATUS with payload -> E_LEN");
        pl_clear; xact(8'h55, 8'h02, "unknown cmd -> E_CMD");
        pl_clear; put32(32'd1000);
        xact(8'h09, 8'h06, "SET_BAUD too fast -> E_ARG");

        // bad CRC, then recovery
        pl_clear; put8(8'h11); put8(8'h22);
        send_frame(8'h01, 1'b1);
        recv_frame(ok);
        check(ok && rp_cmd == 8'h81 && rp[0] == 8'h01 && rp_len == 1, "bad CRC -> E_CRC");
        pl_clear; xact(8'h01, 8'h00, "PING after E_CRC");

        // junk before the sync byte is skipped
        uart_put(8'h00); uart_put(8'h13); uart_put(8'hFF);
        pl_clear; put8(8'h5A); xact(8'h01, 8'h00, "PING after junk");
        check(rp_len == 2 && rp[1] == 8'h5A, "PING after junk echo");

        // truncated frame -> inter-byte timeout, then recovery
        uart_put(8'hA5); uart_put(8'h01); uart_put(8'h10);
        repeat (TIMEOUT_CYC + 500) @(posedge clk);
        pl_clear; xact(8'h01, 8'h00, "PING after timeout");

        // oversize frame: payload is drained, then E_LEN
        pl_clear; for (i = 0; i < 2049; i = i + 1) put8(i);
        xact(8'h01, 8'h03, "PING len 2049 -> E_LEN");
        pl_clear; xact(8'h01, 8'h00, "PING after oversize");

        $display("[4] WR_IMEM");
        pl_clear; put16(16'd2);
        for (i = 0; i < 3 * 7; i = i + 1) put64({8'h10 + i[7:0], 24'h0, 32'hC0DE_0000 + i[31:0]});
        xact(8'h03, 8'h00, "WR_IMEM 3 entries");
        for (j = 0; j < 3; j = j + 1) begin
            pl_clear; put8(8'h00); put8(8'h00); put16(16'd0); put32((2 + j) * 8); put16(7);
            xact(8'h05, 8'h00, "RD_MEM IMEM");
            n = 0;
            for (k = 0; k < 7; k = k + 1) begin
                i = j * 7 + k;
                if (get64(1 + 8 * k) !== {8'h10 + i[7:0], 24'h0, 32'hC0DE_0000 + i[31:0]}) n = n + 1;
            end
            check(n == 0, "IMEM lanes 0..6 read back");
        end
        pl_clear; put16(16'd0); for (i = 0; i < 55; i = i + 1) put8(i);
        xact(8'h03, 8'h03, "WR_IMEM ragged -> E_LEN");
        pl_clear; put16(16'd64); for (i = 0; i < 56; i = i + 1) put8(i);
        xact(8'h03, 8'h05, "WR_IMEM past end -> E_RANGE");

        $display("[5] RUN / STATUS / RESET");
        pl_clear; put16(16'd0); put32(32'd50);
        xact(8'h06, 8'h00, "RUN 0 50");
        status_req;
        check(rp[1] == 8'd1, "STATUS busy while running");
        pl_clear; put16(16'd0); put32(32'd5);
        xact(8'h06, 8'h04, "RUN while busy -> E_BUSY");
        pl_clear; put8(8'h0F); put8(8'hFF); put16(16'd0); put32(0); put64(64'h1);
        xact(8'h04, 8'h04, "WR_MEM while busy -> E_BUSY");
        n = 0;
        do begin status_req; n = n + 1; end while (rp[1] != 8'd0 && n < 200);
        check(rp[1] == 8'd0 && rp[2] == 8'd0, "RUN finished OK");
        check(get16(3) == 16'd50 && get32(9) == 32'd50, "RUN pc and steps");

        pl_clear; put16(16'd60); put32(32'd10);
        xact(8'h06, 8'h00, "RUN 60 10");
        n = 0;
        do begin status_req; n = n + 1; end while (rp[1] != 8'd0 && n < 200);
        check(rp[2] == 8'd1 && get32(5) == 32'd64 && get32(9) == 32'd4, "RUN past IMEM -> E_RANGE pc 64");

        pl_clear; put16(16'd0); put32(32'd50);
        xact(8'h06, 8'h00, "RUN 0 50 (to be reset)");
        pl_clear; xact(8'h08, 8'h00, "RESET");
        status_req;
        check(rp[1] == 8'd0 && get32(9) == 32'd0, "RESET stops the core");

        $display("[6] SET_BAUD");
        pl_clear; put32(32'd6912);                       // 1 Mbaud
        xact(8'h09, 8'h00, "SET_BAUD 1M");
        set_rates(1.0e6, 1.0e6);
        pl_clear; for (i = 0; i < 40; i = i + 1) put8(8'hA5 ^ i);
        xact(8'h01, 8'h00, "PING at 1M");
        status_req;
        check(get32(23) == 32'd6912 && rp[27] == 8'd0, "div committed at 1M");

        pl_clear; put32(32'd3456);                       // 2 Mbaud = 13.5 clocks per bit
        xact(8'h09, 8'h00, "SET_BAUD 2M");
        set_rates(2.0e6, 2.0e6);
        pl_clear; for (i = 0; i < 200; i = i + 1) put8($random);
        xact(8'h01, 8'h00, "PING 200 at 2M");
        n = 0; for (i = 0; i < 200; i = i + 1) if (rp[i + 1] !== pl[i]) n = n + 1;
        check(n == 0, "PING echo at 2M");
        wr_test(100, 32, 8'hFF);
        rd_test(100, 32);

        // sender 2.5 % fast / slow
        set_rates(2.05e6, 2.0e6);
        pl_clear; for (i = 0; i < 100; i = i + 1) put8($random);
        xact(8'h01, 8'h00, "PING host +2.5%");
        set_rates(1.95e6, 2.0e6);
        pl_clear; for (i = 0; i < 100; i = i + 1) put8($random);
        xact(8'h01, 8'h00, "PING host -2.5%");
        set_rates(2.0e6, 2.0e6);

        // probation: switch to 3M but never talk at 3M -> reverts to 2M
        pl_clear; put32(32'd2304);
        xact(8'h09, 8'h00, "SET_BAUD 3M (not confirmed)");
        repeat (PROBATION_CYC + 2000) @(posedge clk);
        pl_clear; xact(8'h01, 8'h00, "PING at 2M after revert");
        status_req;
        check(get32(23) == 32'd3456, "div reverted to 2M");

        // statistics: one CRC error, one timeout, no framing errors / overruns
        check(get16(13) == 16'd1, "crc error count 1");
        check(get16(15) == 16'd0, "framing error count 0");
        check(get16(17) == 16'd0, "overrun count 0");
        check(get16(19) == 16'd1, "timeout count 1");
        check(mon_ferr == 0, "no stop-bit errors seen by the monitor");
        pl_clear; put8(8'h01); xact(8'h08, 8'h00, "RESET clear counters");
        status_req;
        check(get16(13) == 16'd0 && get16(19) == 16'd0, "counters cleared");

        // auto-baud measurement: 0x55 -> last rising edge after 9 bits = 9 * 13.5 clocks
        pl_clear; put8(8'h55); xact(8'h01, 8'h00, "PING 0x55");
        status_req;
        check(get16(21) >= 16'd120 && get16(21) <= 16'd124, "meas ~ 121.5 clocks for 0x55");
        $display("    meas = %0d clocks (ideal 121.5)", get16(21));

        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL %0d of %0d checks failed", errors, checks);
        $finish;
    end

    // global watchdog
    initial begin
        #(400.0e6);
        $display("FAIL watchdog timeout");
        $finish;
    end
endmodule

`timescale 1ns/1ps
// tb_top_1pe: the 1-PE board top (mn_top_1pe = brd_host_if + mn_core) driven through its UART pin
// with protocol frames, like mnhost.py on the board (WP21).
//
//   vvp sim.vvp [+script=FILE] [+quiet]
//
// Script (hex fields; mncore/sim/tb/top_1pe/gen_top.py makes it from the corpus regression):
//   N                                   INFO, checked against this design's parameters
//   C                                   RESET frame (the core clears the PE state)
//   I <entry> <448-bit hex>             WR_IMEM of one entry
//   W <space> <loc> <addr> <mask> <data>    WR_MEM of one long word
//   X <pc> <count>                      RUN, then STATUS until the core is idle; prints
//                                       "S <reason> <info> <pc> <steps>"
//   K <reason> <info>                   check the stop record of the last RUN
//   P <pc> <steps>                      check core_pc / steps of the last RUN
//   Q <space> <loc> <addr> <n> <v0> .. <v(n-1)>   RD_MEM of n long words (n <= 256), checked
//   G <space> <loc> <addr> <status>     RD_MEM of 1 long word that must fail with this status code
//   E                                   end
// Every response frame is checked (sync, command, CRC, status OK unless stated). The last line is
// PASS or FAIL.
// Compile with -DTB_FPALU=<0|1|2|3> / -DTB_MAU=<0|1> for the other configurations (default: the
// board configuration FPALU = 3; the default script passes with every FPALU).
`ifndef TB_FPALU
`define TB_FPALU 3
`endif
`ifndef TB_MAU
`define TB_MAU 1
`endif
module tb_top_1pe;
    localparam real CLK_NS = 1000.0 / 27.0;   // 27 MHz
    localparam integer BAUD = 4500000;        // 6 clocks per bit (the board uses 1M .. 3M)

    reg clk = 1'b0;
    always #(CLK_NS / 2.0) clk = ~clk;

    reg  uart_rx = 1'b1;
    wire uart_tx;
    wire [5:0] led;
    reg  btn = 1'b0;

    mn_top_1pe #(
        .CLK_HZ(27000000), .BAUD(BAUD), .TIMEOUT_CYC(20000), .PROBATION_CYC(100000),
        .FPALU(`TB_FPALU), .MAU(`TB_MAU), .LED_STRETCH(4)
    ) dut (
        .clk(clk), .btn_rst(btn), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led)
    );

    // ------------------------------------------------------------------ bookkeeping
    integer errors = 0, checks = 0;
    reg quiet;
    task check(input cond, input [8*80-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 50) $display("  CHECK FAILED: %0s  (t=%0t)", msg, $time);
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
    real bit_ns = 1.0e9 / BAUD;

    task uart_put(input [7:0] b);
        integer i;
        begin
            uart_rx = 1'b0; #(bit_ns);
            for (i = 0; i < 8; i = i + 1) begin uart_rx = b[i]; #(bit_ns); end
            uart_rx = 1'b1; #(bit_ns);
        end
    endtask

    reg [7:0] rxq [0:65535];
    integer   rq_w = 0, rq_r = 0, mon_ferr = 0;
    initial begin : monitor
        reg [7:0] b;
        integer i;
        forever begin
            @(negedge uart_tx);
            #(bit_ns * 1.5);
            for (i = 0; i < 8; i = i + 1) begin b[i] = uart_tx; #(bit_ns); end
            if (uart_tx !== 1'b1) mon_ferr = mon_ferr + 1;
            rxq[rq_w[15:0]] = b;
            rq_w = rq_w + 1;
        end
    end

    // ------------------------------------------------------------------ frames
    reg [7:0] pl [0:4095];      // request payload
    integer   pl_len;
    reg [7:0] rp [0:4095];      // response payload (rp[0] = status)
    integer   rp_len;
    reg [7:0] rp_cmd;

    task put8(input [7:0] v);   begin pl[pl_len] = v; pl_len = pl_len + 1; end endtask
    task put16(input [15:0] v); begin put8(v[7:0]); put8(v[15:8]); end endtask
    task put32(input [31:0] v); begin put16(v[15:0]); put16(v[31:16]); end endtask
    task put64(input [63:0] v); begin put32(v[31:0]); put32(v[63:32]); end endtask
    function [15:0] get16(input integer i); get16 = {rp[i+1], rp[i]}; endfunction
    function [31:0] get32(input integer i); get32 = {rp[i+3], rp[i+2], rp[i+1], rp[i]}; endfunction
    function [63:0] get64(input integer i); get64 = {get32(i+4), get32(i)}; endfunction

    task send_frame(input [7:0] cmd);
        reg [7:0] c;
        integer i;
        begin
            c = crc8(8'd0, cmd);
            uart_put(8'hA5);
            uart_put(cmd);
            c = crc8(c, pl_len[7:0]);  uart_put(pl_len[7:0]);
            c = crc8(c, pl_len[15:8]); uart_put(pl_len[15:8]);
            for (i = 0; i < pl_len; i = i + 1) begin c = crc8(c, pl[i]); uart_put(pl[i]); end
            uart_put(c);
        end
    endtask

    task get_byte(output [7:0] b, output reg ok);
        real waited;
        begin
            waited = 0.0;
            while (rq_r == rq_w && waited < 50.0e6) begin #(200.0); waited = waited + 200.0; end
            ok = (rq_r != rq_w);
            b  = ok ? rxq[rq_r[15:0]] : 8'hxx;
            if (ok) rq_r = rq_r + 1;
        end
    endtask

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

    // send a request, receive its response, check command, status and body length
    task transact(input [7:0] cmd, input [7:0] want_status, input integer want_len);
        reg ok;
        begin
            send_frame(cmd);
            recv_frame(ok);
            check(ok, "response frame");
            check(rp_cmd == (cmd | 8'h80), "response command");
            check(rp_len >= 1 && rp[0] == want_status, "response status");
            if (want_len >= 0) check(rp_len == want_len, "response length");
            if (ok && rp_len >= 1 && rp[0] != want_status)
                $display("  cmd %02x: status %02x, expected %02x", cmd, rp[0], want_status);
        end
    endtask

    // ------------------------------------------------------------------ script
    localparam [7:0] C_PING = 8'h01, C_INFO = 8'h02, C_WR_IMEM = 8'h03, C_WR_MEM = 8'h04,
                     C_RD_MEM = 8'h05, C_RUN = 8'h06, C_STATUS = 8'h07, C_RESET = 8'h08;
    integer fd, rc, i, k, n, polls, nq, nx;
    reg [8*256-1:0] fname;
    reg [8*1024-1:0] line;
    reg [7:0]   c;
    reg [447:0] ent;
    reg [31:0]  a0, a1, a2, a3;
    reg [63:0]  v, got;
    reg [7:0]   st_reason;
    reg [31:0]  st_info, st_steps;
    reg [15:0]  st_pc;
    reg         done_scr, busy;

    initial begin
        if (!$value$plusargs("script=%s", fname)) fname = "mncore/sim/tb/top_1pe/fixed/top.scr";
        quiet = $test$plusargs("quiet");
        fd = $fopen(fname, "r");
        if (fd == 0) begin
            $display("FAIL cannot open script %0s", fname);
            $finish;
        end
        nq = 0; nx = 0;
        // power-on reset (the POR counter) and the core's clear after reset
        repeat (200) @(posedge clk);
        pl_len = 0;
        transact(C_PING, 8'h00, 1);
        st_reason = 0; st_info = 0; st_pc = 0; st_steps = 0;
        done_scr = 1'b0;
        while (!done_scr && !$feof(fd)) begin
            rc = $fscanf(fd, " %c", c);
            if (rc != 1) begin
                done_scr = 1'b1;
            end else begin
                case (c)
                    "#": rc = $fgets(line, fd);
                    "E": done_scr = 1'b1;
                    "N": begin
                        pl_len = 0;
                        transact(C_INFO, 8'h00, 89);
                        check(rp[1] == 8'd1, "INFO protocol version");
                        check(rp[2] == 8'h02, "INFO design id");
                        check(get32(5) == 32'd27000000, "INFO clock");
                        check(get16(13) == 16'd512, "INFO imem depth");
                        check({rp[15], rp[16], rp[17], rp[18], rp[19]} == 40'h0101010101, "INFO topology");
                        check(rp[20] == 8'h01, "INFO flags");
                        check(get32(21 + 0) == 32'd4096 && get32(21 + 4) == 32'd512 && get32(21 + 8) == 32'd512 &&
                              get32(21 + 12) == 32'd256 && get32(21 + 16) == 32'd256 && get32(21 + 20) == 32'd8 &&
                              get32(21 + 24) == 32'd0 && get32(21 + 36) == 32'd0, "INFO space depths");
                    end
                    "C": begin
                        pl_len = 0;
                        transact(C_RESET, 8'h00, 1);
                    end
                    "I": begin
                        rc = $fscanf(fd, "%h %h", a0, ent);
                        pl_len = 0;
                        put16(a0[15:0]);
                        for (i = 0; i < 7; i = i + 1) put64(ent[64*i +: 64]);
                        transact(C_WR_IMEM, 8'h00, 1);
                    end
                    "W": begin
                        rc = $fscanf(fd, "%h %h %h %h %h", a0, a1, a2, a3, v);
                        pl_len = 0;
                        put8(a0[7:0]); put8(a3[7:0]); put16(a1[15:0]); put32(a2); put64(v);
                        transact(C_WR_MEM, 8'h00, 1);
                    end
                    "X": begin
                        rc = $fscanf(fd, "%h %h", a0, a1);
                        pl_len = 0;
                        put16(a0[15:0]); put32(a1);
                        transact(C_RUN, 8'h00, 1);
                        busy = 1'b1;
                        polls = 0;
                        while (busy && polls < 100000) begin
                            pl_len = 0;
                            transact(C_STATUS, 8'h00, 28);
                            busy = rp[1][0];
                            polls = polls + 1;
                        end
                        check(!busy, "RUN finished");
                        st_reason = rp[2]; st_pc = get16(3); st_info = get32(5); st_steps = get32(9);
                        check(get16(13) == 16'd0 && get16(15) == 16'd0 && get16(17) == 16'd0 &&
                              get16(19) == 16'd0, "link error counters");
                        nx = nx + 1;
                        if (!quiet) $display("S %0h %0h %0h %0h", st_reason, st_info, st_pc, st_steps);
                    end
                    "K": begin
                        rc = $fscanf(fd, "%h %h", a0, a1);
                        check(st_reason == a0[7:0] && st_info == a1, "stop record");
                        if (st_reason != a0[7:0] || st_info != a1)
                            $display("  stop: reason %0h info %0h, expected %0h %0h", st_reason, st_info, a0, a1);
                    end
                    "P": begin
                        rc = $fscanf(fd, "%h %h", a0, a1);
                        check(st_pc == a0[15:0] && st_steps == a1, "stop pc / steps");
                        if (st_pc != a0[15:0] || st_steps != a1)
                            $display("  stop: pc %0h steps %0h, expected %0h %0h", st_pc, st_steps, a0, a1);
                    end
                    "Q": begin
                        rc = $fscanf(fd, "%h %h %h %h", a0, a1, a2, a3);
                        n = a3;
                        pl_len = 0;
                        put8(a0[7:0]); put8(8'h00); put16(a1[15:0]); put32(a2); put16(n[15:0]);
                        transact(C_RD_MEM, 8'h00, 1 + 8 * n);
                        for (k = 0; k < n; k = k + 1) begin
                            rc = $fscanf(fd, "%h", v);
                            got = get64(1 + 8 * k);
                            nq = nq + 1;
                            check(got === v, "RD_MEM value");
                            if (got !== v && errors <= 50)
                                $display("  MISMATCH space %0h loc %0h addr %0h: got %016h expected %016h",
                                         a0, a1, a2 + k, got, v);
                        end
                    end
                    "G": begin
                        rc = $fscanf(fd, "%h %h %h %h", a0, a1, a2, a3);
                        pl_len = 0;
                        put8(a0[7:0]); put8(8'h00); put16(a1[15:0]); put32(a2); put16(16'd1);
                        transact(C_RD_MEM, a3[7:0], -1);
                    end
                    default: begin
                        $display("ERR unknown script command '%c'", c);
                        errors = errors + 1;
                        rc = $fgets(line, fd);
                    end
                endcase
            end
        end
        $fclose(fd);
        check(mon_ferr == 0, "no framing errors on uart_tx");
        if (!quiet) $display("tb_top_1pe: %0d checks (%0d long words read, %0d RUNs), %0d errors, t = %0t ns",
                             checks, nq, nx, errors, $time);
        if (errors == 0) $display("PASS %0d checks", checks);
        else $display("FAIL %0d errors", errors);
        $finish;
    end
endmodule

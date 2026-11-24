// Self-checking testbench for mn_ram_tdp: each port randomly writes or reads every clock.
// Cross-port same-address accesses with a write are avoided (undefined on the hardware).
`timescale 1ns/1ps
module tb_mn_ram_tdp;
    parameter W    = 64;
    parameter AW   = 8;
    parameter NOPS = 5000;

    localparam D = 1 << AW;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg           en_a, we_a, en_b, we_b;
    reg  [AW-1:0] addr_a, addr_b;
    reg  [W-1:0]  wdata_a, wdata_b;
    wire [W-1:0]  rdata_a, rdata_b;

    mn_ram_tdp #(.W(W), .AW(AW)) dut (
        .clk(clk),
        .en_a(en_a), .we_a(we_a), .addr_a(addr_a), .wdata_a(wdata_a), .rdata_a(rdata_a),
        .en_b(en_b), .we_b(we_b), .addr_b(addr_b), .wdata_b(wdata_b), .rdata_b(rdata_b));

    reg [W-1:0] model [0:D-1];
    reg [W-1:0] ea, eb;
    integer     errors = 0, checks = 0, t;
    reg         armed = 1'b0;

    function [W-1:0] rnd_word;
        input integer dummy;
        integer q;
        begin
            rnd_word = 0;
            for (q = 0; q < W; q = q + 32) rnd_word = (rnd_word << 32) ^ {$random};
        end
    endfunction

    always @(posedge clk) begin
        if (en_a && !we_a) ea <= model[addr_a];
        if (en_b && !we_b) eb <= model[addr_b];
        if (en_a && we_a) model[addr_a] <= wdata_a;
        if (en_b && we_b) model[addr_b] <= wdata_b;
    end

    always @(negedge clk) begin
        if (armed) begin
            checks = checks + 1;
            if (rdata_a !== ea || rdata_b !== eb) begin
                errors = errors + 1;
                if (errors <= 5) $display("mismatch t=%0t a=%h/%h b=%h/%h", $time, rdata_a, ea, rdata_b, eb);
            end
        end
    end

    initial begin
        en_a = 0; we_a = 0; en_b = 0; we_b = 0; addr_a = 0; addr_b = 0; wdata_a = 0; wdata_b = 0;
        // fill: port A writes even, port B writes odd addresses
        for (t = 0; t < D; t = t + 2) begin
            @(negedge clk);
            en_a = 1; we_a = 1; addr_a = t[AW-1:0];       wdata_a = rnd_word(0);
            en_b = 1; we_b = 1; addr_b = t[AW-1:0] + 1'b1; wdata_b = rnd_word(0);
        end
        @(negedge clk);
        we_a = 0; we_b = 0; addr_a = 0; addr_b = 1;
        @(negedge clk);
        @(negedge clk);
        armed = 1'b1;
        for (t = 0; t < NOPS; t = t + 1) begin
            @(posedge clk);
            #1;
            en_a = ($random % 4) != 0;  we_a = $random;  addr_a = $random;  wdata_a = rnd_word(0);
            en_b = ($random % 4) != 0;  we_b = $random;  addr_b = $random;  wdata_b = rnd_word(0);
            if (en_a && en_b && (we_a || we_b) && addr_a == addr_b) addr_b = addr_b + 1'b1;
        end
        @(negedge clk);
        if (errors == 0) $display("PASS tb_mn_ram_tdp W=%0d AW=%0d checks=%0d", W, AW, checks);
        else $display("FAIL tb_mn_ram_tdp %0d mismatches of %0d", errors, checks);
        $finish;
    end
endmodule

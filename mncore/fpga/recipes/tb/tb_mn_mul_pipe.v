// Self-checking testbench for mn_mul_pipe: random operands every clock, random ce stalls,
// checks the product and the documented latency (IREG + PREG + NTR + 1 enabled clocks).
`timescale 1ns/1ps
module tb_mn_mul_pipe;
    parameter WA   = 53;
    parameter WB   = 53;
    parameter TW   = 18;
    parameter IREG = 1;
    parameter PREG = 1;
    parameter LVLS = 1;
    parameter NOPS = 20000;

    localparam WP = WA + WB;
    localparam NA = (WA + TW - 1) / TW;
    localparam NB = (WB + TW - 1) / TW;
    localparam NP = NA * NB;

    function integer f_clog2;
        input integer v;
        integer tt;
        begin
            f_clog2 = 0;
            tt = v - 1;
            while (tt > 0) begin
                f_clog2 = f_clog2 + 1;
                tt = tt >> 1;
            end
        end
    endfunction

    localparam L   = f_clog2(NP);
    localparam NTR = (LVLS > 0 && L > 1) ? (L - 1) / LVLS : 0;
    localparam LAT = IREG + PREG + NTR + 1;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg           ce;
    reg  [WA-1:0] a;
    reg  [WB-1:0] b;
    wire [WP-1:0] p;

    mn_mul_pipe #(.WA(WA), .WB(WB), .TW(TW), .IREG(IREG), .PREG(PREG), .LVLS(LVLS)) dut (
        .clk(clk), .ce(ce), .a(a), .b(b), .p(p));

    // reference delay line, advanced only on enabled clocks
    reg [WP-1:0] q [0:LAT];
    reg          v [0:LAT];
    integer      errors = 0, checks = 0, t, k;

    function [WA-1:0] rnd_a;
        input integer mode;
        integer qq;
        begin
            rnd_a = 0;
            for (qq = 0; qq < WA; qq = qq + 32) rnd_a = (rnd_a << 32) ^ {$random};
            if (mode == 1) rnd_a = {WA{1'b1}};          // all ones (largest product)
            if (mode == 2) rnd_a = 0;
        end
    endfunction

    function [WB-1:0] rnd_b;
        input integer mode;
        integer qq;
        begin
            rnd_b = 0;
            for (qq = 0; qq < WB; qq = qq + 32) rnd_b = (rnd_b << 32) ^ {$random};
            if (mode == 1) rnd_b = {WB{1'b1}};
            if (mode == 2) rnd_b = 0;
        end
    endfunction

    always @(posedge clk) begin
        if (ce) begin
            q[0] <= {{(WP-WA){1'b0}}, a} * {{(WP-WB){1'b0}}, b};
            v[0] <= 1'b1;
            for (k = 1; k <= LAT; k = k + 1) begin
                q[k] <= q[k-1];
                v[k] <= v[k-1];
            end
        end
    end

    always @(negedge clk) begin
        if (v[LAT-1] === 1'b1) begin
            checks = checks + 1;
            if (p !== q[LAT-1]) begin
                errors = errors + 1;
                if (errors <= 5) $display("mismatch t=%0t p=%h exp=%h", $time, p, q[LAT-1]);
            end
        end
    end

    integer mode;
    initial begin
        for (k = 0; k <= LAT; k = k + 1) v[k] = 1'b0;
        ce = 0; a = 0; b = 0;
        for (t = 0; t < NOPS; t = t + 1) begin
            @(posedge clk);
            #1;
            ce   = ($random % 5) != 0;
            mode = (($random & 15) == 0) ? 1 : ((($random & 31) == 0) ? 2 : 0);
            a    = rnd_a(mode);
            b    = rnd_b(($random & 7) == 0 ? 1 : 0);
        end
        @(negedge clk);
        if (errors == 0 && checks > NOPS / 2)
            $display("PASS tb_mn_mul_pipe %0dx%0d TW=%0d IREG=%0d PREG=%0d LVLS=%0d LAT=%0d checks=%0d",
                     WA, WB, TW, IREG, PREG, LVLS, LAT, checks);
        else $display("FAIL tb_mn_mul_pipe %0d mismatches of %0d checks", errors, checks);
        $finish;
    end
endmodule

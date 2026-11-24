// Self-checking testbench for mn_ram_2r1w: random writes and two independent reads per clock.
`timescale 1ns/1ps
module tb_mn_ram_2r1w;
    parameter W    = 64;
    parameter AW   = 8;
    parameter NWE  = 2;
    parameter OREG = 0;
    parameter NOPS = 5000;

    localparam D  = 1 << AW;
    localparam LW = W / NWE;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  [NWE-1:0] we;
    reg  [AW-1:0]  waddr, raddr0, raddr1;
    reg  [W-1:0]   wdata;
    reg            re0, re1;
    wire [W-1:0]   rdata0, rdata1;

    mn_ram_2r1w #(.W(W), .AW(AW), .NWE(NWE), .OREG(OREG)) dut (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re0(re0), .raddr0(raddr0), .rdata0(rdata0),
        .re1(re1), .raddr1(raddr1), .rdata1(rdata1));

    reg [W-1:0] model [0:D-1];
    reg [W-1:0] a0, a1, b0, b1;   // expected outputs: a* = BSRAM register, b* = fabric register
    reg         re0_d, re1_d;
    integer     errors = 0, checks = 0, t, k;
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
        if (re0) a0 <= model[raddr0];
        if (re1) a1 <= model[raddr1];
        re0_d <= re0;
        re1_d <= re1;
        if (re0_d) b0 <= a0;
        if (re1_d) b1 <= a1;
        for (k = 0; k < NWE; k = k + 1)
            if (we[k]) model[waddr][k*LW +: LW] <= wdata[k*LW +: LW];
    end

    always @(negedge clk) begin
        if (armed) begin
            checks = checks + 1;
            if (rdata0 !== ((OREG != 0) ? b0 : a0) || rdata1 !== ((OREG != 0) ? b1 : a1)) begin
                errors = errors + 1;
                if (errors <= 5) $display("mismatch t=%0t r0=%h r1=%h", $time, rdata0, rdata1);
            end
        end
    end

    initial begin
        we = 0; waddr = 0; raddr0 = 0; raddr1 = 0; wdata = 0; re0 = 0; re1 = 0;
        re0_d = 0; re1_d = 0;
        for (t = 0; t < D; t = t + 1) begin
            @(negedge clk);
            we = {NWE{1'b1}}; waddr = t[AW-1:0]; wdata = rnd_word(0);
        end
        @(negedge clk);
        we = 0; re0 = 1; re1 = 1;
        @(negedge clk);
        @(negedge clk);
        armed = 1'b1;
        for (t = 0; t < NOPS; t = t + 1) begin
            @(posedge clk);
            #1;
            we     = $random;
            waddr  = $random;
            wdata  = rnd_word(0);
            re0    = ($random % 4) != 0;
            re1    = ($random % 4) != 0;
            raddr0 = $random;
            raddr1 = ($random % 8 == 0) ? raddr0 : $random;   // sometimes both ports read one address
            if (|we && raddr0 == waddr) raddr0 = raddr0 + 1'b1;
            if (|we && raddr1 == waddr) raddr1 = raddr1 + 1'b1;
        end
        @(negedge clk);
        if (errors == 0) $display("PASS tb_mn_ram_2r1w W=%0d AW=%0d NWE=%0d OREG=%0d checks=%0d",
                                  W, AW, NWE, OREG, checks);
        else $display("FAIL tb_mn_ram_2r1w %0d mismatches of %0d", errors, checks);
        $finish;
    end
endmodule

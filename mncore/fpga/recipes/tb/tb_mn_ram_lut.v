// Self-checking testbench for mn_ram_lut: synchronous write, asynchronous reads on NR ports.
`timescale 1ns/1ps
module tb_mn_ram_lut;
    parameter W    = 64;
    parameter AW   = 3;
    parameter NR   = 2;
    parameter NOPS = 3000;

    localparam D = 1 << AW;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg              we;
    reg  [AW-1:0]    waddr;
    reg  [W-1:0]     wdata;
    reg  [NR*AW-1:0] raddr;
    wire [NR*W-1:0]  rdata;

    mn_ram_lut #(.W(W), .AW(AW), .NR(NR)) dut (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata), .raddr(raddr), .rdata(rdata));

    reg [W-1:0] model [0:D-1];
    integer     errors = 0, checks = 0, t, r;

    function [W-1:0] rnd_word;
        input integer dummy;
        integer q;
        begin
            rnd_word = 0;
            for (q = 0; q < W; q = q + 32) rnd_word = (rnd_word << 32) ^ {$random};
        end
    endfunction

    always @(posedge clk) begin
        if (we) model[waddr] <= wdata;
    end

    initial begin
        we = 0; waddr = 0; wdata = 0; raddr = 0;
        for (t = 0; t < D; t = t + 1) begin
            @(negedge clk);
            we = 1; waddr = t[AW-1:0]; wdata = rnd_word(0);
        end
        for (t = 0; t < NOPS; t = t + 1) begin
            @(negedge clk);
            // asynchronous read: check the current contents, including the word written last edge
            for (r = 0; r < NR; r = r + 1) begin
                checks = checks + 1;
                if (rdata[r*W +: W] !== model[raddr[r*AW +: AW]]) begin
                    errors = errors + 1;
                    if (errors <= 5) $display("mismatch t=%0t port=%0d", $time, r);
                end
            end
            we = $random; waddr = $random; wdata = rnd_word(0); raddr = {NR{$random}};
            #1;
            for (r = 0; r < NR; r = r + 1) begin
                checks = checks + 1;
                if (rdata[r*W +: W] !== model[raddr[r*AW +: AW]]) begin
                    errors = errors + 1;
                    if (errors <= 5) $display("mismatch(after addr change) t=%0t port=%0d", $time, r);
                end
            end
        end
        if (errors == 0) $display("PASS tb_mn_ram_lut W=%0d AW=%0d NR=%0d checks=%0d", W, AW, NR, checks);
        else $display("FAIL tb_mn_ram_lut %0d mismatches of %0d", errors, checks);
        $finish;
    end
endmodule

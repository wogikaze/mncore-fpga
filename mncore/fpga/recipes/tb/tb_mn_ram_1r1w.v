// Self-checking testbench for mn_ram_1r1w (and mn_ram_1r1w_be when BE = 1).
// Random writes / reads against a reference model. Same-address read+write in one clock is
// avoided because the hardware result is undefined (see the recipe header).
`timescale 1ns/1ps
module tb_mn_ram_1r1w;
    parameter W    = 64;
    parameter AW   = 8;
    parameter NWE  = 2;
    parameter OREG = 0;
    parameter BE   = 0;      // 1: test mn_ram_1r1w_be (byte enables, NWE ignored, OREG must be 0)
    parameter NOPS = 5000;

    localparam D   = 1 << AW;
    localparam NL  = (BE != 0) ? W / 8 : NWE;   // number of write lanes
    localparam LW  = W / NL;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  [NL-1:0] we;
    reg  [AW-1:0] waddr, raddr;
    reg  [W-1:0]  wdata;
    reg           re;
    wire [W-1:0]  rdata;

    generate
        if (BE != 0) begin : g_be
            mn_ram_1r1w_be #(.W(W), .AW(AW)) dut (
                .clk(clk), .be(we), .waddr(waddr), .wdata(wdata),
                .re(re), .raddr(raddr), .rdata(rdata));
        end else begin : g_lane
            mn_ram_1r1w #(.W(W), .AW(AW), .NWE(NWE), .OREG(OREG)) dut (
                .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
                .re(re), .raddr(raddr), .rdata(rdata));
        end
    endgenerate

    reg [W-1:0] model [0:D-1];
    reg [W-1:0] st0, st1;     // expected BSRAM output register / fabric output register
    reg         re_d;
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

    // reference: update on the same edge as the DUT
    always @(posedge clk) begin
        if (re) st0 <= model[raddr];
        re_d <= re;
        if (re_d) st1 <= st0;
        for (k = 0; k < NL; k = k + 1)
            if (we[k]) model[waddr][k*LW +: LW] <= wdata[k*LW +: LW];
    end

    // compare in the middle of the cycle
    always @(negedge clk) begin
        if (armed) begin
            checks = checks + 1;
            if (rdata !== ((OREG != 0) ? st1 : st0)) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("mismatch t=%0t rdata=%h exp=%h", $time, rdata, (OREG != 0) ? st1 : st0);
            end
        end
    end

    initial begin
        we = 0; waddr = 0; raddr = 0; wdata = 0; re = 0; re_d = 0;
        // fill every word so that reads never return X
        for (t = 0; t < D; t = t + 1) begin
            @(negedge clk);
            we = {NL{1'b1}}; waddr = t[AW-1:0]; wdata = rnd_word(0); re = 0;
        end
        @(negedge clk);
        we = 0;
        re = 1; raddr = 0;
        @(negedge clk);
        @(negedge clk);
        armed = 1'b1;
        for (t = 0; t < NOPS; t = t + 1) begin
            @(posedge clk);
            #1;
            we    = $random;
            waddr = $random;
            wdata = rnd_word(0);
            re    = ($random % 4) != 0;
            raddr = $random;
            if (|we && raddr == waddr) raddr = raddr + 1'b1;   // no same-address collision
        end
        @(negedge clk);
        if (errors == 0) $display("PASS tb_mn_ram_1r1w W=%0d AW=%0d NL=%0d OREG=%0d BE=%0d checks=%0d",
                                  W, AW, NL, OREG, BE, checks);
        else $display("FAIL tb_mn_ram_1r1w %0d mismatches of %0d", errors, checks);
        $finish;
    end
endmodule

`timescale 1ns/1ps
module tb_selftest;
    reg clk = 0, rst = 1, en = 0;
    wire [7:0] q;
    mn_selftest_counter #(.W(8)) dut (.clk(clk), .rst(rst), .en(en), .q(q));
    always #5 clk = ~clk;
    integer i;
    initial begin
        @(posedge clk); @(posedge clk);
        rst <= 0; en <= 1;
        for (i = 0; i < 300; i = i + 1) @(posedge clk);
        en <= 0;
        @(posedge clk); #1;
        if (q !== 8'd44) begin
            $display("FAIL q=%0d expected 44", q);
        end else begin
            $display("PASS");
        end
        $finish;
    end
endmodule

// tb_l1bm_rrn: mn_l1bm_rrn alone against the rrn vectors (tb_l1bm_rrnchk). Last line PASS / FAIL.
//   python mncore/tools/simrun.py l1bm --top tb_l1bm_rrn
//   vvp -n mncore/sim/tb/l1bm/build/sim.vvp +rrndir=mncore/sim/vectors/rrn   (all 186,396 rows)
`timescale 1ns/1ps
`default_nettype none
module tb_l1bm_rrn;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg go = 1'b0;
    wire fin;
    wire [31:0] nrows, nbad;
    tb_l1bm_rrnchk u_chk (.clk(clk), .go(go), .fin(fin), .nrows(nrows), .nbad(nbad));
    initial begin
        #20 go = 1'b1;
        wait (fin);
        if (nbad == 0 && nrows > 0) $display("PASS");
        else $display("FAIL rrn: %0d of %0d rows", nbad, nrows);
        $finish;
    end
endmodule
`default_nettype wire

// tb_l2bm: the WP32 unit testbench (python mncore/tools/simrun.py l2bm).
//
//   1. fixed/l1.tst on mn_l2bm with N_L1B = 1 (the M2 topology: L1B 0 only, its MAB 0 with the PE
//      stub), with the reduction network (RRN = 1) and with the small one of N_L1B = 1 (RRN = 2)
//   2. fixed/l8.tst on N_L1B = 8 (a whole L2B, L2BM instructions only)
// The tests are official-emulator results (gen_tests.py). +only=l1|l8 runs one part; +l1=<file> /
// +l8=<file> replace the test files. Last line PASS / FAIL.
`timescale 1ns/1ps
`default_nettype none
module tb_l2bm;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg go1 = 1'b0, go2 = 1'b0, go8 = 1'b0;
    wire fin1, fin2, fin8;
    wire [31:0] nt1, nf1, nt2, nf2, nt8, nf8;

    tb_l2bm_env #(.N_L1B(1), .RRN(1), .DAR(1), .TESTS("mncore/sim/tb/l2bm/fixed/l1.tst"), .PARG("l1=%s"),
                  .TAG("b1/l1")) u_e1 (.clk(clk), .go(go1), .fin(fin1), .ntests(nt1), .nfail(nf1));
    tb_l2bm_env #(.N_L1B(1), .RRN(2), .DAR(1), .TESTS("mncore/sim/tb/l2bm/fixed/l1.tst"), .PARG("l1=%s"),
                  .TAG("b1rrn2/l1")) u_e2 (.clk(clk), .go(go2), .fin(fin2), .ntests(nt2), .nfail(nf2));
    tb_l2bm_env #(.N_L1B(8), .RRN(1), .DAR(1), .TESTS("mncore/sim/tb/l2bm/fixed/l8.tst"), .PARG("l8=%s"),
                  .TAG("b8/l8")) u_e8 (.clk(clk), .go(go8), .fin(fin8), .ntests(nt8), .nfail(nf8));

    reg [8*8-1:0] only;
    reg run1, run8;
    initial begin
        if (!$value$plusargs("only=%s", only)) only = "all";
        run1 = (only == "all") || (only == "l1");
        run8 = (only == "all") || (only == "l8");
        // the environments are separate units and run at the same time
        #20;
        if (run1) begin go1 = 1'b1; go2 = 1'b1; end
        if (run8) go8 = 1'b1;
        if (run1) begin wait (fin1); wait (fin2); end
        if (run8) wait (fin8);
        $display("N_L1B = 1, RRN = 1: %0d tests (fixed/l1.tst), %0d failed", run1 ? nt1 : 0, run1 ? nf1 : 0);
        $display("N_L1B = 1, RRN = 2: %0d tests (fixed/l1.tst), %0d failed", run1 ? nt2 : 0, run1 ? nf2 : 0);
        $display("N_L1B = 8, RRN = 1: %0d tests (fixed/l8.tst), %0d failed", run8 ? nt8 : 0, run8 ? nf8 : 0);
        if ((!run1 || (nf1 == 0 && nt1 > 0 && nf2 == 0 && nt2 > 0)) && (!run8 || (nf8 == 0 && nt8 > 0)))
            $display("PASS");
        else
            $display("FAIL L2BM unit tests");
        $finish;
    end
endmodule
`default_nettype wire

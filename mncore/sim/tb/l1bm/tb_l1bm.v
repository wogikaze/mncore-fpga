// tb_l1bm: the WP31 unit testbench (python mncore/tools/simrun.py l1bm).
//
//   1. fixed/m1.tst on mn_l1bm with N_MAB = 1 (the M2 topology: MAB 0 only; other MABs send 0),
//      with the reduction network (RRN = 1) and with the small one of N_MAB = 1 (RRN = 2)
//   2. fixed/m1.tst and fixed/m16.tst on N_MAB = 16 (a whole L1B: 64 PEs)
//   3. mn_l1bm_rrn on the rrn vectors (vectors_fixed; +rrndir=mncore/sim/vectors/rrn for all)
// The tests are official-emulator results (gen_tests.py). +only=m1|m16|rrn runs one part;
// +m1=<file> / +m16=<file> replace the test files. Last line PASS / FAIL.
`timescale 1ns/1ps
`default_nettype none
module tb_l1bm;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg go1 = 1'b0, go2 = 1'b0, go16a = 1'b0, go16b = 1'b0, gor = 1'b0;
    wire fin1, fin2, fin16a, fin16b, finr;
    wire [31:0] nt1, nf1, nt2, nf2, nt16a, nf16a, nt16b, nf16b, nrows, nbad;

    tb_l1bm_env #(.N_MAB(1), .RRN(1), .TESTS("mncore/sim/tb/l1bm/fixed/m1.tst"), .PARG("m1=%s"),
                  .TAG("n1/m1")) u_e1 (.clk(clk), .go(go1), .fin(fin1), .ntests(nt1), .nfail(nf1));
    tb_l1bm_env #(.N_MAB(1), .RRN(2), .TESTS("mncore/sim/tb/l1bm/fixed/m1.tst"), .PARG("m1=%s"),
                  .TAG("n1rrn2/m1")) u_e2 (.clk(clk), .go(go2), .fin(fin2), .ntests(nt2), .nfail(nf2));
    tb_l1bm_env #(.N_MAB(16), .RRN(1), .TESTS("mncore/sim/tb/l1bm/fixed/m1.tst"), .PARG("m1=%s"),
                  .TAG("n16/m1")) u_e16a (.clk(clk), .go(go16a), .fin(fin16a), .ntests(nt16a), .nfail(nf16a));
    tb_l1bm_env #(.N_MAB(16), .RRN(1), .TESTS("mncore/sim/tb/l1bm/fixed/m16.tst"), .PARG("m16=%s"),
                  .TAG("n16/m16")) u_e16b (.clk(clk), .go(go16b), .fin(fin16b), .ntests(nt16b), .nfail(nf16b));
    tb_l1bm_rrnchk u_rrn (.clk(clk), .go(gor), .fin(finr), .nrows(nrows), .nbad(nbad));

    reg [8*8-1:0] only;
    reg run1, run16, runr;
    initial begin
        if (!$value$plusargs("only=%s", only)) only = "all";
        run1  = (only == "all") || (only == "m1");
        run16 = (only == "all") || (only == "m16");
        runr  = (only == "all") || (only == "rrn");
        // the environments are separate units and run at the same time
        #20;
        if (run1) begin go1 = 1'b1; go2 = 1'b1; end
        if (run16) begin go16a = 1'b1; go16b = 1'b1; end
        if (runr) gor = 1'b1;
        if (run1) begin wait (fin1); wait (fin2); end
        if (run16) begin wait (fin16a); wait (fin16b); end
        if (runr) wait (finr);
        $display("N_MAB = 1 , RRN = 1: %0d tests (fixed/m1.tst), %0d failed", run1 ? nt1 : 0, run1 ? nf1 : 0);
        $display("N_MAB = 1 , RRN = 2: %0d tests (fixed/m1.tst), %0d failed", run1 ? nt2 : 0, run1 ? nf2 : 0);
        $display("N_MAB = 16, RRN = 1: %0d tests (fixed/m1.tst + fixed/m16.tst), %0d failed",
                 run16 ? nt16a + nt16b : 0, run16 ? nf16a + nf16b : 0);
        $display("rrn vectors        : %0d rows, %0d mismatches", runr ? nrows : 0, runr ? nbad : 0);
        if ((!run1 || (nf1 == 0 && nt1 > 0 && nf2 == 0 && nt2 > 0)) &&
            (!run16 || (nf16a == 0 && nf16b == 0 && nt16a > 0 && nt16b > 0)) &&
            (!runr || (nbad == 0 && nrows > 0)))
            $display("PASS");
        else
            $display("FAIL L1BM unit tests");
        $finish;
    end
endmodule
`default_nettype wire

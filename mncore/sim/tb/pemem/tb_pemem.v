// tb_pemem: WP14 testbench. Runs build/tests.hex (gen_tests.py: programs assembled with the
// official assemble3, expected values from the official emulator) on two instances:
//   d0: mn_pe_mem (BSRAM store)
//   d1: mn_pe_lsu with a store that stalls and answers late at random, and random stalls
//       of the core's results
// Prints PASS or FAIL <reason> as the last line.
`timescale 1ns/1ps
module tb_pemem;
    localparam NREC = 1 << 17;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg [511:0] rec [0:NREC-1];
    integer nrec;

    wire    f0, f1;
    integer nf0, nf1, nc0, nc1, ne0, ne1, nt0, nt1, nr0, nr1, nk0, nk1;
    tb_pemem_drv #(.SLOW(0), .SEED(11)) d0 (
        .clk(clk), .rst(rst), .finished(f0), .nfail(nf0), .nchk(nc0), .nexec(ne0),
        .ntrap(nt0), .nrmw_steps(nr0), .nclk(nk0));
    tb_pemem_drv #(.SLOW(1), .SEED(23)) d1 (
        .clk(clk), .rst(rst), .finished(f1), .nfail(nf1), .nchk(nc1), .nexec(ne1),
        .ntrap(nt1), .nrmw_steps(nr1), .nclk(nk1));

    integer i;
    initial begin
        for (i = 0; i < NREC; i = i + 1) rec[i] = 512'd0;   // op 0 = END after the file
        $readmemh("mncore/sim/tb/pemem/build/tests.hex", rec);
        nrec = 0;
        while (nrec < NREC && rec[nrec][511:504] != 8'd0) nrec = nrec + 1;
        $display("tb_pemem: %0d records", nrec);
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        wait (f0 && f1);
        $display("bsram: steps %0d (rmw %0d), traps %0d, checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne0, nr0, nt0, nc0, nf0, nk0 / ne0, (nk0 * 100 / ne0) % 100);
        $display("slow : steps %0d (rmw %0d), traps %0d, checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne1, nr1, nt1, nc1, nf1, nk1 / ne1, (nk1 * 100 / ne1) % 100);
        $display("time %0t", $time);
        if (nrec == 0)
            $display("FAIL no records (run gen_tests.py first)");
        else if (nf0 != 0 || nf1 != 0)
            $display("FAIL %0d + %0d mismatches", nf0, nf1);
        else if (nc0 == 0 || nc0 != nc1 || ne0 != ne1)
            $display("FAIL check counts differ (%0d/%0d, %0d/%0d)", nc0, nc1, ne0, ne1);
        else
            $display("PASS %0d steps, %0d checks on each instance", ne0, nc0);
        $finish;
    end
endmodule

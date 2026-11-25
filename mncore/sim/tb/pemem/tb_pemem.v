// tb_pemem: WP14 testbench. Runs build/tests.hex (gen_tests.py: programs assembled with the
// official assemble3, expected values from the official emulator) on these instances:
//   d0: mn_pe_mem (BSRAM store)
//   d1: mn_pe_lsu with a store that stalls and answers late at random, and random stalls
//       of the core's results
//   d2, d3: the same with the shared read buffer (RBS = 1, WP21)
//   d4, d5: mn_pe_lsu with NPE = 4 + mn_pe_store with NPE = 4, RBS = 1 / 0 (WP35): per-PE
//       T, mask registers and $mb / $nb; junk in the other PEs is checked (tb_pemem_drv)
// Prints PASS or FAIL <reason> as the last line.
`timescale 1ns/1ps
module tb_pemem;
    localparam NREC = 1 << 17;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg [511:0] rec [0:NREC-1];
    integer nrec;

    wire    f0, f1, f2, f3;
    integer nf0, nf1, nc0, nc1, ne0, ne1, nt0, nt1, nr0, nr1, nk0, nk1;
    integer nf2, nf3, nc2, nc3, ne2, ne3, nt2, nt3, nr2, nr3, nk2, nk3;
    integer nf4, nf5, nc4, nc5, ne4, ne5, nt4, nt5, nr4, nr5, nk4, nk5;
    integer nx0, nx1, nx2, nx3, nx4, nx5;
    wire    f4, f5;
    tb_pemem_drv #(.SLOW(0), .SEED(11)) d0 (
        .clk(clk), .rst(rst), .finished(f0), .nfail(nf0), .nchk(nc0), .nexec(ne0),
        .ntrap(nt0), .nrmw_steps(nr0), .nclk(nk0), .nxchk(nx0));
    tb_pemem_drv #(.SLOW(1), .SEED(23)) d1 (
        .clk(clk), .rst(rst), .finished(f1), .nfail(nf1), .nchk(nc1), .nexec(ne1),
        .ntrap(nt1), .nrmw_steps(nr1), .nclk(nk1), .nxchk(nx1));
    // WP21: the same with the shared read buffer (mn_pe_lsu RBS = 1, used by mn_pe_core)
    tb_pemem_drv #(.SLOW(0), .SEED(37), .RBS(1)) d2 (
        .clk(clk), .rst(rst), .finished(f2), .nfail(nf2), .nchk(nc2), .nexec(ne2),
        .ntrap(nt2), .nrmw_steps(nr2), .nclk(nk2), .nxchk(nx2));
    tb_pemem_drv #(.SLOW(1), .SEED(41), .RBS(1)) d3 (
        .clk(clk), .rst(rst), .finished(f3), .nfail(nf3), .nchk(nc3), .nexec(ne3),
        .ntrap(nt3), .nrmw_steps(nr3), .nclk(nk3), .nxchk(nx3));
    // WP35: T, mask registers and $mb / $nb of 4 PEs in mn_pe_lsu (NPE = 4), store of 4 PEs
    tb_pemem_drv #(.SLOW(0), .SEED(53), .RBS(1), .NPE(4)) d4 (
        .clk(clk), .rst(rst), .finished(f4), .nfail(nf4), .nchk(nc4), .nexec(ne4),
        .ntrap(nt4), .nrmw_steps(nr4), .nclk(nk4), .nxchk(nx4));
    tb_pemem_drv #(.SLOW(0), .SEED(59), .RBS(0), .NPE(4)) d5 (
        .clk(clk), .rst(rst), .finished(f5), .nfail(nf5), .nchk(nc5), .nexec(ne5),
        .ntrap(nt5), .nrmw_steps(nr5), .nclk(nk5), .nxchk(nx5));

    integer i;
    initial begin
        for (i = 0; i < NREC; i = i + 1) rec[i] = 512'd0;   // op 0 = END after the file
        $readmemh("mncore/sim/tb/pemem/build/tests.hex", rec);
        nrec = 0;
        while (nrec < NREC && rec[nrec][511:504] != 8'd0) nrec = nrec + 1;
        $display("tb_pemem: %0d records", nrec);
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        wait (f0 && f1 && f2 && f3 && f4 && f5);
        $display("bsram: steps %0d (rmw %0d), traps %0d, checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne0, nr0, nt0, nc0, nf0, nk0 / ne0, (nk0 * 100 / ne0) % 100);
        $display("slow : steps %0d (rmw %0d), traps %0d, checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne1, nr1, nt1, nc1, nf1, nk1 / ne1, (nk1 * 100 / ne1) % 100);
        $display("bsram, shared read buffer: steps %0d (rmw %0d), traps %0d, checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne2, nr2, nt2, nc2, nf2, nk2 / ne2, (nk2 * 100 / ne2) % 100);
        $display("slow, shared read buffer : steps %0d (rmw %0d), traps %0d, checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne3, nr3, nt3, nc3, nf3, nk3 / ne3, (nk3 * 100 / ne3) % 100);
        $display("NPE 4, shared read buffer: steps %0d (rmw %0d), traps %0d, checks %0d, other-PE checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne4, nr4, nt4, nc4, nx4, nf4, nk4 / ne4, (nk4 * 100 / ne4) % 100);
        $display("NPE 4                    : steps %0d (rmw %0d), traps %0d, checks %0d, other-PE checks %0d, failures %0d, clocks/step %0d.%02d",
                 ne5, nr5, nt5, nc5, nx5, nf5, nk5 / ne5, (nk5 * 100 / ne5) % 100);
        $display("time %0t", $time);
        if (nrec == 0)
            $display("FAIL no records (run gen_tests.py first)");
        else if (nf0 != 0 || nf1 != 0 || nf2 != 0 || nf3 != 0 || nf4 != 0 || nf5 != 0)
            $display("FAIL %0d + %0d + %0d + %0d + %0d + %0d mismatches", nf0, nf1, nf2, nf3, nf4, nf5);
        else if (nc0 == 0 || nc0 != nc1 || ne0 != ne1 || nc0 != nc2 || nc0 != nc3 || ne0 != ne2 || ne0 != ne3 ||
                 nc0 != nc4 || nc0 != nc5 || ne0 != ne4 || ne0 != ne5)
            $display("FAIL check counts differ (%0d/%0d/%0d/%0d/%0d/%0d, %0d/%0d/%0d/%0d/%0d/%0d)",
                     nc0, nc1, nc2, nc3, nc4, nc5, ne0, ne1, ne2, ne3, ne4, ne5);
        else if (nx4 == 0 || nx4 != nx5 || nx0 != 0)
            $display("FAIL other-PE check counts (%0d/%0d/%0d)", nx0, nx4, nx5);
        else
            $display("PASS %0d steps, %0d checks on each instance; NPE 4: %0d other-PE checks", ne0, nc0, nx4);
        $finish;
    end
endmodule

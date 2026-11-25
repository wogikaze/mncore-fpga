// tb_mv: the MV unit tests (WP33). The test programs of fixed/mv.tst (made by gen_tests.py, the
// official emulator's results as expectations) run on the MV test core (mvt_core: mn_mv, mn_l2bm,
// the test L1BM, through the host ports as on the board) with sdr_bus64 and the SDRAM model:
//   a: the board's arrangement: core 27 MHz, SDRAM controller 108 MHz CL3 (ASYNC = 1)
//   b: one clock of 54 MHz for both, CL2 (ASYNC = 0; other latencies and back-pressure)
// +mva=<file> / +mvb=<file> replace the test file of a / b ("skip": none). Last line: PASS / FAIL.
`timescale 1ns/1ps
`default_nettype none
module tb_mv;
    wire        fa, fb;
    wire [31:0] na, nb, xa, xb;
    tb_mv_env #(.ASYNC(1), .FREQ_HZ(108000000), .P_SDR(9.259), .P_BUS(37.037), .CL(3), .RDX(1), .PH_NS(4.63),
                .PARG("mva=%s"), .TAG("a")) ea (.fin(fa), .ntests(na), .nfail(xa));
    tb_mv_env #(.ASYNC(0), .FREQ_HZ(54000000), .P_SDR(18.519), .P_BUS(18.519), .CL(2), .RDX(0), .PH_NS(4.63),
                .PARG("mvb=%s"), .TAG("b")) eb (.fin(fb), .ntests(nb), .nfail(xb));
    initial begin
        wait (fa === 1'b1 && fb === 1'b1);
        #100;
        $display("a (core 27 MHz, SDRAM 108 MHz): %0d tests, %0d failed", na, xa);
        $display("b (54 MHz, one clock):          %0d tests, %0d failed", nb, xb);
        if (xa == 0 && xb == 0 && (na + nb) != 0) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
`default_nettype wire

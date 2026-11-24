// tb_sdram: self-checking test of sdr_bus64 + sdr_ctrl against the SDRAM model, three configurations
// running in parallel:
//   e0: ASYNC=0, 108 MHz, CL3, SDRAM clock 180 deg, read capture +1   (expected board setting)
//   e1: ASYNC=1, controller 108 MHz CL3, bus 25 MHz  (read credits limit the response FIFO)
//   e2: ASYNC=0,  54 MHz, CL2, SDRAM clock 90 deg, read capture +0
// Board delays in all: 3 ns clock-to-pin, 2 ns pin-to-capture register.
`timescale 1ns/1ps

module tb_sdram;
    wire    d0, d1, d2;
    integer f0, f1, f2;

    tb_sdr_env #(.ASYNC(0), .FREQ_HZ(108000000), .P_SDR(9.259), .P_BUS(9.259), .CL(3), .RDX(1),
                 .PH_NS(4.63), .SEQ_AW(12), .N_RAND(6000), .SEED(1), .NAME("e0-sync108"))
        e0 (.done(d0), .fails(f0));

    tb_sdr_env #(.ASYNC(1), .FREQ_HZ(108000000), .P_SDR(9.259), .P_BUS(40.0), .CL(3), .RDX(1),
                 .PH_NS(4.63), .SEQ_AW(10), .N_RAND(3000), .SEED(2), .NAME("e1-async108/25"))
        e1 (.done(d1), .fails(f1));

    tb_sdr_env #(.ASYNC(0), .FREQ_HZ(54000000), .P_SDR(18.519), .P_BUS(18.519), .CL(2), .RDX(0),
                 .PH_NS(4.63), .SEQ_AW(10), .N_RAND(3000), .SEED(3), .NAME("e2-sync54"))
        e2 (.done(d2), .fails(f2));

    initial begin
        #50_000_000;
        $display("FAIL timeout (done %b%b%b)", d0, d1, d2);
        $finish;
    end

    initial begin
        wait (d0 === 1'b1 && d1 === 1'b1 && d2 === 1'b1);
        #100;
        if (f0 == 0 && f1 == 0 && f2 == 0) $display("PASS");
        else $display("FAIL fails e0=%0d e1=%0d e2=%0d", f0, f1, f2);
        $finish;
    end
endmodule

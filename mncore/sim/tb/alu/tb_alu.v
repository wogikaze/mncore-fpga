`timescale 1ns/1ps
// Unit test for the integer ALU (WP11): python mncore/tools/simrun.py alu --lint --synth
//   1. mn_alu_cls: classification of known machine-code forms (Scrapbox "多重化されるALU命令",
//      "ALU opcode観測一覧") and of every (dmode, aluop) combination.
//   2. mn_alu_int with all pipeline registers (IREG = PREG = MREG = 1, latency 4) and with
//      none (latency 1) against the vecgen vectors (tb_alu_run).
// Plusargs (vvp): +vec_fixed (use mncore/sim/vectors_fixed), +vec_only=TEXT, +vec_verbose.
module tb_alu;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 1'b0;
    end

    // ---------------- 1. classification ----------------
    reg  [1:0] c_dmode;
    reg  [4:0] c_aluop;
    reg        c_uns, c_ra, c_rb;
    reg  [3:0] c_isela;
    wire       k_int, k_fp, k_xpe, k_none, k_bad;
    mn_alu_cls u_cls (
        .dmode(c_dmode), .aluop(c_aluop), .is_unsigned(c_uns), .rounda(c_ra), .roundb(c_rb),
        .isela(c_isela),
        .cls_int(k_int), .cls_fp(k_fp), .cls_xpe(k_xpe), .cls_none(k_none), .cls_bad(k_bad));

    integer cls_err = 0, cls_n = 0;
    // expected class: 0 int, 1 fp, 2 xpe, 3 none, 4 bad
    task automatic cls_check(input [1:0] dm, input [4:0] op, input un, input r_a, input r_b,
                             input [3:0] sa, input integer want, input string what);
        reg [4:0] got1h, want1h;
        begin
            c_dmode = dm; c_aluop = op; c_uns = un; c_ra = r_a; c_rb = r_b; c_isela = sa;
            #1;
            got1h  = {k_bad, k_none, k_xpe, k_fp, k_int};
            want1h = 5'b00001 << want;
            cls_n = cls_n + 1;
            if (got1h !== want1h) begin
                cls_err = cls_err + 1;
                $display("CLS MISMATCH %s: dmode=%b aluop=%b u=%b r=%b%b isela=%b -> bad/none/xpe/fp/int=%b, expected %b",
                         what, dm, op, un, r_a, r_b, sa, got1h, want1h);
            end
        end
    endtask

    integer dm, op, un, sa;
    integer want;
    initial begin
        // forms observed with assemble3 (dmode aluop unsigned rounda roundb isela)
        cls_check(2'b01, 5'b11110, 0, 0, 0, 4'b0000, 1, "ffloor / fftoi / fbfn");
        cls_check(2'b11, 5'b11110, 0, 0, 0, 4'b0000, 1, "gbfn");
        cls_check(2'b10, 5'b11101, 1, 0, 0, 4'b0101, 0, "zero");
        cls_check(2'b00, 5'b11111, 0, 0, 0, 4'b0000, 0, "imm");
        cls_check(2'b11, 5'b11111, 1, 1, 1, 4'b1111, 0, "immu with payload bits set");
        cls_check(2'b10, 5'b11101, 0, 0, 0, 4'b0000, 1, "hbfe/6");
        cls_check(2'b10, 5'b11101, 0, 0, 0, 4'b0101, 1, "hbfe/6 $peid");
        cls_check(2'b10, 5'b11110, 0, 0, 0, 4'b0000, 1, "hbfn/6");
        cls_check(2'b11, 5'b00000, 0, 0, 0, 4'b1000, 3, "nop (no ALU)");
        cls_check(2'b01, 5'b10001, 0, 0, 0, 4'b0000, 2, "msl");
        cls_check(2'b01, 5'b10010, 0, 0, 0, 4'b0000, 2, "msr");
        cls_check(2'b10, 5'b11011, 0, 1, 1, 4'b0000, 1, "hmax $x r $y r");
        cls_check(2'b10, 5'b00000, 1, 1, 0, 4'b0000, 0, "usadd $x r");
        cls_check(2'b01, 5'b00000, 0, 1, 0, 4'b0000, 4, "iadd $x r (emulator stops)");
        cls_check(2'b00, 5'b01010, 0, 0, 1, 4'b0000, 4, "lpassa with roundb");
        cls_check(2'b11, 5'b01010, 0, 0, 0, 4'b0000, 4, "passa with dmode 11");
        cls_check(2'b00, 5'b01010, 0, 0, 0, 4'b1000, 0, "dpassa $msb1");
        cls_check(2'b10, 5'b10011, 0, 0, 0, 4'b0000, 0, "hpackbit");
        // every (dmode, aluop, unsigned, isela in {0000, 0101}) without rounding
        for (dm = 0; dm < 4; dm = dm + 1)
            for (op = 0; op < 32; op = op + 1)
                for (un = 0; un < 2; un = un + 1)
                    for (sa = 0; sa < 6; sa = sa + 5) begin
                        if (op == 31)                                   want = 0;  // imm
                        else if (op == 17 || op == 18)                  want = 2;  // msl msr
                        else if (op == 29 && un == 1 && sa == 5)        want = 0;  // zero
                        else if (dm == 3)                               want = (op == 0) ? 3 : (op == 30) ? 1 : 4;
                        else if (op < 16 || op == 19)                   want = 0;
                        else                                            want = 1;
                        cls_check(dm[1:0], op[4:0], un[0], 1'b0, 1'b0, sa[3:0], want, "sweep");
                    end
        $display("mn_alu_cls: %0d cases, %0d errors", cls_n, cls_err);
    end

    // ---------------- 2. vectors ----------------
    wire    d1, d0;
    integer e1, e0, r1, r0, f1, f0;
    tb_alu_run #(.IREG(1), .PREG(1), .MREG(1), .SEED(1)) run1 (
        .clk(clk), .rst(rst), .done(d1), .n_err(e1), .n_rows(r1), .n_files(f1));
    tb_alu_run #(.IREG(0), .PREG(0), .MREG(0), .SEED(2)) run0 (
        .clk(clk), .rst(rst), .done(d0), .n_err(e0), .n_rows(r0), .n_files(f0));

    initial begin
        wait (d1 === 1'b1 && d0 === 1'b1);
        #20;
        if (cls_err != 0)
            $display("FAIL mn_alu_cls: %0d errors", cls_err);
        else if (e1 != 0 || e0 != 0)
            $display("FAIL vectors: %0d errors (registers 111), %0d errors (registers 000)", e1, e0);
        else if (r1 == 0 || r0 == 0 || f1 != f0 || r1 != r0)
            $display("FAIL vectors: rows %0d / %0d, files %0d / %0d", r1, r0, f1, f0);
        else
            $display("PASS mn_alu_int: %0d files, %0d rows x 2 configurations; mn_alu_cls %0d cases", f1, r1, cls_n);
        $finish;
    end

    initial begin
        #2000000000;
        $display("FAIL timeout");
        $finish;
    end
endmodule

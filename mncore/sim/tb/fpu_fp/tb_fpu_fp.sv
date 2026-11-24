// tb_fpu_fp: mn_fp_fma and mn_fp_f2h against the `fp` unit vectors (WP12).
//
// Two vector sets are run (from the repository root, as simrun.py does):
//   1. +vecdir=<dir> (holding <op>.vec), else mncore/sim/vectors/fp when it has been
//      generated, else mncore/sim/vectors_fixed/fp. The files must carry the official
//      expected values (`expect=official` wherever `disputed=` is set, vecgen/FORMAT.md).
//   2. mncore/sim/tb/fpu_fp/probe: rows on the boundaries of the adder alignment rules
//      (product drop, c grid), every expected value checked with the official emulator
//      (mncore/sim/tb/fpu_tools/probe_align.py). +noprobe skips it.
// Every row is checked. One element enters the FMA per clock; results are matched by tag.
`timescale 1ns / 1ps
module tb_fpu_fp;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg         iv = 1'b0;
    reg  [1:0]  prec = 2'b00;
    reg         rnd = 1'b0;
    reg  [63:0] a = 64'd0, b = 64'd0, c = 64'd0;
    reg  [5:0]  tag = 6'd0;
    wire        ov;
    wire [63:0] z;
    wire [5:0]  otag;
    mn_fp_fma #(.TAGW(6)) dut (
        .clk(clk), .rst(rst), .in_valid(iv), .prec(prec), .rnd(rnd),
        .a(a), .b(b), .c(c), .in_tag(tag), .out_valid(ov), .z(z), .out_tag(otag));

    reg  [31:0] fx = 32'd0;
    wire [15:0] fh;
    mn_fp_f2h u_f2h (.x(fx), .h(fh));

    // rows in flight
    reg [63:0] r_z [0:63];
    reg [63:0] r_a [0:63], r_b [0:63], r_c [0:63];
    integer    r_line [0:63];
    integer    r_file [0:63];
    string     names [0:24];
    integer    n_rows = 0, n_bad = 0, n_out = 0, n_fma = 0, n_files = 0;
    integer    per_rows [0:24];
    integer    per_bad [0:24];

    // checker: outputs are stable between clock edges
    always @(negedge clk) begin
        if (ov) begin
            n_out = n_out + 1;
            if (z !== r_z[otag]) begin
                n_bad = n_bad + 1;
                per_bad[r_file[otag]] = per_bad[r_file[otag]] + 1;
                if (n_bad <= 20)
                    $display("MISMATCH %s line %0d: a=%h b=%h c=%h got %h want %h",
                             names[r_file[otag]], r_line[otag], r_a[otag], r_b[otag], r_c[otag],
                             z, r_z[otag]);
            end
        end
    end

    function automatic bit has(input string s, input string pat);
        int i;
        has = 1'b0;
        for (i = 0; i + pat.len() <= s.len(); i = i + 1)
            if (s.substr(i, i + pat.len() - 1) == pat) has = 1'b1;
    endfunction

    // runs every file of `dir`; files that do not exist are skipped
    task automatic run_dir(input string dir);
        integer    fd, n, f, line;
        string     path, hdr, unit, op;
        reg [63:0] va, vb, vc, vz;
        begin
            $display("tb_fpu_fp: vectors from %s", dir);
            for (f = 0; f < 25; f = f + 1) begin
                per_rows[f] = 0;
                per_bad[f] = 0;
            end
            for (f = 0; f < 25; f = f + 1) begin
                path = {dir, "/", names[f], ".vec"};
                fd = $fopen(path, "r");
                if (fd == 0) continue;
                n = $fgets(hdr, fd);
                n = $sscanf(hdr, "# vec v1 unit=%s op=%s", unit, op);
                if (n != 2 || unit != "fp" || op != names[f]) begin
                    $display("FAIL bad header in %s", path);
                    $finish;
                end
                if (has(hdr, "disputed=") && !has(hdr, "expect=official")) begin
                    $display("FAIL %s has disputed rows without official expected values (vecgen --official-expect)", path);
                    $finish;
                end
                n_files = n_files + 1;
                line = 1;
                if (f == 24) begin
                    // cvt_f2h: combinational, `a | z`
                    while (!$feof(fd)) begin
                        n = $fscanf(fd, "%h | %h\n", va, vz);
                        if (n != 2) break;
                        line = line + 1;
                        fx = va[31:0];
                        #1;
                        n_rows = n_rows + 1;
                        per_rows[f] = per_rows[f] + 1;
                        if (fh !== vz[15:0]) begin
                            n_bad = n_bad + 1;
                            per_bad[f] = per_bad[f] + 1;
                            if (n_bad <= 20)
                                $display("MISMATCH cvt_f2h line %0d: a=%h got %h want %h", line, va[31:0], fh, vz[15:0]);
                        end
                    end
                end else begin
                    while (!$feof(fd)) begin
                        n = $fscanf(fd, "%h %h %h | %h\n", va, vb, vc, vz);
                        if (n != 4) break;
                        line = line + 1;
                        @(negedge clk);
                        iv   = 1'b1;
                        prec = (f % 6 < 2) ? 2'b00 : (f % 6 < 4) ? 2'b01 : 2'b10;
                        rnd  = (f % 2 == 1);
                        a = va;
                        b = vb;
                        c = vc;
                        tag = n_fma[5:0];
                        r_z[tag] = vz;
                        r_a[tag] = va;
                        r_b[tag] = vb;
                        r_c[tag] = vc;
                        r_line[tag] = line;
                        r_file[tag] = f;
                        n_fma = n_fma + 1;
                        n_rows = n_rows + 1;
                        per_rows[f] = per_rows[f] + 1;
                    end
                    @(negedge clk) iv = 1'b0;
                end
                $fclose(fd);
            end
            repeat (40) @(negedge clk);
            for (f = 0; f < 25; f = f + 1)
                if (per_rows[f] != 0)
                    $display("  %-9s %6d rows, %0d mismatches", names[f], per_rows[f], per_bad[f]);
        end
    endtask

    string dir;
    integer probe;

    initial begin
        names[0]  = "fma_d";   names[1]  = "fma_dr";   names[2]  = "fma_f";   names[3]  = "fma_fr";
        names[4]  = "fma_h";   names[5]  = "fma_hr";   names[6]  = "mul_d";   names[7]  = "mul_dr";
        names[8]  = "mul_f";   names[9]  = "mul_fr";   names[10] = "mul_h";   names[11] = "mul_hr";
        names[12] = "add_d";   names[13] = "add_dr";   names[14] = "add_f";   names[15] = "add_fr";
        names[16] = "add_h";   names[17] = "add_hr";   names[18] = "passa_d"; names[19] = "passa_dr";
        names[20] = "passa_f"; names[21] = "passa_fr"; names[22] = "passa_h"; names[23] = "passa_hr";
        names[24] = "cvt_f2h";
        if (!$value$plusargs("vecdir=%s", dir)) begin
            probe = $fopen("mncore/sim/vectors/fp/fma_d.vec", "r");
            if (probe != 0) begin
                $fclose(probe);
                dir = "mncore/sim/vectors/fp";
            end else begin
                dir = "mncore/sim/vectors_fixed/fp";
            end
        end
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        run_dir(dir);
        if (!$test$plusargs("noprobe"))
            run_dir("mncore/sim/tb/fpu_fp/probe");

        $display("tb_fpu_fp: %0d files, %0d rows, %0d mismatches", n_files, n_rows, n_bad);
        if (n_files == 0)
            $display("FAIL no vector files");
        else if (n_out != n_fma)
            $display("FAIL %0d results for %0d FMA rows", n_out, n_fma);
        else if (n_bad != 0)
            $display("FAIL %0d mismatches", n_bad);
        else
            $display("PASS");
        $finish;
    end
endmodule

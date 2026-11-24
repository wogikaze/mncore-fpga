// tb_fpu_mau: mn_mau_vec against the `mau` unit vectors (WP12).
//
// Vector directory: +vecdir=<dir> (holding <op>.vec), else mncore/sim/vectors/mau when it
// has been generated, else mncore/sim/vectors_fixed/mau (run from the repository root).
// Every row is one (PE, cycle) slot: z_hi, z_lo and the flags are all compared. Files with
// `disputed=` must carry `expect=official` (mncore/vecgen/FORMAT.md).
// Slots are offered back to back (in_valid / in_ready); results are matched by tag.
`timescale 1ns / 1ps
module tb_fpu_mau;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg          iv = 1'b0;
    wire         irdy;
    reg  [1:0]   dmode = 2'b00;
    reg          rnd = 1'b0, pa = 1'b0, zc = 1'b0, side = 1'b0;
    reg          sa = 1'b0, sb = 1'b0, sc = 1'b0, ea = 1'b0, eb = 1'b0, ec = 1'b0;
    reg  [1:0]   pe = 2'd0;
    reg  [127:0] abus = 128'd0, bbus = 128'd0, cbus = 128'd0;
    reg  [5:0]   tag = 6'd0;
    wire         ov;
    wire [127:0] zbus;
    wire [3:0]   fl;
    wire [5:0]   otag;
    mn_mau_vec #(.TAGW(6)) dut (
        .clk(clk), .rst(rst), .in_valid(iv), .in_ready(irdy),
        .dmode(dmode), .round_out(rnd), .passa(pa), .zeroc(zc), .mdw_side(side),
        .signa(sa), .signb(sb), .signc(sc), .exta(ea), .extb(eb), .extc(ec), .pe_sub(pe),
        .a_bus(abus), .b_bus(bbus), .c_bus(cbus), .in_tag(tag),
        .out_valid(ov), .z_bus(zbus), .flags(fl), .out_tag(otag));

    // instruction forms: name, dmode, kind (passa, zeroc), side (d), round
    string  names [0:27];
    reg [1:0] f_dm [0:27];
    reg       f_pa [0:27], f_zc [0:27], f_side [0:27], f_rnd [0:27];

    task automatic form(input integer i, input string nm, input [1:0] dm, input p, input z,
                        input s, input r);
        names[i] = nm; f_dm[i] = dm; f_pa[i] = p; f_zc[i] = z; f_side[i] = s; f_rnd[i] = r;
    endtask

    // rows in flight
    reg [127:0] r_z [0:63];
    reg [3:0]   r_f [0:63];
    integer     r_line [0:63], r_file [0:63];
    integer     n_rows = 0, n_bad = 0, n_out = 0, n_files = 0;
    integer     per_rows [0:27], per_bad [0:27];
    integer     expect_tag = 0;

    always @(negedge clk) begin
        if (ov) begin
            n_out = n_out + 1;
            if (otag !== expect_tag[5:0]) begin
                n_bad = n_bad + 1;
                $display("ORDER: got tag %0d, expected %0d", otag, expect_tag[5:0]);
            end
            expect_tag = expect_tag + 1;
            if (zbus !== r_z[otag] || fl !== r_f[otag]) begin
                n_bad = n_bad + 1;
                per_bad[r_file[otag]] = per_bad[r_file[otag]] + 1;
                if (n_bad <= 20)
                    $display("MISMATCH %s line %0d: got %h %h %h want %h %h %h",
                             names[r_file[otag]], r_line[otag], zbus[127:64], zbus[63:0], fl,
                             r_z[otag][127:64], r_z[otag][63:0], r_f[otag]);
            end
        end
    end

    function automatic bit has(input string s, input string pat);
        int i;
        has = 1'b0;
        for (i = 0; i + pat.len() <= s.len(); i = i + 1)
            if (s.substr(i, i + pat.len() - 1) == pat) has = 1'b1;
    endfunction

    integer    fd, n, f, line, probe;
    string     dir, path, hdr, unit, op;
    reg [63:0] v [0:15];

    initial begin
        //   i  name       dm     pa zc side r
        form(0,  "dvfmau",   2'b00, 0, 0, 0, 0); form(1,  "dvfmaur",  2'b00, 0, 0, 0, 1);
        form(2,  "dvfmad",   2'b00, 0, 0, 1, 0); form(3,  "dvfmadr",  2'b00, 0, 0, 1, 1);
        form(4,  "dvmulu",   2'b00, 0, 1, 0, 0); form(5,  "dvmulur",  2'b00, 0, 1, 0, 1);
        form(6,  "dvmuld",   2'b00, 0, 1, 1, 0); form(7,  "dvmuldr",  2'b00, 0, 1, 1, 1);
        form(8,  "dvadd",    2'b00, 1, 0, 0, 0); form(9,  "dvaddr",   2'b00, 1, 0, 0, 1);
        form(10, "dvpassa",  2'b00, 1, 1, 0, 0); form(11, "dvpassar", 2'b00, 1, 1, 0, 1);
        form(12, "fvfma",    2'b01, 0, 0, 0, 0); form(13, "fvfmar",   2'b01, 0, 0, 0, 1);
        form(14, "fvmul",    2'b01, 0, 1, 0, 0); form(15, "fvmulr",   2'b01, 0, 1, 0, 1);
        form(16, "fvadd",    2'b01, 1, 0, 0, 0); form(17, "fvaddr",   2'b01, 1, 0, 0, 1);
        form(18, "fvpassa",  2'b01, 1, 1, 0, 0); form(19, "fvpassar", 2'b01, 1, 1, 0, 1);
        form(20, "hvfma",    2'b10, 0, 0, 0, 0); form(21, "hvfmar",   2'b10, 0, 0, 0, 1);
        form(22, "hvmul",    2'b10, 0, 1, 0, 0); form(23, "hvmulr",   2'b10, 0, 1, 0, 1);
        form(24, "hvadd",    2'b10, 1, 0, 0, 0); form(25, "hvaddr",   2'b10, 1, 0, 0, 1);
        form(26, "hvpassa",  2'b10, 1, 1, 0, 0); form(27, "hvpassar", 2'b10, 1, 1, 0, 1);
        for (f = 0; f < 28; f = f + 1) begin
            per_rows[f] = 0;
            per_bad[f] = 0;
        end
        if (!$value$plusargs("vecdir=%s", dir)) begin
            probe = $fopen("mncore/sim/vectors/mau/dvfmau.vec", "r");
            if (probe != 0) begin
                $fclose(probe);
                dir = "mncore/sim/vectors/mau";
            end else begin
                dir = "mncore/sim/vectors_fixed/mau";
            end
        end
        $display("tb_fpu_mau: vectors from %s", dir);
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        for (f = 0; f < 28; f = f + 1) begin
            path = {dir, "/", names[f], ".vec"};
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("  %-9s (no file)", names[f]);
                continue;
            end
            n = $fgets(hdr, fd);
            n = $sscanf(hdr, "# vec v1 unit=%s op=%s", unit, op);
            if (n != 2 || unit != "mau" || op != names[f]) begin
                $display("FAIL bad header in %s", path);
                $finish;
            end
            if (has(hdr, "disputed=") && !has(hdr, "expect=official")) begin
                $display("FAIL %s has disputed rows without official expected values (vecgen --official-expect)", path);
                $finish;
            end
            n_files = n_files + 1;
            line = 1;
            while (!$feof(fd)) begin
                n = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h | %h %h %h\n",
                            v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10],
                            v[11], v[12], v[13], v[14], v[15]);
                if (n != 16) break;
                line = line + 1;
                // wait for in_ready (sampled at the clock edge after this negedge)
                @(negedge clk);
                while (!irdy) @(negedge clk);
                iv    = 1'b1;
                dmode = f_dm[f];
                rnd   = f_rnd[f];
                pa    = f_pa[f];
                zc    = f_zc[f];
                side  = f_side[f];
                pe    = v[0][1:0];
                sa = v[1][0]; sb = v[2][0]; sc = v[3][0];
                ea = v[4][0]; eb = v[5][0]; ec = v[6][0];
                abus = {v[7], v[8]};
                bbus = {v[9], v[10]};
                cbus = {v[11], v[12]};
                tag  = n_rows[5:0];
                r_z[tag]    = {v[13], v[14]};
                r_f[tag]    = v[15][3:0];
                r_line[tag] = line;
                r_file[tag] = f;
                n_rows = n_rows + 1;
                per_rows[f] = per_rows[f] + 1;
                @(posedge clk);
                #1 iv = 1'b0;
            end
            $fclose(fd);
        end
        repeat (60) @(negedge clk);

        for (f = 0; f < 28; f = f + 1)
            if (per_rows[f] != 0)
                $display("  %-9s %6d rows, %0d mismatches", names[f], per_rows[f], per_bad[f]);
        $display("tb_fpu_mau: %0d files, %0d rows, %0d mismatches", n_files, n_rows, n_bad);
        if (n_files == 0)
            $display("FAIL no vector files");
        else if (n_out != n_rows)
            $display("FAIL %0d results for %0d rows", n_out, n_rows);
        else if (n_bad != 0)
            $display("FAIL %0d mismatches", n_bad);
        else
            $display("PASS");
        $finish;
    end
endmodule

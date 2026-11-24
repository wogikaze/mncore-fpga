`timescale 1ns/1ps
// Vector test harness for mn_alu_int (WP11). tb_alu instantiates it with all pipeline
// registers (IREG = PREG = MREG = 1) and with none (all 0).
//
// Reads the unit vectors (mncore/vecgen/FORMAT.md):
//   alu/[u]<l|i|s><op>.vec, alu/[u]s<op>.r.vec, alu/zero.vec, alu/imm.vec, alu/immu.vec
//   fpalu/[u]<d|f|h><passa|packbit>.vec, fpalu/[u]h<passa|packbit>.r.vec
//     (passa and packbit have the same machine code for float and integer precisions)
// from mncore/sim/vectors/ if it was generated (then every file must exist), otherwise from
// mncore/sim/vectors_fixed/ (only the files that exist). Files with `disputed=` must carry
// `expect=official` (vecgen --official-expect, contract §5); disputed rows are not skipped.
//
// Stimulus: random idle cycles on the input and random back-pressure on the output.
module tb_alu_run #(
    parameter IREG = 1,
    parameter PREG = 1,
    parameter MREG = 1,
    parameter SEED = 1
) (
    input  wire        clk,
    input  wire        rst,
    output reg         done,
    output integer     n_err,
    output integer     n_rows,
    output integer     n_files
);
    // ---------------- DUT ----------------
    reg          in_valid = 1'b0;
    wire         in_ready;
    reg  [1:0]   dmode = 2'b00;
    reg  [4:0]   aluop = 5'b00000;
    reg          uns = 1'b0, ra = 1'b0, rb = 1'b0;
    reg  [3:0]   isela = 4'b0000;
    reg  [31:0]  imm32 = 32'd0;
    reg  [127:0] x = 128'd0, y = 128'd0;
    wire         c_int, c_fp, c_xpe, c_none, c_bad;
    wire         out_valid;
    reg          out_ready = 1'b0;
    wire [127:0] z;
    wire [3:0]   flags;
    wire         out_err;

    mn_alu_int #(.IREG(IREG), .PREG(PREG), .MREG(MREG)) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready),
        .pe_aluc_dmode(dmode), .pe_aluc_aluop(aluop), .pe_aluc_is_unsigned(uns),
        .pe_aluc_rounda(ra), .pe_aluc_roundb(rb), .pe_aluc_isela(isela),
        .imm32(imm32), .x(x), .y(y),
        .cls_int(c_int), .cls_fp(c_fp), .cls_xpe(c_xpe), .cls_none(c_none), .cls_bad(c_bad),
        .out_valid(out_valid), .out_ready(out_ready),
        .z(z), .flags(flags), .out_err(out_err));

    integer rnd = SEED;
    always @(negedge clk) out_ready <= ($random(rnd) % 4) != 0;

    // ---------------- expected-value FIFO and checker ----------------
    localparam QN = 16;
    reg [127:0] q_z   [0:QN-1];
    reg [3:0]   q_f   [0:QN-1];
    reg         q_e   [0:QN-1];
    integer     q_file[0:QN-1];
    integer     q_line[0:QN-1];
    integer     q_wr = 0, q_rd = 0;
    string      fnames [0:511];
    integer     n_shown = 0;

    always @(posedge clk) begin
        if (!rst && out_valid && out_ready) begin
            if (q_rd >= q_wr) begin
                n_err = n_err + 1;
                $display("[IPM=%0d%0d%0d] ERROR output without a pending request", IREG, PREG, MREG);
            end else begin
                if (z !== q_z[q_rd % QN] || flags !== q_f[q_rd % QN] || out_err !== q_e[q_rd % QN]) begin
                    n_err = n_err + 1;
                    if (n_shown < 20) begin
                        n_shown = n_shown + 1;
                        $display("[IPM=%0d%0d%0d] MISMATCH %s line %0d: z=%h_%h flags=%h err=%b, expected z=%h_%h flags=%h err=%b",
                                 IREG, PREG, MREG, fnames[q_file[q_rd % QN]], q_line[q_rd % QN],
                                 z[127:64], z[63:0], flags, out_err,
                                 q_z[q_rd % QN][127:64], q_z[q_rd % QN][63:0], q_f[q_rd % QN], q_e[q_rd % QN]);
                    end
                end
                q_rd = q_rd + 1;
            end
        end
    end

    // Send the request on the inputs and queue its expected result.
    // Called between a negedge and the next posedge; returns at the negedge after the
    // request was accepted, with in_valid still 1 so that the next request follows
    // back to back (the caller changes the inputs in zero time).
    task automatic send(input [127:0] ez, input [3:0] ef, input ee, input integer fi, input integer ln);
        begin
            while (($random(rnd) & 7) == 0 || q_wr - q_rd >= QN - 2) begin
                in_valid = 1'b0;
                @(negedge clk);
            end
            in_valid = 1'b1;
            q_z[q_wr % QN] = ez;
            q_f[q_wr % QN] = ef;
            q_e[q_wr % QN] = ee;
            q_file[q_wr % QN] = fi;
            q_line[q_wr % QN] = ln;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
            q_wr = q_wr + 1;
            @(negedge clk);
        end
    endtask

    // ---------------- vector file reader ----------------
    // value of `key=` in the header line ("" if absent)
    function automatic string hdr_get(input string s, input string k);
        integer p, e, L, kl;
        begin
            hdr_get = "";
            L = s.len();
            kl = k.len();
            for (p = 0; p + kl < L; p = p + 1) begin
                if ((p == 0 || s.getc(p - 1) == 8'd32) && s.substr(p, p + kl - 1) == k && s.getc(p + kl) == 8'd61) begin
                    e = p + kl + 1;
                    while (e < L && s.getc(e) != 8'd32 && s.getc(e) != 8'd10 && s.getc(e) != 8'd13) e = e + 1;
                    hdr_get = s.substr(p + kl + 1, e - 1);
                    p = L;
                end
            end
        end
    endfunction

    function automatic integer has_text(input string s, input string t);
        integer p;
        begin
            has_text = 0;
            for (p = 0; p + t.len() <= s.len(); p = p + 1)
                if (s.substr(p, p + t.len() - 1) == t) has_text = 1;
        end
    endfunction

    string vdir;            // "mncore/sim/vectors" or "mncore/sim/vectors_fixed"
    integer full = 0;       // 1: generated vectors, every file must exist
    integer n_missing = 0, n_disp_rows = 0, n_disp_files = 0;

    task automatic run_file(input string unit, input string name);
        integer fd, r, ln, fi, imm_mode, n0;
        string path, line, v;
        reg [1:0] h_dmode;
        reg [4:0] h_aluop;
        reg       h_uns;
        reg [3:0] h_isela;
        reg [63:0] c_ra, c_rb, xh, xl, yh, yl, ezh, ezl, ef, iv;
        begin
            path = {vdir, "/", unit, "/", name};
            fd = $fopen(path, "r");
            if (fd == 0) begin
                if (full) begin
                    n_err = n_err + 1;
                    $display("[IPM=%0d%0d%0d] ERROR missing %s", IREG, PREG, MREG, path);
                end
                n_missing = n_missing + 1;
            end else begin
                fi = n_files;
                fnames[fi] = {unit, "/", name};
                n_files = n_files + 1;
                r = $fgets(line, fd);
                imm_mode = has_text(line, "cols: imm |");
                h_dmode = 2'b00; h_aluop = 5'b00000; h_uns = 1'b0; h_isela = 4'b0000;
                v = hdr_get(line, "dmode");       if (v != "") r = $sscanf(v, "%b", h_dmode);
                v = hdr_get(line, "aluop");       if (v != "") r = $sscanf(v, "%b", h_aluop);
                v = hdr_get(line, "is_unsigned"); if (v != "") r = $sscanf(v, "%b", h_uns);
                v = hdr_get(line, "isela");       if (v != "") r = $sscanf(v, "%b", h_isela);
                if (hdr_get(line, "aluop") == "") begin
                    n_err = n_err + 1;
                    $display("[IPM=%0d%0d%0d] ERROR %s: no aluop in the header", IREG, PREG, MREG, path);
                end
                if (hdr_get(line, "disputed") != "" && hdr_get(line, "expect") != "official") begin
                    n_err = n_err + 1;
                    $display("[IPM=%0d%0d%0d] ERROR %s: disputed=%s without expect=official (run vecgen --official-expect)",
                             IREG, PREG, MREG, path, hdr_get(line, "disputed"));
                end
                n0 = n_rows;
                ln = 1;
                while (!$feof(fd)) begin
                    r = $fgets(line, fd);
                    ln = ln + 1;
                    if (r > 2) begin
                        if (imm_mode) begin
                            r = $sscanf(line, "%h | %h %h %h", iv, ezh, ezl, ef);
                            if (r != 4) begin
                                n_err = n_err + 1;
                                $display("[IPM=%0d%0d%0d] ERROR %s line %0d: bad row", IREG, PREG, MREG, path, ln);
                            end
                            // the payload occupies dmode / rounda / roundb / isela as in the j word
                            imm32 = iv[31:0];
                            dmode = iv[31:30]; ra = iv[29]; rb = iv[28]; isela = iv[27:24];
                            aluop = h_aluop; uns = h_uns;
                            x = {$random(rnd), $random(rnd), $random(rnd), $random(rnd)};
                            y = {$random(rnd), $random(rnd), $random(rnd), $random(rnd)};
                        end else begin
                            r = $sscanf(line, "%h %h %h %h %h %h | %h %h %h", c_ra, c_rb, xh, xl, yh, yl, ezh, ezl, ef);
                            if (r != 9) begin
                                n_err = n_err + 1;
                                $display("[IPM=%0d%0d%0d] ERROR %s line %0d: bad row", IREG, PREG, MREG, path, ln);
                            end
                            dmode = h_dmode; aluop = h_aluop; uns = h_uns; isela = h_isela;
                            ra = c_ra[0]; rb = c_rb[0];
                            imm32 = $random(rnd);
                            x = {xh, xl};
                            y = {yh, yl};
                        end
                        #1;
                        if (c_int !== 1'b1 || {c_fp, c_xpe, c_none, c_bad} !== 4'b0000) begin
                            n_err = n_err + 1;
                            if (n_shown < 20) begin
                                n_shown = n_shown + 1;
                                $display("[IPM=%0d%0d%0d] ERROR %s line %0d: class int/fp/xpe/none/bad = %b%b%b%b%b",
                                         IREG, PREG, MREG, path, ln, c_int, c_fp, c_xpe, c_none, c_bad);
                            end
                        end
                        send({ezh, ezl}, ef[3:0], 1'b0, fi, ln);
                        n_rows = n_rows + 1;
                    end
                end
                $fclose(fd);
                if (n_rows == n0) begin
                    n_err = n_err + 1;
                    $display("[IPM=%0d%0d%0d] ERROR %s: no rows", IREG, PREG, MREG, path);
                end
            end
        end
    endtask

    task automatic run_disputed_count(input string unit, input string name);
        integer fd, r, ln;
        string line;
        begin
            fd = $fopen({vdir, "/", unit, "/", name}, "r");
            if (fd != 0) begin
                r = $fgets(line, fd);
                if (hdr_get(line, "disputed") != "") begin
                    n_disp_files = n_disp_files + 1;
                    ln = 0;
                    while (!$feof(fd)) begin
                        r = $fgets(line, fd);
                        if (r > 2) ln = ln + 1;
                    end
                    n_disp_rows = n_disp_rows + ln;
                end
                $fclose(fd);
            end
        end
    endtask

    function automatic string op_name(input integer k);
        case (k)
            0: op_name = "add";    1: op_name = "sub";    2: op_name = "inc";   3: op_name = "dec";
            4: op_name = "not";    5: op_name = "and";    6: op_name = "or";    7: op_name = "xor";
            8: op_name = "max";    9: op_name = "min";   10: op_name = "passa"; 11: op_name = "lsl";
           12: op_name = "lsr";   13: op_name = "bsl";   14: op_name = "bsr";  15: op_name = "lnot";
           default: op_name = "packbit";
        endcase
    endfunction

    string  only;           // +vec_only=TEXT: only files whose name contains TEXT
    integer verbose = 0;    // +vec_verbose: one line per file

    task automatic run_one(input string unit, input string name);
        integer r0, e0;
        begin
            if (only == "" || has_text({unit, "/", name}, only)) begin
                r0 = n_rows;
                e0 = n_err;
                run_disputed_count(unit, name);
                run_file(unit, name);
                if (verbose && n_rows != r0)
                    $display("[IPM=%0d%0d%0d] %s/%s: %0d rows, %0d errors", IREG, PREG, MREG, unit, name, n_rows - r0, n_err - e0);
            end
        end
    endtask

    integer u, p, k, fd0;
    string  pre, pc;
    initial begin
        done = 1'b0;
        n_err = 0;
        n_rows = 0;
        n_files = 0;
        if (!$value$plusargs("vec_only=%s", only)) only = "";
        if ($test$plusargs("vec_verbose")) verbose = 1;
        fd0 = $test$plusargs("vec_fixed") ? 0 : $fopen("mncore/sim/vectors/alu/iadd.vec", "r");
        if (fd0 != 0) begin
            $fclose(fd0);
            vdir = "mncore/sim/vectors";
            full = 1;
        end else begin
            vdir = "mncore/sim/vectors_fixed";
            full = 0;
        end
        @(negedge rst);
        repeat (2) @(negedge clk);

        // unit alu
        for (u = 0; u < 2; u = u + 1) begin
            pre = (u != 0) ? "u" : "";
            for (p = 0; p < 3; p = p + 1) begin
                pc = (p == 0) ? "l" : (p == 1) ? "i" : "s";
                for (k = 0; k < 17; k = k + 1)
                    run_one("alu", {pre, pc, op_name(k), ".vec"});
            end
            for (k = 0; k < 17; k = k + 1)
                run_one("alu", {pre, "s", op_name(k), ".r.vec"});
        end
        run_one("alu", "zero.vec");
        run_one("alu", "imm.vec");
        run_one("alu", "immu.vec");
        // unit fpalu: passa and packbit in float precisions
        for (u = 0; u < 2; u = u + 1) begin
            pre = (u != 0) ? "u" : "";
            for (p = 0; p < 3; p = p + 1) begin
                pc = (p == 0) ? "d" : (p == 1) ? "f" : "h";
                run_one("fpalu", {pre, pc, "passa.vec"});
                run_one("fpalu", {pre, pc, "packbit.vec"});
            end
            run_one("fpalu", {pre, "hpassa.r.vec"});
            run_one("fpalu", {pre, "hpackbit.r.vec"});
        end

        // operations of other classes are flagged with out_err
        dmode = 2'b10; aluop = 5'b10000; uns = 1'b0; ra = 1'b0; rb = 1'b0; isela = 4'b0000;   // hrsqrt
        send(128'd0, 4'd0, 1'b1, 0, 0);
        aluop = 5'b10001;                                                                    // msl
        send(128'd0, 4'd0, 1'b1, 0, 0);
        in_valid = 1'b0;

        // drain
        while (q_rd < q_wr) @(posedge clk);
        repeat (4) @(posedge clk);
        $display("[IPM=%0d%0d%0d] %s: %0d files, %0d rows (%0d rows in %0d files marked disputed, checked against the official values), %0d files absent, %0d errors",
                 IREG, PREG, MREG, vdir, n_files, n_rows, n_disp_rows, n_disp_files, n_missing, n_err);
        done = 1'b1;
    end
endmodule

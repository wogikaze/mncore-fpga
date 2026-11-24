// tb_fpalu: vector test of mn_fp_alu (per-PE FP ALU instructions) and mn_fp_alu_bfn
// (block-float conversion of a MAB) against the unit vectors of WP03 (mncore/vecgen/FORMAT.md,
// unit fpalu). Self-checking: the last line is PASS or FAIL <reason>.
//
// Plusargs:
//   +manifest=<file>  list of .vec files, one path per line (relative to the repository root;
//                     '#' comments). Default: mncore/sim/tb/fpalu/manifest_fixed.txt
//   +seed=<n>         seed of the random handshake stalls (default 1)
//   +maxerr=<n>       mismatches printed per file (default 5)
//
// The ALUC fields come from each file's header (dmode, aluop, is_unsigned, iselb, isela) and
// the row's ra / rb columns. Where the header has no iselb / isela (the instruction does not use
// them), random values are driven: the unit must ignore them. Both units are driven with random
// valid gaps and random out_ready back-pressure; out_err must stay 0. Each request is also
// checked against the routing of WP11's mn_alu_cls (cls_fp, or cls_int for passa / packbit)
// and mn_fp_alu's cls_bf. Before the vectors, the latencies and out_err for ALUCs the units
// do not execute are checked.
//
// Parameter TB_RND (iverilog -Ptb_fpalu.TB_RND=0) builds both units with RND = 0 (no input
// rounding) and skips the `r` vector files.
`timescale 1ns / 1ps
module tb_fpalu #(
    parameter TB_RND = 1
);
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    // ---- common ALUC fields
    reg [1:0] dmode = 2'b00;
    reg [4:0] aluop = 5'd0;
    reg       uns = 1'b0, ra = 1'b0, rb = 1'b0;
    reg [3:0] isela = 4'd0;
    reg [2:0] iselb = 3'd0;

    // ---- mn_fp_alu
    reg          in_valid = 1'b0, out_ready = 1'b0;
    reg  [127:0] x = 128'd0, y = 128'd0;
    wire         in_ready, out_valid, out_err, cls_bf;
    wire [127:0] z;
    wire [3:0]   flags;
    mn_fp_alu #(.RND(TB_RND)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .pe_aluc_dmode(dmode), .pe_aluc_aluop(aluop), .pe_aluc_is_unsigned(uns),
        .pe_aluc_rounda(ra), .pe_aluc_roundb(rb), .pe_aluc_isela(isela), .pe_aluc_iselb(iselb),
        .x(x), .y(y), .cls_bf(cls_bf),
        .out_valid(out_valid), .out_ready(out_ready), .z(z), .flags(flags), .out_err(out_err));

    // ---- mn_fp_alu_bfn
    reg          b_in_valid = 1'b0, b_out_ready = 1'b0;
    reg  [511:0] bx = 512'd0;
    wire         b_in_ready, b_out_valid, b_out_err;
    wire [511:0] bz;
    wire [15:0]  bflags;
    mn_fp_alu_bfn #(.RND(TB_RND)) dutb (
        .clk(clk), .rst(rst), .in_valid(b_in_valid), .in_ready(b_in_ready),
        .pe_aluc_dmode(dmode), .pe_aluc_aluop(aluop), .pe_aluc_rounda(ra), .pe_aluc_iselb(iselb),
        .x(bx), .out_valid(b_out_valid), .out_ready(b_out_ready), .z(bz), .flags(bflags),
        .out_err(b_out_err));

    // ---- routing (WP11's mn_alu_cls): every fpalu vector file must go to the unit tested here
    wire cls_int, cls_fp, cls_xpe, cls_none, cls_bad;
    mn_alu_cls u_cls (
        .dmode(dmode), .aluop(aluop), .is_unsigned(uns), .rounda(ra), .roundb(rb), .isela(isela),
        .cls_int(cls_int), .cls_fp(cls_fp), .cls_xpe(cls_xpe), .cls_none(cls_none),
        .cls_bad(cls_bad));

    // ---- vectors of the current file
    localparam integer CAP = 4096;
    reg [127:0] vx  [0:CAP-1];
    reg [127:0] vy  [0:CAP-1];
    reg [127:0] vz  [0:CAP-1];
    reg [3:0]   vf  [0:CAP-1];
    reg         vra [0:CAP-1];
    reg         vrb [0:CAP-1];
    reg [511:0] bvx [0:CAP-1];
    reg [511:0] bvz [0:CAP-1];
    reg [15:0]  bvf [0:CAP-1];
    integer nrows;

    // ---- header parsing
    function automatic string hget(input string hd, input string key);
        string k;
        integer p, e;
        k = {" ", key, "="};
        hget = "";
        for (p = 0; p + k.len() <= hd.len(); p = p + 1) begin
            if (hd.substr(p, p + k.len() - 1) == k) begin
                e = p + k.len();
                while (e < hd.len() && hd.getc(e) != " " && hd.getc(e) != 8'h0a &&
                       hd.getc(e) != 8'h0d)
                    e = e + 1;
                hget = hd.substr(p + k.len(), e - 1);
                return hget;
            end
        end
    endfunction

    function automatic bit has(input string hd, input string pat);
        integer p;
        has = 1'b0;
        for (p = 0; p + pat.len() <= hd.len(); p = p + 1)
            if (hd.substr(p, p + pat.len() - 1) == pat) begin
                has = 1'b1;
                return has;
            end
    endfunction

    // ---- run state
    integer seed, maxerr;
    integer n_files = 0, n_rows = 0, n_bad = 0, n_bad_files = 0, n_off_files = 0;
    integer n_lane_rows = 0, n_bf_rows = 0, n_skip = 0;
    string  op, fname;
    reg     rand_iselb, rand_isela;
    reg [2:0] hdr_iselb;
    reg [3:0] hdr_isela;
    integer file_bad;

    // random number in 0 .. m-1
    function automatic integer rn(input integer m);
        rn = {$random(seed)} % m;
    endfunction

    task automatic pick_sel;
        begin
            iselb = rand_iselb ? rn(8) : hdr_iselb;
            isela = rand_isela ? rn(15) : hdr_isela;
        end
    endtask

    // routing of the current request: mn_alu_cls must give cls_fp (cls_int for passa /
    // packbit, which mn_alu_int executes) and mn_fp_alu's cls_bf must tell the block-float forms
    integer n_route_bad = 0;
    reg     exp_int;
    task automatic check_route(input want_bf);
        reg ok;
        begin
            ok = (exp_int ? (cls_int & ~cls_fp) : (cls_fp & ~cls_int)) & ~cls_xpe & ~cls_none &
                 ~cls_bad & (cls_bf == want_bf);
            if (!ok) begin
                n_route_bad = n_route_bad + 1;
                if (n_route_bad <= 5)
                    $display("  ROUTE %s: dmode=%b aluop=%b u=%b ra=%b rb=%b isela=%b iselb=%b -> int %b fp %b xpe %b none %b bad %b bf %b",
                             op, dmode, aluop, uns, ra, rb, isela, iselb, cls_int, cls_fp,
                             cls_xpe, cls_none, cls_bad, cls_bf);
            end
        end
    endtask

    // lane unit: stream all rows with random gaps and back-pressure, check in order
    task automatic run_lane;
        integer sent, recv, cyc;
        reg fire_in, fire_out;
        reg [127:0] gz;
        reg [3:0] gf;
        reg ge;
        begin
            sent = 0; recv = 0; cyc = 0; fire_in = 1'b0;
            while (recv < nrows) begin
                @(negedge clk);
                // inputs change only at the falling edge
                if (fire_in) begin
                    in_valid = 1'b0;
                    x = {4{32'hdeadbeef}}; y = {4{32'hbadc0ffe}};  // inputs are not held
                end
                // a new request when none is pending
                if (!in_valid) begin
                    if (sent < nrows && rn(5) != 0) begin
                        in_valid = 1'b1;
                        x = vx[sent]; y = vy[sent]; ra = vra[sent]; rb = vrb[sent];
                        pick_sel();
                    end
                end
                out_ready = rn(4) != 0;
                #3;
                if (in_valid) check_route(1'b0);
                fire_in  = in_valid & in_ready;
                fire_out = out_valid & out_ready;
                gz = z; gf = flags; ge = out_err;
                @(posedge clk);
                if (fire_in) sent = sent + 1;
                if (fire_out) begin
                    if (gz !== vz[recv] || gf !== vf[recv] || ge !== 1'b0) begin
                        file_bad = file_bad + 1;
                        if (file_bad <= maxerr)
                            $display("  MISMATCH %s line %0d: ra=%b rb=%b x=%h y=%h | want %h %h got %h %h err %b",
                                     op, recv + 2, vra[recv], vrb[recv], vx[recv], vy[recv],
                                     vz[recv], vf[recv], gz, gf, ge);
                    end
                    recv = recv + 1;
                end
                cyc = cyc + 1;
                if (cyc > 20 * nrows + 100) begin
                    $display("  TIMEOUT %s: sent %0d received %0d of %0d", op, sent, recv, nrows);
                    file_bad = file_bad + nrows - recv;
                    recv = nrows;
                end
            end
            @(negedge clk);
            in_valid = 1'b0; out_ready = 1'b0;
        end
    endtask

    // block-float unit: one MAB-cycle at a time
    task automatic run_bf;
        integer r, cyc;
        reg done;
        begin
            for (r = 0; r < nrows; r = r + 1) begin
                @(negedge clk);
                while (rn(3) == 0) @(negedge clk);
                b_in_valid = 1'b1;
                bx = bvx[r]; ra = vra[r]; rb = 1'b0;
                pick_sel();
                #3;
                check_route(1'b1);
                cyc = 0;
                while (!b_in_ready) begin
                    @(negedge clk);
                    #3;
                    cyc = cyc + 1;
                    if (cyc > 200) begin
                        $display("FAIL %s line %0d: the block-float unit does not accept input", op, r + 2);
                        $finish;
                    end
                end
                @(negedge clk);
                b_in_valid = 1'b0;
                bx = {16{32'hdeadbeef}};
                cyc = 0;
                done = 1'b0;
                while (!done) begin
                    b_out_ready = rn(3) != 0;
                    #3;
                    if (b_out_valid && b_out_ready) begin
                        done = 1'b1;
                        if (bz !== bvz[r] || bflags !== bvf[r] || b_out_err !== 1'b0) begin
                            file_bad = file_bad + 1;
                            if (file_bad <= maxerr)
                                $display("  MISMATCH %s line %0d: ra=%b x=%h\n    want %h %h\n    got  %h %h err %b",
                                         op, r + 2, vra[r], bvx[r], bvz[r], bvf[r], bz, bflags,
                                         b_out_err);
                        end
                    end
                    @(negedge clk);
                    b_out_ready = 1'b0;
                    cyc = cyc + 1;
                    if (cyc > 200) begin
                        $display("  TIMEOUT %s line %0d", op, r + 2);
                        file_bad = file_bad + 1;
                        done = 1'b1;
                    end
                end
            end
        end
    endtask

    // ---- latency (documented in rtl/fpu/SPEC.md): request in cycle t -> result in cycle t + L
    task automatic check_latency(input bf_unit, input [1:0] dm, input [4:0] op5, input r,
                                 input integer want);
        integer t;
        begin
            @(negedge clk);
            dmode = dm; aluop = op5; ra = r; rb = 1'b0; uns = 1'b0; iselb = 3'd0; isela = 4'd0;
            out_ready = 1'b1; b_out_ready = 1'b1;
            if (bf_unit) b_in_valid = 1'b1; else in_valid = 1'b1;
            t = 0;
            @(negedge clk);
            b_in_valid = 1'b0; in_valid = 1'b0;
            while (!(bf_unit ? b_out_valid : out_valid) && t < 100) begin
                t = t + 1;
                @(negedge clk);
            end
            t = t + 1;
            if (t != want) begin
                $display("FAIL latency of %s (dmode %b, r %b): %0d cycles, expected %0d",
                         bf_unit ? "mn_fp_alu_bfn" : "mn_fp_alu", dm, r, t, want);
                $finish;
            end
            @(negedge clk);
            out_ready = 1'b0; b_out_ready = 1'b0;
        end
    endtask

    // ---- an ALUC the unit does not execute gives out_err (mn_fp_alu: z = 0, flags = 0)
    task automatic check_err(input bf_unit, input [1:0] dm, input [4:0] op5, input [2:0] sb);
        integer t;
        reg ok;
        begin
            @(negedge clk);
            dmode = dm; aluop = op5; ra = 1'b0; rb = 1'b0; uns = 1'b0; iselb = sb; isela = 4'd0;
            x = {4{32'h3f80_0001}}; y = {4{32'h4000_0003}}; bx = {16{32'h3f80_0001}};
            out_ready = 1'b1; b_out_ready = 1'b1;
            if (bf_unit) b_in_valid = 1'b1; else in_valid = 1'b1;
            @(negedge clk);
            b_in_valid = 1'b0; in_valid = 1'b0;
            t = 0;
            while (!(bf_unit ? b_out_valid : out_valid) && t < 100) begin
                t = t + 1;
                @(negedge clk);
            end
            ok = bf_unit ? (b_out_err === 1'b1) :
                           (out_err === 1'b1 && z === 128'd0 && flags === 4'd0);
            if (!ok) begin
                $display("FAIL %s: aluop %b iselb %b was not reported with out_err",
                         bf_unit ? "mn_fp_alu_bfn" : "mn_fp_alu", op5, sb);
                $finish;
            end
            @(negedge clk);
            out_ready = 1'b0; b_out_ready = 1'b0;
        end
    endtask

    // ---- main
    integer mf, vf_fd, cnt, rc;
    string  manifest, line, hdr, s;
    reg [8*4096-1:0] lbuf;
    reg [63:0] c [0:20];
    reg bf;
    initial begin
        if (!$value$plusargs("manifest=%s", manifest))
            manifest = "mncore/sim/tb/fpalu/manifest_fixed.txt";
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("maxerr=%d", maxerr)) maxerr = 5;
        repeat (3) @(posedge clk);
        rst = 1'b0;
        check_latency(1'b0, 2'b10, 5'b11011, 1'b1, TB_RND ? 5 : 4);    // hmax with r
        check_latency(1'b1, 2'b00, 5'b11110, 1'b0, 15);                // dbfn
        check_latency(1'b1, 2'b10, 5'b11101, 1'b1, TB_RND ? 19 : 15);  // hbfe/9 with r
        if (TB_RND) $display("latency: mn_fp_alu 5, mn_fp_alu_bfn 15 (19 with r)");
        else        $display("RND = 0: latency mn_fp_alu 4, mn_fp_alu_bfn 15; r files skipped");
        check_err(1'b0, 2'b01, 5'b00000, 3'b001);  // iadd: integer ALU
        check_err(1'b0, 2'b00, 5'b11110, 3'b000);  // dbfn: block-float unit
        check_err(1'b0, 2'b10, 5'b11101, 3'b011);  // hbfe/6: block-float unit
        check_err(1'b1, 2'b01, 5'b11011, 3'b001);  // fmax: per-PE unit
        check_err(1'b1, 2'b00, 5'b11110, 3'b110);  // dfloor: per-PE unit
        $display("out_err: checked for 5 ALUCs that the units do not execute");

        mf = $fopen(manifest, "r");
        if (mf == 0) begin
            $display("FAIL cannot open manifest %s", manifest);
            $finish;
        end
        while (!$feof(mf)) begin
            rc = $fgets(lbuf, mf);
            if (rc == 0) continue;
            line = lbuf;
            // trim: up to the first blank or '#'
            fname = "";
            for (cnt = 0; cnt < line.len(); cnt = cnt + 1) begin
                if (line.getc(cnt) == " " || line.getc(cnt) == "#" || line.getc(cnt) == 8'h0a ||
                    line.getc(cnt) == 8'h0d || line.getc(cnt) == 8'h09)
                    break;
            end
            if (cnt == 0) continue;
            fname = line.substr(0, cnt - 1);
            if (TB_RND == 0 && has(fname, ".r.vec")) begin
                n_skip = n_skip + 1;
                continue;
            end

            vf_fd = $fopen(fname, "r");
            if (vf_fd == 0) begin
                $display("FAIL cannot open %s", fname);
                $finish;
            end
            rc = $fgets(lbuf, vf_fd);
            hdr = lbuf;
            if (hget(hdr, "unit") != "fpalu") begin
                $display("FAIL %s: not an fpalu vector file", fname);
                $finish;
            end
            op = hget(hdr, "op");
            if (has(fname, ".r.vec")) op = {op, ".r"};  // the op name does not carry the r
            s = hget(hdr, "dmode");
            dmode = s.atobin();
            s = hget(hdr, "aluop");
            aluop = s.atobin();
            s = hget(hdr, "is_unsigned");
            uns = s.atobin();
            s = hget(hdr, "iselb");
            rand_iselb = (s.len() == 0);
            hdr_iselb = s.atobin();
            s = hget(hdr, "isela");
            rand_isela = (s.len() == 0);
            hdr_isela = s.atobin();
            bf = has(hdr, " x0_hi");
            exp_int = (aluop == 5'b01010) || (aluop == 5'b10011);  // passa, packbit
            if (hget(hdr, "expect") == "official") n_off_files = n_off_files + 1;
            else if (hget(hdr, "disputed") != "") begin
                // the expected values of this file are the Rust simulator's (contract section 5)
                $display("FAIL %s: disputed= without expect=official (run vecgen --official-expect)",
                         fname);
                $finish;
            end

            // rows
            nrows = 0;
            while (!$feof(vf_fd) && nrows < CAP) begin
                if (bf) begin
                    rc = $fscanf(vf_fd, " %h %h %h %h %h %h %h %h %h | %h %h %h %h %h %h %h %h %h %h %h %h",
                                 c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8],
                                 c[9], c[10], c[11], c[12], c[13], c[14], c[15], c[16],
                                 c[17], c[18], c[19], c[20]);
                    if (rc != 21) break;
                    vra[nrows] = c[0][0];
                    bvx[nrows] = {c[7], c[8], c[5], c[6], c[3], c[4], c[1], c[2]};
                    bvz[nrows] = {c[15], c[16], c[13], c[14], c[11], c[12], c[9], c[10]};
                    bvf[nrows] = {c[20][3:0], c[19][3:0], c[18][3:0], c[17][3:0]};
                end else begin
                    rc = $fscanf(vf_fd, " %h %h %h %h %h %h | %h %h %h",
                                 c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]);
                    if (rc != 9) break;
                    vra[nrows] = c[0][0];
                    vrb[nrows] = c[1][0];
                    vx[nrows] = {c[2], c[3]};
                    vy[nrows] = {c[4], c[5]};
                    vz[nrows] = {c[6], c[7]};
                    vf[nrows] = c[8][3:0];
                end
                nrows = nrows + 1;
            end
            $fclose(vf_fd);
            s = hget(hdr, "rows");
            if (nrows == 0 || (s.len() != 0 && s.atoi() != nrows)) begin
                $display("FAIL %s: read %0d rows, header says %s", fname, nrows, s);
                $finish;
            end

            file_bad = 0;
            if (bf) begin
                run_bf();
                n_bf_rows = n_bf_rows + nrows;
            end else begin
                run_lane();
                n_lane_rows = n_lane_rows + nrows;
            end
            n_files = n_files + 1;
            n_rows = n_rows + nrows;
            n_bad = n_bad + file_bad;
            if (file_bad != 0) n_bad_files = n_bad_files + 1;
            line = "";
            if (file_bad != 0) line = $sformatf(", %0d mismatches", file_bad);
            s = hget(hdr, "disputed");
            if (s.len() != 0) begin
                line = {line, " (disputed=", s};
                s = hget(hdr, "expect");
                line = {line, ", expect=", s, ")"};
            end
            $display("%s %-12s %5d rows%s", (file_bad != 0) ? "BAD" : "ok ", op, nrows, line);
            $fflush();
        end
        $fclose(mf);

        $display("files %0d (expect=official %0d, skipped %0d), rows %0d (lane %0d, block float %0d), mismatching rows %0d in %0d files",
                 n_files, n_off_files, n_skip, n_rows, n_lane_rows, n_bf_rows, n_bad, n_bad_files);
        $display("routing (mn_alu_cls, cls_bf): %0d errors", n_route_bad);
        if (n_files == 0)
            $display("FAIL no vector files");
        else if (n_bad != 0)
            $display("FAIL %0d mismatching rows", n_bad);
        else if (n_route_bad != 0)
            $display("FAIL %0d routing errors", n_route_bad);
        else
            $display("PASS");
        $finish;
    end
endmodule

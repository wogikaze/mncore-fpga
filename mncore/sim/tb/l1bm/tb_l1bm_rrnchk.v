// tb_l1bm_rrnchk: mn_l1bm_rrn against the rrn vectors (WP03, all checked on the official emulator).
//
//   +rrndir=<dir>      vector directory (default mncore/sim/vectors_fixed/rrn; the full
//                      generated set is mncore/sim/vectors/rrn)
//   +manifest=<file>   default mncore/sim/tb/l1bm/rrn_manifest.txt (gen_rrn_manifest.py)
// Every row of every file: the inputs go to in_val (halves extended to single where the
// manifest says ext), the result must equal z. Starts on go, fin when all files are done.
`timescale 1ns/1ps
`default_nettype none
module tb_l1bm_rrnchk (
    input  wire        clk,
    input  wire        go,
    output reg         fin,
    output reg  [31:0] nrows,
    output reg  [31:0] nbad
);
    reg         rst = 1'b1;
    reg  [2:0]  op = 3'd0;
    reg  [1:0]  fmt = 2'd0;
    reg         out_half = 1'b0, two_stage = 1'b0, ext = 1'b0;
    reg  [3:0]  nin_m1 = 4'd3;
    reg         start = 1'b0;
    wire [3:0]  in_idx;
    reg  [63:0] xin [0:15];
    wire        busy, done;
    wire [63:0] res;

    function [63:0] h2s(input [15:0] h);   // precision extension half -> single
        begin
            if (h[14:9] == 6'd0)       h2s = 64'd0;
            else if (h[14:9] == 6'h3f) h2s = {32'd0, h[15], 8'hff, 23'd0};
            else                       h2s = {32'd0, h[15], {2'b00, h[14:9]} + 8'd96, h[8:0], 14'd0};
        end
    endfunction
    wire [63:0] in_val = ext ? h2s(xin[in_idx][15:0]) : xin[in_idx];

    mn_l1bm_rrn dut (
        .clk(clk), .rst(rst), .start(start), .op(op), .fmt(fmt), .out_half(out_half),
        .two_stage(two_stage), .nin_m1(nin_m1), .zgrp(4'd0), .in_idx(in_idx), .in_val(in_val),
        .busy(busy), .done(done), .res(res));

    integer mf, vf, r, nfiles, k, nin, opi, fmti, ohi, tsi, nmi, exi, cyc, maxcyc;
    reg [8*256-1:0] dir, man, name, path, line;
    reg [63:0] z, got, wm;
    reg [7:0] bar;
    initial begin
        fin = 1'b0; nrows = 0; nbad = 0;
        wait (go);
        if (!$value$plusargs("rrndir=%s", dir)) dir = "mncore/sim/vectors_fixed/rrn";
        if (!$value$plusargs("manifest=%s", man)) man = "mncore/sim/tb/l1bm/rrn_manifest.txt";
        nfiles = 0; maxcyc = 0;
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        mf = $fopen(man, "r");
        if (mf == 0) begin
            $display("rrn: ERROR cannot open %0s", man);
            nbad = 1;
        end else begin
            while ($fscanf(mf, "%d %d %d %d %d %d %d %s\n", opi, fmti, ohi, tsi, nmi, exi, nin, name) == 8) begin
                op = opi[2:0]; fmt = fmti[1:0]; out_half = ohi[0]; two_stage = tsi[0];
                nin_m1 = nmi[3:0]; ext = exi[0];
                $sformat(path, "%0s/%0s.vec", dir, name);
                vf = $fopen(path, "r");
                if (vf == 0) begin
                    $display("rrn: ERROR cannot open %0s", path);
                    nbad = nbad + 1;
                end else begin
                    r = $fgets(line, vf);   // header
                    nfiles = nfiles + 1;
                    wm = (fmt == 2'd0 && !out_half) ? 64'hffffffffffffffff :
                         (fmt == 2'd2 || out_half) ? 64'h000000000000ffff : 64'h00000000ffffffff;
                    forever begin
                        r = $fscanf(vf, "%h", xin[0]);
                        if (r != 1) break;
                        for (k = 1; k < nin; k = k + 1) r = $fscanf(vf, "%h", xin[k]);
                        for (k = nin; k < 16; k = k + 1) xin[k] = 64'd0;
                        r = $fscanf(vf, " %c", bar);
                        r = $fscanf(vf, "%h", z);
                        @(posedge clk);
                        start <= 1'b1;
                        @(posedge clk);
                        start <= 1'b0;
                        cyc = 1;
                        while (!done) begin
                            @(posedge clk);
                            cyc = cyc + 1;
                        end
                        if (cyc > maxcyc) maxcyc = cyc;
                        got = res & wm;
                        nrows = nrows + 1;
                        if (got !== z) begin
                            nbad = nbad + 1;
                            if (nbad <= 10)
                                $display("rrn: MISMATCH %0s row %0d: in %h %h %h %h .. expected %h got %h", name,
                                         nrows, xin[0], xin[1], xin[2], xin[3], z, got);
                        end
                    end
                    $fclose(vf);
                end
            end
            $fclose(mf);
        end
        $display("rrn: %0d files, %0d rows, %0d mismatches, at most %0d clocks per lane (%0s)", nfiles, nrows,
                 nbad, maxcyc, dir);
        fin = 1'b1;
    end
endmodule
`default_nettype wire

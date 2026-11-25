// tb_core: runs command scripts on mn_core through its host ports (WP20).
//
//   vvp sim.vvp [+script=FILE] [+maxclk=N] [+quiet]
//
// The script is what mncore/sim/regress/run.py (or gen_fixed.py) makes from an assembled
// program, the same sequence as `mnhost.py run` on the board (PROTOCOL.md section 6):
//   C                                  reset the core for 16 clocks, like the RESET command: mn_core
//                                      then clears the PE state (GRF0/GRF1/LM0/LM1/T, OMR, $mb/$nb
//                                      = 0, the official emulator's initial state); the following
//                                      commands wait for it (mw_ready / mr_ready)
//   Z                                  clear the PE state through the host ports instead (WR_MEM)
//   I <entry> <448-bit hex>            write an instruction memory entry (lanes 0..6, space 0)
//   W <space> <loc> <addr> <mask> <data>   WR_MEM of one long word (hex fields)
//   R <tag> <space> <loc> <addr> <n>   RD_MEM of n long words; prints "D <tag> <space> <addr> <value>"
//                                      or "DERR <tag> <space> <addr>"
//   Q <space> <loc> <addr> <value>     read one long word and check it (self-test)
//   X <pc> <count>                     RUN; prints "S <reason> <info> <pc> <steps> <trap> <clocks>"
//                                      (after a RUN that stopped with WAIT, reason 4 (M2), the program
//                                      blocks there like on the official emulator: later X print the
//                                      same stop without running, later W are skipped, until C)
//   K <reason> <info>                  check the stop record of the last RUN (self-test)
//   P <pc> <steps>                     check core_pc and core_steps of the last RUN (self-test)
//   E                                  end
//   # ...                              comment
// All numbers are hex. The last line is PASS (no failed check, no port error) or FAIL.
// Compile with -DTB_FPALU=0 / -DTB_MAU=0 for the reduced cores (mncore/sim/regress/run.py --define),
// -DTB_NPE=4 for the time-multiplexed MAB of 4 PEs (WP30; then LM_AW = 8 unless -DTB_LMAW=n, and
// -DTB_BFN=0 leaves out bfn / bfe). The 4 PEs are at loc 0..3 (n0c0b0m0p0..p3).
// -DTB_MAT=1 adds the matrix register and matrix MAU of the MAB (WP36, with TB_NPE=4).
// -DTB_M2=1 adds the L1BM, L2BM and MV units (WP37, with TB_NPE=4; -DTB_REPLICA=1 the replica rule)
// and the behavioural SDRAM bus memory tb_sdmem (mncore/sim/tb/m2) for the PDM / DRAM; C also
// clears that memory (the board design clears the DRAM / PDM after reset, mn_core SDCLR). The spaces
// 0x06 L1BM, 0x07 L2BM, 0x08 PDM, 0x09 DRAM go through W / R like the others.
`timescale 1ns/1ps
`ifndef TB_FPALU
`define TB_FPALU 1
`endif
`ifndef TB_MAU
`define TB_MAU 1
`endif
`ifndef TB_NPE
`define TB_NPE 1
`endif
`ifndef TB_BFN
`define TB_BFN 1
`endif
`ifndef TB_MAT
`define TB_MAT 0
`endif
`ifndef TB_LMAW
`define TB_LMAW ((`TB_NPE > 1) ? 8 : 9)
`endif
`ifndef TB_M2
`define TB_M2 0
`endif
`ifndef TB_REPLICA
`define TB_REPLICA 0
`endif
// -DTB_SDCLR=1: the core clears the DRAM / PDM after reset itself (mn_core SDCLR, the board's setting),
// on a small DRAM / PDM (-DTB_DRAM_AW / -DTB_PDM_AW, default 10 / 8) so that the clear is short;
// C then does not clear tb_sdmem
`ifndef TB_SDCLR
`define TB_SDCLR 0
`endif
`ifndef TB_DRAM_AW
`define TB_DRAM_AW ((`TB_SDCLR != 0) ? 10 : 19)
`endif
`ifndef TB_PDM_AW
`define TB_PDM_AW ((`TB_SDCLR != 0) ? 8 : 17)
`endif
module tb_core;
    localparam IMEM_AW = 9, LM_AW = `TB_LMAW, GRF_AW = 8, NPE = `TB_NPE;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg         mw_valid = 1'b0;
    wire        mw_ready, mw_err;
    reg  [7:0]  mw_space = 8'd0;
    reg  [15:0] mw_loc = 16'd0;
    reg  [22:0] mw_addr = 23'd0;
    reg  [63:0] mw_data = 64'd0;
    reg  [7:0]  mw_mask = 8'd0;
    reg         mr_valid = 1'b0;
    wire        mr_ready, mr_err;
    reg  [7:0]  mr_space = 8'd0;
    reg  [15:0] mr_loc = 16'd0;
    reg  [22:0] mr_addr = 23'd0;
    wire        mr_rsp_valid;
    wire [63:0] mr_rsp_data;
    reg         run_start = 1'b0;
    reg  [15:0] run_pc = 16'd0;
    reg  [31:0] run_count = 32'd0;
    wire        core_busy;
    wire [7:0]  core_reason;
    wire [31:0] core_info;
    wire [15:0] core_pc;
    wire [31:0] core_steps;
    wire [16:0] core_trap;
    wire        sd_req_valid, sd_req_ready, sd_req_we, sd_rsp_valid, sd_err_addr, unit_busy, unit_err;
    wire [22:0] sd_req_addr;
    wire [63:0] sd_req_wdata, sd_rsp_rdata;
    wire [7:0]  sd_req_wmask;

    mn_core #(.IMEM_AW(IMEM_AW), .IMEM_RD(1), .LM_AW(LM_AW), .GRF_AW(GRF_AW),
              .FPALU(`TB_FPALU), .MAU(`TB_MAU), .N_PE(NPE), .BFN(`TB_BFN), .MAT(`TB_MAT),
              .M2(`TB_M2), .REPLICA(`TB_REPLICA), .SDCLR(`TB_SDCLR), .DRAM_AW(`TB_DRAM_AW),
              .PDM_AW(`TB_PDM_AW)) dut (
        .clk(clk), .rst(rst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space),
        .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space),
        .mr_loc(mr_loc), .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps), .core_trap(core_trap),
        .sd_req_valid(sd_req_valid), .sd_req_ready(sd_req_ready), .sd_req_we(sd_req_we),
        .sd_req_addr(sd_req_addr), .sd_req_wdata(sd_req_wdata), .sd_req_wmask(sd_req_wmask),
        .sd_rsp_valid(sd_rsp_valid), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(sd_err_addr),
        .unit_busy(unit_busy), .unit_err(unit_err)
    );
`ifdef TB_SDMEM
    // the PDM / DRAM (WP37, files of mncore/sim/tb/m2)
    tb_sdmem #(.AW(20)) u_sdmem (
        .clk(clk), .rst(rst), .req_valid(sd_req_valid), .req_ready(sd_req_ready), .req_we(sd_req_we),
        .req_addr(sd_req_addr), .req_wdata(sd_req_wdata), .req_wmask(sd_req_wmask),
        .rsp_valid(sd_rsp_valid), .rsp_rdata(sd_rsp_rdata), .err_addr(sd_err_addr));
`else
    assign sd_req_ready = 1'b0;
    assign sd_rsp_valid = 1'b0;
    assign sd_rsp_rdata = 64'd0;
    assign sd_err_addr  = 1'b0;
`endif

    integer clocks = 0;
    always @(posedge clk) clocks <= clocks + 1;

    // ------------------------------------------------------------------ host port tasks
    task automatic mem_write(input [7:0] sp, input [15:0] loc, input [22:0] a, input [7:0] mask,
                             input [63:0] d, output reg err);
        begin
            @(negedge clk);
            mw_valid = 1'b1; mw_space = sp; mw_loc = loc; mw_addr = a; mw_mask = mask; mw_data = d;
            #1;
            while (!mw_ready) begin @(negedge clk); #1; end
            err = mw_err;
            @(negedge clk);
            mw_valid = 1'b0;
        end
    endtask

    task automatic mem_read(input [7:0] sp, input [15:0] loc, input [22:0] a, output reg [63:0] d,
                            output reg err);
        integer t;
        begin
            @(negedge clk);
            mr_valid = 1'b1; mr_space = sp; mr_loc = loc; mr_addr = a;
            #1;
            while (!mr_ready) begin @(negedge clk); #1; end
            err = mr_err;
            d = 64'd0;
            @(negedge clk);
            mr_valid = 1'b0;
            if (!err) begin
                t = 0;
                #1;
                while (!mr_rsp_valid && t < 1000) begin @(negedge clk); #1; t = t + 1; end
                if (mr_rsp_valid) d = mr_rsp_data;
                else err = 1'b1;
            end
        end
    endtask

    // ------------------------------------------------------------------ DRAM / PDM backdoor (WP37)
    // With TB_SDMEM, W / R of the DRAM (space 9) and PDM (8) of n0 at long word 64 and above go
    // straight into / out of tb_sdmem's array (zero time; the core is idle between RUNs): the large
    // `r` line images and the DRAM probe of the M2 regression would otherwise take most of the
    // simulation. Long words 0..63 go through the host port (mn_mv), like the board. +nobd: all through
    // the host port.
    reg nobd = 1'b0;
    initial nobd = $test$plusargs("nobd");
    function automatic bd_ok(input [7:0] sp, input [15:0] loc, input [22:0] a);
        bd_ok = 1'b0;
`ifdef TB_SDMEM
        bd_ok = !nobd && (sp == 8'h08 || sp == 8'h09) && (loc == 16'd0) && (a >= 23'd64) &&
                (a < ((sp == 8'h08) ? (23'd1 << `TB_PDM_AW) : (23'd1 << `TB_DRAM_AW)));
`endif
    endfunction
    task automatic bd_write(input [7:0] sp, input [22:0] a, input [7:0] mask, input [63:0] d, output reg err);
        reg [19:0] sa;
        begin
            err = 1'b0;
            sa  = (sp == 8'h08) ? (20'h80000 | a[19:0]) : a[19:0];
`ifdef TB_SDMEM
            if (|mask[7:4]) u_sdmem.mem[sa][63:32] = d[63:32];
            if (|mask[3:0]) u_sdmem.mem[sa][31:0]  = d[31:0];
`endif
        end
    endtask
    task automatic bd_read(input [7:0] sp, input [22:0] a, output reg [63:0] d, output reg err);
        reg [19:0] sa;
        begin
            err = 1'b0;
            d   = 64'd0;
            sa  = (sp == 8'h08) ? (20'h80000 | a[19:0]) : a[19:0];
`ifdef TB_SDMEM
            d = u_sdmem.mem[sa];
`endif
        end
    endtask

    // ------------------------------------------------------------------ script
    integer fd, rc, maxclk, nchk, nfail, nerr, i, n, ctag, t0, zp;
    reg [8*16-1:0] word;
    reg [7:0]   c;
    reg [447:0] ent;
    reg [31:0]  a0, a1, a2, a3, a4;
    reg [63:0]  v, d;
    reg         err, quiet, done_scr;
    reg         blocked = 1'b0;    // a RUN stopped with WAIT (reason 4): the program blocks there
    reg [31:0]  blk_info = 32'd0;
    reg [15:0]  blk_pc = 16'd0;
    reg [8*256-1:0] fname;
    reg [8*1024-1:0] line;

    initial begin
`ifdef TB_SCRIPT
        if (!$value$plusargs("script=%s", fname)) fname = `TB_SCRIPT;
`else
        if (!$value$plusargs("script=%s", fname)) fname = "mncore/sim/tb/core/fixed/all.scr";
`endif
        if (!$value$plusargs("maxclk=%d", maxclk)) maxclk = 2000000;
        quiet = $test$plusargs("quiet");
        nchk = 0; nfail = 0; nerr = 0;
        fd = $fopen(fname, "r");
        if (fd == 0) begin
            $display("FAIL cannot open script %0s", fname);
            $finish;
        end
        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);
        done_scr = 1'b0;
        while (!done_scr && !$feof(fd)) begin
            rc = $fscanf(fd, " %c", c);
            if (rc != 1) begin
                done_scr = 1'b1;
            end else begin
                case (c)
                    "#": rc = $fgets(line, fd);
                    "E": done_scr = 1'b1;
                    "C": begin
                        @(negedge clk);
                        rst = 1'b1;
                        blocked = 1'b0;
`ifdef TB_SDMEM
                        if (`TB_SDCLR == 0) u_sdmem.clear;   // the board clears the DRAM / PDM after RESET (SDCLR)
`endif
                        repeat (16) @(negedge clk);
                        rst = 1'b0;
                    end
                    "Z": for (zp = 0; zp < NPE; zp = zp + 1) begin
                        for (i = 0; i < (1 << GRF_AW); i = i + 1) begin
                            mem_write(8'h03, zp, i, 8'hff, 64'd0, err); nerr = nerr + err;
                            mem_write(8'h04, zp, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        for (i = 0; i < (1 << LM_AW); i = i + 1) begin
                            mem_write(8'h01, zp, i, 8'hff, 64'd0, err); nerr = nerr + err;
                            mem_write(8'h02, zp, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        for (i = 0; i < 8; i = i + 1) begin
                            mem_write(8'h05, zp, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        for (i = 1; i < 16; i = i + 1) begin
                            mem_write(8'h10, zp, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        mem_write(8'h11, zp, 0, 8'hff, 64'd0, err); nerr = nerr + err;
                        mem_write(8'h11, zp, 1, 8'hff, 64'd0, err); nerr = nerr + err;
                    end
                    "I": begin
                        rc = $fscanf(fd, "%h %h", a0, ent);
                        for (i = 0; i < 7; i = i + 1) begin
                            mem_write(8'h00, 16'd0, a0 * 8 + i, 8'hff, ent[64*i +: 64], err);
                            if (err) begin
                                $display("ERR imem write entry %0d lane %0d rejected", a0, i);
                                nerr = nerr + 1;
                            end
                        end
                    end
                    "W": begin
                        rc = $fscanf(fd, "%h %h %h %h %h", a0, a1, a2, a3, v);
                        if (blocked) err = 1'b0;   // after a WAIT stop: no more d set (WP37)
                        else if (bd_ok(a0[7:0], a1[15:0], a2[22:0])) bd_write(a0[7:0], a2[22:0], a3[7:0], v, err);
                        else mem_write(a0[7:0], a1[15:0], a2[22:0], a3[7:0], v, err);
                        if (err) begin
                            $display("ERR write space %0h loc %0h addr %0h rejected", a0, a1, a2);
                            nerr = nerr + 1;
                        end
                    end
                    "R": begin
                        rc = $fscanf(fd, "%h %h %h %h %h", a4, a0, a1, a2, a3);
                        for (i = 0; i < a3; i = i + 1) begin
                            if (bd_ok(a0[7:0], a1[15:0], a2[22:0] + i)) bd_read(a0[7:0], a2[22:0] + i, d, err);
                            else mem_read(a0[7:0], a1[15:0], a2[22:0] + i, d, err);
                            if (err) $display("DERR %0h %0h %0h", a4, a0, a2 + i);
                            else     $display("D %0h %0h %0h %016h", a4, a0, a2 + i, d);
                        end
                    end
                    "Q": begin
                        rc = $fscanf(fd, "%h %h %h %h", a0, a1, a2, v);
                        mem_read(a0[7:0], a1[15:0], a2[22:0], d, err);
                        nchk = nchk + 1;
                        if (err || d !== v) begin
                            nfail = nfail + 1;
                            if (nfail <= 50)
                                $display("MISMATCH space %0h loc %0h addr %0h: got %016h%0s expected %016h",
                                         a0, a1, a2, d, err ? " (error)" : "", v);
                        end
                    end
                    "X": begin
                        rc = $fscanf(fd, "%h %h", a0, a1);
                        if (blocked) begin
                            // after a WAIT stop the official blocks for ever: no more RUNs
                            $display("S 4 %0h %0h 0 0 0", blk_info, blk_pc);
                        end else begin
                            @(negedge clk);
                            run_start = 1'b1; run_pc = a0[15:0]; run_count = a1;
                            @(negedge clk);
                            run_start = 1'b0;
                            t0 = clocks;
                            while (core_busy && (clocks - t0) < maxclk) @(negedge clk);
                            if (core_busy) begin
                                $display("S TIMEOUT pc %0h steps %0h after %0d clocks", core_pc, core_steps, clocks - t0);
                                nerr = nerr + 1;
                                done_scr = 1'b1;
                            end else begin
                                $display("S %0h %0h %0h %0h %0h %0d", core_reason, core_info, core_pc, core_steps,
                                         core_trap, clocks - t0);
                                if (core_reason == 8'd4) begin
                                    blocked  = 1'b1;
                                    blk_info = core_info;
                                    blk_pc   = core_pc;
                                end
                            end
                        end
                    end
                    "K": begin
                        rc = $fscanf(fd, "%h %h", a0, a1);
                        nchk = nchk + 1;
                        if (core_reason !== a0[7:0] || core_info !== a1) begin
                            nfail = nfail + 1;
                            $display("MISMATCH status: reason %0h info %0h, expected %0h %0h",
                                     core_reason, core_info, a0, a1);
                        end
                    end
                    "P": begin
                        rc = $fscanf(fd, "%h %h", a0, a1);
                        nchk = nchk + 1;
                        if (core_pc !== a0[15:0] || core_steps !== a1) begin
                            nfail = nfail + 1;
                            $display("MISMATCH status: pc %0h steps %0h, expected %0h %0h",
                                     core_pc, core_steps, a0, a1);
                        end
                    end
                    default: begin
                        $display("ERR unknown script command '%c'", c);
                        nerr = nerr + 1;
                        rc = $fgets(line, fd);
                    end
                endcase
            end
        end
        $fclose(fd);
        if (!quiet) $display("tb_core: %0d checks, %0d mismatches, %0d port errors, %0d clocks",
                             nchk, nfail, nerr, clocks);
        if (nfail == 0 && nerr == 0) $display("PASS %0d checks", nchk);
        else $display("FAIL %0d mismatches, %0d errors", nfail, nerr);
        $finish;
    end
endmodule

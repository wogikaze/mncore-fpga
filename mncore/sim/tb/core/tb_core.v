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
//   K <reason> <info>                  check the stop record of the last RUN (self-test)
//   E                                  end
//   # ...                              comment
// All numbers are hex. The last line is PASS (no failed check, no port error) or FAIL.
// Compile with -DTB_FPALU=0 / -DTB_MAU=0 for the reduced cores (mncore/sim/regress/run.py --define).
`timescale 1ns/1ps
`ifndef TB_FPALU
`define TB_FPALU 1
`endif
`ifndef TB_MAU
`define TB_MAU 1
`endif
module tb_core;
    localparam IMEM_AW = 9, LM_AW = 9, GRF_AW = 8;

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

    mn_core #(.IMEM_AW(IMEM_AW), .IMEM_RD(1), .LM_AW(LM_AW), .GRF_AW(GRF_AW),
              .FPALU(`TB_FPALU), .MAU(`TB_MAU)) dut (
        .clk(clk), .rst(rst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space),
        .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space),
        .mr_loc(mr_loc), .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps), .core_trap(core_trap)
    );

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

    // ------------------------------------------------------------------ script
    integer fd, rc, maxclk, nchk, nfail, nerr, i, n, ctag, t0;
    reg [8*16-1:0] word;
    reg [7:0]   c;
    reg [447:0] ent;
    reg [31:0]  a0, a1, a2, a3, a4;
    reg [63:0]  v, d;
    reg         err, quiet, done_scr;
    reg [8*256-1:0] fname;
    reg [8*1024-1:0] line;

    initial begin
        if (!$value$plusargs("script=%s", fname)) fname = "mncore/sim/tb/core/fixed/all.scr";
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
                        repeat (16) @(negedge clk);
                        rst = 1'b0;
                    end
                    "Z": begin
                        for (i = 0; i < (1 << GRF_AW); i = i + 1) begin
                            mem_write(8'h03, 16'd0, i, 8'hff, 64'd0, err); nerr = nerr + err;
                            mem_write(8'h04, 16'd0, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        for (i = 0; i < (1 << LM_AW); i = i + 1) begin
                            mem_write(8'h01, 16'd0, i, 8'hff, 64'd0, err); nerr = nerr + err;
                            mem_write(8'h02, 16'd0, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        for (i = 0; i < 8; i = i + 1) begin
                            mem_write(8'h05, 16'd0, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        for (i = 1; i < 16; i = i + 1) begin
                            mem_write(8'h10, 16'd0, i, 8'hff, 64'd0, err); nerr = nerr + err;
                        end
                        mem_write(8'h11, 16'd0, 0, 8'hff, 64'd0, err); nerr = nerr + err;
                        mem_write(8'h11, 16'd0, 1, 8'hff, 64'd0, err); nerr = nerr + err;
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
                        mem_write(a0[7:0], a1[15:0], a2[22:0], a3[7:0], v, err);
                        if (err) begin
                            $display("ERR write space %0h loc %0h addr %0h rejected", a0, a1, a2);
                            nerr = nerr + 1;
                        end
                    end
                    "R": begin
                        rc = $fscanf(fd, "%h %h %h %h %h", a4, a0, a1, a2, a3);
                        for (i = 0; i < a3; i = i + 1) begin
                            mem_read(a0[7:0], a1[15:0], a2[22:0] + i, d, err);
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
                        end else
                            $display("S %0h %0h %0h %0h %0h %0d", core_reason, core_info, core_pc, core_steps,
                                     core_trap, clocks - t0);
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

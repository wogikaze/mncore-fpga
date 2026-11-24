// tb_l1bm_env: runs a test file on mn_l1bm with a PE stub of N_MAB MABs (WP31 testbench).
//
// Test file (gen_tests.py; the expected values are the official emulator's, contract 1):
//   T <name> <init_mabs> <seed> <style> <lb_zero>   begin a test: reset the unit, make the initial
//        data with splitmix64(seed) (gen_tests.py / l1prog.py Init: L1BM long words 0..1023, then
//        for each PE of MABs < init_mabs GRF0, GRF1 long words 0..31, LM0, LM1 0..63, T 0..7),
//        write the L1BM through port B
//   W <kind> <arg> <word>   a j word (hex): kind 0 executes it, 1 expects E_RANGE (chk_trap) and
//        stops the test there, 2 expects E_UNSUPPORTED with field arg (chk_unsup, chk_field)
//   K L <block> <hash>      FNV-1a 64 of L1BM long words 64 block .. 64 block + 63 (port B reads)
//   K P <pe> <space> <hash> FNV-1a 64 of the PE's 32-bit words: space 0 GRF0 0..63, 1 GRF1 0..63,
//                           2 LM0 0..127, 3 LM1 0..127, 4 T 0..15 (cycle-major)
//   E                       end of the test
// The PE stub executes what the tests use (and gen_tests.py only emits such words, its model
// raises otherwise): the PE -> L1BM operand ($lr $ls $t $lm $ln, cycle addresses and word
// lengths of the word), destinations with isel 10 (GRF0 GRF1 LM0 LM1 T) with zero flush by a
// literal pattern, $lbf, and ?passa (isel 01) of a memory operand or of $lbf. Per word: every
// read first (sources, ?passa input, $lbf), then start, src pushes, results, writes, commit.
`timescale 1ns/1ps
`default_nettype none
module tb_l1bm_env #(
    parameter N_MAB = 1,
    parameter RRN   = 1,
    parameter TESTS = "mncore/sim/tb/l1bm/fixed/m1.tst",
    parameter PARG  = "m1=%s",     // plusarg that replaces TESTS
    parameter TAG   = "m1"
) (
    input  wire clk,
    input  wire go,
    output reg  fin,
    output reg  [31:0] ntests,
    output reg  [31:0] nfail
);
    localparam NPE = 4 * N_MAB;
    localparam LMW = 4096;     // LM words per PE (the chip's)
    localparam GRW = 512;      // GRF words per PE
    integer err;               // stub errors of the current test

    // ------------------------------------------------------------------ DUT
    reg          rst = 1'b1;
    reg  [425:0] jw = 426'd0;
    wire [1:0]   ll, bmode, zsel, t_isel, r0_isel, r1_isel, m0_isel, m1_isel;
    wire         lwrite, rmode, me, dmode, ext, rnd, wl, mwl, zero;
    wire [12:0]  ladr;
    wire [3:0]   mabadr, opcode, alu_isela;
    wire [2:0]   isel;
    wire [4:0]   imr, aluop;
    wire [1:0]   alu_dmode;
    wire         t_wr, r0_wr, r1_wr, m0_wr, m1_wr;
    wire [1:0]   r0_rwl, r0_wwl, r1_rwl, r1_wwl, m0_wl, m1_wl;
    wire [35:0]  c_r0w, c_r0r, c_r1w, c_r1r;
    wire [47:0]  c_m0, c_m1;
    wire         is_imm;
    /* verilator lint_off PINMISSING */
    mn_dec_j u_dec (
        .jw(jw), .ll(ll), .pe_mrc_imr(imr), .pe_mrc_wl(mwl), .pe_mrc_zero(zero), .pe_mrc_zero_sel(zsel),
        .pe_trc_write(t_wr), .pe_trc_isel(t_isel),
        .pe_rfc0_write(r0_wr), .pe_rfc0_isel(r0_isel), .pe_rfc0_wwl(r0_wwl), .pe_rfc0_rwl(r0_rwl),
        .pe_rfc1_write(r1_wr), .pe_rfc1_isel(r1_isel), .pe_rfc1_wwl(r1_wwl), .pe_rfc1_rwl(r1_rwl),
        .pe_lm0_write(m0_wr), .pe_lm0_isel(m0_isel), .pe_lm0_wl(m0_wl),
        .pe_lm1_write(m1_wr), .pe_lm1_isel(m1_isel), .pe_lm1_wl(m1_wl),
        .pe_aluc_dmode(alu_dmode), .pe_aluc_aluop(aluop), .pe_aluc_isela(alu_isela),
        .l1bm_bmode(bmode), .l1bm_lwrite(lwrite), .l1bm_rmode(rmode), .l1bm_me(me), .l1bm_ladr(ladr),
        .l1bm_dmode(dmode), .l1bm_ext(ext), .l1bm_round_out(rnd), .l1bm_mabadr(mabadr),
        .l1bm_opcode(opcode), .l1bm_isel(isel), .l1bm_wl(wl),
        .cyc_rfc0_w(c_r0w), .cyc_rfc0_r(c_r0r), .cyc_rfc1_w(c_r1w), .cyc_rfc1_r(c_r1r),
        .cyc_lm0(c_m0), .cyc_lm1(c_m1), .is_imm(is_imm));
    /* verilator lint_on PINMISSING */

    wire         use_src, lbf_upd, chk_trap, chk_unsup, idle, done, res_ready, res_valid;
    wire [12:0]  chk_addr;
    wire [6:0]   chk_field;
    wire [127:0] res_data, lbf_rdata;
    reg          start = 1'b0, commit = 1'b0, src_we = 1'b0, res_req = 1'b0, lbf_we = 1'b0;
    reg  [3:0]   src_mab = 4'd0, res_mab = 4'd0, lbf_rmab = 4'd0, lbf_wmab = 4'd0;
    reg  [1:0]   src_pe = 2'd0, src_cycle = 2'd0, res_pe = 2'd0, res_cycle = 2'd0;
    reg  [1:0]   lbf_rpe = 2'd0, lbf_rcycle = 2'd0, lbf_wpe = 2'd0, lbf_wcycle = 2'd0;
    reg  [127:0] src_data = 128'd0, lbf_wdata = 128'd0;
    reg          b_req_valid = 1'b0, b_req_we = 1'b0;
    reg  [22:0]  b_req_addr = 23'd0;
    reg  [63:0]  b_req_wdata = 64'd0;
    wire         b_req_ready, b_req_err, b_rsp_valid;
    wire [63:0]  b_rsp_rdata;

    mn_l1bm #(.N_MAB(N_MAB), .AW(10), .RRN(RRN), .CLEAR(1)) dut (
        .clk(clk), .rst(rst),
        .ll(ll), .l1bm_bmode(bmode), .l1bm_lwrite(lwrite), .l1bm_rmode(rmode), .l1bm_me(me),
        .l1bm_ladr(ladr), .l1bm_dmode(dmode), .l1bm_ext(ext), .l1bm_round_out(rnd),
        .l1bm_mabadr(mabadr), .l1bm_opcode(opcode), .l1bm_isel(isel), .l1bm_wl(wl),
        .use_src(use_src), .lbf_upd(lbf_upd), .chk_trap(chk_trap), .chk_addr(chk_addr),
        .chk_unsup(chk_unsup), .chk_field(chk_field),
        .start(start), .idle(idle), .commit(commit), .done(done),
        .src_we(src_we), .src_mab(src_mab), .src_pe(src_pe), .src_cycle(src_cycle), .src_data(src_data),
        .res_req(res_req), .res_ready(res_ready), .res_mab(res_mab), .res_pe(res_pe),
        .res_cycle(res_cycle), .res_valid(res_valid), .res_data(res_data),
        .lbf_rmab(lbf_rmab), .lbf_rpe(lbf_rpe), .lbf_rcycle(lbf_rcycle), .lbf_rdata(lbf_rdata),
        .lbf_we(lbf_we), .lbf_wmab(lbf_wmab), .lbf_wpe(lbf_wpe), .lbf_wcycle(lbf_wcycle),
        .lbf_wdata(lbf_wdata),
        .b_req_valid(b_req_valid), .b_req_ready(b_req_ready), .b_req_we(b_req_we),
        .b_req_addr(b_req_addr), .b_req_wdata(b_req_wdata), .b_req_wmask(8'hff), .b_req_err(b_req_err),
        .b_rsp_valid(b_rsp_valid), .b_rsp_rdata(b_rsp_rdata));

    // ------------------------------------------------------------------ PE stub state
    reg [31:0] grf0 [0:NPE*GRW-1];
    reg [31:0] grf1 [0:NPE*GRW-1];
    reg [31:0] lm0  [0:NPE*LMW-1];
    reg [31:0] lm1  [0:NPE*LMW-1];
    reg [31:0] tr   [0:NPE*16-1];
    reg [127:0] srcb [0:NPE*4-1];      // PE -> L1BM operands of the word
    reg [127:0] alub [0:NPE*4-1];      // ?passa results of the word
    reg [127:0] resb [0:NPE*4-1];      // L1BM -> PE data of the word

    // ------------------------------------------------------------------ data generator
    reg [63:0] sm_s;
    task sm_next(output [63:0] z);
        reg [63:0] t;
        begin
            sm_s = sm_s + 64'h9E3779B97F4A7C15;
            t = sm_s;
            t = (t ^ (t >> 30)) * 64'hBF58476D1CE4E5B9;
            t = (t ^ (t >> 27)) * 64'h94D049BB133111EB;
            z = t ^ (t >> 31);
        end
    endtask
    function [63:0] styled(input [63:0] r, input integer style);
        reg [10:0] e;
        reg [31:0] h;
        reg [15:0] q;
        integer k;
        begin
            styled = r;
            if (style == 1) begin
                e = (r[7:4] == 4'd0) ? 11'd0 : (r[7:4] == 4'd1) ? 11'd2047 : 11'd1000 + {5'd0, r[61:56]};
                styled = {r[63], e, r[51:0]};
            end else if (style == 2) begin
                for (k = 0; k < 2; k = k + 1) begin
                    h = k == 0 ? r[63:32] : r[31:0];
                    e = (h[3:0] == 4'd0) ? 11'd0 : (h[3:0] == 4'd1) ? 11'd255 : 11'd110 + {6'd0, h[29:25]};
                    if (k == 0) styled[63:32] = {h[31], e[7:0], h[22:0]};
                    else        styled[31:0]  = {h[31], e[7:0], h[22:0]};
                end
            end else if (style == 3) begin
                for (k = 0; k < 4; k = k + 1) begin
                    q = r[63 - 16 * k -: 16];
                    e = (q[2:0] == 3'd0) ? 11'd0 : (q[2:0] == 3'd1) ? 11'd63 : 11'd24 + {7'd0, q[12:9]};
                    styled[63 - 16 * k -: 16] = {q[15], e[5:0], q[8:0]};
                end
            end else if (style == 4) begin
                case (r[2:0])
                    3'd0: styled = 64'd0;
                    3'd1: styled = 64'd1;
                    3'd2: styled = 64'hffffffffffffffff;
                    3'd3: styled = r & 64'hff;
                    3'd4: styled = r & 64'h0000ffff0000ffff;
                    default: styled = r;
                endcase
            end
        end
    endfunction

    // ------------------------------------------------------------------ hashes
    function [63:0] fnv(input [63:0] h, input [63:0] v);
        fnv = (h ^ v) * 64'h00000100000001B3;
    endfunction

    // ------------------------------------------------------------------ PE operands
    function [1:0] nw_of(input [1:0] wlf);      // word length field -> log2 of words
        nw_of = (wlf == 2'd0) ? 2'd0 : (wlf == 2'd1) ? 2'd1 : 2'd2;
    endfunction
    task pe_read(input integer i, input integer c, input integer sp, output [127:0] b);
        integer a, n, k;
        reg [31:0] w [0:3];
        begin
            for (k = 0; k < 4; k = k + 1) w[k] = 32'd0;
            case (sp)
                0: begin n = 1 << nw_of(r0_rwl); a = c_r0r[9*c +: 9] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) w[k] = grf0[i*GRW + ((a + k) % GRW)]; end
                1: begin n = 1 << nw_of(r1_rwl); a = c_r1r[9*c +: 9] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) w[k] = grf1[i*GRW + ((a + k) % GRW)]; end
                2: for (k = 0; k < 4; k = k + 1) w[k] = tr[i*16 + 4*c + k];
                3: begin n = 1 << nw_of(m0_wl); a = c_m0[12*c +: 12] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) w[k] = lm0[i*LMW + ((a + k) % LMW)]; end
                4: begin n = 1 << nw_of(m1_wl); a = c_m1[12*c +: 12] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) w[k] = lm1[i*LMW + ((a + k) % LMW)]; end
                default: begin
                    $display("%0s: ERROR PE operand %0d is not in the stub", TAG, sp);
                    err = err + 1;
                end
            endcase
            b = {w[0], w[1], w[2], w[3]};
        end
    endtask
    task pe_write(input integer i, input integer c, input integer sp, input [127:0] b);
        integer a, n, k;
        begin
            case (sp)
                0: begin n = 1 << nw_of(r0_wwl); a = c_r0w[9*c +: 9] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) grf0[i*GRW + ((a + k) % GRW)] = b[127 - 32*k -: 32]; end
                1: begin n = 1 << nw_of(r1_wwl); a = c_r1w[9*c +: 9] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) grf1[i*GRW + ((a + k) % GRW)] = b[127 - 32*k -: 32]; end
                2: for (k = 0; k < 4; k = k + 1) tr[i*16 + 4*c + k] = b[127 - 32*k -: 32];
                3: begin n = 1 << nw_of(m0_wl); a = c_m0[12*c +: 12] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) lm0[i*LMW + ((a + k) % LMW)] = b[127 - 32*k -: 32]; end
                default: begin n = 1 << nw_of(m1_wl); a = c_m1[12*c +: 12] & ~(n - 1);
                         for (k = 0; k < n; k = k + 1) lm1[i*LMW + ((a + k) % LMW)] = b[127 - 32*k -: 32]; end
            endcase
        end
    endtask
    // zero flush of the L1BM data by a literal pattern ($imr >= 16): cycle c on or off
    function [127:0] flush(input [127:0] b, input integer c);
        reg on;
        begin
            flush = b;
            if (zero && (zsel == 2'b10)) begin
                on = imr[3 - c];
                if (!on) flush = mwl ? 128'd0 : {64'd0, b[63:0]};
            end
        end
    endfunction

    // ------------------------------------------------------------------ one word
    integer d_r0, d_r1, d_m0, d_m1, d_t;     // destinations: 0 none, 1 ALU, 2 L1BM
    task run_word;
        integer i, c, k;
        reg [127:0] b;
        reg need_res, alu;
        begin
            d_r0 = r0_wr ? r0_isel : 0;
            d_r1 = r1_wr ? r1_isel : 0;
            d_m0 = (m0_wr & ~is_imm) ? m0_isel : 0;
            d_m1 = m1_wr ? m1_isel : 0;
            d_t  = t_wr ? t_isel : 0;
            // the stub knows the outputs ALU (?passa) and L1BM; d_* = 0 also stands for none
            if ((r0_wr && r0_isel != 2'b01 && r0_isel != 2'b10) || (r1_wr && r1_isel != 2'b01 && r1_isel != 2'b10) ||
                (m0_wr && !is_imm && m0_isel != 2'b01 && m0_isel != 2'b10) ||
                (m1_wr && m1_isel != 2'b01 && m1_isel != 2'b10) || (t_wr && t_isel != 2'b01 && t_isel != 2'b10)) begin
                $display("%0s: ERROR a destination isel is not in the stub", TAG);
                err = err + 1;
            end
            need_res = (d_r0 == 2) || (d_r1 == 2) || (d_m0 == 2) || (d_m1 == 2) || (d_t == 2) || lbf_upd;
            alu = (aluop == 5'b01010) && (alu_dmode != 2'b11);
            // reads
            for (i = 0; i < NPE; i = i + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    if (use_src) begin
                        pe_read(i, c, isel, b);
                        srcb[i*4 + c] = b;
                    end
                    if (alu) begin
                        if (alu_isela == 4'd13) begin
                            lbf_rmab = i / 4; lbf_rpe = i % 4; lbf_rcycle = c;
                            #1;
                            alub[i*4 + c] = lbf_rdata;
                        end else begin
                            pe_read(i, c, alu_isela, b);
                            alub[i*4 + c] = b;
                        end
                    end
                end
            end
            // the unit
            @(posedge clk); start <= 1'b1;
            @(posedge clk); start <= 1'b0;
            if (use_src) begin
                for (i = 0; i < NPE; i = i + 1)
                    for (c = 0; c < 4; c = c + 1) begin
                        src_we <= 1'b1; src_mab <= i / 4; src_pe <= i % 4; src_cycle <= c;
                        src_data <= srcb[i*4 + c];
                        @(posedge clk);
                    end
                src_we <= 1'b0;
            end
            if (need_res) begin
                for (i = 0; i < NPE; i = i + 1)
                    for (c = 0; c < 4; c = c + 1) begin
                        while (!res_ready) @(posedge clk);
                        res_req <= 1'b1; res_mab <= i / 4; res_pe <= i % 4; res_cycle <= c;
                        @(posedge clk);
                        res_req <= 1'b0;
                        while (!res_valid) @(posedge clk);
                        resb[i*4 + c] = res_data;
                        lbf_we <= 1'b1; lbf_wmab <= i / 4; lbf_wpe <= i % 4; lbf_wcycle <= c;
                        lbf_wdata <= flush(res_data, c);
                        @(posedge clk);
                        lbf_we <= 1'b0;
                    end
            end
            @(posedge clk); commit <= 1'b1;
            @(posedge clk); commit <= 1'b0;
            while (!done) @(posedge clk);
            // PE writes
            for (i = 0; i < NPE; i = i + 1)
                for (c = 0; c < 4; c = c + 1) begin
                    if (d_r0 == 2) pe_write(i, c, 0, flush(resb[i*4 + c], c));
                    if (d_r1 == 2) pe_write(i, c, 1, flush(resb[i*4 + c], c));
                    if (d_m0 == 2) pe_write(i, c, 3, flush(resb[i*4 + c], c));
                    if (d_m1 == 2) pe_write(i, c, 4, flush(resb[i*4 + c], c));
                    if (d_t  == 2) pe_write(i, c, 2, flush(resb[i*4 + c], c));
                    if (alu) begin
                        if (d_r0 == 1) pe_write(i, c, 0, alub[i*4 + c]);
                        if (d_r1 == 1) pe_write(i, c, 1, alub[i*4 + c]);
                        if (d_m0 == 1) pe_write(i, c, 3, alub[i*4 + c]);
                        if (d_m1 == 1) pe_write(i, c, 4, alub[i*4 + c]);
                        if (d_t  == 1) pe_write(i, c, 2, alub[i*4 + c]);
                    end
                end
        end
    endtask

    // ------------------------------------------------------------------ port B
    task b_write(input integer a, input [63:0] v);
        begin
            b_req_valid <= 1'b1; b_req_we <= 1'b1; b_req_addr <= a; b_req_wdata <= v;
            @(posedge clk);
            while (!b_req_ready) @(posedge clk);
            b_req_valid <= 1'b0; b_req_we <= 1'b0;
        end
    endtask
    task b_read(input integer a, output [63:0] v);
        begin
            b_req_valid <= 1'b1; b_req_we <= 1'b0; b_req_addr <= a;
            @(posedge clk);
            while (!b_req_ready) @(posedge clk);
            b_req_valid <= 1'b0;
            while (!b_rsp_valid) @(posedge clk);
            v = b_rsp_rdata;
        end
    endtask

    // ------------------------------------------------------------------ test file
    integer fd, r, k, i, init_mabs, style, lbz, kind, arg, blk, pe, sp, nwords, tfail;
    reg [8*64-1:0]  name;
    reg [8*8-1:0]   cmd, sub;
    reg [63:0]      seed, h, want, v;
    reg [427:0]     word;
    reg [8*512-1:0] line;
    reg [8*256-1:0] fname;
    reg             stopped;
    initial begin
        fin = 1'b0; ntests = 0; nfail = 0; err = 0;
        wait (go);
        if (!$value$plusargs(PARG, fname)) fname = TESTS;
        fd = $fopen(fname, "r");
        if (fd == 0) begin
            $display("%0s: ERROR cannot open %0s", TAG, fname);
            nfail = 1;
            fin = 1'b1;
        end else begin
            while ($fscanf(fd, "%s", cmd) == 1) begin
                if (cmd == "#") begin
                    r = $fgets(line, fd);   // a comment line
                end else if (cmd == "T") begin
                    r = $fscanf(fd, "%s %d %h %d %d", name, init_mabs, seed, style, lbz);
                    ntests = ntests + 1; tfail = 0; stopped = 1'b0; nwords = 0; err = 0;
                    // reset the unit (it clears the L1BM, $lbi and $lbf) and the PE stub
                    rst = 1'b1;
                    repeat (3) @(posedge clk);
                    rst = 1'b0;
                    for (k = 0; k < NPE*GRW; k = k + 1) begin grf0[k] = 0; grf1[k] = 0; end
                    for (k = 0; k < NPE*LMW; k = k + 1) begin lm0[k] = 0; lm1[k] = 0; end
                    for (k = 0; k < NPE*16; k = k + 1) tr[k] = 0;
                    while (!idle) @(posedge clk);
                    sm_s = seed;
                    // lb_zero: the L1BM stays as the reset left it (CLEAR = 1 writes 0)
                    if (!lbz) begin
                        for (k = 0; k < 1024; k = k + 1) begin
                            sm_next(v); v = styled(v, style);
                            b_write(k, v);
                        end
                    end
                    for (i = 0; i < 4 * init_mabs; i = i + 1) begin
                        for (k = 0; k < 32; k = k + 1) begin sm_next(v); v = styled(v, style);
                            if (i < NPE) begin grf0[i*GRW + 2*k] = v[63:32]; grf0[i*GRW + 2*k + 1] = v[31:0]; end end
                        for (k = 0; k < 32; k = k + 1) begin sm_next(v); v = styled(v, style);
                            if (i < NPE) begin grf1[i*GRW + 2*k] = v[63:32]; grf1[i*GRW + 2*k + 1] = v[31:0]; end end
                        for (k = 0; k < 64; k = k + 1) begin sm_next(v); v = styled(v, style);
                            if (i < NPE) begin lm0[i*LMW + 2*k] = v[63:32]; lm0[i*LMW + 2*k + 1] = v[31:0]; end end
                        for (k = 0; k < 64; k = k + 1) begin sm_next(v); v = styled(v, style);
                            if (i < NPE) begin lm1[i*LMW + 2*k] = v[63:32]; lm1[i*LMW + 2*k + 1] = v[31:0]; end end
                        for (k = 0; k < 8; k = k + 1) begin sm_next(v); v = styled(v, style);
                            if (i < NPE) begin tr[i*16 + 2*k] = v[63:32]; tr[i*16 + 2*k + 1] = v[31:0]; end end
                    end
                end else if (cmd == "W") begin
                    r = $fscanf(fd, "%d %d %h", kind, arg, word);
                    nwords = nwords + 1;
                    if (!stopped) begin
                        jw = word[425:0];
                        #1;
                        if (kind == 1 || kind == 2) begin
                            if (kind == 1 && !chk_trap) begin
                                $display("%0s %0s: word %0d: expected E_RANGE, chk_trap = 0", TAG, name, nwords - 1);
                                tfail = tfail + 1;
                            end
                            if (kind == 2 && (chk_trap || !chk_unsup || chk_field != arg)) begin
                                $display("%0s %0s: word %0d: expected E_UNSUPPORTED field %0d, got trap %0d unsup %0d field %0d",
                                         TAG, name, nwords - 1, arg, chk_trap, chk_unsup, chk_field);
                                tfail = tfail + 1;
                            end
                            stopped = 1'b1;
                        end else if (ll[0]) begin
                            if (chk_trap || chk_unsup) begin
                                $display("%0s %0s: word %0d: unexpected trap %0d / unsup %0d (field %0d)",
                                         TAG, name, nwords - 1, chk_trap, chk_unsup, chk_field);
                                tfail = tfail + 1;
                                stopped = 1'b1;
                            end else begin
                                run_word;
                            end
                        end
                    end
                end else if (cmd == "K") begin
                    r = $fscanf(fd, "%s", sub);
                    if (sub == "L") begin
                        r = $fscanf(fd, "%d %h", blk, want);
                        h = 64'hCBF29CE484222325;
                        for (k = 0; k < 64; k = k + 1) begin
                            b_read(64 * blk + k, v);
                            h = fnv(h, v);
                        end
                        if (h !== want) begin
                            $display("%0s %0s: L1BM long words %0d..%0d differ (hash %h, expected %h)",
                                     TAG, name, 64 * blk, 64 * blk + 63, h, want);
                            tfail = tfail + 1;
                        end
                    end else begin
                        r = $fscanf(fd, "%d %d %h", pe, sp, want);
                        h = 64'hCBF29CE484222325;
                        for (k = 0; k < ((sp <= 1) ? 64 : (sp <= 3) ? 128 : 16); k = k + 1) begin
                            case (sp)
                                0: v = grf0[pe*GRW + k];
                                1: v = grf1[pe*GRW + k];
                                2: v = lm0[pe*LMW + k];
                                3: v = lm1[pe*LMW + k];
                                default: v = tr[pe*16 + k];
                            endcase
                            h = fnv(h, v);
                        end
                        if (h !== want) begin
                            $display("%0s %0s: PE m%0dp%0d %0s differs (hash %h, expected %h)", TAG, name, pe / 4,
                                     pe % 4, (sp == 0) ? "GRF0" : (sp == 1) ? "GRF1" : (sp == 2) ? "LM0" :
                                     (sp == 3) ? "LM1" : "T", h, want);
                            tfail = tfail + 1;
                        end
                    end
                end else if (cmd == "E") begin
                    tfail = tfail + err;
                    if (tfail != 0) begin
                        nfail = nfail + 1;
                        $display("%0s: FAIL %0s (%0d differences)", TAG, name, tfail);
                    end else begin
                        $display("%0s: ok   %0s", TAG, name);
                    end
                end
            end
            $fclose(fd);
            fin = 1'b1;
        end
    end
endmodule
`default_nettype wire

// tb_l2bm_env: runs a test file on mn_l2bm with N_L1B L1Bs (mn_l1bm, N_MAB = 1) and a PE stub
// for MAB 0 of L1B 0 (WP32 testbench).
//
// Test file (gen_tests.py; the expected values are the official emulator's, contract 1):
//   T <name> <l1bs> <seed> <style> <l2_zero> <l1_zero> <pes>   begin a test: reset the units, make
//        the initial data with splitmix64(seed) (l2prog.py Init: L2BM long words 0..2047, then the
//        L1BM 0..1023 of L1Bs 0..l1bs-1, then with pes for PEs m0p0..p3 GRF0, GRF1 long words 0..31,
//        LM0, LM1 0..63, T 0..7); the L2BM and L1BMs are written through their ports B
//   W <kind> <arg> <word>   a j word (hex): kind 0 executes it, 1 expects E_RANGE (chk_trap of
//        mn_l2bm or mn_l1bm) and stops the test there, 2 expects E_UNSUPPORTED with field arg
//   K C <block> <hash>      FNV-1a 64 of L2BM long words 64 block .. 64 block + 63 (port B)
//   K L <l1b> <block> <hash> the same for the L1BM of L1B l1b (its port B)
//   K P <pe> <space> <hash> FNV-1a 64 of the PE's 32-bit words: space 0 GRF0 0..63, 1 GRF1 0..63,
//                           2 LM0 0..127, 3 LM1 0..127, 4 T 0..15 (cycle-major)
//   D <entry> <value>       DAR entry (decimal), through the DAR read port
//   E                       end of the test
// A word runs as WP37 will run it (rtl/l2bm/README.md): the PE stub reads its operands, both
// units start; the L1BM unit gets the PE -> L1BM sources and gives the L1BM -> PE results while
// mn_l2bm runs its first part; after pre_done, mn_l1bm commits, then mn_l2bm (its L1BM writes);
// then the PE stub writes its destinations. A j word without an L2BM part (also ll = 00) pulses
// skip. The PE stub is the one of WP31 (tb_l1bm_env.v): the PE -> L1BM operand ($lr $ls $t $lm
// $ln), destinations with isel 10 / 01 (?passa of a memory operand or of $lbf), zero flush by a
// literal pattern. With N_L1B > 1 only words without an L1BM part run (the PEs of L1Bs 1.. are
// not modelled). +l2time prints the clocks of every L2BM word.
`timescale 1ns/1ps
`default_nettype none
module tb_l2bm_env #(
    parameter N_L1B = 1,
    parameter RRN   = 1,
    parameter DAR   = 1,
    parameter TESTS = "mncore/sim/tb/l2bm/fixed/l1.tst",
    parameter PARG  = "l1=%s",     // plusarg that replaces TESTS
    parameter TAG   = "l1"
) (
    input  wire clk,
    input  wire go,
    output reg  fin,
    output reg  [31:0] ntests,
    output reg  [31:0] nfail
);
    localparam NPE = 4;        // MAB 0 of L1B 0
    localparam LMW = 4096;     // LM words per PE (the chip's)
    localparam GRW = 512;      // GRF words per PE
    integer err;               // stub errors of the current test
    reg [8*64-1:0] name;       // the current test
    integer nwords;            // words of the current test so far

    // ------------------------------------------------------------------ decoder
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
    wire         gwrite, l2_lwrite, darsend, darwrite;
    wire [9:0]   gadr;
    wire [1:0]   bdmode, l2_dmode;
    wire [10:0]  l2_ladr;
    wire [2:0]   l1adr, immode;
    wire [3:0]   l2_opcode;
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
        .l1bm_gwrite(gwrite), .l1bm_gadr(gadr), .l2bm_lwrite(l2_lwrite), .l2bm_bdmode(bdmode),
        .l2bm_ladr(l2_ladr), .l2bm_l1adr(l1adr), .l2bm_immode(immode), .l2bm_dmode(l2_dmode),
        .l2bm_opcode(l2_opcode), .l2bm_darsend(darsend), .l2bm_darwrite(darwrite),
        .cyc_rfc0_w(c_r0w), .cyc_rfc0_r(c_r0r), .cyc_rfc1_w(c_r1w), .cyc_rfc1_r(c_r1r),
        .cyc_lm0(c_m0), .cyc_lm1(c_m1), .is_imm(is_imm));
    /* verilator lint_on PINMISSING */

    // ------------------------------------------------------------------ mn_l2bm
    wire         l2_act, l2_trap, l2_unsup, l2_idle, l2_pre, l2_done;
    wire [6:0]   l2_field;
    reg          l2_start = 1'b0, l2_commit = 1'b0, l2_skip = 1'b0;
    wire         lb_req_valid, lb_req_we;
    wire [2:0]   lb_req_l1b;
    wire [22:0]  lb_req_addr;
    wire [63:0]  lb_req_wdata;
    wire [7:0]   lb_req_wmask;
    wire         lb_req_ready, lb_req_err, lb_rsp_valid;
    wire [63:0]  lb_rsp_rdata;
    reg          c_req_valid = 1'b0, c_req_we = 1'b0;
    reg  [22:0]  c_req_addr = 23'd0;
    reg  [63:0]  c_req_wdata = 64'd0;
    wire         c_req_ready, c_req_err, c_rsp_valid;
    wire [63:0]  c_rsp_rdata;
    reg          dar_re = 1'b0;
    reg  [9:0]   dar_raddr = 10'd0;
    wire [31:0]  dar_rdata;

    mn_l2bm #(.N_L1B(N_L1B), .AW(11), .L1AW(10), .RRN(RRN), .DAR(DAR), .CLEAR(1)) dut (
        .clk(clk), .rst(rst),
        .ll(ll), .l1bm_gwrite(gwrite), .l1bm_gadr(gadr), .l2bm_lwrite(l2_lwrite), .l2bm_bdmode(bdmode),
        .l2bm_ladr(l2_ladr), .l2bm_l1adr(l1adr), .l2bm_immode(immode), .l2bm_dmode(l2_dmode),
        .l2bm_opcode(l2_opcode), .l2bm_darsend(darsend), .l2bm_darwrite(darwrite),
        .l1bm_bmode(bmode), .l1bm_lwrite(lwrite), .l1bm_me(me), .l1bm_ladr(ladr), .l1bm_wl(wl),
        .act(l2_act), .chk_trap(l2_trap), .chk_unsup(l2_unsup), .chk_field(l2_field),
        .start(l2_start), .idle(l2_idle), .pre_done(l2_pre), .commit(l2_commit), .done(l2_done), .skip(l2_skip),
        .lb_req_valid(lb_req_valid), .lb_req_ready(lb_req_ready), .lb_req_l1b(lb_req_l1b),
        .lb_req_we(lb_req_we), .lb_req_addr(lb_req_addr), .lb_req_wdata(lb_req_wdata),
        .lb_req_wmask(lb_req_wmask), .lb_req_err(lb_req_err), .lb_rsp_valid(lb_rsp_valid),
        .lb_rsp_rdata(lb_rsp_rdata),
        .b_req_valid(c_req_valid), .b_req_ready(c_req_ready), .b_req_we(c_req_we), .b_req_addr(c_req_addr),
        .b_req_wdata(c_req_wdata), .b_req_wmask(8'hff), .b_req_err(c_req_err),
        .b_rsp_valid(c_rsp_valid), .b_rsp_rdata(c_rsp_rdata),
        .dar_re(dar_re), .dar_raddr(dar_raddr), .dar_rdata(dar_rdata));

    // ------------------------------------------------------------------ the L1BMs
    // port B of L1B b: the testbench (tb_own, initial data and hashes) or the L2BM master port
    reg          tb_own = 1'b1;
    reg          t_req_valid = 1'b0, t_req_we = 1'b0;
    reg  [2:0]   t_req_l1b = 3'd0;
    reg  [22:0]  t_req_addr = 23'd0;
    reg  [63:0]  t_req_wdata = 64'd0;
    wire [N_L1B-1:0]    pb_ready, pb_err, pb_rvalid;
    wire [64*N_L1B-1:0] pb_rdata;
    wire         m_valid = tb_own ? t_req_valid : lb_req_valid;
    wire         m_we    = tb_own ? t_req_we : lb_req_we;
    wire [2:0]   m_l1b   = tb_own ? t_req_l1b : lb_req_l1b;
    wire [22:0]  m_addr  = tb_own ? t_req_addr : lb_req_addr;
    wire [63:0]  m_wdata = tb_own ? t_req_wdata : lb_req_wdata;
    reg  [2:0]   rsp_l1b = 3'd0;    // L1B of the read in flight
    always @(posedge clk) if (m_valid && pb_ready[m_l1b] && !m_we) rsp_l1b <= m_l1b;
    wire         m_ready  = pb_ready[m_l1b];
    wire         m_err    = pb_err[m_l1b];
    wire         m_rvalid = pb_rvalid[rsp_l1b];
    wire [63:0]  m_rdata  = pb_rdata[64*rsp_l1b +: 64];
    assign lb_req_ready = ~tb_own & m_ready;
    assign lb_req_err   = ~tb_own & m_err;
    assign lb_rsp_valid = ~tb_own & m_rvalid;
    assign lb_rsp_rdata = m_rdata;

    // L1B 0: the L1BM step of the word (PE stub)
    wire         use_src, lbf_upd, chk_trap1, chk_unsup1, idle1, done1, res_ready, res_valid;
    wire [12:0]  chk_addr1;
    wire [6:0]   chk_field1;
    wire [127:0] res_data, lbf_rdata;
    reg          start1 = 1'b0, commit1 = 1'b0, src_we = 1'b0, res_req = 1'b0, lbf_we = 1'b0;
    reg  [1:0]   src_pe = 2'd0, src_cycle = 2'd0, res_pe = 2'd0, res_cycle = 2'd0;
    reg  [1:0]   lbf_rpe = 2'd0, lbf_rcycle = 2'd0, lbf_wpe = 2'd0, lbf_wcycle = 2'd0;
    reg  [127:0] src_data = 128'd0, lbf_wdata = 128'd0;
    wire [N_L1B-1:0] idles;

    genvar gb;
    generate
        for (gb = 0; gb < N_L1B; gb = gb + 1) begin : g_l1b
            wire [63:0] rd;
            wire        sel = (m_l1b == gb);
            if (gb == 0) begin : g_pe
                mn_l1bm #(.N_MAB(1), .AW(10), .RRN(2), .CLEAR(1)) u_l1 (
                    .clk(clk), .rst(rst),
                    .ll(ll), .l1bm_bmode(bmode), .l1bm_lwrite(lwrite), .l1bm_rmode(rmode), .l1bm_me(me),
                    .l1bm_ladr(ladr), .l1bm_dmode(dmode), .l1bm_ext(ext), .l1bm_round_out(rnd),
                    .l1bm_mabadr(mabadr), .l1bm_opcode(opcode), .l1bm_isel(isel), .l1bm_wl(wl),
                    .use_src(use_src), .lbf_upd(lbf_upd), .chk_trap(chk_trap1), .chk_addr(chk_addr1),
                    .chk_unsup(chk_unsup1), .chk_field(chk_field1),
                    .start(start1), .idle(idles[gb]), .commit(commit1), .done(done1),
                    .src_we(src_we), .src_mab(4'd0), .src_pe(src_pe), .src_cycle(src_cycle), .src_data(src_data),
                    .res_req(res_req), .res_ready(res_ready), .res_mab(4'd0), .res_pe(res_pe),
                    .res_cycle(res_cycle), .res_valid(res_valid), .res_data(res_data),
                    .lbf_rmab(4'd0), .lbf_rpe(lbf_rpe), .lbf_rcycle(lbf_rcycle), .lbf_rdata(lbf_rdata),
                    .lbf_we(lbf_we), .lbf_wmab(4'd0), .lbf_wpe(lbf_wpe), .lbf_wcycle(lbf_wcycle),
                    .lbf_wdata(lbf_wdata),
                    .b_req_valid(m_valid & sel), .b_req_ready(pb_ready[gb]), .b_req_we(m_we),
                    .b_req_addr(m_addr), .b_req_wdata(m_wdata), .b_req_wmask(8'hff), .b_req_err(pb_err[gb]),
                    .b_rsp_valid(pb_rvalid[gb]), .b_rsp_rdata(rd));
            end else begin : g_nope
                // the other L1Bs: only their port B is used (their L1BM fields stay at the defaults)
                /* verilator lint_off PINMISSING */
                mn_l1bm #(.N_MAB(1), .AW(10), .RRN(0), .CLEAR(1)) u_l1 (
                    .clk(clk), .rst(rst),
                    .ll(2'b00), .l1bm_bmode(2'b00), .l1bm_lwrite(1'b0), .l1bm_rmode(1'b0), .l1bm_me(1'b0),
                    .l1bm_ladr(13'd0), .l1bm_dmode(1'b0), .l1bm_ext(1'b0), .l1bm_round_out(1'b0),
                    .l1bm_mabadr(4'd0), .l1bm_opcode(4'd0), .l1bm_isel(3'd7), .l1bm_wl(1'b0),
                    .start(1'b0), .idle(idles[gb]), .commit(1'b0),
                    .src_we(1'b0), .src_mab(4'd0), .src_pe(2'd0), .src_cycle(2'd0), .src_data(128'd0),
                    .res_req(1'b0), .res_mab(4'd0), .res_pe(2'd0), .res_cycle(2'd0),
                    .lbf_rmab(4'd0), .lbf_rpe(2'd0), .lbf_rcycle(2'd0),
                    .lbf_we(1'b0), .lbf_wmab(4'd0), .lbf_wpe(2'd0), .lbf_wcycle(2'd0), .lbf_wdata(128'd0),
                    .b_req_valid(m_valid & sel), .b_req_ready(pb_ready[gb]), .b_req_we(m_we),
                    .b_req_addr(m_addr), .b_req_wdata(m_wdata), .b_req_wmask(8'hff), .b_req_err(pb_err[gb]),
                    .b_rsp_valid(pb_rvalid[gb]), .b_rsp_rdata(rd));
                /* verilator lint_on PINMISSING */
            end
            assign pb_rdata[64*gb +: 64] = rd;
        end
    endgenerate

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
            end else if (style == 5) begin
                styled = {26'd0, r[45:40], 26'd0, r[13:8]};
            end
        end
    endfunction

    // ------------------------------------------------------------------ hashes
    function [63:0] fnv(input [63:0] h, input [63:0] v);
        fnv = (h ^ v) * 64'h00000100000001B3;
    endfunction

    // ------------------------------------------------------------------ PE operands (WP31 stub)
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
    integer wd;                              // watchdog
    integer cyc = 0, t0, tmax = 0;           // clocks; +l2time prints the clocks of every L2BM word
    reg     l2time;
    always @(posedge clk) cyc <= cyc + 1;
    initial l2time = $test$plusargs("l2time");
    function cond_of(input integer which);   // 0 l2 pre_done, 1 l1 done, 2 l2 done, 3 res_valid
        cond_of = (which == 0) ? l2_pre : (which == 1) ? done1 : (which == 2) ? l2_done : res_valid;
    endfunction
    task wait_for(input integer which);
        begin
            wd = 0;
            while (!cond_of(which) && (wd <= 400000)) begin
                @(posedge clk);
                wd = wd + 1;
            end
            if (wd > 400000) begin
                $display("%0s: ERROR timeout (%0d)", TAG, which);
                err = err + 1;
            end
        end
    endtask
    task run_word;
        integer i, c;
        reg [127:0] b;
        reg need_res, alu, l1p, l2p;
        begin
            d_r0 = r0_wr ? r0_isel : 0;
            d_r1 = r1_wr ? r1_isel : 0;
            d_m0 = (m0_wr & ~is_imm) ? m0_isel : 0;
            d_m1 = m1_wr ? m1_isel : 0;
            d_t  = t_wr ? t_isel : 0;
            if ((r0_wr && r0_isel != 2'b01 && r0_isel != 2'b10) || (r1_wr && r1_isel != 2'b01 && r1_isel != 2'b10) ||
                (m0_wr && !is_imm && m0_isel != 2'b01 && m0_isel != 2'b10) ||
                (m1_wr && m1_isel != 2'b01 && m1_isel != 2'b10) || (t_wr && t_isel != 2'b01 && t_isel != 2'b10)) begin
                $display("%0s: ERROR a destination isel is not in the stub", TAG);
                err = err + 1;
            end
            need_res = (d_r0 == 2) || (d_r1 == 2) || (d_m0 == 2) || (d_m1 == 2) || (d_t == 2) || lbf_upd;
            alu = (aluop == 5'b01010) && (alu_dmode != 2'b11);
            l1p = use_src || need_res || alu || lwrite;
            l2p = l2_act;
            if (l1p && (N_L1B > 1)) begin
                $display("%0s: ERROR a word with an L1BM part in a test of %0d L1Bs", TAG, N_L1B);
                err = err + 1;
            end
            // reads
            for (i = 0; i < NPE; i = i + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    if (use_src) begin
                        pe_read(i, c, isel, b);
                        srcb[i*4 + c] = b;
                    end
                    if (alu) begin
                        if (alu_isela == 4'd13) begin
                            lbf_rpe = i % 4; lbf_rcycle = c;
                            #1;
                            alub[i*4 + c] = lbf_rdata;
                        end else begin
                            pe_read(i, c, alu_isela, b);
                            alub[i*4 + c] = b;
                        end
                    end
                end
            end
            // both units start; the L1BM unit's step runs while mn_l2bm does its first part
            tb_own = 1'b0;
            @(posedge clk); start1 <= 1'b1; l2_start <= l2p;
            t0 = cyc;
            @(posedge clk); start1 <= 1'b0; l2_start <= 1'b0;
            if (use_src) begin
                for (i = 0; i < NPE; i = i + 1)
                    for (c = 0; c < 4; c = c + 1) begin
                        src_we <= 1'b1; src_pe <= i % 4; src_cycle <= c;
                        src_data <= srcb[i*4 + c];
                        @(posedge clk);
                    end
                src_we <= 1'b0;
            end
            if (need_res) begin
                for (i = 0; i < NPE; i = i + 1)
                    for (c = 0; c < 4; c = c + 1) begin
                        while (!res_ready) @(posedge clk);
                        res_req <= 1'b1; res_pe <= i % 4; res_cycle <= c;
                        @(posedge clk);
                        res_req <= 1'b0;
                        wait_for(3);
                        resb[i*4 + c] = res_data;
                        lbf_we <= 1'b1; lbf_wpe <= i % 4; lbf_wcycle <= c;
                        lbf_wdata <= flush(res_data, c);
                        @(posedge clk);
                        lbf_we <= 1'b0;
                    end
            end
            if (l2p) wait_for(0);
            @(posedge clk); commit1 <= 1'b1;
            @(posedge clk); commit1 <= 1'b0;
            wait_for(1);
            if (l2p) begin
                @(posedge clk); l2_commit <= 1'b1;
                @(posedge clk); l2_commit <= 1'b0;
                wait_for(2);
                if (cyc - t0 > tmax) tmax = cyc - t0;
                if (l2time) $display("%0s %0s: word %0d: %0d clocks (start to the L2BM unit's done)",
                                     TAG, name, nwords - 1, cyc - t0);
            end
            @(posedge clk);
            tb_own = 1'b1;
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

    // a j word that does not start mn_l2bm (the l2bmdars address rule)
    task pulse_skip;
        begin
            @(posedge clk); l2_skip <= 1'b1;
            @(posedge clk); l2_skip <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ ports B
    task l1_write(input integer bl, input integer a, input [63:0] v);
        begin
            t_req_valid <= 1'b1; t_req_we <= 1'b1; t_req_l1b <= bl; t_req_addr <= a; t_req_wdata <= v;
            @(posedge clk);
            while (!m_ready) @(posedge clk);
            t_req_valid <= 1'b0; t_req_we <= 1'b0;
        end
    endtask
    task l1_read(input integer bl, input integer a, output [63:0] v);
        begin
            t_req_valid <= 1'b1; t_req_we <= 1'b0; t_req_l1b <= bl; t_req_addr <= a;
            @(posedge clk);
            while (!m_ready) @(posedge clk);
            t_req_valid <= 1'b0;
            while (!m_rvalid) @(posedge clk);
            v = m_rdata;
        end
    endtask
    task l2_write(input integer a, input [63:0] v);
        begin
            c_req_valid <= 1'b1; c_req_we <= 1'b1; c_req_addr <= a; c_req_wdata <= v;
            @(posedge clk);
            while (!c_req_ready) @(posedge clk);
            c_req_valid <= 1'b0; c_req_we <= 1'b0;
        end
    endtask
    task l2_read(input integer a, output [63:0] v);
        begin
            c_req_valid <= 1'b1; c_req_we <= 1'b0; c_req_addr <= a;
            @(posedge clk);
            while (!c_req_ready) @(posedge clk);
            c_req_valid <= 1'b0;
            while (!c_rsp_valid) @(posedge clk);
            v = c_rsp_rdata;
        end
    endtask
    task dar_read(input integer e, output [31:0] v);
        begin
            dar_re <= 1'b1; dar_raddr <= e;
            @(posedge clk);
            dar_re <= 1'b0;
            @(posedge clk);
            v = dar_rdata;
        end
    endtask

    // ------------------------------------------------------------------ test file
    integer fd, r, k, i, bl, l1bs, style, l2z, l1z, pes, kind, arg, blk, pe, sp, tfail, de, dv;
    reg [8*8-1:0]   cmd, sub;
    reg [63:0]      seed, h, want, v;
    reg [31:0]      dgot;
    reg [427:0]     word;
    reg [8*512-1:0] line;
    reg [8*256-1:0] fname;
    reg             stopped, tr_any, un_ok;
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
                    r = $fscanf(fd, "%s %d %h %d %d %d %d", name, l1bs, seed, style, l2z, l1z, pes);
                    ntests = ntests + 1; tfail = 0; stopped = 1'b0; nwords = 0; err = 0;
                    if (l1bs > N_L1B) begin
                        $display("%0s: ERROR test %0s has %0d L1Bs", TAG, name, l1bs);
                        err = err + 1;
                    end
                    // reset the units (they clear the L2BM, DAR, L1BMs and $lbi) and the PE stub
                    rst = 1'b1;
                    repeat (3) @(posedge clk);
                    rst = 1'b0;
                    for (k = 0; k < NPE*GRW; k = k + 1) begin grf0[k] = 0; grf1[k] = 0; end
                    for (k = 0; k < NPE*LMW; k = k + 1) begin lm0[k] = 0; lm1[k] = 0; end
                    for (k = 0; k < NPE*16; k = k + 1) tr[k] = 0;
                    while (!(l2_idle && (&idles))) @(posedge clk);
                    sm_s = seed;
                    for (k = 0; k < 2048; k = k + 1) begin
                        sm_next(v); v = styled(v, style);
                        if (!l2z) l2_write(k, v);
                    end
                    for (bl = 0; bl < l1bs; bl = bl + 1)
                        for (k = 0; k < 1024; k = k + 1) begin
                            sm_next(v); v = styled(v, style);
                            if (!l1z && bl < N_L1B) l1_write(bl, k, v);
                        end
                    if (pes) begin
                        for (i = 0; i < 4; i = i + 1) begin
                            for (k = 0; k < 32; k = k + 1) begin sm_next(v); v = styled(v, style);
                                grf0[i*GRW + 2*k] = v[63:32]; grf0[i*GRW + 2*k + 1] = v[31:0]; end
                            for (k = 0; k < 32; k = k + 1) begin sm_next(v); v = styled(v, style);
                                grf1[i*GRW + 2*k] = v[63:32]; grf1[i*GRW + 2*k + 1] = v[31:0]; end
                            for (k = 0; k < 64; k = k + 1) begin sm_next(v); v = styled(v, style);
                                lm0[i*LMW + 2*k] = v[63:32]; lm0[i*LMW + 2*k + 1] = v[31:0]; end
                            for (k = 0; k < 64; k = k + 1) begin sm_next(v); v = styled(v, style);
                                lm1[i*LMW + 2*k] = v[63:32]; lm1[i*LMW + 2*k + 1] = v[31:0]; end
                            for (k = 0; k < 8; k = k + 1) begin sm_next(v); v = styled(v, style);
                                tr[i*16 + 2*k] = v[63:32]; tr[i*16 + 2*k + 1] = v[31:0]; end
                        end
                    end
                end else if (cmd == "W") begin
                    r = $fscanf(fd, "%d %d %h", kind, arg, word);
                    nwords = nwords + 1;
                    if (!stopped) begin
                        jw = word[425:0];
                        #1;
                        tr_any = l2_trap | chk_trap1;
                        un_ok  = (l2_unsup && l2_field == arg) || (!l2_unsup && chk_unsup1 && chk_field1 == arg);
                        if (kind == 1 || kind == 2) begin
                            if (kind == 1 && !tr_any) begin
                                $display("%0s %0s: word %0d: expected E_RANGE, no trap", TAG, name, nwords - 1);
                                tfail = tfail + 1;
                            end
                            if (kind == 2 && (tr_any || !un_ok)) begin
                                $display("%0s %0s: word %0d: expected E_UNSUPPORTED field %0d, got trap %0d unsup %0d/%0d field %0d/%0d",
                                         TAG, name, nwords - 1, arg, tr_any, l2_unsup, chk_unsup1, l2_field, chk_field1);
                                tfail = tfail + 1;
                            end
                            stopped = 1'b1;
                        end else if (ll[0]) begin
                            if (tr_any || l2_unsup || chk_unsup1) begin
                                $display("%0s %0s: word %0d: unexpected trap %0d / unsup %0d %0d (field %0d %0d)",
                                         TAG, name, nwords - 1, tr_any, l2_unsup, chk_unsup1, l2_field, chk_field1);
                                tfail = tfail + 1;
                                stopped = 1'b1;
                            end else begin
                                run_word;
                                if (!l2_act) pulse_skip;
                            end
                        end else begin
                            pulse_skip;      // a nop (ll = 00) word
                        end
                    end
                end else if (cmd == "K") begin
                    r = $fscanf(fd, "%s", sub);
                    if (sub == "C") begin
                        r = $fscanf(fd, "%d %h", blk, want);
                        h = 64'hCBF29CE484222325;
                        for (k = 0; k < 64; k = k + 1) begin
                            l2_read(64 * blk + k, v);
                            h = fnv(h, v);
                        end
                        if (h !== want) begin
                            $display("%0s %0s: L2BM long words %0d..%0d differ (hash %h, expected %h)",
                                     TAG, name, 64 * blk, 64 * blk + 63, h, want);
                            tfail = tfail + 1;
                        end
                    end else if (sub == "L") begin
                        r = $fscanf(fd, "%d %d %h", bl, blk, want);
                        h = 64'hCBF29CE484222325;
                        for (k = 0; k < 64; k = k + 1) begin
                            l1_read(bl, 64 * blk + k, v);
                            h = fnv(h, v);
                        end
                        if (h !== want) begin
                            $display("%0s %0s: L1BM b%0d long words %0d..%0d differ (hash %h, expected %h)",
                                     TAG, name, bl, 64 * blk, 64 * blk + 63, h, want);
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
                            $display("%0s %0s: PE m0p%0d %0s differs (hash %h, expected %h)", TAG, name,
                                     pe % 4, (sp == 0) ? "GRF0" : (sp == 1) ? "GRF1" : (sp == 2) ? "LM0" :
                                     (sp == 3) ? "LM1" : "T", h, want);
                            tfail = tfail + 1;
                        end
                    end
                end else if (cmd == "D") begin
                    r = $fscanf(fd, "%d %d", de, dv);
                    if (DAR != 0) begin
                        dar_read(de, dgot);
                        if (dgot !== dv) begin
                            $display("%0s %0s: DAR[%0d] = %0d, expected %0d", TAG, name, de, dgot, dv);
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
            $display("%0s: the longest word took %0d clocks", TAG, tmax);
            fin = 1'b1;
        end
    end
endmodule
`default_nettype wire

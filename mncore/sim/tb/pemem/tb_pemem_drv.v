// tb_pemem_drv: runs the records of tb_pemem.rec (gen_tests.py) on one PE memory instance.
//   SLOW = 0: mn_pe_mem (BSRAM store, req_ready = 1, read latency 1)
//   SLOW = 1: mn_pe_lsu + tb_pemem_slowstore (random back-pressure and read latency) and
//             random stalls on res_valid
// The core side is modelled here: the ALU output of passa / imm / immu / zero (all that the
// test programs use) is computed from the operands of the expected cycle; the MAU, L1BM and
// matrix-read outputs carry per-step junk, so a wrong isel shows up as a mismatch.
//
// Record (512 bits): [511:504] op, [503:496] space, [495:472] addr, [471:464] mask,
// [463:400] data, [425:0] j word (EXEC). ops: 0 END, 1 CLEAR, 2 WR, 3 EXEC, 4 CHK,
// 5 BEGIN (space = PE, addr = test), 6 EXPECT_TRAP (mask = {wr, mem[1:0], cycle[1:0]},
// data = word address; applies to the next EXEC).
// RBS = 1 (WP21): the DUT has the shared read buffer; opr_mem selects the memory of the ALU
// input (isela), the only operand the core model reads.
// NPE = 4 (WP35): mn_pe_lsu with NPE = 4 (T, mask registers, $mb / $nb per PE, by subpe) and
// mn_pe_store with NPE = 4 (pe = subpe). A test that uses j<madpe> runs on its record's PE,
// the others (which do not depend on subpe) on PE (test number mod 4), so T-indirect, $mb /
// $nb and mask tests run on every PE. Before
// a test, the other three PEs get junk in T, $omr1..15, $mb / $nb and some GRF / LM long
// words (host port, subpe = that PE); after the test the junk is read back and must be
// unchanged. A step that used or wrote another PE's state would fail the test's checks or the
// junk checks (nxchk counts the junk checks). A directed check at the start writes a
// different value to each PE and reads them all back.
module tb_pemem_drv #(
    parameter SLOW   = 0,
    parameter SEED   = 1,
    parameter LM_AW  = 9,
    parameter GRF_AW = 8,
    parameter RBS    = 0,
    parameter NPE    = 1
) (
    input  wire clk,
    input  wire rst,
    output reg  finished,
    output integer nfail,
    output integer nchk,
    output integer nexec,
    output integer ntrap,
    output integer nrmw_steps,
    output integer nclk,       // clocks from start to done, summed over the steps
    output integer nxchk       // NPE > 1: checks of the other PEs' state
);
    // ---------------------------------------------------------------- DUT signals
    reg  [1:0]   subpe;
    reg          start;
    reg  [425:0] jw;
    wire [3:0]   rd_use;
    wire         idle, busy, opr_valid, res_ready, done, trap, trap_wr, unsup;
    wire [1:0]   res_cycle, trap_mem, trap_cycle;
    wire [11:0]  trap_addr;
    wire [127:0] opr_grf0, opr_grf1, opr_lm0, opr_lm1, opr_t;
    wire         zf_en;
    wire [1:0]   zf_sel;
    wire [127:0] zf_mask;
    wire         res_valid;
    wire [127:0] res_mau, res_alu, res_l1bm, res_mread;
    wire [3:0]   res_alu_flags, res_mau_flags;
    reg          hp_req_valid, hp_req_we;
    reg  [7:0]   hp_req_space;
    reg  [22:0]  hp_req_addr;
    reg  [63:0]  hp_req_wdata;
    reg  [7:0]   hp_req_wmask;
    wire         hp_req_ready, hp_req_err, hp_rsp_valid;
    wire [63:0]  hp_rsp_rdata;
    integer      st_nerr;
    wire         dut_rmw;   // the sequencer is in its read-modify-write state

    mn_pe_rduse u_ru (.jw(jw), .rd_use(rd_use));

    // memory of the ALU input A (isela 0 $lr, 1 $ls, 3 $lm, 4 $ln) for the shared read buffer
    wire [3:0] isela_w = jw[425-155 -: 4];
    wire [1:0] opr_mem = (isela_w == 4'd1) ? 2'd1 : (isela_w == 4'd3) ? 2'd2 : (isela_w == 4'd4) ? 2'd3 : 2'd0;

    generate
        if (NPE > 1) begin : g_npe
            wire [3:0]   st_req_valid, st_req_ready, st_req_we, st_rsp_valid;
            wire [91:0]  st_req_addr;
            wire [255:0] st_req_wdata, st_rsp_rdata;
            wire [31:0]  st_req_wmask;
            mn_pe_lsu #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .RBS(RBS), .NPE(NPE)) dut (
                .clk(clk), .rst(rst), .subpe(subpe),
                .start(start), .idle(idle), .jw(jw), .rd_use(rd_use), .busy(busy),
                .opr_valid(opr_valid), .opr_cycle(res_cycle), .opr_mem(opr_mem),
                .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
                .res_valid(res_valid), .res_ready(res_ready), .res_cycle(res_cycle),
                .res_mau(res_mau), .res_alu(res_alu), .res_l1bm(res_l1bm), .res_mread(res_mread),
                .res_alu_flags(res_alu_flags), .res_mau_flags(res_mau_flags),
                .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
                .done(done), .trap(trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
                .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(unsup),
                .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we),
                .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr), .hp_req_wdata(hp_req_wdata),
                .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
                .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata),
                .st_req_valid(st_req_valid), .st_req_ready(st_req_ready), .st_req_we(st_req_we),
                .st_req_addr(st_req_addr), .st_req_wdata(st_req_wdata), .st_req_wmask(st_req_wmask),
                .st_rsp_valid(st_rsp_valid), .st_rsp_rdata(st_rsp_rdata));
            mn_pe_store #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .NPE(NPE)) u_st (
                .clk(clk), .rst(rst), .pe(subpe),
                .req_valid(st_req_valid), .req_ready(st_req_ready), .req_we(st_req_we),
                .req_addr(st_req_addr), .req_wdata(st_req_wdata), .req_wmask(st_req_wmask),
                .rsp_valid(st_rsp_valid), .rsp_rdata(st_rsp_rdata));
            initial st_nerr = 0;
            assign dut_rmw = (dut.state == 2'd2) && (dut.xs == 2'd1);
        end else if (SLOW == 0) begin : g_fast
            mn_pe_mem #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .RBS(RBS)) dut (
                .clk(clk), .rst(rst), .subpe(subpe),
                .start(start), .idle(idle), .jw(jw), .rd_use(rd_use), .busy(busy),
                .opr_valid(opr_valid), .opr_cycle(res_cycle), .opr_mem(opr_mem),
                .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
                .res_valid(res_valid), .res_ready(res_ready), .res_cycle(res_cycle),
                .res_mau(res_mau), .res_alu(res_alu), .res_l1bm(res_l1bm), .res_mread(res_mread),
                .res_alu_flags(res_alu_flags), .res_mau_flags(res_mau_flags),
                .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
                .done(done), .trap(trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
                .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(unsup),
                .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we),
                .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr), .hp_req_wdata(hp_req_wdata),
                .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
                .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata));
            initial st_nerr = 0;
            assign dut_rmw = (dut.u_lsu.state == 2'd2) && (dut.u_lsu.xs == 2'd1);
        end else begin : g_slow
            wire [3:0]   st_req_valid, st_req_ready, st_req_we, st_rsp_valid;
            wire [91:0]  st_req_addr;
            wire [255:0] st_req_wdata, st_rsp_rdata;
            wire [31:0]  st_req_wmask;
            mn_pe_lsu #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .RBS(RBS)) dut (
                .clk(clk), .rst(rst), .subpe(subpe),
                .start(start), .idle(idle), .jw(jw), .rd_use(rd_use), .busy(busy),
                .opr_valid(opr_valid), .opr_cycle(res_cycle), .opr_mem(opr_mem),
                .opr_grf0(opr_grf0), .opr_grf1(opr_grf1), .opr_lm0(opr_lm0), .opr_lm1(opr_lm1), .opr_t(opr_t),
                .res_valid(res_valid), .res_ready(res_ready), .res_cycle(res_cycle),
                .res_mau(res_mau), .res_alu(res_alu), .res_l1bm(res_l1bm), .res_mread(res_mread),
                .res_alu_flags(res_alu_flags), .res_mau_flags(res_mau_flags),
                .zf_en(zf_en), .zf_sel(zf_sel), .zf_mask(zf_mask),
                .done(done), .trap(trap), .trap_wr(trap_wr), .trap_mem(trap_mem),
                .trap_cycle(trap_cycle), .trap_addr(trap_addr), .unsup(unsup),
                .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we),
                .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr), .hp_req_wdata(hp_req_wdata),
                .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
                .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata),
                .st_req_valid(st_req_valid), .st_req_ready(st_req_ready), .st_req_we(st_req_we),
                .st_req_addr(st_req_addr), .st_req_wdata(st_req_wdata), .st_req_wmask(st_req_wmask),
                .st_rsp_valid(st_rsp_valid), .st_rsp_rdata(st_rsp_rdata));
            tb_pemem_slowstore #(.SEED(SEED)) u_st (
                .clk(clk), .rst(rst),
                .req_valid(st_req_valid), .req_ready(st_req_ready), .req_we(st_req_we),
                .req_addr(st_req_addr), .req_wdata(st_req_wdata), .req_wmask(st_req_wmask),
                .rsp_valid(st_rsp_valid), .rsp_rdata(st_rsp_rdata), .nerr(st_nerr));
            assign dut_rmw = (dut.state == 2'd2) && (dut.xs == 2'd1);
        end
    endgenerate

    // ---------------------------------------------------------------- core model (ALU only)
    function [131:0] alu_model(input [425:0] w, input [127:0] g0, input [127:0] g1,
                               input [127:0] t, input [127:0] m0, input [127:0] m1);
        reg [4:0]   op;
        reg [1:0]   dm;
        reg [3:0]   sa;
        reg [127:0] x;
        reg [31:0]  v;
        reg [3:0]   f;
        begin
            op = w[425-147 -: 5];
            dm = w[425-145 -: 2];
            sa = w[425-155 -: 4];
            if (op == 5'b11111) begin   // imm / immu: payload in ALUC and LM0 fields
                v = {w[425-145], w[425-146], w[425-153], w[425-154], w[425-155 -: 4],
                     w[425-159 -: 3], w[425-75 -: 3], w[425-90 -: 6], w[425-78 -: 12]};
                alu_model = {4'h0, w[425-152] ? {v, 32'd0, v, 32'd0} : {v, v, v, v}};
            end else if (op == 5'b11101 && sa == 4'b0101 && dm == 2'b10) begin   // zero
                alu_model = 132'd0;
            end else if (op == 5'b01010) begin   // passa: copy A, zero flags of the MSB long word
                case (sa)
                    4'd0: x = g0;
                    4'd1: x = g1;
                    4'd2: x = t;
                    4'd3: x = m0;
                    4'd4: x = m1;
                    default: x = {128{1'bx}};
                endcase
                case (dm)
                    2'b00:   f = {4{x[127:64] == 64'd0}};
                    2'b01:   f = {{2{x[127:96] == 32'd0}}, {2{x[95:64] == 32'd0}}};
                    default: f = {x[127:112] == 16'd0, x[111:96] == 16'd0, x[95:80] == 16'd0, x[79:64] == 16'd0};
                endcase
                alu_model = {f, x};
            end else begin
                alu_model = {132{1'bx}};   // not modelled: a write of it fails the checks
            end
        end
    endfunction

    wire [131:0] alu_r = alu_model(jw, opr_grf0, opr_grf1, opr_t, opr_lm0, opr_lm1);
    assign res_alu       = alu_r[127:0];
    assign res_alu_flags = alu_r[131:128];
    reg  [31:0] junk;
    assign res_mau       = {4{junk ^ {30'd0, res_cycle}}};
    assign res_l1bm      = ~res_mau;
    assign res_mread     = {res_mau[63:0], ~res_mau[127:64]};
    assign res_mau_flags = junk[7:4] ^ {2'b0, res_cycle};

    // valid/ready: once res_valid is high it stays high until res_ready
    reg rv_hold, rnd_v;
    integer seed;
    assign res_valid = opr_valid & (rv_hold | rnd_v);
    always @(posedge clk) begin
        if (rst) begin
            rv_hold <= 1'b0;
            rnd_v   <= 1'b1;
        end else begin
            rv_hold <= res_valid & ~res_ready;
            rnd_v   <= (SLOW == 0) ? 1'b1 : (($random(seed) & 3) != 0);
        end
    end
    // count steps that went through read-modify-write (coverage)
    reg rmw_seen;
    always @(posedge clk) begin
        if (start) rmw_seen <= 1'b0;
        else if (dut_rmw) rmw_seen <= 1'b1;
    end

    // ---------------------------------------------------------------- host port tasks
    task host_wr(input [7:0] sp, input [22:0] a, input [63:0] d, input [7:0] m);
        begin
            hp_req_valid <= 1'b1; hp_req_we <= 1'b1; hp_req_space <= sp;
            hp_req_addr <= a; hp_req_wdata <= d; hp_req_wmask <= m;
            @(posedge clk);
            while (!hp_req_ready) @(posedge clk);
            if (hp_req_err) begin
                $display("FAIL[%0d] host write rejected: space %h addr %h", SLOW, sp, a);
                nfail = nfail + 1;
            end
            hp_req_valid <= 1'b0;
        end
    endtask

    task host_rd(input [7:0] sp, input [22:0] a, output [63:0] d);
        integer guard;
        begin
            hp_req_valid <= 1'b1; hp_req_we <= 1'b0; hp_req_space <= sp;
            hp_req_addr <= a; hp_req_wmask <= 8'h00;
            @(posedge clk);
            while (!hp_req_ready) @(posedge clk);
            hp_req_valid <= 1'b0;
            if (hp_req_err) begin
                d = {64{1'bx}};
            end else begin
                guard = 0;
                @(posedge clk);
                while (!hp_rsp_valid && guard < 100) begin @(posedge clk); guard = guard + 1; end
                d = hp_rsp_rdata;
            end
        end
    endtask

    task clear_all;
        integer a;
        begin
            for (a = 0; a < (1 << GRF_AW); a = a + 1) begin host_wr(8'h03, a, 64'd0, 8'hff); host_wr(8'h04, a, 64'd0, 8'hff); end
            for (a = 0; a < (1 << LM_AW); a = a + 1)  begin host_wr(8'h01, a, 64'd0, 8'hff); host_wr(8'h02, a, 64'd0, 8'hff); end
            for (a = 0; a < 8; a = a + 1)  host_wr(8'h05, a, 64'd0, 8'hff);
            for (a = 1; a < 16; a = a + 1) host_wr(8'h10, a, 64'd0, 8'hff);
            host_wr(8'h11, 0, 64'd0, 8'hff);
            host_wr(8'h11, 1, 64'd0, 8'hff);
        end
    endtask

    // directed checks of the host-only spaces and of the reject path
    task host_selftest;
        reg [63:0] d;
        begin
            host_wr(8'h10, 5, 64'h0000_0000_0000_a5c3, 8'h03);
            host_wr(8'h11, 1, 64'h0000_0000_0000_0abc, 8'hff);
            host_wr(8'h05, 3, 64'h1111_2222_3333_4444, 8'hff);
            host_wr(8'h05, 3, 64'hffff_ffff_ffff_ffff, 8'hf0);   // only the upper word
            host_wr(8'h03, 7, 64'h0123_4567_89ab_cdef, 8'hff);
            host_wr(8'h03, 7, 64'hffff_ffff_0000_0000, 8'h0f);   // only the lower word
            host_rd(8'h10, 5, d); if (d !== 64'h0000_0000_0000_a5c3) begin $display("FAIL[%0d] OMR %h", SLOW, d); nfail = nfail + 1; end
            host_rd(8'h10, 0, d); if (d !== 64'h0000_0000_0000_ffff) begin $display("FAIL[%0d] OMR0 %h", SLOW, d); nfail = nfail + 1; end
            host_rd(8'h11, 1, d); if (d !== 64'h0000_0000_0000_0abc) begin $display("FAIL[%0d] BAR %h", SLOW, d); nfail = nfail + 1; end
            host_rd(8'h05, 3, d); if (d !== 64'hffff_ffff_3333_4444) begin $display("FAIL[%0d] T %h", SLOW, d); nfail = nfail + 1; end
            host_rd(8'h03, 7, d); if (d !== 64'h0123_4567_0000_0000) begin $display("FAIL[%0d] GRF0 %h", SLOW, d); nfail = nfail + 1; end
            // rejected: unknown space, LM beyond the reduced depth
            hp_req_valid <= 1'b1; hp_req_we <= 1'b1; hp_req_space <= 8'h09; hp_req_addr <= 23'd0;
            @(posedge clk); while (!hp_req_ready) @(posedge clk);
            if (!hp_req_err) begin $display("FAIL[%0d] space 9 not rejected", SLOW); nfail = nfail + 1; end
            hp_req_space <= 8'h01; hp_req_addr <= 23'd1 << LM_AW;
            @(posedge clk); while (!hp_req_ready) @(posedge clk);
            if (!hp_req_err) begin $display("FAIL[%0d] LM0 depth not rejected", SLOW); nfail = nfail + 1; end
            hp_req_valid <= 1'b0;
            @(posedge clk);
        end
    endtask

    // ---------------------------------------------------------------- other PEs (NPE > 1)
    // junk of PE q for test t: T 8 long words, OMR entries 1..15 (16 bits), BAR 0/1 (12 bits),
    // GRF0 / GRF1 long words 0 and 255, LM0 / LM1 long words 0 and 2**LM_AW - 1
    function [63:0] jval(input integer q, input integer t, input [7:0] sp, input integer a);
        jval = {8'hc3 ^ q[7:0], t[15:0], sp, a[7:0], 8'h5a ^ q[7:0], t[7:0] ^ 8'h96, a[7:0] ^ sp};
    endfunction
    function [63:0] jmask(input [7:0] sp);
        jmask = (sp == 8'h10) ? 64'h0000_0000_0000_ffff : (sp == 8'h11) ? 64'h0000_0000_0000_0fff :
                64'hffff_ffff_ffff_ffff;
    endfunction
    task junk_one(input integer q, input integer t, input [7:0] sp, input integer a, input do_wr);
        reg [63:0] d;
        begin
            if (do_wr) begin
                host_wr(sp, a, jval(q, t, sp, a), 8'hff);
            end else begin
                host_rd(sp, a, d);
                nxchk = nxchk + 1;
                if ((d & jmask(sp)) !== (jval(q, t, sp, a) & jmask(sp))) begin
                    nfail = nfail + 1;
                    $display("FAIL[%0d] test %0d: PE %0d space %h addr %0d changed: %h, expected %h",
                             SLOW, t, q, sp, a, d, jval(q, t, sp, a) & jmask(sp));
                end
            end
        end
    endtask
    // write (do_wr) or check the junk of every PE but p
    task junk_others(input integer p, input integer t, input do_wr);
        integer q, a;
        begin
            for (q = 0; q < NPE; q = q + 1) begin
                if (q != p) begin
                    subpe <= q[1:0];
                    @(posedge clk);
                    for (a = 0; a < 8; a = a + 1)  junk_one(q, t, 8'h05, a, do_wr);
                    for (a = 1; a < 16; a = a + 1) junk_one(q, t, 8'h10, a, do_wr);
                    junk_one(q, t, 8'h11, 0, do_wr);
                    junk_one(q, t, 8'h11, 1, do_wr);
                    junk_one(q, t, 8'h03, 0, do_wr);
                    junk_one(q, t, 8'h04, (1 << GRF_AW) - 1, do_wr);
                    junk_one(q, t, 8'h01, 0, do_wr);
                    junk_one(q, t, 8'h02, (1 << LM_AW) - 1, do_wr);
                end
            end
            subpe <= p[1:0];
            @(posedge clk);
        end
    endtask
    // directed: a different value in each PE's T, OMR and BAR, then all read back
    task npe_selftest;
        integer q;
        reg [63:0] d;
        begin
            for (q = 0; q < NPE; q = q + 1) begin
                subpe <= q[1:0];
                @(posedge clk);
                host_wr(8'h05, 6, {16'h7e57, q[15:0], 32'h1234_5678 ^ q}, 8'hff);
                host_wr(8'h10, 9, {48'd0, 16'h9000 | q[15:0]}, 8'h03);
                host_wr(8'h11, 0, {52'd0, 12'h300 | q[11:0]}, 8'hff);
            end
            for (q = 0; q < NPE; q = q + 1) begin
                subpe <= q[1:0];
                @(posedge clk);
                host_rd(8'h05, 6, d);
                if (d !== {16'h7e57, q[15:0], 32'h1234_5678 ^ q}) begin $display("FAIL[%0d] PE %0d T %h", SLOW, q, d); nfail = nfail + 1; end
                host_rd(8'h10, 9, d);
                if (d !== {48'd0, 16'h9000 | q[15:0]}) begin $display("FAIL[%0d] PE %0d OMR %h", SLOW, q, d); nfail = nfail + 1; end
                host_rd(8'h11, 0, d);
                if (d !== {52'd0, 12'h300 | q[11:0]}) begin $display("FAIL[%0d] PE %0d BAR %h", SLOW, q, d); nfail = nfail + 1; end
                nxchk = nxchk + 3;
            end
            subpe <= 2'd0;
            @(posedge clk);
        end
    endtask

    // ---------------------------------------------------------------- one step
    reg        xt_pend;
    reg [7:0]  xt_info;
    reg [11:0] xt_addr;
    reg        stopped;
    integer    cur_test;
    task run_step(input [425:0] w);
        integer guard;
        begin
            jw <= w;
            start <= 1'b1;
            junk <= $random(seed);
            @(posedge clk);
            while (!idle) @(posedge clk);
            if (unsup) begin
                $display("FAIL[%0d] test %0d: unsup at start", SLOW, cur_test);
                nfail = nfail + 1;
            end
            start <= 1'b0;
            guard = 0;
            @(posedge clk);
            while (!done && guard < 2000) begin @(posedge clk); guard = guard + 1; end
            if (!done) begin
                $display("FAIL[%0d] test %0d: step timeout", SLOW, cur_test);
                nfail = nfail + 1;
            end
            nexec = nexec + 1;
            nclk  = nclk + guard + 2;
            if (rmw_seen) nrmw_steps = nrmw_steps + 1;
            if (trap) begin
                ntrap = ntrap + 1;
                stopped = 1'b1;
                if (!xt_pend || {trap_wr, trap_mem, trap_cycle} !== xt_info[4:0] || trap_addr !== xt_addr) begin
                    $display("FAIL[%0d] test %0d: trap wr=%0d mem=%0d cycle=%0d addr=%0d (expected %s %h %0d)",
                             SLOW, cur_test, trap_wr, trap_mem, trap_cycle, trap_addr,
                             xt_pend ? "trap" : "no trap", xt_info, xt_addr);
                    nfail = nfail + 1;
                end
            end else if (xt_pend) begin
                $display("FAIL[%0d] test %0d: expected trap did not happen", SLOW, cur_test);
                nfail = nfail + 1;
            end
            xt_pend = 1'b0;
        end
    endtask

    // ---------------------------------------------------------------- record loop
    reg [511:0] r;
    reg [63:0]  got;
    integer     pc, run, nmis_test;
    integer     jp, jt;   // NPE > 1: PE and number of the test whose other PEs hold junk
    integer     la;       // NPE > 1: look-ahead over the test's records
    reg         uses_mj;  // NPE > 1: the test uses j<madpe>
    initial begin
        finished = 1'b0;
        nfail = 0; nchk = 0; nexec = 0; ntrap = 0; nrmw_steps = 0; nclk = 0; nxchk = 0;
        seed = SEED;
        start = 1'b0; jw = 426'd0; subpe = 2'd0; junk = 32'd0;
        hp_req_valid = 1'b0; hp_req_we = 1'b0; hp_req_space = 8'd0; hp_req_addr = 23'd0;
        hp_req_wdata = 64'd0; hp_req_wmask = 8'd0;
        xt_pend = 1'b0; stopped = 1'b0; cur_test = -1; nmis_test = 0;
        @(negedge rst);
        @(posedge clk);
        host_selftest;
        if (NPE > 1) npe_selftest;
        pc = 0;
        jt = -1;
        run = 1;
        while (run) begin
            r = tb_pemem.rec[pc];
            pc = pc + 1;
            case (r[511:504])
                8'd0: begin
                    if (NPE > 1 && jt >= 0) junk_others(jp, jt, 1'b0);
                    run = 0;
                end
                8'd1: clear_all;
                8'd2: host_wr(r[503:496], r[494:472], r[463:400], r[471:464]);
                8'd3: if (!stopped) run_step(r[425:0]);
                8'd4: begin
                    host_rd(r[503:496], r[494:472], got);
                    nchk = nchk + 1;
                    if (got !== r[463:400]) begin
                        nfail = nfail + 1;
                        nmis_test = nmis_test + 1;
                        if (nmis_test <= 4)
                            $display("FAIL[%0d] test %0d p%0d: space %h addr %h got %h expected %h",
                                     SLOW, cur_test, subpe, r[503:496], r[494:472], got, r[463:400]);
                    end
                end
                8'd5: begin
                    // NPE > 1: check the previous test's junk, then put junk in the other PEs.
                    // A test whose words do not use j<madpe> (maadj, bit 91 / 111) does not
                    // depend on subpe, so it runs on PE (test number mod NPE); a j<madpe>
                    // test runs on its own PE.
                    if (NPE > 1 && jt >= 0) junk_others(jp, jt, 1'b0);
                    cur_test = r[495:472];
                    stopped = 1'b0;
                    xt_pend = 1'b0;
                    nmis_test = 0;
                    if (NPE > 1) begin
                        jt = jt + 1;
                        uses_mj = 1'b0;
                        la = pc;
                        while (tb_pemem.rec[la][511:504] != 8'd5 && tb_pemem.rec[la][511:504] != 8'd0) begin
                            if (tb_pemem.rec[la][511:504] == 8'd3 &&
                                (tb_pemem.rec[la][425-91] || tb_pemem.rec[la][425-111]))
                                uses_mj = 1'b1;
                            la = la + 1;
                        end
                        jp = uses_mj ? (r[497:496] & (NPE - 1)) : (jt % NPE);
                        subpe <= jp[1:0];
                        @(posedge clk);
                        junk_others(jp, jt, 1'b1);
                    end else begin
                        subpe <= r[497:496];
                        @(posedge clk);
                    end
                end
                8'd6: begin
                    xt_pend = 1'b1;
                    xt_info = r[471:464];
                    xt_addr = r[411:400];
                end
                default: begin
                    $display("FAIL[%0d] bad record %0d", SLOW, pc - 1);
                    nfail = nfail + 1;
                    run = 0;
                end
            endcase
        end
        nfail = nfail + st_nerr;
        finished = 1'b1;
    end
endmodule

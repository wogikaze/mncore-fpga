// tb_mv_env: runs a test file on the MV test core mvt_core (mn_mv, mn_l2bm, the test L1BM) with
// sdr_bus64 and the timing-checking SDRAM model (WP33 testbench).
//
// The core is driven through its host ports as brd_host_if drives it on the board (the same
// flow as mncore/fpga/mv_test/hwrun.py):
//   T <name> <seed>          begin a test: reset the core (it clears the L2BM, DAR and the MV tags;
//                            the SDRAM keeps its contents) and restart splitmix64(seed)
//   F <space> <addr> <n> <style>   write n long words from addr: style 0..5 the next n values of
//                            splitmix64 through styled() (gen_tests.py / l2prog.styled), 9 zeros
//   G <space> <addr> <n> <style>   the same through the backdoor (the memory arrays, zero time)
//   V <space> <addr> <value> write one long word
//   J <word> / M <word>      the next instruction entry: a j word (107 hex digits) / an m word (21)
//   R <reason> <info> <pc> <steps>   RUN all entries from 0; the expected stop record (reason 0
//                            OK, 1 E_RANGE, 2 E_UNSUPPORTED, 3 E_DECODE, 4 WAIT)
//   K <space> <addr> <hash>  FNV-1a 64 of the long words addr .. addr + 63 (read through the host port)
//   B <space> <addr> <hash>  the same through the backdoor (after a K of the SDRAM, so that the
//                            SDRAM requests before it are done)
//   E                        end of the test
// Spaces: 6 L1BM, 7 L2BM, 8 PDM, 9 DRAM (loc 0). The expected values are the official emulator's
// (gen_tests.py). +mvtime prints the clocks of every RUN.
`timescale 1ns/1ps
`default_nettype none
module tb_mv_env #(
    parameter integer ASYNC   = 1,
    parameter integer FREQ_HZ = 108000000,
    parameter real    P_SDR   = 9.259,     // controller clock period (ns)
    parameter real    P_BUS   = 37.037,    // core clock period (ASYNC only)
    parameter integer CL      = 3,
    parameter integer RDX     = 1,
    parameter real    PH_NS   = 4.63,      // SDRAM clock phase delay vs. the controller clock
    parameter real    T_CO    = 3.0,
    parameter real    T_IN    = 2.0,
    parameter TESTS = "mncore/sim/tb/mv/fixed/mv.tst",
    parameter PARG  = "mv=%s",
    parameter TAG   = "mv"
) (
    output reg         fin,
    output reg  [31:0] ntests,
    output reg  [31:0] nfail
);
    // ------------------------------------------------------------------ clocks and resets
    reg sclk = 1'b0, bclk_r = 1'b0;
    always #(P_SDR / 2.0) sclk = ~sclk;
    always #(P_BUS / 2.0) bclk_r = ~bclk_r;
    wire clk = (ASYNC != 0) ? bclk_r : sclk;
    reg  srst = 1'b1;      // SDRAM controller: once at the start
    reg  crst = 1'b1;      // the core: at every test (RESET)

    // ------------------------------------------------------------------ the core
    reg         mw_valid = 1'b0, mr_valid = 1'b0, run_start = 1'b0;
    reg  [7:0]  mw_space = 8'd0, mr_space = 8'd0, mw_mask = 8'hff;
    reg  [15:0] mw_loc = 16'd0, mr_loc = 16'd0, run_pc = 16'd0;
    reg  [22:0] mw_addr = 23'd0, mr_addr = 23'd0;
    reg  [63:0] mw_data = 64'd0;
    reg  [31:0] run_count = 32'd0;
    wire        mw_ready, mw_err, mr_ready, mr_err, mr_rsp_valid, core_busy;
    wire [63:0] mr_rsp_data;
    wire [7:0]  core_reason;
    wire [31:0] core_info, core_steps;
    wire [15:0] core_pc;
    wire        sd_req_valid, sd_req_ready, sd_req_we, sd_rsp_valid, init_done, err_addr, mv_busy, mv_err;
    wire [22:0] sd_req_addr;
    wire [63:0] sd_req_wdata, sd_rsp_rdata;
    wire [7:0]  sd_req_wmask;

    mvt_core #(.IMEM_AW(9), .L2AW(11), .PDM_AW(17), .DRAM_AW(19), .PDM_BASE(20'h80000), .DRAM_BASE(20'h00000))
    u_core (
        .clk(clk), .rst(crst),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err), .mw_space(mw_space), .mw_loc(mw_loc),
        .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err), .mr_space(mr_space), .mr_loc(mr_loc),
        .mr_addr(mr_addr), .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info), .core_pc(core_pc),
        .core_steps(core_steps),
        .sd_req_valid(sd_req_valid), .sd_req_ready(sd_req_ready), .sd_req_we(sd_req_we),
        .sd_req_addr(sd_req_addr), .sd_req_wdata(sd_req_wdata), .sd_req_wmask(sd_req_wmask),
        .sd_rsp_valid(sd_rsp_valid), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(err_addr),
        .mv_busy_o(mv_busy), .mv_err_o(mv_err));

    // ------------------------------------------------------------------ SDRAM (as tb_sdr_env)
    wire        d_cke, d_cs_n, d_ras_n, d_cas_n, d_we_n;
    wire [1:0]  d_ba;
    wire [10:0] d_a;
    wire [3:0]  d_dqm;
    wire [31:0] d_dq_o, d_dq_oe;
    reg  [31:0] d_dq_i;
    localparam integer INIT_CYC = 2200;      // ~20 us instead of 200 us
    sdr_bus64 #(.ASYNC(ASYNC), .FREQ_HZ(FREQ_HZ), .CL(CL), .INIT_CYC(INIT_CYC)) u_sdr (
        .clk(clk), .rst(srst), .sclk(sclk), .srst(srst), .cfg_rdx(RDX[1:0]),
        .init_done(init_done), .err_addr(err_addr),
        .req_valid(sd_req_valid), .req_ready(sd_req_ready), .req_we(sd_req_we), .req_addr(sd_req_addr),
        .req_wdata(sd_req_wdata), .req_wmask(sd_req_wmask), .rsp_valid(sd_rsp_valid), .rsp_rdata(sd_rsp_rdata),
        .sdr_cke(d_cke), .sdr_cs_n(d_cs_n), .sdr_ras_n(d_ras_n), .sdr_cas_n(d_cas_n), .sdr_we_n(d_we_n),
        .sdr_ba(d_ba), .sdr_a(d_a), .sdr_dqm(d_dqm), .sdr_dq_o(d_dq_o), .sdr_dq_oe(d_dq_oe), .sdr_dq_i(d_dq_i));
    reg         m_clk = 1'b0;
    reg         m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n;
    reg  [1:0]  m_ba;
    reg  [10:0] m_a;
    reg  [3:0]  m_dqm;
    reg  [31:0] m_dq_o, m_dq_oe;
    wire [31:0] dq_bus;
    always @(sclk) m_clk <= #(PH_NS + T_CO) sclk;
    always @(d_cke or d_cs_n or d_ras_n or d_cas_n or d_we_n or d_ba or d_a or d_dqm)
        {m_cke, m_cs_n, m_ras_n, m_cas_n, m_we_n, m_ba, m_a, m_dqm} <=
            #(T_CO) {d_cke, d_cs_n, d_ras_n, d_cas_n, d_we_n, d_ba, d_a, d_dqm};
    always @(d_dq_o or d_dq_oe) begin
        m_dq_o  <= #(T_CO) d_dq_o;
        m_dq_oe <= #(T_CO) d_dq_oe;
    end
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : g_dq
            assign dq_bus[g] = m_dq_oe[g] ? m_dq_o[g] : 1'bz;
        end
    endgenerate
    always @(dq_bus) d_dq_i <= #(T_IN) dq_bus;
    tb_sdr_model #(.T_INIT(15000.0), .NAME(TAG)) mdl (
        .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
        .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(dq_bus));

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
    function [63:0] fnv(input [63:0] h, input [63:0] v);
        fnv = (h ^ v) * 64'h00000100000001B3;
    endfunction

    // ------------------------------------------------------------------ backdoor (G / B lines)
    // The memories without the ports, in zero time (to keep the simulation short; the F / K lines
    // use the host ports): the SDRAM model (long word la of sdr_bus64 = {row, bank, colpair}: the
    // low half in the even column, the high half in the odd one), the L2BM of mn_l2bm and the
    // test L1BM (mn_ram_1r1w lanes: lane 0 the low half).
    localparam [19:0] PDM_BASE = 20'h80000, DRAM_BASE = 20'h00000;
    function [20:0] sdr_idx(input [19:0] la, input hi);
        sdr_idx = {la[8:7], la[19:9], la[6:0], hi};
    endfunction
    reg [19:0] la;
    task bd_write(input integer sp, input [22:0] ad, input [63:0] d);
        begin
            case (sp)
                6: begin u_core.u_l1.u_mem.g_lane[0].mem[ad[9:0]] = d[31:0];
                         u_core.u_l1.u_mem.g_lane[1].mem[ad[9:0]] = d[63:32]; end
                7: begin u_core.u_l2.u_mem.g_lane[0].mem[ad[10:0]] = d[31:0];
                         u_core.u_l2.u_mem.g_lane[1].mem[ad[10:0]] = d[63:32]; end
                default: begin
                    la = ((sp == 8) ? PDM_BASE : DRAM_BASE) | ad[19:0];
                    mdl.mem[sdr_idx(la, 1'b0)] = d[31:0];
                    mdl.mem[sdr_idx(la, 1'b1)] = d[63:32];
                end
            endcase
        end
    endtask
    task bd_read(input integer sp, input [22:0] ad, output [63:0] d);
        begin
            case (sp)
                6: d = {u_core.u_l1.u_mem.g_lane[1].mem[ad[9:0]], u_core.u_l1.u_mem.g_lane[0].mem[ad[9:0]]};
                7: d = {u_core.u_l2.u_mem.g_lane[1].mem[ad[10:0]], u_core.u_l2.u_mem.g_lane[0].mem[ad[10:0]]};
                default: begin
                    la = ((sp == 8) ? PDM_BASE : DRAM_BASE) | ad[19:0];
                    d = {mdl.mem[sdr_idx(la, 1'b1)], mdl.mem[sdr_idx(la, 1'b0)]};
                end
            endcase
        end
    endtask

    // ------------------------------------------------------------------ host port tasks
    integer err;
    task host_write(input [7:0] sp, input [22:0] a, input [63:0] d);
        begin
            mw_valid <= 1'b1; mw_space <= sp; mw_loc <= 16'd0; mw_addr <= a; mw_data <= d; mw_mask <= 8'hff;
            @(posedge clk);
            while (!mw_ready) @(posedge clk);
            if (mw_err) begin
                $display("%0s: ERROR host write rejected (space %0d address %0d)", TAG, sp, a);
                err = err + 1;
            end
            mw_valid <= 1'b0;
        end
    endtask
    integer wdg;
    task host_read(input [7:0] sp, input [22:0] a, output [63:0] d);
        begin
            mr_valid <= 1'b1; mr_space <= sp; mr_loc <= 16'd0; mr_addr <= a;
            @(posedge clk);
            while (!mr_ready) @(posedge clk);
            mr_valid <= 1'b0;
            d = 64'd0;
            if (mr_err) begin
                $display("%0s: ERROR host read rejected (space %0d address %0d)", TAG, sp, a);
                err = err + 1;
            end else begin
                wdg = 0;
                @(posedge clk);
                while (!mr_rsp_valid && wdg < 10000) begin @(posedge clk); wdg = wdg + 1; end
                if (wdg >= 10000) begin
                    $display("%0s: ERROR no read response", TAG);
                    err = err + 1;
                end
                d = mr_rsp_data;
            end
        end
    endtask

    // ------------------------------------------------------------------ test file
    integer fd, r, k, n, style, sp, nent, tfail, cyc, t0, mvtime, xr, xi, xp, xs;
    reg [8*8-1:0]   cmd;
    reg [8*64-1:0]  name;
    reg [8*512-1:0] line;
    reg [8*256-1:0] fname;
    reg [63:0]      seed, v, h, want;
    reg [22:0]      a;
    reg [427:0]     word;
    always @(posedge clk) cyc <= cyc + 1;
    initial begin
        fin = 1'b0; ntests = 0; nfail = 0; err = 0; cyc = 0;
        mvtime = $test$plusargs("mvtime");
        repeat (8) @(posedge sclk);
        srst <= 1'b0;
        if (!$value$plusargs(PARG, fname)) fname = TESTS;
        fd = (fname == "skip") ? 0 : $fopen(fname, "r");
        if (fname == "skip") begin
            fin = 1'b1;
        end else if (fd == 0) begin
            $display("%0s: ERROR cannot open %0s", TAG, fname);
            nfail = 1;
            fin = 1'b1;
        end else begin
            while (!init_done) @(posedge clk);
            while ($fscanf(fd, "%s", cmd) == 1) begin
                if (cmd == "#") begin
                    r = $fgets(line, fd);
                end else if (cmd == "T") begin
                    r = $fscanf(fd, "%s %h", name, seed);
                    ntests = ntests + 1; tfail = 0; err = 0; nent = 0;
                    sm_s = seed;
                    crst = 1'b1;
                    repeat (16) @(posedge clk);
                    crst = 1'b0;
                    // the units clear the L2BM and the tags first (the backdoor fills come after)
                    @(posedge clk);
                    while (!(u_core.l2_idle && u_core.mv_ready)) @(posedge clk);
                end else if (cmd == "G") begin
                    r = $fscanf(fd, "%d %h %d %d", sp, a, n, style);
                    for (k = 0; k < n; k = k + 1) begin
                        if (style == 9) v = 64'd0;
                        else begin sm_next(v); v = styled(v, style); end
                        bd_write(sp, a + k, v);
                    end
                end else if (cmd == "B") begin
                    r = $fscanf(fd, "%d %h %h", sp, a, want);
                    h = 64'hCBF29CE484222325;
                    for (k = 0; k < 64; k = k + 1) begin
                        bd_read(sp, a + k, v);
                        h = fnv(h, v);
                    end
                    if (h !== want) begin
                        $display("%0s %0s: %0s long words %0h..%0h differ (hash %h, expected %h; backdoor)", TAG, name,
                                 (sp == 6) ? "L1BM" : (sp == 7) ? "L2BM" : (sp == 8) ? "PDM" : "DRAM",
                                 a, a + 63, h, want);
                        tfail = tfail + 1;
                    end
                end else if (cmd == "F") begin
                    r = $fscanf(fd, "%d %h %d %d", sp, a, n, style);
                    for (k = 0; k < n; k = k + 1) begin
                        if (style == 9) v = 64'd0;
                        else begin sm_next(v); v = styled(v, style); end
                        host_write(sp, a + k, v);
                    end
                end else if (cmd == "V") begin
                    r = $fscanf(fd, "%d %h %h", sp, a, v);
                    host_write(sp, a, v);
                end else if (cmd == "J" || cmd == "M") begin
                    r = $fscanf(fd, "%h", word);
                    word[427:426] = (cmd == "J") ? 2'b01 : 2'b10;
                    word[425:82] = (cmd == "J") ? word[425:82] : 344'd0;
                    for (k = 0; k < 7; k = k + 1)
                        host_write(8'h00, {nent[19:0], k[2:0]},
                                   (k == 6) ? {word[427:426], 20'd0, word[425:384]} : word[64*k +: 64]);
                    nent = nent + 1;
                end else if (cmd == "R") begin
                    r = $fscanf(fd, "%d %h %d %d", xr, xi, xp, xs);
                    @(posedge clk);
                    run_start <= 1'b1; run_pc <= 16'd0; run_count <= nent;
                    @(posedge clk);
                    run_start <= 1'b0;
                    t0 = cyc;
                    @(posedge clk);
                    wdg = 0;
                    while (core_busy && wdg < 20000000) begin @(posedge clk); wdg = wdg + 1; end
                    if (wdg >= 20000000) begin
                        $display("%0s %0s: ERROR the RUN does not end", TAG, name);
                        err = err + 1;
                    end
                    if (mvtime) $display("%0s %0s: RUN of %0d entries: %0d clocks", TAG, name, nent, cyc - t0);
                    if (core_reason !== xr || core_info !== xi || core_pc !== xp || core_steps !== xs) begin
                        $display("%0s %0s: stop reason %0d info %0h pc %0d steps %0d, expected %0d %0h %0d %0d",
                                 TAG, name, core_reason, core_info, core_pc, core_steps, xr, xi, xp, xs);
                        tfail = tfail + 1;
                    end
                end else if (cmd == "K") begin
                    r = $fscanf(fd, "%d %h %h", sp, a, want);
                    h = 64'hCBF29CE484222325;
                    for (k = 0; k < 64; k = k + 1) begin
                        host_read(sp, a + k, v);
                        h = fnv(h, v);
                    end
                    if (h !== want) begin
                        $display("%0s %0s: %0s long words %0h..%0h differ (hash %h, expected %h)", TAG, name,
                                 (sp == 6) ? "L1BM" : (sp == 7) ? "L2BM" : (sp == 8) ? "PDM" : "DRAM",
                                 a, a + 63, h, want);
                        tfail = tfail + 1;
                    end
                end else if (cmd == "E") begin
                    tfail = tfail + err;
                    if (tfail != 0) begin
                        nfail = nfail + 1;
                        $display("%0s: FAIL %0s (%0d differences)", TAG, name, tfail);
                    end else begin
                        $display("%0s: ok   %0s", TAG, name);
                    end
                end else begin
                    $display("%0s: ERROR unknown line %0s", TAG, cmd);
                    r = $fgets(line, fd);
                end
            end
            $fclose(fd);
            if (mdl.errors != 0) begin
                $display("%0s: ERROR the SDRAM model saw %0d violations", TAG, mdl.errors);
                nfail = nfail + 1;
            end
            if (mv_err) begin
                $display("%0s: ERROR sdr_bus64 err_addr", TAG);
                nfail = nfail + 1;
            end
            fin = 1'b1;
        end
    end
endmodule
`default_nettype wire

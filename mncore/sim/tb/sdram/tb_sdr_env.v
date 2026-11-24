// tb_sdr_env: one sdr_bus64 + board delays + SDRAM model + traffic and reference checker.
// Simulation only (iverilog -g2012). `done` goes high at the end; `fails` counts all problems
// (data mismatches, missing / extra responses, SDRAM model errors, timeouts).
`timescale 1ns/1ps

module tb_sdr_env #(
    parameter integer ASYNC    = 0,
    parameter integer FREQ_HZ  = 108000000,
    parameter real    P_SDR    = 9.259,     // controller clock period (ns)
    parameter real    P_BUS    = 9.259,     // bus clock period (ASYNC only)
    parameter integer CL       = 3,
    parameter integer RDX      = 1,
    parameter real    PH_NS    = 4.63,      // SDRAM clock phase delay vs. the controller clock
    parameter real    T_CO     = 3.0,       // FPGA clock -> output pin
    parameter real    T_IN     = 2.0,       // input pin -> capture register
    parameter integer SEQ_AW   = 12,        // sequential test: 2**SEQ_AW long words
    parameter integer N_RAND   = 6000,      // random mixed operations
    parameter integer SEED     = 1,
    parameter NAME = "env"
) (
    output reg     done,
    output integer fails
);
    // ------------------------------------------------------------ clocks and resets
    reg sclk = 1'b0, bclk_r = 1'b0;
    always #(P_SDR / 2.0) sclk = ~sclk;
    always #(P_BUS / 2.0) bclk_r = ~bclk_r;
    wire bclk = (ASYNC != 0) ? bclk_r : sclk;

    reg rst = 1'b1, srst = 1'b1;
    initial begin
        repeat (8) @(posedge bclk);
        rst <= 1'b0;
    end
    initial begin
        repeat (8) @(posedge sclk);
        repeat (4) @(posedge bclk);
        srst <= 1'b0;
    end

    // ------------------------------------------------------------ DUT
    reg         req_valid = 1'b0;
    wire        req_ready;
    reg         req_we = 1'b0;
    reg  [22:0] req_addr = 23'd0;
    reg  [63:0] req_wdata = 64'd0;
    reg  [7:0]  req_wmask = 8'd0;
    wire        rsp_valid;
    wire [63:0] rsp_rdata;
    wire        init_done, err_addr;

    wire        d_cke, d_cs_n, d_ras_n, d_cas_n, d_we_n;
    wire [1:0]  d_ba;
    wire [10:0] d_a;
    wire [3:0]  d_dqm;
    wire [31:0] d_dq_o, d_dq_oe;
    reg  [31:0] d_dq_i;

    localparam integer INIT_CYC = 2200;      // ~20 us instead of 200 us

    sdr_bus64 #(
        .ASYNC(ASYNC), .FREQ_HZ(FREQ_HZ), .CL(CL), .INIT_CYC(INIT_CYC)
    ) dut (
        .clk(bclk), .rst(rst), .sclk(sclk), .srst(srst), .cfg_rdx(RDX[1:0]),
        .init_done(init_done), .err_addr(err_addr),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_wmask(req_wmask), .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata),
        .sdr_cke(d_cke), .sdr_cs_n(d_cs_n), .sdr_ras_n(d_ras_n), .sdr_cas_n(d_cas_n), .sdr_we_n(d_we_n),
        .sdr_ba(d_ba), .sdr_a(d_a), .sdr_dqm(d_dqm), .sdr_dq_o(d_dq_o), .sdr_dq_oe(d_dq_oe),
        .sdr_dq_i(d_dq_i)
    );

    // ------------------------------------------------------------ board: pin delays
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

    tb_sdr_model #(.T_INIT(15000.0), .NAME(NAME)) mdl (
        .clk(m_clk), .cke(m_cke), .cs_n(m_cs_n), .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
        .ba(m_ba), .a(m_a), .dqm(m_dqm), .dq(dq_bus)
    );

    // ------------------------------------------------------------ reference and checker
    reg [63:0] refm [0:(1 << 20) - 1];
    reg [63:0] expq [$];
    reg [19:0] adrq [$];
    integer    nrsp = 0, nreq_rd = 0, mism = 0;
    initial fails = 0;

    always @(posedge bclk) begin
        if (rsp_valid) begin
            if (expq.size() == 0) begin
                fails = fails + 1;
                $display("[%s] unexpected response %h", NAME, rsp_rdata);
            end else begin : chk
                reg [63:0] e;
                reg [19:0] ea;
                e  = expq.pop_front();
                ea = adrq.pop_front();
                if (rsp_rdata !== e) begin
                    mism = mism + 1;
                    fails = fails + 1;
                    if (mism <= 10)
                        $display("[%s] %0t mismatch @%05h: got %h exp %h", NAME, $realtime, ea, rsp_rdata, e);
                end
            end
            nrsp = nrsp + 1;
        end
    end

    function automatic [63:0] merge(input [63:0] old, input [63:0] d, input [7:0] m);
        integer b;
        begin
            merge = old;
            for (b = 0; b < 8; b = b + 1)
                if (m[b]) merge[8*b +: 8] = d[8*b +: 8];
        end
    endfunction

    // one request; returns after it was accepted
    task automatic req(input reg we, input [22:0] ad, input [63:0] d, input [7:0] m);
        begin
            req_valid <= 1'b1;
            req_we    <= we;
            req_addr  <= ad;
            req_wdata <= d;
            req_wmask <= m;
            @(posedge bclk);
            while (!req_ready) @(posedge bclk);
            if (we) begin
                refm[ad[19:0]] = merge(refm[ad[19:0]], d, m);
            end else begin
                expq.push_back(refm[ad[19:0]]);
                adrq.push_back(ad[19:0]);
                nreq_rd = nreq_rd + 1;
            end
        end
    endtask

    task automatic wr(input [22:0] ad, input [63:0] d, input [7:0] m);
        req(1'b1, ad, d, m);
    endtask

    task automatic rd(input [22:0] ad);
        req(1'b0, ad, 64'd0, 8'd0);
    endtask

    task automatic idle;
        req_valid <= 1'b0;
    endtask

    task automatic drain;
        integer t;
        begin
            idle();
            t = 0;
            while (expq.size() != 0 && t < 100000) begin
                @(posedge bclk);
                t = t + 1;
            end
            if (expq.size() != 0) begin
                fails = fails + 1;
                $display("[%s] timeout: %0d responses missing", NAME, expq.size());
            end
            repeat (4) @(posedge bclk);
        end
    endtask

    function automatic [63:0] pat(input [19:0] ad, input [31:0] s);
        pat = {~ad[11:0], ad[19:0] ^ s[19:0], ad[19:0], ad[19:8] ^ s[31:20]};
    endfunction

    function automatic [19:0] pool(input integer p);
        pool = (p * 20'h9E3B7 + 20'h01234);
    endfunction

    integer seed_v = SEED;
    function automatic [31:0] rnd(input integer dummy);
        rnd = $random(seed_v);
    endfunction

    function automatic [63:0] rnd64(input integer dummy);
        rnd64 = {rnd(0), rnd(0)};
    endfunction

    // ------------------------------------------------------------ test sequence
    integer k, p, t0, t1, cyc_seq, cyc_rnd, cyc_seqw;
    reg [7:0] m;
    reg [19:0] base;

    initial begin
        done = 1'b0;
        @(negedge rst);
        while (!init_done) @(posedge bclk);
        $display("[%s] init done at %0t ns (ASYNC=%0d f=%0d CL=%0d RDX=%0d PH=%.2f)",
                 NAME, $realtime, ASYNC, FREQ_HZ, CL, RDX, PH_NS);

        // 1. directed: one row, back to back
        for (k = 0; k < 8; k = k + 1) wr(k, 64'h1111_0000_0000_0000 * k + k, 8'hff);
        for (k = 0; k < 8; k = k + 1) rd(k);
        // read-after-write and write-after-read on one address, partial masks
        wr(20'h00010, 64'h0123_4567_89ab_cdef, 8'hff);
        rd(20'h00010);
        wr(20'h00010, 64'hffee_ddcc_bbaa_9988, 8'b1010_0101);
        rd(20'h00010);
        rd(20'h00010);
        wr(20'h00010, 64'h0, 8'b0000_0001);
        rd(20'h00010);
        // same bank, different rows (row conflict every access)
        for (k = 0; k < 6; k = k + 1) wr({k[10:0], 2'd1, 7'd5}, rnd64(0), 8'hff);
        for (k = 0; k < 6; k = k + 1) rd({k[10:0], 2'd1, 7'd5});
        // four banks, same row index, interleaved
        for (k = 0; k < 16; k = k + 1) wr({11'd7, k[1:0], k[6:2]}, rnd64(0), 8'hff);
        for (k = 0; k < 16; k = k + 1) rd({11'd7, k[1:0], k[6:2]});
        drain();

        // 2. sequential stream crossing row / bank boundaries
        base = 20'h003c0;
        t0 = $realtime;
        for (k = 0; k < (1 << SEQ_AW); k = k + 1) wr(base + k, pat(base + k, 32'h5a5a_c3c3), 8'hff);
        idle();
        t1 = $realtime;
        cyc_seqw = (t1 - t0) / P_BUS;
        t0 = $realtime;
        for (k = 0; k < (1 << SEQ_AW); k = k + 1) rd(base + k);
        drain();
        t1 = $realtime;
        cyc_seq = (t1 - t0) / P_BUS;

        // 3. random pool over the whole address space
        for (p = 0; p < 4096; p = p + 1) wr(pool(p), rnd64(0), 8'hff);
        for (k = 0; k < N_RAND; k = k + 1) begin
            p = rnd(0) % 4096;
            m = (rnd(0) % 4 == 0) ? 8'hff : rnd(0);
            if (rnd(0) % 2) wr(pool(p), rnd64(0), m);
            else rd(pool(p));
            if (rnd(0) % 16 == 0) begin
                idle();
                repeat (rnd(0) % 8) @(posedge bclk);
            end
        end
        drain();
        t0 = $realtime;
        for (k = 0; k < 2048; k = k + 1) rd(pool(rnd(0) % 4096));
        drain();
        t1 = $realtime;
        cyc_rnd = (t1 - t0) / P_BUS;

        // 4. idle across several refresh intervals, then read back the sequential area
        repeat (40000 / P_BUS) @(posedge bclk);
        for (k = 0; k < 256; k = k + 1) rd(base + k * 13);
        drain();

        // 5. out-of-range address: wraps to [19:0] and sets err_addr
        if (err_addr !== 1'b0) begin
            fails = fails + 1;
            $display("[%s] err_addr set too early", NAME);
        end
        rd({3'd5, base});
        drain();
        if (err_addr !== 1'b1) begin
            fails = fails + 1;
            $display("[%s] err_addr not set", NAME);
        end

        if (nrsp != nreq_rd) begin
            fails = fails + 1;
            $display("[%s] %0d reads, %0d responses", NAME, nreq_rd, nrsp);
        end
        fails = fails + mdl.errors;
        $display("[%s] reads=%0d mismatches=%0d model_errors=%0d (ACT %0d RD %0d WR %0d PRE %0d REF %0d)",
                 NAME, nreq_rd, mism, mdl.errors, mdl.n_act, mdl.n_rd, mdl.n_wr, mdl.n_pre, mdl.n_ref);
        $display("[%s] bus cycles per long word: seq write %.3f, seq read %.3f, random read %.3f",
                 NAME, 1.0 * cyc_seqw / (1 << SEQ_AW), 1.0 * cyc_seq / (1 << SEQ_AW), cyc_rnd / 2048.0);
        done = 1'b1;
    end
endmodule

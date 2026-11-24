// sdr_test_ctl: SDRAM test sequencer for the sdram_test design.
//
// 1. Sweep (SWEEP = 1): for every SDRAM clock phase (0..15 if DYN_PHASE, else FIX_PH) and every
//    read capture delay cfg_rdx (0..3): reset + re-initialize the controller, write 2**QAW long words,
//    read them back sequentially and in random order. Print "S p= k= e=" per point.
//    Then choose the (phase, k) in the middle of the longest passing phase window ("C ..." line).
// 2. Full test with the chosen setting, repeated forever (header, "C" and "R" lines per iteration):
//      sw: sequential write of 2**AW long words (pattern A)          -> cycles
//      sr: sequential read + check                                     -> cycles
//      rr: 2**AW random reads (20-bit LFSR addresses) + check          -> cycles
//      rw: 2**AW random writes (pattern A again, contents unchanged)   -> cycles
//      mask: sequential write of pattern B with a per-address byte mask, then read + check the merge
//    The pattern seed changes every iteration. Cycle counts run from the first request to the last
//    response (reads) or to the last accepted request (writes).
`default_nettype none

module sdr_test_ctl #(
    parameter integer FREQ_HZ   = 108000000,
    parameter integer CL        = 3,
    parameter integer AW        = 20,
    parameter integer QAW       = 14,
    parameter integer SWEEP     = 1,
    parameter integer DYN_PHASE = 1,
    parameter integer FIX_PH    = 8,
    parameter integer FIX_K     = 1,
    parameter integer BOOT_CYC  = 100000,  // wait before the first line (host opens the port)
    parameter integer SETTLE_CYC = 4096    // controller reset time after a phase change
) (
    input  wire         clk,
    input  wire         rst,

    output reg          crst,
    output reg  [1:0]   cfg_rdx,
    output reg  [3:0]   psda,
    input  wire         init_done,

    output reg          req_valid,
    input  wire         req_ready,
    output reg          req_we,
    output reg  [22:0]  req_addr,
    output reg  [63:0]  req_wdata,
    output reg  [7:0]   req_wmask,
    input  wire         rsp_valid,
    input  wire [63:0]  rsp_rdata,

    output reg          pr_start,
    output reg  [1:0]   pr_kind,
    output reg  [287:0] pr_fields,
    input  wire         pr_busy,

    output reg          st_init,
    output reg          st_sweep_done,
    output reg          st_pass,
    output reg          st_fail,
    output reg          st_iter
);
    // ------------------------------------------------------------------ patterns
    function [63:0] pat_a;
        input [19:0] a;
        input [63:0] s;
        begin
            pat_a = {~a[15:0], a[19:4], a[19:0], a[11:0]} ^ s;
        end
    endfunction

    function [7:0] mask_b;
        input [11:0] a;
        begin
            mask_b = {a[3:0], ~a[3:0]} ^ {a[7:4], a[11:8]} ^ 8'h5a;
        end
    endfunction

    function [63:0] merge;
        input [63:0] old;
        input [63:0] nw;
        input [7:0]  m;
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1)
                merge[8*b +: 8] = m[b] ? nw[8*b +: 8] : old[8*b +: 8];
        end
    endfunction

    function [19:0] lfsr_next;             // x^20 + x^17 + 1
        input [19:0] l;
        begin
            lfsr_next = {l[18:0], l[19] ^ l[16]};
        end
    endfunction

    // ------------------------------------------------------------------ operation engine
    localparam [20:0] N_FULL  = 21'd1 << AW;
    localparam [20:0] N_QUICK = 21'd1 << QAW;
    localparam [19:0] M_FULL  = N_FULL[19:0] - 20'd1;
    localparam [19:0] M_QUICK = N_QUICK[19:0] - 20'd1;

    reg         op_busy, op_go, op_done;
    reg         op_we, op_rand, op_mask, op_full;
    reg  [63:0] seed;
    reg  [20:0] iss_n, chk_n;
    reg  [19:0] lf_i, lf_c;
    reg  [31:0] cyc;

    wire [20:0] op_n   = op_full ? N_FULL : N_QUICK;
    wire [19:0] amask  = op_full ? M_FULL : M_QUICK;
    wire [19:0] iss_a  = op_rand ? (lf_i & amask) : iss_n[19:0];
    wire [19:0] chk_a  = op_rand ? (lf_c & amask) : chk_n[19:0];

    reg         c_v;
    reg  [63:0] c_got, c_exp;
    reg  [19:0] c_addr;
    reg  [23:0] err_a, err_m;
    reg         c_is_m;
    reg  [19:0] fa;
    reg  [63:0] fd;
    reg         have_fa;

    wire        last_acc = req_valid && req_ready && (iss_n == op_n);

    always @(posedge clk) begin
        op_done <= 1'b0;
        c_v <= 1'b0;
        if (rst) begin
            op_busy   <= 1'b0;
            req_valid <= 1'b0;
        end else if (op_go) begin
            op_busy   <= 1'b1;
            iss_n     <= 21'd0;
            chk_n     <= 21'd0;
            lf_i      <= 20'd1;
            lf_c      <= 20'd1;
            cyc       <= 32'd0;
            req_valid <= 1'b0;
        end else if (op_busy) begin
            cyc <= cyc + 32'd1;
            // issue
            if (!req_valid || req_ready) begin
                if (iss_n != op_n) begin
                    req_valid <= 1'b1;
                    req_we    <= op_we;
                    req_addr  <= {3'b000, iss_a};
                    req_wdata <= op_mask ? pat_a(iss_a, ~seed) : pat_a(iss_a, seed);
                    req_wmask <= op_mask ? mask_b(iss_a[11:0]) : 8'hff;
                    iss_n     <= iss_n + 21'd1;
                    lf_i      <= lfsr_next(lf_i);
                end else begin
                    req_valid <= 1'b0;
                end
            end
            // check, stage 1
            if (rsp_valid) begin
                c_v    <= 1'b1;
                c_got  <= rsp_rdata;
                c_exp  <= op_mask ? merge(pat_a(chk_a, seed), pat_a(chk_a, ~seed), mask_b(chk_a[11:0]))
                                  : pat_a(chk_a, seed);
                c_addr <= chk_a;
                c_is_m <= op_mask;
                chk_n  <= chk_n + 21'd1;
                lf_c   <= lfsr_next(lf_c);
            end
            // done
            if (op_we ? last_acc : (chk_n == op_n && !c_v && iss_n == op_n && !req_valid)) begin
                op_busy   <= 1'b0;
                op_done   <= 1'b1;
                req_valid <= 1'b0;
            end
        end
    end

    // check, stage 2 (error counters are cleared by the sequencer)
    reg clr_err;
    always @(posedge clk) begin
        if (rst || clr_err) begin
            err_a   <= 24'd0;
            err_m   <= 24'd0;
            have_fa <= 1'b0;
            fa      <= 20'd0;
            fd      <= 64'd0;
        end else if (c_v && c_got != c_exp) begin
            if (c_is_m) begin
                if (err_m != 24'hffffff) err_m <= err_m + 24'd1;
            end else begin
                if (err_a != 24'hffffff) err_a <= err_a + 24'd1;
            end
            if (!have_fa) begin
                have_fa <= 1'b1;
                fa      <= c_addr;
                fd      <= c_got;
            end
        end
    end

    // ------------------------------------------------------------------ sequencer
    localparam [4:0] Q_BOOT = 5'd0, Q_HELLO = 5'd1, Q_PRW = 5'd2, Q_SET = 5'd3, Q_SETW = 5'd4,
                     Q_INITW = 5'd5, Q_OP = 5'd6, Q_OPW = 5'd7, Q_REP = 5'd8, Q_NEXT = 5'd9,
                     Q_PICK = 5'd10, Q_PICKR = 5'd11, Q_REPH = 5'd12, Q_REPC = 5'd13,
                     Q_REPR = 5'd14;
    reg  [4:0]  q, q_ret;
    reg  [28:0] tmr;
    reg         sweeping;
    reg  [3:0]  ph;
    reg  [1:0]  kk;
    reg  [2:0]  step;
    reg  [31:0] cyc_s [0:3];
    reg  [63:0] eye;
    reg  [15:0] iter;
    reg  [1:0]  pk;
    reg  [3:0]  ps;
    reg  [4:0]  pl, best_n;
    reg  [3:0]  best_ph;
    reg  [1:0]  best_k;

    localparam [3:0] PH0   = (DYN_PHASE != 0) ? 4'd0 : FIX_PH[3:0];
    localparam [2:0] NSTEP_SWEEP = 3'd3;
    localparam [2:0] NSTEP_FULL  = 3'd6;
    localparam [28:0] BOOT = BOOT_CYC[28:0];
    localparam [28:0] SETTLE = SETTLE_CYC[28:0] - 29'd1;
    localparam [287:0] HELLO = {FREQ_HZ[31:0], CL[3:0], AW[7:0], 244'd0};

    wire [5:0] eye_i  = {pk, ps + pl[3:0]};
    wire       eye_ok = eye[eye_i];
    wire [3:0] best_c = ps + ((pl[3:0] - 4'd1) >> 1);

    always @(posedge clk) begin
        op_go    <= 1'b0;
        pr_start <= 1'b0;
        clr_err  <= 1'b0;
        if (rst) begin
            q             <= Q_BOOT;
            tmr           <= BOOT;
            crst          <= 1'b1;
            psda          <= PH0;
            cfg_rdx       <= FIX_K[1:0];
            eye           <= 64'd0;
            iter          <= 16'd0;
            st_init       <= 1'b0;
            st_sweep_done <= 1'b0;
            st_pass       <= 1'b0;
            st_fail       <= 1'b0;
            st_iter       <= 1'b0;
        end else begin
            case (q)
                Q_BOOT: begin                  // let the host open the serial port
                    if (tmr != 29'd0) tmr <= tmr - 29'd1;
                    else q <= Q_HELLO;
                end
                Q_HELLO: begin
                    pr_kind   <= 2'd0;
                    pr_fields <= HELLO;
                    pr_start  <= 1'b1;
                    sweeping  <= (SWEEP != 0);
                    ph        <= (SWEEP != 0) ? PH0 : FIX_PH[3:0];
                    kk        <= (SWEEP != 0) ? 2'd0 : FIX_K[1:0];
                    best_n    <= 5'd0;
                    best_ph   <= FIX_PH[3:0];
                    best_k    <= FIX_K[1:0];
                    q         <= Q_PRW;
                    q_ret     <= Q_SET;
                end
                Q_PRW: if (!pr_start && !pr_busy) q <= q_ret;
                Q_SET: begin
                    crst    <= 1'b1;
                    psda    <= ph;
                    cfg_rdx <= kk;
                    st_init <= 1'b0;
                    tmr     <= SETTLE;         // let the PLL phase settle
                    q       <= Q_SETW;
                end
                Q_SETW: begin
                    if (tmr != 29'd0) tmr <= tmr - 29'd1;
                    else begin
                        crst <= 1'b0;
                        q    <= Q_INITW;
                    end
                end
                Q_INITW: if (init_done && !crst) begin
                    st_init <= 1'b1;
                    step    <= 3'd0;
                    clr_err <= 1'b1;
                    seed    <= {iter, ph, 2'b00, kk, 8'h5a, iter ^ 16'hc3a5, 16'h0f1e};
                    q       <= Q_OP;
                end
                Q_OP: begin
                    op_full <= !sweeping;
                    case (step)
                        3'd0: begin op_we <= 1'b1; op_rand <= 1'b0; op_mask <= 1'b0; end
                        3'd1: begin op_we <= 1'b0; op_rand <= 1'b0; op_mask <= 1'b0; end
                        3'd2: begin op_we <= 1'b0; op_rand <= 1'b1; op_mask <= 1'b0; end
                        3'd3: begin op_we <= 1'b1; op_rand <= 1'b1; op_mask <= 1'b0; end
                        3'd4: begin op_we <= 1'b1; op_rand <= 1'b0; op_mask <= 1'b1; end
                        default: begin op_we <= 1'b0; op_rand <= 1'b0; op_mask <= 1'b1; end
                    endcase
                    op_go <= 1'b1;
                    q     <= Q_OPW;
                end
                Q_OPW: if (op_done) begin
                    if (step < 3'd4) cyc_s[step[1:0]] <= cyc;
                    step <= step + 3'd1;
                    if (step + 3'd1 == (sweeping ? NSTEP_SWEEP : NSTEP_FULL)) q <= Q_REP;
                    else q <= Q_OP;
                end
                Q_REP: if (!c_v) begin         // the last check result is in the counters
                    if (sweeping) begin
                        pr_kind   <= 2'd1;
                        pr_fields <= {ph, 2'b00, kk, err_a, 256'd0};
                        eye[{kk, ph}] <= (err_a == 24'd0) && (err_m == 24'd0);
                        pr_start  <= 1'b1;
                        q         <= Q_PRW;
                        q_ret     <= Q_NEXT;
                    end else begin
                        if (err_a != 24'd0 || err_m != 24'd0) st_fail <= 1'b1;
                        else st_pass <= 1'b1;
                        st_iter <= ~st_iter;
                        q       <= Q_REPH;
                    end
                end
                // full test: repeat the header and the chosen setting before every result, so a
                // host that connects late still gets everything
                Q_REPH: begin
                    pr_kind   <= 2'd0;
                    pr_fields <= HELLO;
                    pr_start  <= 1'b1;
                    q         <= Q_PRW;
                    q_ret     <= Q_REPC;
                end
                Q_REPC: begin
                    pr_kind   <= 2'd2;
                    pr_fields <= {best_ph, 2'b00, best_k, 3'b000, best_n, eye, 208'd0};
                    pr_start  <= 1'b1;
                    q         <= Q_PRW;
                    q_ret     <= Q_REPR;
                end
                Q_REPR: begin
                    pr_kind   <= 2'd3;
                    pr_fields <= {iter, ph, 2'b00, kk, err_a, err_m,
                                  cyc_s[0], cyc_s[1], cyc_s[2], cyc_s[3], fa, fd, 4'd0};
                    pr_start  <= 1'b1;
                    q         <= Q_PRW;
                    q_ret     <= Q_NEXT;
                end
                Q_NEXT: begin
                    if (sweeping) begin
                        if (kk != 2'd3) begin
                            kk <= kk + 2'd1;
                            q  <= Q_SET;
                        end else if (DYN_PHASE != 0 && ph != 4'd15) begin
                            kk <= 2'd0;
                            ph <= ph + 4'd1;
                            q  <= Q_SET;
                        end else begin
                            pk      <= 2'd0;
                            ps      <= 4'd0;
                            pl      <= 5'd0;
                            best_n  <= 5'd0;
                            best_ph <= FIX_PH[3:0];
                            best_k  <= FIX_K[1:0];
                            q       <= Q_PICK;
                        end
                    end else begin
                        iter    <= iter + 16'd1;
                        step    <= 3'd0;
                        clr_err <= 1'b1;
                        seed    <= {iter + 16'd1, ph, 2'b00, kk, 8'h5a, (iter + 16'd1) ^ 16'hc3a5, 16'h0f1e};
                        q       <= Q_OP;
                    end
                end
                Q_PICK: begin                  // longest circular run of passing phases per k
                    if (pl != 5'd16 && eye_ok) begin
                        pl <= pl + 5'd1;
                    end else begin
                        if (pl > best_n) begin
                            best_n  <= pl;
                            best_k  <= pk;
                            best_ph <= (pl == 5'd16) ? 4'd8 : best_c;
                        end
                        pl <= 5'd0;
                        ps <= ps + 4'd1;
                        if (ps == 4'd15) begin
                            pk <= pk + 2'd1;
                            if (pk == 2'd3) q <= Q_PICKR;
                        end
                    end
                end
                Q_PICKR: begin
                    pr_kind   <= 2'd2;
                    pr_fields <= {best_ph, 2'b00, best_k, 3'b000, best_n, eye, 208'd0};
                    pr_start  <= 1'b1;
                    st_sweep_done <= 1'b1;
                    if (best_n == 5'd0) st_fail <= 1'b1;
                    sweeping  <= 1'b0;
                    ph        <= best_ph;
                    kk        <= best_k;
                    q         <= Q_PRW;
                    q_ret     <= Q_SET;
                end
                default: q <= Q_BOOT;
            endcase
        end
    end
endmodule

`default_nettype wire

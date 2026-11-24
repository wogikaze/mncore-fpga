// mn_l1bm_rrn: one lane of the result reduction network (RRN), sequential (WP31).
//
// Reduces the inputs of one stage (nin_m1 + 1 of them, at most 16), or 16 inputs in two
// stages of 4 (the L1BM 16x1 reduction: inputs 4g..4g+3 give stage result g, the 4 stage
// results give the result), one lane at a time. The arithmetic is the one of viz/core rrn.rs,
// which the official emulator matches on every rrn vector (WP03):
//   fadd : every input with a non-zero exponent field gets its hidden bit and 3 zero bits, is
//          shifted to the largest exponent of the stage with round-to-nearest-even (each input
//          rounded on its own), the signed values are added exactly, and the sum is rounded once
//          (nearest even) into the output format and packed: zero for a zero sum or when every
//          exponent field is 0, infinity on overflow, +0 on underflow (no subnormals). Any input
//          with an all-ones exponent makes the result infinity, negative only if every such
//          input is negative.
//   max / min: sign-magnitude integers (+0 > -0); iadd: sum modulo the lane width;
//   band / bor: bitwise; and / or: 1 if all / any inputs are non-zero, else 0.
// A two-stage fadd rounds the stage results to the input format; out_half rounds the final
// result of a single-precision fadd to half (the L1BM hfadd, whose inputs the caller extends
// to single). Formats: d 1/11/52, f 1/8/23, h 1/6/9 (SDM 1.3).
// The L2BM reductions (WP32) are one stage of 8 (l2bmr) or 2 (l2bmr2) inputs; their hfadd is
// a half-precision fadd (fmt = 2, out_half = 0).
//
// Protocol: start (when !busy) with the configuration, which stays stable until done. The unit
// reads input in_idx through in_val in the same clock (in_idx = 4 g + i in a two-stage
// reduction, else i); a lane value is in the low bits with the upper bits 0. zgrp[g] says that
// the 4 inputs of group g are known to be 0 (MABs that do not exist): the group is skipped,
// its stage result is 0 for every operation. done pulses with res (lane value in the low bits).
// Time per stage: fadd 2 (n + 1) clocks plus about shift / 8 per input and the normalisation,
// the other operations n + 2 clocks.
`default_nettype none
module mn_l1bm_rrn (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [2:0]  op,         // 0 fadd, 1 max, 2 min, 3 iadd, 4 band, 5 and, 6 bor, 7 or
    input  wire [1:0]  fmt,        // lane: 0 64 bits (d / l), 1 32 bits (f / i), 2 16 bits (h / s)
    input  wire        out_half,   // fadd, fmt = 1: the final result is rounded to half
    input  wire        two_stage,  // 16 inputs in two stages of 4 (nin_m1 is then ignored)
    input  wire [3:0]  nin_m1,     // one stage: number of inputs - 1
    input  wire [3:0]  zgrp,       // two_stage: groups whose inputs are all 0
    output wire [3:0]  in_idx,
    input  wire [63:0] in_val,
    output wire        busy,
    output reg         done,
    output reg  [63:0] res
);
    localparam [2:0] OP_FADD = 3'd0, OP_MAX = 3'd1, OP_IADD = 3'd3;
    localparam [2:0] OP_BAND = 3'd4, OP_AND = 3'd5, OP_BOR = 3'd6, OP_OR = 3'd7;
    localparam [3:0] S_IDLE = 4'd0, S_GS = 4'd1, S_P1 = 4'd2, S_LD = 4'd3, S_SH = 4'd4,
                     S_AC = 4'd5, S_AB = 4'd6, S_NM = 4'd7, S_RD = 4'd8, S_ST = 4'd9;

    reg  [3:0]  s;
    reg         st2;        // second stage (inputs: the stage results rr[0..3])
    reg  [1:0]  g;
    reg  [3:0]  i;
    reg  [10:0] emx;        // largest exponent field of the stage
    reg         infany, infpos;
    reg  [63:0] acc;
    reg  [55:0] sa;         // fadd: input significand being aligned
    reg         grd, stk, aneg;
    reg  [10:0] cnt;        // remaining alignment shift
    reg  [5:0]  nsh;        // normalisation shift
    reg         flag;
    reg  [63:0] sres;       // stage result

    wire [3:0] ilast = two_stage ? 4'd3 : nin_m1;
    wire       ifin  = (i == ilast);
    assign busy   = (s != S_IDLE);
    assign in_idx = two_stage ? {g, i[1:0]} : i;

    // ---------------------------------------------------------------- stage results
    wire        rr_we = (s == S_ST) & two_stage & ~st2;
    wire [63:0] rr_rd;
    mn_ram_lut #(.W(64), .AW(2), .NR(1)) u_rr (
        .clk(clk), .we(rr_we), .waddr(g), .wdata(sres), .raddr(i[1:0]), .rdata(rr_rd));

    // ---------------------------------------------------------------- input unpack
    wire [63:0] cur  = st2 ? rr_rd : in_val;
    wire        is_d = (fmt == 2'd0);
    wire        is_h = (fmt == 2'd2);
    wire [63:0] wmask = is_d ? 64'hffffffffffffffff : is_h ? 64'h000000000000ffff : 64'h00000000ffffffff;
    wire [63:0] v    = cur & wmask;
    wire        sgn  = is_d ? v[63] : is_h ? v[15] : v[31];
    wire [62:0] mag  = is_d ? v[62:0] : is_h ? {48'd0, v[14:0]} : {32'd0, v[30:0]};
    wire [10:0] ex   = is_d ? v[62:52] : is_h ? {5'd0, v[14:9]} : {3'd0, v[30:23]};
    wire [10:0] emax = is_d ? 11'd2047 : is_h ? 11'd63 : 11'd255;
    wire [55:0] sig3 = is_d ? {1'b1, v[51:0], 3'b000} : is_h ? {43'd0, 1'b1, v[8:0], 3'b000}
                                                            : {29'd0, 1'b1, v[22:0], 3'b000};
    wire [10:0] dmax = is_d ? 11'd56 : is_h ? 11'd13 : 11'd27;   // wider shifts give 0
    wire [10:0] dsh  = emx - ex;

    // sign-magnitude order of v against acc (the running best)
    wire        asg  = is_d ? acc[63] : is_h ? acc[15] : acc[31];
    wire [62:0] amag = is_d ? acc[62:0] : is_h ? {48'd0, acc[14:0]} : {32'd0, acc[30:0]};
    // key(v) < key(acc); equal magnitudes and signs are equal values, so one comparator does
    wire        mlt  = (mag < amag);
    wire        v_lt = (sgn != asg) ? sgn : (sgn ? ~mlt : mlt);

    // ---------------------------------------------------------------- fadd datapath
    wire        sh8   = (cnt >= 11'd8);
    wire [56:0] aadd  = {1'b0, sa} + {56'd0, grd & (stk | sa[0])};
    wire [63:0] acc_n = aneg ? (acc - {7'd0, aadd}) : (acc + {7'd0, aadd});
    // rounding of the normalised magnitude (MSB at bit 60) into the output format
    wire        oh    = out_half & (st2 | ~two_stage);
    wire [1:0]  ofm   = oh ? 2'd2 : fmt;
    wire [61:0] rinc  = (ofm == 2'd0) ? (62'd1 << 8) : (ofm == 2'd2) ? (62'd1 << 51) : (62'd1 << 37);
    wire        rgd   = (ofm == 2'd0) ? acc[7] : (ofm == 2'd2) ? acc[50] : acc[36];
    wire        rstk  = (ofm == 2'd0) ? (|acc[6:0]) : (ofm == 2'd2) ? (|acc[49:0]) : (|acc[35:0]);
    wire        rlsb  = (ofm == 2'd0) ? acc[8] : (ofm == 2'd2) ? acc[51] : acc[37];
    /* verilator lint_off UNUSEDSIGNAL */
    // bits below the kept mantissa and bit 60 (the hidden bit) are not part of the result
    wire [61:0] rsum  = acc[61:0] + ((rgd & (rstk | rlsb)) ? rinc : 62'd0);
    /* verilator lint_on UNUSEDSIGNAL */
    // biased exponent = emx + K - nsh + carry; K = 5 (d), 34 (f), 48 (h), -62 (f -> h)
    wire signed [13:0] kk   = (fmt == 2'd0) ? 14'sd5 : (fmt == 2'd2) ? 14'sd48 : (oh ? -14'sd62 : 14'sd34);
    wire signed [13:0] bex  = $signed({3'b000, emx}) + kk - $signed({8'd0, nsh}) + $signed({13'd0, rsum[61]});
    wire signed [13:0] oemx = (ofm == 2'd0) ? 14'sd2047 : (ofm == 2'd2) ? 14'sd63 : 14'sd255;
    reg  [63:0] pkd;
    always @* begin
        pkd = 64'd0;
        if (bex >= oemx) begin
            case (ofm)
                2'd0:    pkd = {aneg, 11'h7ff, 52'd0};
                2'd2:    pkd = {48'd0, aneg, 6'h3f, 9'd0};
                default: pkd = {32'd0, aneg, 8'hff, 23'd0};
            endcase
        end else if (bex > 14'sd0) begin
            case (ofm)
                2'd0:    pkd = {aneg, bex[10:0], rsum[61] ? 52'd0 : rsum[59:8]};
                2'd2:    pkd = {48'd0, aneg, bex[5:0], rsum[61] ? 9'd0 : rsum[59:51]};
                default: pkd = {32'd0, aneg, bex[7:0], rsum[61] ? 23'd0 : rsum[59:37]};
            endcase
        end
    end
    wire [63:0] inf_v = (ofm == 2'd0) ? {~infpos, 11'h7ff, 52'd0} :
                        (ofm == 2'd2) ? {48'd0, ~infpos, 6'h3f, 9'd0} : {32'd0, ~infpos, 8'hff, 23'd0};

    // ---------------------------------------------------------------- the other operations
    reg [63:0] acc_op;
    always @* begin
        case (op)
            OP_IADD: acc_op = (acc + v) & wmask;
            OP_BAND: acc_op = acc & v;
            OP_BOR:  acc_op = acc | v;
            OP_MAX:  acc_op = v_lt ? acc : v;
            default: acc_op = v_lt ? v : acc;      // min
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            s    <= S_IDLE;
            done <= 1'b0;
            res  <= 64'd0;
            st2  <= 1'b0;
            g    <= 2'd0;
            i    <= 4'd0;
        end else begin
            done <= 1'b0;
            case (s)
                S_IDLE: if (start) begin
                    st2 <= 1'b0;
                    g   <= 2'd0;
                    s   <= S_GS;
                end
                // start of a stage (a group of the first stage, or the second stage)
                S_GS: begin
                    i      <= 4'd0;
                    emx    <= 11'd0;
                    infany <= 1'b0;
                    infpos <= 1'b0;
                    acc    <= 64'd0;
                    flag   <= 1'b0;
                    if (two_stage & ~st2 & zgrp[g]) begin
                        sres <= 64'd0;
                        s    <= S_ST;
                    end else begin
                        s <= (op == OP_FADD) ? S_P1 : S_LD;
                    end
                end
                // fadd pass 1: the largest exponent and the infinities
                S_P1: begin
                    if (ex > emx) emx <= ex;
                    if (ex == emax) begin
                        infany <= 1'b1;
                        if (!sgn) infpos <= 1'b1;
                    end
                    i <= ifin ? 4'd0 : i + 4'd1;
                    if (ifin) s <= S_LD;
                end
                S_LD: begin
                    if (op == OP_FADD) begin
                        if ((ex == 11'd0) || (dsh > dmax)) begin
                            i <= i + 4'd1;                     // contributes nothing
                            if (ifin) s <= S_AB;
                        end else begin
                            sa   <= sig3;
                            cnt  <= dsh;
                            grd  <= 1'b0;
                            stk  <= 1'b0;
                            aneg <= sgn;
                            s    <= S_SH;
                        end
                    end else begin
                        if (i == 4'd0) begin
                            acc  <= v;
                            flag <= (v != 64'd0);
                        end else begin
                            acc  <= acc_op;
                            flag <= (op == OP_AND) ? (flag & (v != 64'd0)) : (flag | (v != 64'd0));
                        end
                        i <= i + 4'd1;
                        if (ifin) s <= S_AB;
                    end
                end
                S_SH: begin
                    if (cnt == 11'd0) begin
                        s <= S_AC;
                    end else if (sh8) begin
                        sa  <= {8'd0, sa[55:8]};
                        grd <= sa[7];
                        stk <= stk | grd | (|sa[6:0]);
                        cnt <= cnt - 11'd8;
                    end else begin
                        sa  <= {1'b0, sa[55:1]};
                        grd <= sa[0];
                        stk <= stk | grd;
                        cnt <= cnt - 11'd1;
                    end
                end
                S_AC: begin
                    acc <= acc_n;
                    i   <= i + 4'd1;
                    s   <= ifin ? S_AB : S_LD;
                end
                // end of the inputs: the other operations are done; fadd takes |sum|
                S_AB: begin
                    if (op != OP_FADD) begin
                        sres <= ((op == OP_AND) || (op == OP_OR)) ? {63'd0, flag} : acc;
                        s    <= S_ST;
                    end else if (infany) begin
                        sres <= inf_v;
                        s    <= S_ST;
                    end else if ((emx == 11'd0) || (acc == 64'd0)) begin
                        sres <= 64'd0;
                        s    <= S_ST;
                    end else begin
                        aneg <= acc[63];
                        acc  <= acc[63] ? (64'd0 - acc) : acc;
                        nsh  <= 6'd0;
                        s    <= S_NM;
                    end
                end
                S_NM: begin
                    if (acc[60]) begin
                        s <= S_RD;
                    end else if (acc[60:53] == 8'd0) begin
                        acc <= {acc[55:0], 8'd0};
                        nsh <= nsh + 6'd8;
                    end else begin
                        acc <= {acc[62:0], 1'b0};
                        nsh <= nsh + 6'd1;
                    end
                end
                S_RD: begin
                    sres <= pkd;
                    s    <= S_ST;
                end
                S_ST: begin
                    if (two_stage & ~st2) begin
                        g <= g + 2'd1;
                        if (g == 2'd3) st2 <= 1'b1;
                        s <= S_GS;
                    end else begin
                        res  <= sres;
                        done <= 1'b1;
                        s    <= S_IDLE;
                    end
                end
                default: s <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire

// mn_mab_mrnd: the final step of one output element of the matrix FMA (?mfma / ?mmul, WP36):
// round(D + c) once, where D is the exact block-float dot product of the row and x.
//
// Serial (a few tens of clocks per element), for the f, g and h formats (single, pseudo-single,
// half). Bit-exact to the official emulator (gpfn3_package_main), measured in WP36
// (mncore/status/WP-36.md, mncore/sim/tb/mat/matref.py):
//   - Ep = (ca - bias) + (cb - bias): ca, cb are the common exponent fields of the row and of x
//     (the largest exponent field of the block).
//   - ca or cb = 0: the dot product is 0 and c is not aligned (the result is c rounded).
//     Otherwise ca or cb = all ones: the result is +inf (whatever c is).
//   - D is given on the adder grid 2^G, G = Ep - K: K = 39 (f), 34 (g), 26 (h). The caller
//     makes D exact on that grid (f: the partial-product truncation of SDM 4.5 makes every
//     product a multiple of the grid).
//   - c is aligned to the grid: bits below it are jammed into the grid bit, and c is dropped
//     when its leading bit is two or more places below it.
//   - h: the dot product is dropped when Uc - Ep >= 30 (f / g: no such rule is visible, since
//     their output has the precision of c).
//   - The exact sum is rounded to nearest even to single (f, g, h) or half (h with round_out);
//     overflow gives a signed infinity, underflow and zero give +0. c = +-inf gives that inf.
// Window: 76 bits two's complement on the grid. D takes the low 48 bits; c is placed at its
// position, or, when c is too large for the window (Uc - G >= 70, D then only acts below the
// rounding point of c: it is dropped as in the emulator for h, and cannot change a single
// result rounded from a single c), exactly (D = 0).
//
// Protocol: start (one clock) with the inputs stable until done (one clock, z valid with it).
`default_nettype none
module mn_mab_mrnd (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [1:0]  prec,      // 01 f, 11 g, 10 h (00 d: not supported, gives +0)
    input  wire        rnd_h,     // h: half output (round_out)
    input  wire [47:0] dsum,      // D on the grid, two's complement
    input  wire [7:0]  ca,        // common exponent fields (h: 6 bits, zero-extended)
    input  wire [7:0]  cb,
    input  wire [31:0] c,         // the addend, single (after e / sign / zeroc)
    output reg         done,
    output reg  [31:0] z          // single, or half in [15:0]
);
    localparam [3:0] R_IDLE = 4'd0, R_SPEC = 4'd1, R_SHL8 = 4'd2, R_SHL1 = 4'd3, R_SHR = 4'd4,
                     R_NEGC = 4'd5, R_ADD = 4'd6, R_ABS = 4'd7, R_N8 = 4'd8, R_N1 = 4'd9,
                     R_RND = 4'd10, R_PACK = 4'd11;
    reg [3:0] st;

    // ------------------------------------------------------------------ format constants
    wire        p_h   = (prec == 2'b10);
    wire        p_f   = (prec == 2'b01);
    wire [7:0]  emax  = p_h ? 8'h3f : 8'hff;
    wire signed [11:0] bias2 = p_h ? 12'sd62 : 12'sd254;
    wire signed [11:0] kgrid = p_h ? 12'sd26 : p_f ? 12'sd39 : 12'sd34;

    // ------------------------------------------------------------------ inputs (decoded at start)
    wire        sc    = c[31];
    wire [7:0]  ec    = c[30:23];
    wire        c_zero = (ec == 8'd0);
    wire        c_inf  = (ec == 8'hff);
    wire signed [11:0] uc = $signed({4'd0, ec}) - 12'sd127;
    wire signed [11:0] ep = $signed({4'd0, ca}) + $signed({4'd0, cb}) - bias2;
    wire signed [11:0] g0 = ep - kgrid;
    wire        bf_zero = (ca == 8'd0) | (cb == 8'd0);
    wire        bf_inf  = ~bf_zero & ((ca == emax) | (cb == emax));
    wire signed [11:0] ucg = uc - g0;                 // c's leading bit on the grid
    wire        drop_d = p_h & ~c_zero & ((uc - ep) >= 12'sd30);
    wire        cdom   = ~c_zero & (ucg >= 12'sd70);
    wire        exact  = bf_zero | cdom;               // c placed exactly, D = 0
    // grid of the window and the offset of c's LSB on it (-24 .. 46 when c is placed: only the
    // sign and the low 7 bits are used)
    wire signed [11:0] gw  = exact ? (uc - 12'sd48) : g0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [11:0] off = exact ? 12'sd25 : (ucg - 12'sd23);
    /* verilator lint_on UNUSEDSIGNAL */
    wire        c_gone = ~exact & (ucg <= -12'sd2);   // c dropped by the alignment

    // ------------------------------------------------------------------ state
    reg [75:0] w;          // the window
    reg        jam;        // a bit of c was shifted out below the grid
    reg [6:0]  cnt;        // shifts still to do (c alignment)
    reg signed [11:0] ge;  // exponent of window bit 0
    reg        neg;        // the sum is negative
    reg [31:0] z_sp;       // the result, given in R_PACK
    reg        use_d;      // add D
    reg        sc_q;
    reg [6:0]  nsh;        // normalization shifts done

    // one adder: w + b + ci
    reg  [75:0] add_b;
    reg         add_ci;
    reg  [75:0] add_a;
    wire [75:0] add_s = add_a + add_b + {75'd0, add_ci};
    always @* begin
        add_a  = w;
        add_b  = 76'd0;
        add_ci = 1'b0;
        if (st == R_NEGC || st == R_ABS) begin      // -w
            add_a  = ~w;
            add_ci = 1'b1;
        end else if (st == R_ADD) begin             // w + D
            add_b  = {{28{dsum[47]}}, dsum};
        end
    end

    // rounding of the normalized window (leading one at bit 75)
    wire [23:0] sig_s = w[75:52];
    wire        rb_s  = w[51];
    wire        st_s  = |w[50:0];
    wire [9:0]  sig_h = w[75:66];
    wire        rb_h  = w[65];
    wire        st_h  = |w[64:0];
    wire        hout  = p_h & rnd_h;
    wire        inc   = hout ? (rb_h & (st_h | sig_h[0])) : (rb_s & (st_s | sig_s[0]));
    wire [24:0] sig_r = hout ? {14'd0, {1'b0, sig_h} + {10'd0, inc}} : ({1'b0, sig_s} + {24'd0, inc});
    wire        carry = hout ? sig_r[10] : sig_r[24];
    // biased exponent of the result: leading bit at window bit 75 - nsh
    wire signed [11:0] eo = ge + 12'sd75 - $signed({5'd0, nsh}) + (hout ? 12'sd31 : 12'sd127) +
                            $signed({11'd0, carry});

    always @(posedge clk) begin
        if (rst) begin
            st   <= R_IDLE;
            done <= 1'b0;
            z    <= 32'd0;
        end else begin
            done <= 1'b0;
            case (st)
                R_IDLE: if (start) st <= R_SPEC;
                R_SPEC: begin
                    // specials, then load c's significand at bit 0
                    use_d <= ~exact & ~drop_d;
                    sc_q  <= sc;
                    ge    <= gw;
                    jam   <= 1'b0;
                    nsh   <= 7'd0;
                    w     <= (c_zero | c_gone) ? 76'd0 : {52'd0, 1'b1, c[22:0]};
                    if (bf_inf) begin
                        z_sp <= hout ? 32'h0000_7e00 : 32'h7f80_0000;
                        st   <= R_PACK;
                    end else if (c_inf) begin
                        z_sp <= hout ? {16'd0, sc, 15'h7e00} : {sc, 31'h7f80_0000};
                        st   <= R_PACK;
                    end else if (c_zero | c_gone) begin
                        st <= R_ADD;
                    end else if (!off[11]) begin
                        cnt <= off[6:0];
                        st  <= R_SHL8;
                    end else begin
                        cnt <= -off[6:0];
                        st  <= R_SHR;
                    end
                end
                R_SHL8: begin   // c << off, by 8 then by 1
                    if (|cnt[6:3]) begin
                        w   <= w << 8;
                        cnt <= {cnt[6:3] - 4'd1, cnt[2:0]};
                    end else begin
                        st <= R_SHL1;
                    end
                end
                R_SHL1: begin
                    if (|cnt[2:0]) begin
                        w   <= w << 1;
                        cnt <= {4'd0, cnt[2:0] - 3'd1};
                    end else begin
                        st <= sc_q ? R_NEGC : R_ADD;
                    end
                end
                R_SHR: begin    // c >> -off with the jam bit
                    if (|cnt) begin
                        jam <= jam | w[0];
                        w   <= w >> 1;
                        cnt <= cnt - 7'd1;
                    end else begin
                        w  <= w | {75'd0, jam};
                        st <= sc_q ? R_NEGC : R_ADD;
                    end
                end
                R_NEGC: begin
                    w  <= add_s;
                    st <= R_ADD;
                end
                R_ADD: begin
                    if (use_d) w <= add_s;
                    st <= R_ABS;
                end
                R_ABS: begin
                    neg <= w[75];
                    if (w[75]) w <= add_s;
                    st <= R_N8;
                end
                R_N8: begin
                    if (w == 76'd0) begin
                        z_sp <= 32'd0;
                        st   <= R_PACK;
                    end else if (w[75:68] == 8'd0) begin
                        w   <= w << 8;
                        nsh <= nsh + 7'd8;
                    end else begin
                        st <= R_N1;
                    end
                end
                R_N1: begin
                    if (!w[75]) begin
                        w   <= w << 1;
                        nsh <= nsh + 7'd1;
                    end else begin
                        st <= R_RND;
                    end
                end
                R_RND: begin
                    if (eo >= (hout ? 12'sd63 : 12'sd255))
                        z_sp <= hout ? {16'd0, neg, 15'h7e00} : {neg, 31'h7f80_0000};
                    else if (eo <= 12'sd0)
                        z_sp <= 32'd0;
                    else if (hout)
                        z_sp <= {16'd0, neg, eo[5:0], carry ? sig_r[9:1] : sig_r[8:0]};
                    else
                        z_sp <= {neg, eo[7:0], carry ? sig_r[23:1] : sig_r[22:0]};
                    st <= R_PACK;
                end
                default: begin  // R_PACK
                    z    <= z_sp;
                    done <= 1'b1;
                    st   <= R_IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire

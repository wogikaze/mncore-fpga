// mn_mau_vec: MAU vector instructions fma / mul / add / passa for one (PE, cycle) slot (WP12).
//
// Takes the 2-long-word operand buses of one PE and one cycle, with the decoded MAUC
// fields, and returns the 2-long-word result and the 4 mask flags (SDM 3.6.9).
//   dmode      pe_mauc_dmode: 00 d, 01 f, 10 h, 11 g (treated as f; the assembler has no gv*)
//   round_out  pe_mauc_round_out: output rounding (d -> single, f/h -> half)
//   passa      pe_mauc_passa: b = 1.0 (vadd, vpassa)
//   zeroc      pe_mauc_zeroc: c = +0 (vmul, vpassa)
//   mdw_side   pe_mauc_mdw_side: dvfma/dvmul multiply in PE 2,3 (1, `d`) or PE 0,1 (0, `u`);
//              the other PEs use a zero product. Applies to dmode 00 with passa = 0.
//   signa..c   input sign inversion (`-` operand prefix)
//   exta..c    precision extension (`e` suffix): d: single -> double, f: half -> single;
//              h: a, b are rounded from single (`r` suffix, mn_fp_f2h), c is half -> single
//   pe_sub     position of the PE in its MAB (0..3)
// Operand layout (SDM 1.3): elements are packed from the MSB of the 128-bit bus.
//   d: 1 lane, a/b/c 64 bits (32 with e); f: 2 lanes of 32 (16 with e);
//   h: 4 lanes, a/b 16 bits (32 with r), c 32 bits (16 with e).
// Result: elements packed from the MSB, the rest zero; flags = inverted sign bits:
//   d {4{p0}}, dr {p0,p0,0,0}, f {p0,p0,p1,p1}, fr {p0,p1,0,0}, h/hr {p0,p1,p2,p3}.
//
// The lanes of a slot go through one shared mn_fp_fma, one lane per clock (w1: element
// selection, w2: extension / rounding and the options, then the FMA); a new slot is
// accepted while the last lane of the previous one issues (in_ready), so the throughput is
// one lane per clock (d: 1 slot, f: 1/2, h: 1/4 per clock). Results come out in order, as a
// one-clock out_valid pulse with out_tag, 18 + lanes - 1 clock edges after the edge that
// accepted the slot (d 18, f 19, h 21).
module mn_mau_vec #(
    parameter TAGW = 1
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            in_valid,
    output wire            in_ready,
    input  wire [1:0]      dmode,
    input  wire            round_out,
    input  wire            passa,
    input  wire            zeroc,
    input  wire            mdw_side,
    input  wire            signa,
    input  wire            signb,
    input  wire            signc,
    input  wire            exta,
    input  wire            extb,
    input  wire            extc,
    /* verilator lint_off UNUSEDSIGNAL */
    // only the PE pair (bit 1) matters (dvfma u/d, SDM 3.6.9.10)
    input  wire [1:0]      pe_sub,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [127:0]    a_bus,
    input  wire [127:0]    b_bus,
    input  wire [127:0]    c_bus,
    input  wire [TAGW-1:0] in_tag,
    output reg             out_valid,
    output wire [127:0]    z_bus,     // valid while out_valid
    output reg  [3:0]      flags,
    output reg  [TAGW-1:0] out_tag
);
    // ---------------------------------------------------------------- slot register
    reg            busy;
    reg [1:0]      ln;
    reg [1:0]      q_dm;
    reg            q_rnd, q_pa, q_zc, q_mul;
    reg            q_sa, q_sb, q_sc, q_ea, q_eb, q_ec;
    reg [127:0]    q_a, q_b, q_c;
    reg [TAGW-1:0] q_tag;

    wire q_md = (q_dm == 2'b00);
    wire q_mh = (q_dm == 2'b10);
    wire q_mf = ~q_md & ~q_mh;
    wire last = (ln == (q_md ? 2'd0 : q_mf ? 2'd1 : 2'd3));
    assign in_ready = ~busy | last;
    wire take = in_valid & in_ready;

    always @(posedge clk) begin
        if (take) begin
            ln    <= 2'd0;
            q_dm  <= dmode;
            q_rnd <= round_out;
            q_pa  <= passa;
            q_zc  <= zeroc;
            // dvfma/dvmul u/d: only two PEs of the MAB multiply
            q_mul <= (dmode != 2'b00) | passa | (mdw_side == pe_sub[1]);
            q_sa  <= signa;
            q_sb  <= signb;
            q_sc  <= signc;
            q_ea  <= exta;
            q_eb  <= extb;
            q_ec  <= extc;
            q_a   <= a_bus;
            q_b   <= b_bus;
            q_c   <= c_bus;
            q_tag <= in_tag;
        end else if (busy & ~last) begin
            ln <= ln + 2'd1;
        end
        if (rst) busy <= 1'b0;
        else if (take) busy <= 1'b1;
        else if (busy & last) busy <= 1'b0;
    end

    // ---------------------------------------------------------------- lane operands
    // element `l` of width 32 / 16 from the MSB of the bus (a 64-bit element is bus[127:64])
    function [31:0] lane32;
        input [127:0] bus;
        input [1:0]   l;
        begin
            lane32 = bus[127 - 32 * l -: 32];
        end
    endfunction
    function [15:0] lane16;
        input [127:0] bus;
        input [1:0]   l;
        begin
            lane16 = bus[127 - 16 * l -: 16];
        end
    endfunction
    // exact widening (exponent 0 stays zero, all ones stays infinity)
    function [63:0] s2d;
        input [31:0] x;
        begin
            s2d = {x[31],
                   (x[30:23] == 8'd0) ? 11'd0 : (x[30:23] == 8'hff) ? 11'h7ff : {3'd0, x[30:23]} + 11'd896,
                   x[22:0], 29'd0};
        end
    endfunction
    function [31:0] h2s;
        input [15:0] x;
        begin
            h2s = {x[15],
                   (x[14:9] == 6'd0) ? 8'd0 : (x[14:9] == 6'h3f) ? 8'hff : {2'd0, x[14:9]} + 8'd96,
                   x[8:0], 14'd0};
        end
    endfunction

    // ---------------------------------------------------------------- w1: raw lane bits
    // the element of each operand in its stored width (64, 32 or 16 bits), zero-extended
    reg            v1, md1, mf1, rnd1, pa1, zc1, mul1, sa1, sb1, sc1, ea1, eb1, ec1, lst1;
    reg [1:0]      dm1, ln1;
    reg [TAGW-1:0] tag1;
    reg [63:0]     ra1, rb1, rc1;
    always @(posedge clk) begin
        v1   <= busy & ~rst;
        dm1  <= q_dm;
        md1  <= q_md;
        mf1  <= q_mf;
        rnd1 <= q_rnd;
        pa1  <= q_pa;
        zc1  <= q_zc;
        mul1 <= q_mul;
        sa1  <= q_sa;
        sb1  <= q_sb;
        sc1  <= q_sc;
        ea1  <= q_ea;
        eb1  <= q_eb;
        ec1  <= q_ec;
        lst1 <= last;
        ln1  <= ln;
        tag1 <= q_tag;
        // a, b: d 64 (e: 32), f 32 (e: 16), h 16 (r: 32); c: d 64 (e: 32), f/h 32 (e: 16)
        ra1 <= q_md ? (q_ea ? {32'd0, q_a[127:96]} : q_a[127:64]) :
               ((q_mf ^ q_ea) ? {32'd0, lane32(q_a, ln)} : {48'd0, lane16(q_a, ln)});
        rb1 <= q_md ? (q_eb ? {32'd0, q_b[127:96]} : q_b[127:64]) :
               ((q_mf ^ q_eb) ? {32'd0, lane32(q_b, ln)} : {48'd0, lane16(q_b, ln)});
        rc1 <= q_md ? (q_ec ? {32'd0, q_c[127:96]} : q_c[127:64]) :
               (q_ec ? {48'd0, lane16(q_c, ln)} : {32'd0, lane32(q_c, ln)});
    end

    // ---------------------------------------------------------------- w2: operands
    // a and b in the operation format, c in double (d) or single (f, h); options applied
    wire [15:0] ra_h, rb_h;
    mn_fp_f2h u_ra (.x(ra1[31:0]), .h(ra_h));
    mn_fp_f2h u_rb (.x(rb1[31:0]), .h(rb_h));
    wire [63:0] a_cv = md1 ? (ea1 ? s2d(ra1[31:0]) : ra1) :
                       mf1 ? {32'd0, ea1 ? h2s(ra1[15:0]) : ra1[31:0]} :
                             {48'd0, ea1 ? ra_h : ra1[15:0]};
    wire [63:0] b_cv = md1 ? (eb1 ? s2d(rb1[31:0]) : rb1) :
                       mf1 ? {32'd0, eb1 ? h2s(rb1[15:0]) : rb1[31:0]} :
                             {48'd0, eb1 ? rb_h : rb1[15:0]};
    wire [63:0] c_cv = md1 ? (ec1 ? s2d(rc1[31:0]) : rc1) :
                       {32'd0, ec1 ? h2s(rc1[15:0]) : rc1[31:0]};
    wire [63:0] sgn_ab = md1 ? {1'b1, 63'd0} : mf1 ? {32'd0, 1'b1, 31'd0} : {48'd0, 1'b1, 15'd0};
    wire [63:0] sgn_c  = md1 ? {1'b1, 63'd0} : {32'd0, 1'b1, 31'd0};
    wire [63:0] one_ab = md1 ? 64'h3ff0_0000_0000_0000 : mf1 ? 64'h3f80_0000 : 64'h3e00;

    reg            v2, rnd2, lst2;
    reg [1:0]      dm2, ln2;
    reg [TAGW-1:0] tag2;
    reg [63:0]     fa2, fb2, fc2;
    always @(posedge clk) begin
        v2   <= v1 & ~rst;
        dm2  <= dm1;
        rnd2 <= rnd1;
        lst2 <= lst1;
        ln2  <= ln1;
        tag2 <= tag1;
        fa2  <= ~mul1 ? 64'd0 : a_cv ^ (sa1 ? sgn_ab : 64'd0);
        fb2  <= ~mul1 ? 64'd0 : pa1 ? one_ab : b_cv ^ (sb1 ? sgn_ab : 64'd0);
        fc2  <= zc1 ? 64'd0 : c_cv ^ (sc1 ? sgn_c : 64'd0);
    end

    // ---------------------------------------------------------------- FMA
    // tag: {slot tag, dmode, round, last lane, lane}
    wire                fo_v;
    wire [63:0]         fo_z;
    wire [TAGW+5:0]     fo_t;
    mn_fp_fma #(.TAGW(TAGW + 6)) u_fma (
        .clk(clk), .rst(rst), .in_valid(v2), .prec(dm2), .rnd(rnd2),
        .a(fa2), .b(fb2), .c(fc2), .in_tag({tag2, dm2, rnd2, lst2, ln2}),
        .out_valid(fo_v), .z(fo_z), .out_tag(fo_t));

    // ---------------------------------------------------------------- collect the lanes
    wire [1:0] o_ln  = fo_t[1:0];
    wire       o_lst = fo_t[2];
    wire       o_rnd = fo_t[3];
    wire [1:0] o_dm  = fo_t[5:4];
    wire       o_md  = (o_dm == 2'b00);
    wire       o_mh  = (o_dm == 2'b10);
    // element width: 0 = 64, 1 = 32, 2 = 16
    wire [1:0] o_w   = o_md ? (o_rnd ? 2'd1 : 2'd0) : (o_rnd ? 2'd2 : 2'd1);
    wire       o_neg = (o_w == 2'd0) ? fo_z[63] : (o_w == 2'd1) ? fo_z[31] : fo_z[15];

    // the result is written in place, 16 bits (chunk ck = bits [127-16ck -: 16]) at a time:
    // the chunks of the arriving lane get its bits, the others are cleared on lane 0
    reg  [127:0] acc;
    reg  [3:0]   sg;     // sign bit of each lane result
    wire [3:0]   sg_n  = ((o_ln == 2'd0) ? 4'd0 : sg) | ({3'd0, o_neg} << o_ln);
    wire [3:0]   p_n   = ~sg_n;   // p_n[i]: lane i is not negative
    wire [3:0]   fl_n  = o_md ? (o_rnd ? {p_n[0], p_n[0], 2'b00} : {4{p_n[0]}}) :
                         o_mh ? {p_n[0], p_n[1], p_n[2], p_n[3]} :
                         (o_rnd ? {p_n[0], p_n[1], 2'b00} : {p_n[0], p_n[0], p_n[1], p_n[1]});
    integer ck;
    always @(posedge clk) begin
        if (fo_v) begin
            for (ck = 0; ck < 8; ck = ck + 1) begin
                if ((o_w == 2'd0) ? (ck < 4) : (o_w == 2'd1) ? (ck / 2 == {30'd0, o_ln}) : (ck == {30'd0, o_ln}))
                    acc[127-16*ck -: 16] <= (o_w == 2'd0) ? fo_z[63-16*(ck%4) -: 16] :
                                            (o_w == 2'd1) ? fo_z[31-16*(ck%2) -: 16] : fo_z[15:0];
                else if (o_ln == 2'd0)
                    acc[127-16*ck -: 16] <= 16'd0;
            end
            sg <= sg_n;
        end
        out_valid <= fo_v & o_lst & ~rst;
        if (fo_v & o_lst) begin
            flags   <= fl_n;
            out_tag <= fo_t[TAGW+5:6];
        end
    end
    assign z_bus = acc;
endmodule

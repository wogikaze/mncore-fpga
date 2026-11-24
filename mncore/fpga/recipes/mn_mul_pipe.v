// mn_mul_pipe: pipelined unsigned multiplier built from DSP tiles (WP07 recipe).
//
// p = a * b (unsigned, full width WA + WB).
// The operands are cut into TW-bit tiles. Each tile product a_i * b_j is one inferred
// multiplication of at most TW x TW bits, which yosys maps to one MULT18X18 for TW = 18
// (unsigned 18 x 18 fits one multiplier, measured). The NA * NB tile products are summed
// by a binary adder tree in the fabric (ALU carry chains).
// Measured DSP / LUT / Fmax per configuration: mncore/07-device-budget.md.
//
// Pipeline (all registers honour ce):
//   IREG = 1 : register a and b
//   PREG = 1 : register every tile product (the DSP output)
//   LVLS = k : register after every k-th adder level (k = 0: no register inside the tree)
//   always   : output register after the last adder level
// Latency in clocks = IREG + PREG + NTR + 1, where
//   L   = ceil(log2(NA * NB))             (adder levels)
//   NTR = (LVLS > 0 && L > 1) ? (L - 1) / LVLS : 0
// e.g. 53 x 53, TW = 18: 9 tiles, L = 4; IREG = PREG = 1, LVLS = 1 gives latency 6.
//
// yosys does not use the DSP-internal registers (techlibs/gowin/dsp_map.v ties CLK to 0),
// so IREG / PREG are fabric flip-flops next to the DSP.
module mn_mul_pipe #(
    parameter WA   = 53,
    parameter WB   = 53,
    parameter TW   = 18,
    parameter IREG = 1,
    parameter PREG = 1,
    parameter LVLS = 1
) (
    input  wire             clk,
    input  wire             ce,
    input  wire [WA-1:0]    a,
    input  wire [WB-1:0]    b,
    output wire [WA+WB-1:0] p
);
    // ---- constant functions (used for sizes and offsets) ----
    function integer f_clog2;
        input integer v;
        integer t;
        begin
            f_clog2 = 0;
            t = v - 1;
            while (t > 0) begin
                f_clog2 = f_clog2 + 1;
                t = t >> 1;
            end
        end
    endfunction

    // number of nodes at tree level l (level 0 = tile products)
    function integer f_lvl_n;
        input integer n0;
        input integer l;
        integer k;
        begin
            f_lvl_n = n0;
            for (k = 0; k < l; k = k + 1) f_lvl_n = (f_lvl_n + 1) / 2;
        end
    endfunction

    // index of the first node of level l in the flattened node vector
    function integer f_lvl_off;
        input integer n0;
        input integer l;
        integer k, n;
        begin
            f_lvl_off = 0;
            n = n0;
            for (k = 0; k < l; k = k + 1) begin
                f_lvl_off = f_lvl_off + n;
                n = (n + 1) / 2;
            end
        end
    endfunction

    localparam NA    = (WA + TW - 1) / TW;
    localparam NB    = (WB + TW - 1) / TW;
    localparam NP    = NA * NB;
    localparam WP    = WA + WB;
    localparam L     = f_clog2(NP);
    localparam NNODE = f_lvl_off(NP, L) + 1;

    // ---- stage A: operand registers ----
    wire [WA-1:0] a_s;
    wire [WB-1:0] b_s;
    generate
        if (IREG != 0) begin : g_ireg
            reg [WA-1:0] ar;
            reg [WB-1:0] br;
            always @(posedge clk) begin
                if (ce) begin
                    ar <= a;
                    br <= b;
                end
            end
            assign a_s = ar;
            assign b_s = br;
        end else begin : g_noireg
            assign a_s = a;
            assign b_s = b;
        end
    endgenerate

    // zero-extend to whole tiles
    wire [NA*TW-1:0] ax;
    wire [NB*TW-1:0] bx;
    assign ax[WA-1:0] = a_s;
    assign bx[WB-1:0] = b_s;
    generate
        if (NA * TW > WA) begin : g_apad
            assign ax[NA*TW-1:WA] = {(NA*TW-WA){1'b0}};
        end
        if (NB * TW > WB) begin : g_bpad
            assign bx[NB*TW-1:WB] = {(NB*TW-WB){1'b0}};
        end
    endgenerate

    // flattened tree nodes, node n occupies nd[n*WP +: WP]
    wire [NNODE*WP-1:0] nd;

    // ---- stage B: tile products (one DSP each) ----
    genvar i, j;
    generate
        for (i = 0; i < NA; i = i + 1) begin : g_ta
            for (j = 0; j < NB; j = j + 1) begin : g_tb
                localparam S  = (i + j) * TW;                         // weight of this tile
                localparam PW = (2 * TW < WP - S) ? 2 * TW : WP - S;  // bits that can be non-zero
                wire [2*TW-1:0] pp = ax[i*TW +: TW] * bx[j*TW +: TW];
                wire [PW-1:0]   ps;
                if (PREG != 0) begin : g_preg
                    reg [PW-1:0] r;
                    always @(posedge clk) begin
                        if (ce) r <= pp[PW-1:0];
                    end
                    assign ps = r;
                end else begin : g_nopreg
                    assign ps = pp[PW-1:0];
                end
                if (S > 0) begin : g_lo
                    assign nd[(i*NB+j)*WP +: S] = {S{1'b0}};
                end
                assign nd[(i*NB+j)*WP + S +: PW] = ps;
                if (S + PW < WP) begin : g_hi
                    assign nd[(i*NB+j)*WP + S + PW +: WP - S - PW] = {(WP-S-PW){1'b0}};
                end
                /* verilator lint_off UNUSEDSIGNAL */
                // pp bits above PW are zero by construction (the top tiles are zero-padded).
                wire unused_pp = (PW < 2 * TW) ? |pp : 1'b0;
                /* verilator lint_on UNUSEDSIGNAL */
            end
        end
    endgenerate

    // ---- adder tree ----
    genvar l, n;
    generate
        for (l = 1; l <= L; l = l + 1) begin : g_lvl
            for (n = 0; n < f_lvl_n(NP, l); n = n + 1) begin : g_nd
                localparam CI = f_lvl_off(NP, l - 1) + 2 * n;  // left child
                localparam NO = f_lvl_off(NP, l) + n;          // this node
                wire [WP-1:0] s;
                if (2 * n + 1 < f_lvl_n(NP, l - 1)) begin : g_add
                    assign s = nd[CI*WP +: WP] + nd[(CI+1)*WP +: WP];
                end else begin : g_pass
                    assign s = nd[CI*WP +: WP];
                end
                if (LVLS > 0 && l < L && (l % LVLS) == 0) begin : g_reg
                    reg [WP-1:0] r;
                    always @(posedge clk) begin
                        if (ce) r <= s;
                    end
                    assign nd[NO*WP +: WP] = r;
                end else begin : g_comb
                    assign nd[NO*WP +: WP] = s;
                end
            end
        end
    endgenerate

    // ---- output register ----
    reg [WP-1:0] pr;
    always @(posedge clk) begin
        if (ce) pr <= nd[(NNODE-1)*WP +: WP];
    end
    assign p = pr;
endmodule

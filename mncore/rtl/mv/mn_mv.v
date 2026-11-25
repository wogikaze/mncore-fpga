// mn_mv: the MV unit of the reduced topology (WP33): executes the m words (82 bits) between the
// L2BM (mn_l2bm port B), the PDM and the DRAM (both in the SDRAM, sdr_bus64), keeps the MV tags
// for the PE core's wait, and serves the host's access to the spaces L2BM / PDM / DRAM.
//
// Interface and semantics: mncore/rtl/mv/README.md (the port definition for WP37). Short version:
//   - Topology N_L2B = 1 (contract section 3): group 0 and its L2B 0 (n0c0) exist. Transfers to
//     the other groups / L2Bs are dropped (and their sources not read), reads from them give
//     zero, and a reduction gets zeros from the L2BMs that do not exist.
//   - Issue: start (when ready) with the m word mw (read in that clock only). The unit decodes
//     the word, runs a check pass over the accesses it will make (E_RANGE beyond the reduced
//     L2BM / PDM / DRAM; E_UNSUPPORTED for the words the official emulator aborts on) and pulses
//     acc with acc_st 0 OK / 1 E_RANGE / 2 E_UNSUPPORTED (acc_field = MN_M_<field>_IDX). After an
//     OK the transfer runs in the background; busy stays 1 until it is complete, then the tag
//     (mvid != 0) is counted. A word that is not OK changes nothing. The official completes an
//     MV when it is issued, so the core starts no L2BM instruction, MV or wait while busy.
//   - Wait: wt_cnt = completed MVs of tag wt_tag not yet waited for (0, 1, 2 = two or more),
//     valid while busy = 0; wt_take consumes them (official: a wait passes once per completion,
//     blocks for ever without one, aborts with two).
//   - Every transfer moves chunks of 16 long words: the source chunk is read into a 16-entry
//     buffer, then written to the destination (the reductions of mvr / mvr2 / mvr4 on the way,
//     mn_mv_red). PDM -> PDM runs backwards when the destination is above the source, so
//     overlapping ranges are copied like the official (all reads before the writes).
//   - DRAM addresses: chunk i of the transfer is at adra * 16 + 16 i (direct), or (indirect = 1)
//     at 16 * (DAR[(M + i / N) % 1024] + i % N), M = adra[9:0], N = adra[14:10]; N = 0 is N
//     infinite: 16 * (DAR[M] + i). DAR through dar_re / dar_raddr -> dar_rdata (mn_l2bm). Chip
//     wraps: L2BM 2**15, PDM 2**19, DRAM 2**29 long words; then the reduced capacities apply.
//   - Host: hw_* / hr_* (the mw / mr ports of brd_host_if) for the spaces 0x07 L2BM (loc n0c0),
//     0x08 PDM and 0x09 DRAM (loc n0), served while busy = 0.
// SDRAM layout (long words of sdr_bus64): DRAM of group 0 at DRAM_BASE + a (a < 2**DRAM_AW), PDM
// at PDM_BASE + a (a < 2**PDM_AW); the bases are multiples of the depths.
`default_nettype none
module mn_mv #(
    parameter L2AW    = 11,               // L2BM depth 2**L2AW long words (mn_l2bm AW; contract L2BM_DEPTH)
    parameter PDM_AW  = 17,               // PDM depth 2**PDM_AW long words (proposed PDM_DEPTH)
    parameter DRAM_AW = 19,               // DRAM depth 2**DRAM_AW long words (proposed DRAM_DEPTH)
    parameter [19:0] PDM_BASE  = 20'h80000,
    parameter [19:0] DRAM_BASE = 20'h00000
) (
    input  wire         clk,
    input  wire         rst,
    // ---- issue (the core)
    input  wire         start,          // taken when ready; mw is read in this clock only
    input  wire [81:0]  mw,
    output wire         ready,
    output reg          acc,            // 1-clock pulse: the word was checked
    output reg  [1:0]   acc_st,         // 0 OK (it runs), 1 E_RANGE, 2 E_UNSUPPORTED (not run)
    output reg  [3:0]   acc_field,      // E_UNSUPPORTED: MN_M_<field>_IDX
    output wire         busy,           // checking or transferring (also the clear after reset)
    // ---- wait (the core)
    input  wire [7:0]   wt_tag,
    output wire [1:0]   wt_cnt,         // valid while busy = 0
    input  wire         wt_take,        // only while busy = 0
    // ---- L2BM: port B of mn_l2bm (contract section 6 bus)
    output wire         cb_req_valid,
    input  wire         cb_req_ready,
    output wire         cb_req_we,
    output wire [22:0]  cb_req_addr,
    output wire [63:0]  cb_req_wdata,
    output wire [7:0]   cb_req_wmask,
    input  wire         cb_req_err,
    input  wire         cb_rsp_valid,
    input  wire [63:0]  cb_rsp_rdata,
    // ---- DAR read port of mn_l2bm (dar_rdata = DAR[dar_raddr] of the dar_re clock, next clock)
    output wire         dar_re,
    output wire [9:0]   dar_raddr,
    input  wire [31:0]  dar_rdata,
    // ---- SDRAM: sdr_bus64 (contract section 6 bus)
    output wire         sd_req_valid,
    input  wire         sd_req_ready,
    output wire         sd_req_we,
    output wire [22:0]  sd_req_addr,
    output wire [63:0]  sd_req_wdata,
    output wire [7:0]   sd_req_wmask,
    input  wire         sd_rsp_valid,
    input  wire [63:0]  sd_rsp_rdata,
    input  wire         sd_err_addr,    // sdr_bus64 err_addr (sticky): never expected
    output wire         err_sdr,
    // ---- host (brd_host_if mw / mr ports, spaces 0x07 / 0x08 / 0x09), while busy = 0
    input  wire         hw_valid,
    output wire         hw_ready,
    output wire         hw_err,
    input  wire [7:0]   hw_space,
    input  wire [15:0]  hw_loc,
    input  wire [22:0]  hw_addr,
    input  wire [63:0]  hw_data,
    input  wire [7:0]   hw_mask,
    input  wire         hr_valid,
    output wire         hr_ready,
    output wire         hr_err,
    input  wire [7:0]   hr_space,
    input  wire [15:0]  hr_loc,
    input  wire [22:0]  hr_addr,
    output wire         hr_rsp_valid,
    output wire [63:0]  hr_rsp_data
);
`include "mn_mfields.vh"

    // ------------------------------------------------------------------ constants
    localparam [1:0] K_NONE = 2'd0, K_C = 2'd1, K_P = 2'd2, K_D = 2'd3;   // memory kinds (source K_NONE: zeros)
    localparam [2:0] M_P2D = 3'd0, M_P2C = 3'd1, M_D2C = 3'd2, M_P2P = 3'd3, M_D2P = 3'd4,
                     M_C2P = 3'd5, M_C2D = 3'd6;
    localparam [2:0] T_SINGLE = 3'd0, T_PAR = 3'd1, T_B2 = 3'd2, T_B4 = 3'd3, T_B = 3'd4, T_D = 3'd5;
    localparam [1:0] A_OK = 2'd0, A_RANGE = 2'd1, A_UNSUP = 2'd2;
    localparam [3:0] F_TMODE = MN_M_TMODE_IDX[3:0], F_SRCID = MN_M_SRCID_IDX[3:0],
                     F_DMODE = MN_M_DMODE_IDX[3:0], F_NW = MN_M_NW_IDX[3:0];
    localparam integer DCW = 25;     // DRAM chunk address: the chip's 2**29 long words / 16

    // ------------------------------------------------------------------ the word being run
    reg         w_valid;
    reg  [2:0]  w_mm, w_tm, w_sid, w_did;
    reg  [1:0]  w_dm;
    reg  [7:0]  w_id;
    reg         w_ind;
    reg  [29:0] w_adra;
    reg  [14:0] w_adrb;
    reg  [10:0] w_nw;

    // ------------------------------------------------------------------ decode (from the latched word)
    // adra: the DRAM chunk (forms with DRAM) or the PDM address / 16 (PDM <-> L2BM, the source of
    // PDM -> PDM); adrb: the L2BM address / 16 (bits 1..0 not used: 64-long-word aligned) or the
    // PDM address / 16 (PDM <-> DRAM, the destination of PDM -> PDM). Probed: README.
    wire [18:0] a_p = {w_adra[14:0], 4'd0};              // PDM address from adra (mod 2**19)
    wire [18:0] b_p = {w_adrb, 4'd0};                    // PDM address from adrb
    wire [18:0] b_c = {4'd0, w_adrb[10:2], 6'd0};        // L2BM address from adrb (mod 2**15)
    wire        gs0 = (w_sid[2:1] == 2'd0);
    wire        gd0 = (w_did[2:1] == 2'd0);
    wire        cs0 = (w_sid == 3'd0);
    wire        cd0 = (w_did == 3'd0);
    wire        ls0 = ~w_sid[0];
    wire        ld0 = ~w_did[0];
    wire [10:0] nw4 = {2'd0, w_nw[10:2]};
    wire [10:0] nw4c = {2'd0, w_nw[10:2]} + {10'd0, |w_nw[1:0]};   // ceil(nw / 4)

    // reduction: opcode {destid[0], srcid} (0000 fadd 0001 max 0010 min 1000 iadd 1001 band 1010 and
    // 1100 bor 1101 or)
    reg       op_ok;
    reg [2:0] rop;
    always @* begin
        op_ok = 1'b1;
        case ({w_did[0], w_sid})
            4'b0000: rop = 3'd0;
            4'b0001: rop = 3'd1;
            4'b0010: rop = 3'd2;
            4'b1000: rop = 3'd3;
            4'b1001: rop = 3'd4;
            4'b1010: rop = 3'd5;
            4'b1100: rop = 3'd6;
            4'b1101: rop = 3'd7;
            default: begin rop = 3'd0; op_ok = 1'b0; end
        endcase
    end

    // The plan of the word: U units of S slots; each slot moves one chunk of 16 long words
    //   destination: kind p_dk (K_NONE: not there), address p_db + (u << ush) + (s << 4 when p_dsl)
    //   source:      kind p_sk (K_NONE: zeros), only in slot 0, address p_sb + (u << ush)
    //   DRAM chunk index (the DRAM side): u, 2u (p_c2) or 2u + s (p_cs)
    // ush: 0 -> 4 (16 long words), 1 -> 6 (64), 2 -> 7 (128)
    reg         p_run, p_nop, p_red, p_rev, p_dsl, p_c2, p_cs, p_nw4;
    reg  [3:0]  p_ufld;
    reg  [2:0]  p_smax;
    reg  [10:0] p_U;
    reg  [1:0]  p_dk, p_sk, p_dsh, p_ssh;
    reg  [18:0] p_db, p_sb;
    always @* begin
        p_run = 1'b1; p_nop = 1'b0; p_red = 1'b0; p_rev = 1'b0; p_dsl = 1'b0; p_c2 = 1'b0; p_cs = 1'b0;
        p_nw4 = 1'b0; p_ufld = F_TMODE; p_smax = 3'd0; p_U = w_nw;
        p_dk = K_NONE; p_sk = K_NONE; p_dsh = 2'd0; p_ssh = 2'd0; p_db = 19'd0; p_sb = 19'd0;
        case ({w_mm, w_tm})
            // ---- individual transfers: chunk u of the source to chunk u of the destination
            {M_P2D, T_SINGLE}: begin p_dk = gd0 ? K_D : K_NONE; p_sk = gs0 ? K_P : K_NONE; p_sb = b_p; end
            {M_D2P, T_SINGLE}: begin p_dk = gd0 ? K_P : K_NONE; p_db = b_p; p_sk = gs0 ? K_D : K_NONE; end
            {M_P2C, T_SINGLE}: begin p_dk = cd0 ? K_C : K_NONE; p_db = b_c; p_sk = gs0 ? K_P : K_NONE; p_sb = a_p; end
            {M_C2P, T_SINGLE}: begin p_dk = gd0 ? K_P : K_NONE; p_db = a_p; p_sk = cs0 ? K_C : K_NONE; p_sb = b_c; end
            {M_D2C, T_SINGLE}: begin p_dk = cd0 ? K_C : K_NONE; p_db = b_c; p_sk = gs0 ? K_D : K_NONE; end
            {M_C2D, T_SINGLE}: begin p_dk = gd0 ? K_D : K_NONE; p_sk = cs0 ? K_C : K_NONE; p_sb = b_c; end
            {M_P2P, T_SINGLE}: begin p_dk = gd0 ? K_P : K_NONE; p_db = b_p; p_sk = gs0 ? K_P : K_NONE; p_sb = a_p;
                                     p_rev = gs0 & (b_p > a_p); end
            {M_P2C, T_PAR}:    begin p_dk = ld0 ? K_C : K_NONE; p_db = b_c; p_sk = K_P; p_sb = a_p; end
            {M_C2P, T_PAR}:    begin p_dk = K_P; p_db = a_p; p_sk = ls0 ? K_C : K_NONE; p_sb = b_c; end
            {M_D2C, T_PAR}:    begin p_dk = ld0 ? K_C : K_NONE; p_db = b_c; p_sk = K_D; end
            {M_C2D, T_PAR}:    begin p_dk = K_D; p_sk = ls0 ? K_C : K_NONE; p_sb = b_c; end
            {M_P2D, T_PAR}:    begin p_dk = K_D; p_sk = K_P; p_sb = b_p; end
            {M_D2P, T_PAR}:    begin p_dk = K_P; p_db = b_p; p_sk = K_D; end
            {M_P2P, T_PAR}:    begin p_dk = K_P; p_db = b_p; p_sk = K_P; p_sb = a_p; p_rev = (b_p > a_p); end
            // ---- broadcasts / reductions in chunks (nw % 4 = 0)
            {M_D2C, T_B2}:     begin p_nw4 = 1'b1; p_dk = K_C; p_db = b_c; p_sk = K_D; end
            {M_P2C, T_B2}:     begin p_nw4 = 1'b1; p_dk = gd0 ? K_C : K_NONE; p_db = b_c; p_sk = K_P; p_sb = a_p; end
            {M_C2D, T_B2}:     begin p_nw4 = 1'b1; p_dk = K_D; p_sk = K_C; p_sb = b_c; p_red = 1'b1; end
            {M_C2P, T_B2}:     begin p_nw4 = 1'b1; p_dk = gd0 ? K_P : K_NONE; p_db = a_p; p_sk = K_C; p_sb = b_c;
                                     p_red = 1'b1; end
            {M_P2C, T_B}:      begin p_nw4 = 1'b1; p_dk = K_C; p_db = b_c; p_sk = gs0 ? K_P : K_NONE; p_sb = a_p; end
            {M_C2P, T_B}:      begin p_nw4 = 1'b1; p_dk = gd0 ? K_P : K_NONE; p_db = a_p; p_sk = K_C; p_sb = b_c;
                                     p_red = 1'b1; end
            // ---- 64-long-word units (nw % 4 = 0): u = unit, s = the group / L2B of the slot
            {M_D2C, T_B4}:     begin p_nw4 = 1'b1; p_U = nw4; p_smax = 3'd3; p_dk = K_C; p_db = b_c; p_dsh = 2'd1;
                                     p_dsl = 1'b1; p_sk = K_D; p_c2 = 1'b1; end
            {M_C2D, T_B4}:     begin p_nw4 = 1'b1; p_U = nw4; p_smax = 3'd1; p_dk = K_D; p_sk = K_C; p_sb = b_c;
                                     p_ssh = 2'd1; p_cs = 1'b1; p_red = 1'b1; end
            {M_D2C, T_B}:      begin p_nw4 = 1'b1; p_U = nw4; p_smax = 3'd3; p_dk = K_C; p_db = b_c; p_dsh = 2'd1;
                                     p_dsl = 1'b1; p_sk = K_D; end
            {M_C2D, T_B}:      begin p_nw4 = 1'b1; p_U = nw4; p_dk = K_D; p_sk = K_C; p_sb = b_c; p_ssh = 2'd1;
                                     p_red = 1'b1; end
            {M_D2P, T_D}:      begin p_nw4 = 1'b1; p_U = nw4; p_smax = 3'd3; p_dk = gd0 ? K_P : K_NONE; p_db = b_p;
                                     p_dsh = 2'd1; p_dsl = 1'b1; p_sk = K_D; end
            // ---- distribution / combination: u = the L2BM chunk (16 long words), any nw
            {M_P2C, T_D}:      begin p_dk = K_C; p_db = b_c; p_sk = gs0 ? K_P : K_NONE; p_sb = a_p; p_ssh = 2'd2; end
            {M_C2P, T_D}:      begin p_smax = 3'd7; p_dk = gd0 ? K_P : K_NONE; p_db = a_p; p_dsh = 2'd2;
                                     p_dsl = 1'b1; p_sk = K_C; p_sb = b_c; end
            {M_P2D, T_D}:      begin p_U = nw4c; p_dk = K_D; p_sk = gs0 ? K_P : K_NONE; p_sb = b_p; p_ssh = 2'd1; end
            default: begin
                // mmode 111, tmode 110 / 111: nothing (the MV completes, its tag counts); the
                // other pairs make the official abort
                p_run = 1'b0;
                p_nop = (w_mm == 3'b111) | (w_tm[2:1] == 2'b11);
            end
        endcase
        // the official aborts on: no chunk, nw % 4 != 0 in the forms with 64-long-word units, a
        // reduction opcode outside the table or dmode 11
        if (p_run) begin
            if (p_red && !op_ok)                     p_ufld = F_SRCID;
            else if (p_red && (w_dm == 2'b11))       p_ufld = F_DMODE;
            else if (w_nw == 11'd0)                  p_ufld = F_NW;
            else if (p_nw4 && (w_nw[1:0] != 2'd0))   p_ufld = F_NW;
            else                                     p_ufld = 4'd0;
        end
    end
    wire p_bad = (p_run & (p_ufld != 4'd0)) | (~p_run & ~p_nop);

    // ------------------------------------------------------------------ phases
    localparam [2:0] PH_CLR = 3'd0, PH_IDLE = 3'd1, PH_DEC = 3'd2, PH_CHK = 3'd3, PH_RUN = 3'd4,
                     PH_FIN = 3'd5;
    localparam [2:0] ST_SLOT = 3'd0, ST_DAR = 3'd1, ST_GO = 3'd2, ST_RD = 3'd3, ST_WR = 3'd4;
    reg  [2:0]  ph;
    reg  [2:0]  st;
    wire        tags_clr;
    assign busy  = (ph != PH_IDLE);
    assign ready = (ph == PH_IDLE);
    wire        pass = (ph == PH_CHK) | (ph == PH_RUN);

    // loop counters
    reg  [10:0] u;              // unit
    reg  [2:0]  s;              // slot
    reg  [11:0] ci;             // DRAM chunk index (direct; indirect with N = 0: the offset)
    reg  [9:0]  de;             // indirect: DAR entry
    reg  [4:0]  dof;            // indirect, N != 0: offset (< N)
    wire        u_last = (u == p_U - 11'd1);
    wire        s_last = (s == p_smax);

    // the slot's addresses
    wire [10:0] uu = p_rev ? (p_U - 11'd1 - u) : u;
    function [18:0] uoff(input [10:0] uv, input [1:0] sh);
        case (sh)
            2'd0:    uoff = {4'd0, uv, 4'd0};
            2'd1:    uoff = {2'd0, uv, 6'd0};
            default: uoff = {1'b0, uv, 7'd0};
        endcase
    endfunction
    wire [18:0] d_a19 = p_db + (uoff(uu, p_dsh) | (p_dsl ? {12'd0, s, 4'd0} : 19'd0));
    wire [18:0] s_a19 = p_sb + uoff(uu, p_ssh);
    wire        s_real = (p_sk != K_NONE) & (s == 3'd0);
    wire        d_ex   = (p_dk != K_NONE);
    wire        dside  = (p_dk == K_D) | (s_real & (p_sk == K_D));
    // indirect: N = adra[14:10] (0: N infinite), M = adra[9:0]
    wire [4:0]  nd     = w_adra[14:10];
    assign dar_re    = (st == ST_SLOT) & pass & d_ex & dside & w_ind;
    assign dar_raddr = de;

    // slot registers (ST_GO .. ST_WR)
    reg  [1:0]     g_dk, g_sk;  // kinds of this slot (g_sk K_NONE: zeros)
    reg  [18:0]    g_da, g_sa;  // L2BM / PDM chip addresses
    reg  [DCW-1:0] g_dc;        // DRAM chunk address (chip, mod 2**25)
    reg  [3:0]     ki, kr, kw;  // reads issued, reads returned, writes issued (of 16)
    reg            ki_end, kw_end;

    // a chunk is inside the reduced capacity (after the chip's wrap)
    function chunk_ok(input [1:0] kind, input [18:0] a, input [DCW-1:0] dc);
        begin
            case (kind)
                K_C:     chunk_ok = ({4'd0, a[14:0]} >> L2AW) == 19'd0;
                K_P:     chunk_ok = (a >> PDM_AW) == 19'd0;
                K_D:     chunk_ok = (dc >> (DRAM_AW - 4)) == {DCW{1'b0}};
                default: chunk_ok = 1'b1;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------ chunk buffer and reduction
    wire [63:0] buf_q;
    wire        buf_we = (ph == PH_RUN) & (st == ST_RD) &
                         (((g_sk == K_C) & cb_rsp_valid) | ((g_sk != K_C) & sd_rsp_valid));
    wire [63:0] buf_wd = (g_sk == K_C) ? cb_rsp_rdata : sd_rsp_rdata;
    mn_ram_lut #(.W(64), .AW(4), .NR(1)) u_buf (
        .clk(clk), .we(buf_we), .waddr(kr), .wdata(buf_wd), .raddr(kw), .rdata(buf_q));
    wire [63:0] red_y;
    mn_mv_red u_red (.op(rop), .fmt(w_dm), .x(buf_q), .y(red_y));
    wire [63:0] wr_data = (g_sk == K_NONE) ? 64'd0 : p_red ? red_y : buf_q;

    // address of long word k of the slot's chunk: L2BM, or SDRAM for the PDM / DRAM
    /* verilator lint_off UNUSEDSIGNAL */
    // the bits above the depths were checked by the check pass
    wire [18:0]    g_pa = (st == ST_WR) ? g_da : g_sa;
    wire [DCW-1:0] g_dx = g_dc;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [3:0]  kk       = (st == ST_WR) ? kw : ki;
    wire [1:0]  kind_now = (st == ST_WR) ? g_dk : g_sk;
    wire [19:0] pdm_sa   = PDM_BASE  | {{(20 - PDM_AW){1'b0}}, g_pa[PDM_AW-1:4], kk};
    wire [19:0] dram_sa  = DRAM_BASE | {{(20 - DRAM_AW){1'b0}}, g_dx[DRAM_AW-5:0], kk};
    wire [L2AW-1:0] l2_a = {g_pa[L2AW-1:4], kk};

    // ------------------------------------------------------------------ tags
    // the count of the MV's tag is updated in PH_FIN, while busy is still 1: when busy falls,
    // wt_cnt already includes this MV
    wire fin_now = (ph == PH_FIN);
    mn_mv_tags u_tags (
        .clk(clk), .rst(rst), .clearing(tags_clr), .done(fin_now), .done_tag(w_id),
        .wt_tag(wt_tag), .wt_cnt(wt_cnt), .take(wt_take));

    // ------------------------------------------------------------------ host port
    // spaces 0x07 L2BM (loc 0 = n0c0), 0x08 PDM, 0x09 DRAM (loc 0 = n0); served while idle
    wire idle_h = (ph == PH_IDLE);
    wire hw_c = (hw_space == 8'h07), hw_p = (hw_space == 8'h08), hw_d = (hw_space == 8'h09);
    wire hr_c = (hr_space == 8'h07), hr_p = (hr_space == 8'h08), hr_d = (hr_space == 8'h09);
    wire hw_ok = (hw_loc == 16'd0) & ((hw_c & ((hw_addr >> L2AW) == 23'd0)) |
                                      (hw_p & ((hw_addr >> PDM_AW) == 23'd0)) |
                                      (hw_d & ((hw_addr >> DRAM_AW) == 23'd0)));
    wire hr_ok = (hr_loc == 16'd0) & ((hr_c & ((hr_addr >> L2AW) == 23'd0)) |
                                      (hr_p & ((hr_addr >> PDM_AW) == 23'd0)) |
                                      (hr_d & ((hr_addr >> DRAM_AW) == 23'd0)));
    assign hw_ready = idle_h & (~hw_ok | (hw_c ? cb_req_ready : sd_req_ready));
    assign hw_err   = ~hw_ok;
    assign hr_ready = idle_h & ~hw_valid & (~hr_ok | (hr_c ? cb_req_ready : sd_req_ready));
    assign hr_err   = ~hr_ok;
    // the host's request of this clock (a write before a read): one address for both directions
    wire        h_w    = idle_h & hw_valid & hw_ok;
    wire        h_r    = idle_h & ~hw_valid & hr_valid & hr_ok;
    /* verilator lint_off UNUSEDSIGNAL */
    // the bits above the depths were checked by hw_ok / hr_ok
    wire [22:0] h_addr = hw_valid ? hw_addr : hr_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        h_c    = hw_valid ? hw_c : hr_c;
    wire        h_p    = hw_valid ? hw_p : hr_p;
    wire [19:0] h_sa   = h_p ? (PDM_BASE | {{(20 - PDM_AW){1'b0}}, h_addr[PDM_AW-1:0]}) :
                               (DRAM_BASE | {{(20 - DRAM_AW){1'b0}}, h_addr[DRAM_AW-1:0]});
    reg  h_rd;          // a host read is in flight (brd_host_if has one at a time)
    assign hr_rsp_valid = h_rd & (cb_rsp_valid | sd_rsp_valid);
    assign hr_rsp_data  = cb_rsp_valid ? cb_rsp_rdata : sd_rsp_rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_h = hw_d | hr_d;      // (the DRAM is "not L2BM and not PDM")
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------ request ports
    // the engine (ST_RD: the 16 reads of the source chunk, ST_WR: the 16 writes of the destination
    // chunk, only in PH_RUN) or the host (only while idle); the two ports share the fields
    wire        eng_rd = (ph == PH_RUN) & (st == ST_RD) & ~ki_end;
    wire        eng_wr = (ph == PH_RUN) & (st == ST_WR) & ~kw_end;
    wire        eng    = eng_rd | eng_wr;
    wire        to_c   = eng ? (kind_now == K_C) : h_c;
    wire        req_v  = eng | h_w | h_r;
    wire        req_we = eng ? eng_wr : h_w;
    wire [63:0] req_wd = eng ? wr_data : hw_data;
    wire [7:0]  req_wm = eng ? 8'hff : hw_mask;
    assign cb_req_valid = req_v & to_c;
    assign cb_req_we    = req_we;
    assign cb_req_addr  = {{(23 - L2AW){1'b0}}, eng ? l2_a : h_addr[L2AW-1:0]};
    assign cb_req_wdata = req_wd;
    assign cb_req_wmask = req_wm;
    assign sd_req_valid = req_v & ~to_c;
    assign sd_req_we    = req_we;
    assign sd_req_addr  = {3'd0, eng ? ((kind_now == K_P) ? pdm_sa : dram_sa) : h_sa};
    assign sd_req_wdata = req_wd;
    assign sd_req_wmask = req_wm;
    wire eng_acc = (kind_now == K_C) ? cb_req_ready : sd_req_ready;

    reg sd_err_q;
    assign err_sdr = sd_err_q;

    // ------------------------------------------------------------------ DRAM chunk counters
    // advance by st_n (1 or 2) chunks: direct ci; indirect (e, o) with N = nd (N = 0: e fixed)
    reg  [11:0] ci_n;
    reg  [9:0]  de_n;
    reg  [4:0]  dof_n;
    reg  [1:0]  adv;            // chunks to advance after this slot (0, 1, 2)
    always @* begin
        adv = 2'd0;
        if (p_cs)                       adv = 2'd1;
        else if (s_last)                adv = p_c2 ? 2'd2 : 2'd1;
        ci_n = ci + {10'd0, adv};
        de_n = de; dof_n = dof;
        if (nd == 5'd1) begin
            de_n = de + {8'd0, adv};
        end else if (nd != 5'd0) begin
            if ({1'b0, dof} + {4'd0, adv} >= {1'b0, nd}) begin
                dof_n = dof + {3'd0, adv} - nd;
                de_n  = de + 10'd1;
            end else begin
                dof_n = dof + {3'd0, adv};
            end
        end
    end
    // DRAM chunk address of the slot (direct: adra + ci; indirect: DAR + offset, ST_DAR)
    wire [DCW-1:0] dc_direct = w_adra[DCW-1:0] + {{(DCW - 12){1'b0}}, ci};
    wire [31:0]    dar_off   = (nd == 5'd0) ? {20'd0, ci} : {27'd0, dof};
    /* verilator lint_off UNUSEDSIGNAL */
    // not used: priority (mw[1:0]; no effect on results, SDM 3.5.7) and the DRAM address bits at
    // and above the chip's 2**29 long words (adra[29:25], DAR + offset bits 31..25: the official
    // wraps there)
    wire unused_bits = ^{mw[1:0], w_adra[29:25], dar_rdata[31:25], dar_off[31:25]};
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------ sequencer
    always @(posedge clk) begin
        if (rst) begin
            ph <= PH_CLR; st <= ST_SLOT;
            acc <= 1'b0; acc_st <= A_OK; acc_field <= 4'd0;
            h_rd <= 1'b0; sd_err_q <= 1'b0;
            w_valid <= 1'b0; w_mm <= 3'd0; w_tm <= 3'd0; w_sid <= 3'd0; w_did <= 3'd0; w_dm <= 2'd0;
            w_id <= 8'd0; w_ind <= 1'b0; w_adra <= 30'd0; w_adrb <= 15'd0; w_nw <= 11'd0;
            u <= 11'd0; s <= 3'd0; ci <= 12'd0; de <= 10'd0; dof <= 5'd0;
            g_dk <= K_NONE; g_sk <= K_NONE; g_da <= 19'd0; g_sa <= 19'd0; g_dc <= {DCW{1'b0}};
            ki <= 4'd0; kr <= 4'd0; kw <= 4'd0; ki_end <= 1'b0; kw_end <= 1'b0;
        end else begin
            acc <= 1'b0;
            if (sd_err_addr) sd_err_q <= 1'b1;
            if (h_r & (h_c ? cb_req_ready : sd_req_ready)) h_rd <= 1'b1;
            else if (cb_rsp_valid | sd_rsp_valid)                    h_rd <= 1'b0;
            case (ph)
                PH_CLR: if (!tags_clr) ph <= PH_IDLE;
                PH_IDLE: if (start) begin
                    w_valid <= `MN_M_VALID(mw);
                    w_mm  <= `MN_M_MMODE(mw);   w_tm  <= `MN_M_TMODE(mw);
                    w_did <= `MN_M_DESTID(mw);  w_sid <= `MN_M_SRCID(mw);
                    w_dm  <= `MN_M_DMODE(mw);   w_id  <= `MN_M_MVID(mw);
                    w_ind <= `MN_M_INDIRECT(mw);
                    w_adra <= `MN_M_ADRA(mw);   w_adrb <= `MN_M_ADRB(mw);
                    w_nw  <= `MN_M_NW(mw);
                    ph <= PH_DEC;
                end
                PH_DEC: begin
                    pass_init;
                    if (!w_valid) begin                     // mvnop: nothing, no tag
                        acc <= 1'b1; acc_st <= A_OK; ph <= PH_IDLE;
                    end else if (p_bad) begin
                        acc <= 1'b1; acc_st <= A_UNSUP; acc_field <= p_run ? p_ufld : F_TMODE; ph <= PH_IDLE;
                    end else if (p_nop) begin               // nothing moves; the MV completes
                        acc <= 1'b1; acc_st <= A_OK; ph <= PH_FIN;
                    end else begin
                        ph <= PH_CHK;
                    end
                end
                PH_CHK, PH_RUN: begin
                    case (st)
                        ST_SLOT: begin
                            g_dk <= p_dk;
                            g_sk <= s_real ? p_sk : K_NONE;
                            g_da <= d_a19;
                            g_sa <= s_a19;
                            g_dc <= dc_direct;
                            ki <= 4'd0; kr <= 4'd0; kw <= 4'd0; ki_end <= 1'b0; kw_end <= 1'b0;
                            st <= (d_ex & dside & w_ind) ? ST_DAR : ST_GO;   // dar_re in this clock
                        end
                        ST_DAR: begin
                            g_dc <= dar_rdata[DCW-1:0] + dar_off[DCW-1:0];
                            st   <= ST_GO;
                        end
                        ST_GO: begin
                            if (g_dk == K_NONE) begin
                                next_slot;              // the destination is not there: nothing
                            end else if (ph == PH_CHK) begin
                                if (!chunk_ok(g_dk, g_da, g_dc) || !chunk_ok(g_sk, g_sa, g_dc)) begin
                                    acc <= 1'b1; acc_st <= A_RANGE; ph <= PH_IDLE;
                                end else begin
                                    next_slot;
                                end
                            end else begin
                                st <= (g_sk == K_NONE) ? ST_WR : ST_RD;
                            end
                        end
                        ST_RD: begin
                            if (!ki_end && eng_acc) begin
                                ki <= ki + 4'd1;
                                if (ki == 4'd15) ki_end <= 1'b1;
                            end
                            if (buf_we) begin
                                kr <= kr + 4'd1;
                                if (kr == 4'd15) st <= ST_WR;
                            end
                        end
                        default: begin      // ST_WR
                            if (!kw_end && eng_acc) begin
                                kw <= kw + 4'd1;
                                if (kw == 4'd15) begin kw_end <= 1'b1; next_slot; end
                            end
                        end
                    endcase
                end
                PH_FIN: ph <= PH_IDLE;                     // the tag count is written now (fin_now)
                default: ph <= PH_IDLE;
            endcase
        end
    end

    // the counters at the start of a pass
    task pass_init;
        begin
            u <= 11'd0; s <= 3'd0; ci <= 12'd0; de <= w_adra[9:0]; dof <= 5'd0; st <= ST_SLOT;
        end
    endtask
    // the next slot / unit; at the end of the check pass: acc OK and the run pass; at the end of
    // the run pass: the tag
    task next_slot;
        begin
            st <= ST_SLOT;
            ci <= ci_n; de <= de_n; dof <= dof_n;
            if (!s_last) begin
                s <= s + 3'd1;
            end else begin
                s <= 3'd0;
                if (!u_last) begin
                    u <= u + 11'd1;
                end else if (ph == PH_CHK) begin
                    pass_init;
                    acc <= 1'b1; acc_st <= A_OK; ph <= PH_RUN;
                end else begin
                    ph <= PH_FIN;
                end
            end
        end
    endtask

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && start && !ready) $display("mn_mv: ERROR start while not ready");
        if (!rst && wt_take && busy) $display("mn_mv: ERROR wt_take while busy");
        if (!rst && cb_req_valid && cb_req_ready && cb_req_err)
            $display("mn_mv: ERROR L2BM port error at %0d", cb_req_addr);
        if (!rst && sd_err_addr && !sd_err_q) $display("mn_mv: ERROR SDRAM address error");
    end
`endif
endmodule
`default_nettype wire

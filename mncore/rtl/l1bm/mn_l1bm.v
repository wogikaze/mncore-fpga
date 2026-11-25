// mn_l1bm: the L1BM of one L1B and the PE <-> L1BM transfers (WP31).
//
// Interface and semantics: mncore/rtl/l1bm/README.md (the port definition for WP37 / WP32).
// Short version:
//   - The core gives the L1BM fields of the j word (mn_dec_j) and keeps them stable from start
//     until done. use_src / lbf_upd / chk_* are combinational from them.
//   - Step (every word with ll = 01 / 11 that has an L1BM expression or a destination with
//     isel = 10): start; the core pushes the PE -> L1BM source value of every PE (m, p) with
//     m < N_MAB and every cycle c (src_*, when use_src), and fetches the L1BM -> PE value of a
//     PE and cycle (res_*) for its destinations with isel = 10 and for $lbf (when lbf_upd), in
//     any order; then commit. The unit writes the L1BM and the turnaround register $lbi only
//     after commit (all reads of the step see the state before the step), then pulses done.
//     A word with chk_trap / chk_unsup must not be executed: the core reports the error and
//     calls neither start nor commit (if it does, nothing is written).
//   - $lbf (the L1BM -> PE forwarding register, per PE and cycle) is read by the core's operand
//     gather (lbf_r*) and written by the core with the zero-flushed result (lbf_w*); the unit
//     ignores the write unless lbf_upd.
//   - Port B: the L1BM through the contract section 6 memory bus (host WR_MEM / RD_MEM of space
//     6 and the L2BM side of WP32), served in the clocks where the PE side does not use the
//     memory port it needs.
// Semantics (official emulator, probed with mncore/sim/tb/l1bm; the model is l1model.py):
//   lwrite = 0: the L1BM -> PE data come from the L1BM (also when me = 0), layout by bmode
//     (00 l1bmp, 01 l1bmm, 10 l1bmm4, 11 l1bmd) and wl.
//   lwrite = 1: the L1BM -> PE data come from $lbi (turnaround), in the layout of the transfer
//     that last wrote $lbi (its bmode, wl and MAB shift, which this unit keeps; the word's own
//     bmode does not matter), and the word makes a PE -> L1BM transfer (l1bmm@, l1bmm4@, l1bmd,
//     l1bmr, l1bmr4; bmode 00 as 01) of the isel operand, or of zeros when isel = 111 (a
//     turnaround read alone, `l1bmm $lbi ...`). It writes $lbi unless noforward (ll = 11) and
//     the L1BM when me = 1.
//   l1bmd with a MAB shift: the assembler puts -4 * shift into ladr[5:0]; with L = ladr[5:2] * 4,
//     distribution reads block position (L + 4 m + p) mod 64, gathering writes the value of PE
//     (m, p) at (4 m + p - L) mod 64; $lbi is written without the shift.
//   $lbf: updated by a word with an L1BM expression (some L1BM field not at its default) that is
//     not noforward. (The emulator also loads it in words without L1BM fields, with their
//     implicit l1bmp $lb0 read; the assembler rejects reading $lbf after such a word.)
//   Reductions (rmode = 1): mn_l1bm_rrn per lane; precision from (opcode, dmode, ext, round_out);
//     the L1BM layout follows wl (see README.md for the e / r forms).
//   MABs m >= N_MAB do not exist: they send 0 to PE -> L1BM transfers (contract section 3) and
//   get nothing. With N_MAB = 1, $lbi keeps only positions 0..3 of both planes (the others are
//   always 0).
//   REPLICA = 1 (WP37, the replica rule of mncore/wp/WP-3x.md; N_MAB a power of 2): a MAB m that
//   does not exist is a copy of MAB m mod N_MAB. It sends that MAB's values to PE -> L1BM
//   transfers and reductions (l1bmm@m, l1bmm4@i, l1bmd, l1bmr, l1bmr4: the inputs are the
//   implemented values repeated), and the $lbi positions it would write read as those of the
//   copied MAB (position mod 2**LBW). It still gets nothing (writes to it are dropped). With
//   RRN = 2 a reduction is that of 16 (l1bmr) or 4 (l1bmr4) copies of MAB 0's value: fadd /
//   iadd scale it by 2**4 / 2**2 (exactly, like the network: the copies have one exponent), the
//   other operations keep it (and / or: 0 or 1).
`default_nettype none
module mn_l1bm #(
    parameter N_MAB = 1,    // MABs of the L1B (1..16), MAB 0 .. N_MAB-1 exist (contract N_MAB)
    parameter AW    = 10,   // L1BM depth = 2**AW long words (contract L1BM_DEPTH; chip 13)
    parameter RRN   = 1,    // 1: reduction network mn_l1bm_rrn (any N_MAB); 2: N_MAB = 1 only, one
                            // value and zeros per lane (small); 0: none, l1bmr / l1bmr4 E_UNSUPPORTED
    parameter CLEAR = 1,    // 1: after reset, clear the L1BM and $lbi (2**AW clocks, idle = 0)
    parameter REPLICA = 0   // 1: absent MABs are copies of the implemented ones (WP37, see above)
) (
    input  wire         clk,
    input  wire         rst,
    // ---- fields of the j word (mn_dec_j), stable from start until done
    input  wire [1:0]   ll,
    input  wire [1:0]   l1bm_bmode,
    input  wire         l1bm_lwrite,
    input  wire         l1bm_rmode,
    input  wire         l1bm_me,
    input  wire [12:0]  l1bm_ladr,
    input  wire         l1bm_dmode,
    input  wire         l1bm_ext,
    input  wire         l1bm_round_out,
    input  wire [3:0]   l1bm_mabadr,
    input  wire [3:0]   l1bm_opcode,
    input  wire [2:0]   l1bm_isel,
    input  wire         l1bm_wl,
    // ---- what the word does (combinational from the fields)
    output wire         use_src,     // PE -> L1BM: src of every PE and cycle is needed
    output wire         lbf_upd,     // the word updates $lbf (res of every PE and cycle needed)
    output wire         chk_trap,    // E_RANGE: an L1BM access at or beyond 2**AW
    output wire [12:0]  chk_addr,    //   the largest L1BM address of the word
    output wire         chk_unsup,   // E_UNSUPPORTED
    output wire [6:0]   chk_field,   //   field index (MN_J_<field>_IDX)
    // ---- step
    input  wire         start,       // taken when idle
    output wire         idle,
    input  wire         commit,      // after the sources and results of the step
    output reg          done,        // 1-clock pulse after commit
    // ---- PE -> L1BM source values (between start and commit)
    input  wire         src_we,
    input  wire [3:0]   src_mab,
    input  wire [1:0]   src_pe,
    input  wire [1:0]   src_cycle,
    input  wire [127:0] src_data,    // the l1bm_isel operand, bus layout of mn_pe_lsu
    // ---- L1BM -> PE values (between start and commit)
    input  wire         res_req,     // taken when res_ready
    output wire         res_ready,
    input  wire [3:0]   res_mab,
    input  wire [1:0]   res_pe,
    input  wire [1:0]   res_cycle,
    output reg          res_valid,   // 1-clock pulse; res_data holds until the next request
    output reg  [127:0] res_data,    // before zero flush and masks
    // ---- $lbf
    input  wire [3:0]   lbf_rmab,
    input  wire [1:0]   lbf_rpe,
    input  wire [1:0]   lbf_rcycle,
    output wire [127:0] lbf_rdata,   // combinational
    input  wire         lbf_we,
    input  wire [3:0]   lbf_wmab,
    input  wire [1:0]   lbf_wpe,
    input  wire [1:0]   lbf_wcycle,
    input  wire [127:0] lbf_wdata,   // the result after its zero flush
    // ---- port B: the L1BM as a memory (contract section 6 bus, long word addresses)
    input  wire         b_req_valid,
    output wire         b_req_ready,
    input  wire         b_req_we,
    input  wire [22:0]  b_req_addr,
    input  wire [63:0]  b_req_wdata,
    input  wire [7:0]   b_req_wmask, // a 32-bit half is written when its 4 bits are all 1
    output wire         b_req_err,   // with the accept: address at or beyond 2**AW (dropped)
    output reg          b_rsp_valid,
    output wire [63:0]  b_rsp_rdata
);
`include "mn_jfields.vh"

    localparam integer SAW = (N_MAB > 1) ? $clog2(N_MAB) + 4 : 4;   // {m, p, c}
    localparam integer LBW = (N_MAB > 1) ? 6 : 2;                   // $lbi positions kept
    localparam integer LAW = LBW + 2;                               // {c, position}
    localparam integer MQI = (N_MAB - 1) / 4;
    localparam integer NMI = N_MAB;
    localparam integer N4I = 4 * N_MAB;
    localparam [3:0]   MQ  = MQI[3:0];                              // largest m >> 2
    localparam [7:0]   NM4 = N4I[7:0];                              // PEs of the L1B
    localparam [4:0]   NM  = NMI[4:0];                              // MABs, for 5-bit compares

    // ------------------------------------------------------------------ word decode
    // (official emulator, probed) A word with lwrite = 0 reads the L1BM for its L1BM -> PE data
    // (me only enables the write of a PE -> L1BM transfer). A word with lwrite = 1 takes its
    // L1BM -> PE data from $lbi (turnaround) and makes a PE -> L1BM transfer (zero data when
    // isel = 111) that writes $lbi unless noforward, and the L1BM when me = 1.
    wire act    = ll[0];                                 // ll = 01 normal, 11 noforward
    wire nofwd  = (ll == 2'b11);
    wire p2l    = act & l1bm_lwrite;                     // PE -> L1BM (and turnaround read)
    wire p2l_w  = p2l & (l1bm_me | ~nofwd);              // ... that writes something
    wire l2pm   = act & ~l1bm_lwrite;                    // L1BM -> PE from the L1BM
    wire l2pi   = act & l1bm_lwrite;                     // L1BM -> PE from $lbi
    // an L1BM expression is in the word: some L1BM field differs from its default
    wire l1any  = (l1bm_bmode != 2'b00) | l1bm_lwrite | l1bm_rmode | l1bm_me | (l1bm_ladr != 13'd0) |
                  l1bm_dmode | l1bm_ext | l1bm_round_out | (l1bm_mabadr != 4'd0) |
                  (l1bm_opcode != 4'd0) | (l1bm_isel != 3'd7) | l1bm_wl;
    assign use_src = p2l & (l1bm_isel != 3'd7);
    assign lbf_upd = act & ~nofwd & l1any;
    wire [5:0] lsh  = {l1bm_ladr[5:2], 2'b00};           // l1bmd: MAB shift (ladr[1:0] unused)
    // PE -> L1BM layout: bmode 00 behaves as 01 (16x1)
    wire [1:0] wbm  = (l1bm_bmode == 2'b00) ? 2'b01 : l1bm_bmode;

    // reduction: operation, lane format and layout
    reg       op_ok;
    reg [2:0] rop;
    always @* begin
        op_ok = 1'b1;
        case (l1bm_opcode)
            4'b0000: rop = 3'd0;    // fadd
            4'b0001: rop = 3'd1;    // max
            4'b0010: rop = 3'd2;    // min
            4'b1000: rop = 3'd3;    // iadd
            4'b1001: rop = 3'd4;    // band
            4'b1010: rop = 3'd5;    // and
            4'b1100: rop = 3'd6;    // bor
            4'b1101: rop = 3'd7;    // or
            default: begin rop = 3'd0; op_ok = 1'b0; end
        endcase
    end
    wire       r_int  = l1bm_opcode[3];
    wire       r_fadd = (l1bm_opcode == 4'b0000);
    // floating point of dmode 1 (probed):
    //   ext : the 4 halves of the input MSB long word extended to 4 singles (sign and mantissa
    //         kept, exponent 0 -> 0, 63 -> 255, else + 96), reduced in single
    //   rnd : the 4 singles of the two input long words reduced, each rounded to half: fadd
    //         inside the RRN (round to nearest even, overflow to infinity, underflow to 0),
    //         max / min with the ALU `r` rounding (exponent saturates, mantissa kept)
    //   both: fadd = hfadd (extend, reduce in single, round); max / min = h, 16-bit lanes
    wire       r_flt  = ~r_int & l1bm_dmode;
    wire       r_xt   = r_flt & l1bm_ext & (r_fadd | ~l1bm_round_out);
    wire       r_rn   = r_flt & l1bm_round_out & (r_fadd | ~l1bm_ext);
    // lane format of the reduction: 0 64, 1 32, 2 16 bits
    wire [1:0] r_fmt  = ~l1bm_dmode ? 2'd0 : (r_xt | r_rn | ~l1bm_ext) ? 2'd1 : 2'd2;
    // combinations the emulator rejects (d with e / r aborts) or the assembler never makes
    wire       r_bad  = ~op_ok | (~l1bm_dmode & (l1bm_ext | l1bm_round_out)) | (r_int & l1bm_round_out);
    wire [6:0] r_badf = ~op_ok ? MN_J_L1BM_OPCODE_IDX[6:0] :
                        (l1bm_ext & ~l1bm_dmode) ? MN_J_L1BM_EXT_IDX[6:0] : MN_J_L1BM_ROUND_OUT_IDX[6:0];

    // block of one cycle in the L1BM (PE -> L1BM) and the two-long-word flag of the layout: wl,
    // also for reductions (a 4-single result with wl = 0 keeps its first long word, a 4-half
    // result with wl = 1 gets a zero second long word; probed)
    wire       k_two  = l1bm_wl;
    wire       k_m4   = (wbm == 2'b10);
    wire       k_ga   = (wbm == 2'b11);
    wire [6:0] k_blk  = k_ga ? 7'd64 : k_m4 ? (k_two ? 7'd32 : 7'd16) : (k_two ? 7'd8 : 7'd4);
    wire [12:0] k_base = k_ga ? {l1bm_ladr[12:6], 6'd0} : l1bm_ladr;

    // ------------------------------------------------------------------ range check
    // The largest L1BM address the word accesses (14 bits, before wrapping at the chip's 8192).
    // Only accesses that happen are checked (contract section 3): the L1BM -> PE read of a word
    // with an L1BM expression (a word without one reads long words 0..3: always inside), for
    // the PEs that exist, and the L1BM write of a PE -> L1BM transfer with me = 1.
    wire [7:0] d_last = ({2'b00, lsh} + NM4 - 8'd1 > 8'd63) ? 8'd63 : ({2'b00, lsh} + NM4 - 8'd1);
    reg  [13:0] amax;
    always @* begin
        if (l2pm) begin
            case (l1bm_bmode)
                2'b00:   amax = {1'b0, l1bm_ladr} + (l1bm_wl ? 14'd7 : 14'd3);
                2'b01:   amax = {1'b0, l1bm_ladr} + (l1bm_wl ? 14'd31 : 14'd15);
                2'b10:   amax = {1'b0, l1bm_ladr} + (l1bm_wl ? (14'd103 + {7'd0, MQ, 3'd0})
                                                             : (14'd51 + {8'd0, MQ, 2'd0}));
                default: amax = {1'b0, l1bm_ladr[12:6], 6'd0} + 14'd192 + {6'd0, d_last};
            endcase
        end else begin
            amax = {1'b0, k_base} + {5'd0, k_blk, 2'b00} - 14'd1;
        end
    end
    wire   mem_acc = (l2pm & l1any) | (p2l & l1bm_me);
    assign chk_trap = mem_acc & (amax >= (14'd1 << AW));
    // reported address: ladr when it is already outside, else the largest address of the word
    assign chk_addr = (l1bm_ladr >= (13'd1 << AW)) ? l1bm_ladr : amax[12:0];

    // ------------------------------------------------------------------ unsupported words
    // reductions: only with lwrite (l1bmr / l1bmr4: bmode 01 / 10) and a known operation and
    // precision; the emulator aborts on d with e / r, the assembler makes none of the others
    wire u_rm  = act & l1bm_rmode & (~p2l | k_ga | (RRN == 0));
    wire u_rr  = p2l & l1bm_rmode & ~u_rm & r_bad;
    assign chk_unsup = u_rm | u_rr;
    assign chk_field = u_rm ? MN_J_L1BM_RMODE_IDX[6:0] : r_badf;

    // ------------------------------------------------------------------ state
    localparam [1:0] P_IDLE = 2'd0, P_STEP = 2'd1, P_COMMIT = 2'd2, P_CLEAR = 2'd3;
    reg  [1:0]  ph;
    reg         cpend;      // commit seen while a result read was in flight
    reg  [AW-1:0] clr_a;
    reg  [1:0]  t_bmode;    // the transfer that last wrote $lbi
    reg         t_wl;
    reg  [5:0]  t_adr;
    assign idle = (ph == P_IDLE);

    // ------------------------------------------------------------------ L1BM memory
    wire [1:0]    m_we;
    wire [AW-1:0] m_waddr;
    wire [63:0]   m_wdata;
    wire          m_re;
    wire [AW-1:0] m_raddr;
    wire [63:0]   m_rdata;
    mn_ram_1r1w #(.W(64), .AW(AW), .NWE(2), .OREG(0)) u_mem (
        .clk(clk), .we(m_we), .waddr(m_waddr), .wdata(m_wdata),
        .re(m_re), .raddr(m_raddr), .rdata(m_rdata));

    // ------------------------------------------------------------------ source buffer
    wire [SAW-1:0] sb_raddr;
    wire [127:0]   sb_rdata;
    wire [SAW-1:0] sb_waddr = sidx(src_mab, src_pe, src_cycle);
    wire           sb_we    = src_we & ({1'b0, src_mab} < NM);
    mn_ram_lut #(.W(128), .AW(SAW), .NR(1)) u_src (
        .clk(clk), .we(sb_we), .waddr(sb_waddr), .wdata(src_data), .raddr(sb_raddr), .rdata(sb_rdata));

    /* verilator lint_off UNUSEDSIGNAL */
    // index {m, p, c} of a PE and cycle; with N_MAB = 1 the MAB bits are dropped (m is always 0)
    function [SAW-1:0] sidx(input [3:0] m, input [1:0] p, input [1:0] c);
        reg [7:0] t;
        begin
            t    = {m, p, c};
            sidx = t[SAW-1:0];
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------ $lbf
    // Not cleared at reset: reading $lbf before an L1BM -> PE transfer is an error in the
    // emulator and the assembler rejects it.
    wire lbf_ok = lbf_we & (ph == P_STEP) & lbf_upd & ({1'b0, lbf_wmab} < NM);
    mn_ram_lut #(.W(128), .AW(SAW), .NR(1)) u_lbf (
        .clk(clk), .we(lbf_ok), .waddr(sidx(lbf_wmab, lbf_wpe, lbf_wcycle)), .wdata(lbf_wdata),
        .raddr(sidx(lbf_rmab, lbf_rpe, lbf_rcycle)), .rdata(lbf_rdata));

    // ------------------------------------------------------------------ $lbi (two planes)
    wire           li_we0, li_we1;
    wire [LAW-1:0] li_waddr;
    wire [63:0]    li_wdata;
    wire [LAW-1:0] li_raddr;
    wire [63:0]    li_rd0, li_rd1;
    mn_ram_lut #(.W(64), .AW(LAW), .NR(1)) u_lbi0 (
        .clk(clk), .we(li_we0), .waddr(li_waddr), .wdata(li_wdata), .raddr(li_raddr), .rdata(li_rd0));
    mn_ram_lut #(.W(64), .AW(LAW), .NR(1)) u_lbi1 (
        .clk(clk), .we(li_we1), .waddr(li_waddr), .wdata(li_wdata), .raddr(li_raddr), .rdata(li_rd1));

    // ------------------------------------------------------------------ results (L1BM -> PE)
    localparam [1:0] R_IDLE = 2'd0, R_HI = 2'd1, R_LO = 2'd2;
    reg  [1:0]  rs;
    reg  [12:0] r_alo;      // address of the LSB long word (wl)
    reg         r_dual;
    reg  [63:0] r_hi;
    // turnaround: $lbi position of PE (m, p) in the layout of the transfer that wrote $lbi
    wire [5:0] t_pos = (t_bmode == 2'b10) ? (t_wl ? {1'b0, res_mab[3:2], 1'b0, res_pe} : {2'b00, res_mab[3:2], res_pe}) :
                       (t_bmode == 2'b11) ? (t_adr + {res_mab, res_pe}) : {4'd0, res_pe};
    // REPLICA: a position beyond the kept ones belongs to a copy of the MAB of position mod 2**LBW
    wire       t_in  = (REPLICA != 0) | (t_pos < (1 << LBW));
    assign li_raddr = {res_cycle, t_pos[LBW-1:0]};
    // L1BM -> PE from the L1BM: the MSB long word address of PE (m, p), cycle c
    reg  [12:0] r_ahi;
    always @* begin
        case (l1bm_bmode)
            2'b00:   r_ahi = l1bm_ladr + {11'd0, res_cycle};
            2'b01:   r_ahi = l1bm_ladr + (l1bm_wl ? {8'd0, res_cycle, 3'd0} : {9'd0, res_cycle, 2'd0}) +
                             {11'd0, res_pe};
            2'b10:   r_ahi = l1bm_ladr + (l1bm_wl ? {6'd0, res_cycle, 5'd0} : {7'd0, res_cycle, 4'd0}) +
                             (l1bm_wl ? {8'd0, res_mab[3:2], 3'd0} : {9'd0, res_mab[3:2], 2'd0}) +
                             {11'd0, res_pe};
            default: r_ahi = {l1bm_ladr[12:6], 6'd0} + {5'd0, res_cycle, 6'd0} +
                             {7'd0, lsh + {res_mab, res_pe}};
        endcase
    end
    wire r_go   = res_req & res_ready;
    wire r_memx = (rs == R_HI) & r_dual;       // the LSB long word read
    assign res_ready = (ph == P_STEP) & (rs == R_IDLE) & ~cpend;

    always @(posedge clk) begin
        if (rst) begin
            rs        <= R_IDLE;
            res_valid <= 1'b0;
            res_data  <= 128'd0;
        end else begin
            res_valid <= 1'b0;
            case (rs)
                R_IDLE: if (r_go) begin
                    if (l2pi) begin
                        res_data  <= t_in ? {li_rd0, li_rd1} : 128'd0;
                        res_valid <= 1'b1;
                    end else if (l2pm & ({1'b0, res_mab} < NM)) begin
                        r_alo <= r_ahi + 13'd4;
                        r_dual <= l1bm_wl & (l1bm_bmode != 2'b11);
                        rs    <= R_HI;
                    end else begin
                        res_data  <= 128'd0;
                        res_valid <= 1'b1;
                    end
                end
                R_HI: begin
                    r_hi <= m_rdata;
                    if (r_dual) begin
                        rs <= R_LO;
                    end else begin
                        res_data  <= {m_rdata, 64'd0};
                        res_valid <= 1'b1;
                        rs        <= R_IDLE;
                    end
                end
                default: begin   // R_LO
                    res_data  <= {r_hi, m_rdata};
                    res_valid <= 1'b1;
                    rs        <= R_IDLE;
                end
            endcase
        end
    end
    wire          pe_re    = (r_go & l2pm & ~l2pi & ({1'b0, res_mab} < NM)) | r_memx;
    /* verilator lint_off UNUSEDSIGNAL */
    // chip addresses (13 bits); only the low AW bits index the L1BM (chk_trap checked the rest)
    wire [12:0]   pe_raddr = r_memx ? r_alo : r_ahi;
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------ commit: PE -> L1BM
    // Items: for every cycle kc and block offset ko < k_blk, one long word to the L1BM (when me)
    // and to $lbi (unless noforward). bmode 01 / 10 (l1bmm@ / l1bmr, l1bmm4@ / l1bmr4):
    // ko = {g, k, p} (two long words) or {g, p}: PE p, output long word k, MAB group g.
    // bmode 11 (l1bmd): q = (ko + ladr) mod 64 = 4 m + p.
    reg  [1:0]  kc;
    reg  [5:0]  ko;
    reg  [1:0]  kj;         // reduction lane
    reg  [63:0] kw;         // reduction: the output long word being assembled
    reg         krun;       // reduction lane running in the RRN
    wire [5:0]  k_q   = ko + lsh;
    wire        k_k   = k_two & ko[2] & ~k_ga;          // output long word (l1bmd: always 0)
    wire [1:0]  k_p   = k_ga ? k_q[1:0] : ko[1:0];
    wire [1:0]  k_g   = k_m4 ? (k_two ? ko[4:3] : ko[3:2]) : 2'd0;
    wire [3:0]  k_mab = k_ga ? k_q[5:2] : k_m4 ? {k_g, l1bm_mabadr[1:0]} : l1bm_mabadr;
    wire [5:0]  k_pos = k_ga ? k_q : k_m4 ? (k_two ? {1'b0, k_g, 1'b0, k_p} : {2'b00, k_g, k_p}) : {4'd0, k_p};
    wire        k_last = (ko == k_blk[5:0] - 6'd1);   // k_blk = 64: 6'd63
    wire [12:0] k_coff = k_blk[6] ? {5'd0, kc, 6'd0} : k_blk[5] ? {6'd0, kc, 5'd0} :
                         k_blk[4] ? {7'd0, kc, 4'd0} : k_blk[3] ? {8'd0, kc, 3'd0} : {9'd0, kc, 2'd0};
    /* verilator lint_off UNUSEDSIGNAL */
    // chip address (13 bits); only the low AW bits index the L1BM (chk_trap checked the rest)
    wire [12:0] k_addr = k_base + k_coff + {7'd0, ko};
    /* verilator lint_on UNUSEDSIGNAL */

    // reductions: lane layout
    // plain : 64 / width lanes; lane j of output long word k <- input long word k, lane j
    // ext   : 2 lanes of 32; lane j of output long word k <- input MSB long word, half 2k + j
    // rnd   : 4 half lanes <- input long word j / 2, single j % 2, rounded to half
    // both  : 4 half lanes <- input MSB long word, half j, extended, rounded to half
    wire [1:0] o_fmt  = (r_rn) ? 2'd2 : r_xt ? 2'd1 : r_fmt;       // output lane width
    wire [1:0] kj_last = (o_fmt == 2'd0) ? 2'd0 : (o_fmt == 2'd1) ? 2'd1 : 2'd3;
    wire [3:0] rr_idx;
    wire [63:0] rr_val;
    wire       rr_busy, rr_done;
    wire [63:0] rr_res;
    // the input of lane kj: MAB, long word and lane
    wire [3:0] rr_mab = k_m4 ? {k_g, rr_idx[1:0]} : rr_idx;
    wire       in_lo  = r_xt ? 1'b0 : r_rn ? kj[1] : k_k;
    wire [1:0] in_ln  = r_xt ? (r_rn ? kj : {k_k, kj[0]}) : r_rn ? {1'b0, kj[0]} : kj;   // lane index
    // a rounded result is one long word: the second one (wl = 1) is 0
    wire        k_nos = (l1bm_isel == 3'd7);          // no PE operand: zero data
    // an absent MAB sends 0, or (REPLICA) the value of the MAB it copies (sidx drops the MAB bits
    // that N_MAB does not have, so the source buffer gives that MAB's value)
    wire        rr_ex = (REPLICA != 0) | ({1'b0, rr_mab} < NM);
    wire [63:0] in_w  = (rr_ex & ~k_nos) ? (in_lo ? sb_rdata[63:0] : sb_rdata[127:64]) : 64'd0;
    wire [1:0] in_fmt = r_xt ? 2'd2 : r_fmt;                       // width of the input lane
    wire [63:0] in_lane = lane_of(in_w, in_fmt, in_ln);
    assign rr_val = r_xt ? h2s(in_lane[15:0]) : in_lane;
    wire [63:0] rr_out;     // the lane result: max / min with rnd round it here (fadd in the RRN)
    wire [3:0] rr_zg;
    genvar zg;
    generate
        for (zg = 0; zg < 4; zg = zg + 1) begin : g_zg
            assign rr_zg[zg] = (REPLICA == 0) && (4 * zg >= N_MAB);
        end
    endgenerate
    wire k_red  = l1bm_rmode;
    // an item of value 0: a 4x4 group without MABs (not with REPLICA: copies), or the second long
    // word of a rounded result
    wire k_zero = k_red & (((REPLICA == 0) & k_m4 & ({1'b0, k_g, 2'b00} >= NM)) | (r_rn & k_k));

    function [63:0] lane_of(input [63:0] w, input [1:0] f, input [1:0] j);
        begin
            case (f)
                2'd0:    lane_of = w;
                2'd1:    lane_of = j[0] ? {32'd0, w[31:0]} : {32'd0, w[63:32]};
                default: lane_of = {48'd0, w[63 - 16 * j -: 16]};
            endcase
        end
    endfunction
    // precision extension half -> single of the reduction inputs: sign and mantissa kept,
    // exponent 0 -> 0, 63 -> 255, else + 96 (an fadd does not look at the mantissa of a zero or
    // infinite input; max / min see it: probed)
    function [63:0] h2s(input [15:0] h);
        begin
            h2s = {32'd0, h[15], (h[14:9] == 6'd0) ? 8'd0 : (h[14:9] == 6'h3f) ? 8'hff :
                   {2'b00, h[14:9]} + 8'd96, h[8:0], 14'd0};
        end
    endfunction
    // the ALU `r` rounding single -> half (the official emulator's, WP03 r_round): sign kept,
    // exponent clamp(E - 96 + carry, 0, 63), mantissa rounded to nearest even and kept
    function [63:0] rnd_r(input [31:0] s);
        reg [9:0] k;
        reg       up;
        reg [9:0] eh;
        begin
            up = s[13] & ((|s[12:0]) | s[14]);
            k  = {1'b0, s[22:14]} + {9'd0, up};
            eh = {2'b00, s[30:23]} + {9'd0, k[9]};
            rnd_r = {48'd0, s[31], (eh < 10'd96) ? 6'd0 : (eh > 10'd159) ? 6'h3f : eh[5:0] - 6'd32, k[8:0]};
        end
    endfunction
    function [63:0] put_lane(input [63:0] w, input [1:0] f, input [1:0] j, input [63:0] v);
        begin
            put_lane = w;
            case (f)
                2'd0:    put_lane = v;
                2'd1:    if (j[0]) put_lane[31:0] = v[31:0]; else put_lane[63:32] = v[31:0];
                default: put_lane[63 - 16 * j -: 16] = v[15:0];
            endcase
        end
    endfunction

    wire rr_start = (ph == P_COMMIT) & k_red & ~k_zero & ~krun & ~rr_busy;
    generate
        if (RRN == 2) begin : g_rrn1
            // N_MAB = 1: every lane reduces the value of MAB 0 with zeros (the other MABs do not
            // exist), in one clock: fadd gives the value (0 for a zero exponent field, infinity
            // for an all-ones one), rounded to half for out_half; max / min the value or +0 by
            // its sign; iadd / bor the value; band / and 0; or 1 when the value is not 0.
            reg rr_d;
            always @(posedge clk) rr_d <= rst ? 1'b0 : rr_start;
            assign rr_done = rr_d;
            assign rr_busy = rr_d;
            assign rr_idx  = 4'd0;
            // REPLICA: 16 copies (l1bmr, two stages of 4) or 4 copies (l1bmr4) of the value
            if (REPLICA != 0) begin : g_rep
                assign rr_res = rrn_rep(rop, r_fmt, r_rn & r_fadd, k_m4 ? 3'd2 : 3'd4, rr_val);
            end else begin : g_zero
                assign rr_res = rrn_one(rop, r_fmt, r_rn & r_fadd, rr_val);
            end
            wire unused_rr = ^rr_zg;
        end else if (RRN == 0) begin : g_norrn
            // no reductions: chk_unsup stops every l1bmr / l1bmr4 word
            assign rr_done = 1'b0;
            assign rr_busy = 1'b0;
            assign rr_idx  = 4'd0;
            assign rr_res  = 64'd0;
            wire unused_rr = ^{rr_zg, rr_val, rr_start, rop};
        end else begin : g_rrn
            mn_l1bm_rrn u_rrn (
                .clk(clk), .rst(rst), .start(rr_start), .op(rop), .fmt(r_fmt), .out_half(r_rn & r_fadd),
                .two_stage(~k_m4), .nin_m1(4'd3), .zgrp(rr_zg), .in_idx(rr_idx), .in_val(rr_val),
                .busy(rr_busy), .done(rr_done), .res(rr_res));
        end
    endgenerate

    // RRN = 2: one lane of a reduction of one value and zeros (viz/core rrn.rs with n - 1 zeros)
    function [63:0] rrn_one(input [2:0] op, input [1:0] f, input oh, input [63:0] v);
        reg        s, ez, ef;
        reg [10:0] e;
        reg [9:0]  kh;     // the 9 kept mantissa bits of a single rounded to half, and the carry
        reg        up;
        reg signed [9:0] bh;
        begin
            s  = (f == 2'd0) ? v[63] : (f == 2'd2) ? v[15] : v[31];
            e  = (f == 2'd0) ? v[62:52] : (f == 2'd2) ? {5'd0, v[14:9]} : {3'd0, v[30:23]};
            ez = (e == 11'd0);
            ef = (f == 2'd0) ? (e == 11'd2047) : (f == 2'd2) ? (e == 11'd63) : (e == 11'd255);
            up = v[13] & ((|v[12:0]) | v[14]);
            kh = {1'b0, v[22:14]} + {9'd0, up};   // carry: 1.1..1 rounds up to 10.0..0
            bh = $signed({2'b00, v[30:23]}) - 10'sd96 + $signed({9'd0, kh[9]});
            case (op)
                3'd0: begin    // fadd
                    if (ez)      rrn_one = 64'd0;
                    else if (ef) rrn_one = oh ? {48'd0, s, 6'h3f, 9'd0} :
                                           (f == 2'd0) ? {s, 11'h7ff, 52'd0} : {32'd0, s, 8'hff, 23'd0};
                    else if (oh) rrn_one = (bh >= 10'sd63) ? {48'd0, s, 6'h3f, 9'd0} :
                                           (bh <= 10'sd0) ? 64'd0 :
                                           {48'd0, s, bh[5:0], kh[8:0]};
                    else         rrn_one = v;
                end
                3'd1:    rrn_one = s ? 64'd0 : v;                 // max
                3'd2:    rrn_one = s ? v : 64'd0;                 // min
                3'd4,
                3'd5:    rrn_one = 64'd0;                         // band, and
                3'd7:    rrn_one = {63'd0, v != 64'd0};           // or
                default: rrn_one = v;                             // iadd, bor
            endcase
        end
    endfunction

    // RRN = 2, REPLICA: one lane of a reduction of 2**sh copies of one value (viz/core rrn.rs with
    // equal inputs): fadd adds the copies exactly (one exponent) and rounds once, so it is the value
    // with its exponent + sh (an all-ones exponent: infinity), then rounded like one value (rrn_one:
    // a zero exponent field gives 0, out_half rounds to half); iadd shifts it (lane wrap); max / min
    // / band / bor keep it; and / or give 1 when it is not 0.
    function [63:0] rrn_rep(input [2:0] op, input [1:0] f, input oh, input [2:0] sh, input [63:0] v);
        reg        s, ez, ef;
        reg [10:0] e, em;
        reg [11:0] es;
        reg [63:0] w;
        begin
            s  = (f == 2'd0) ? v[63] : (f == 2'd2) ? v[15] : v[31];
            e  = (f == 2'd0) ? v[62:52] : (f == 2'd2) ? {5'd0, v[14:9]} : {3'd0, v[30:23]};
            em = (f == 2'd0) ? 11'd2047 : (f == 2'd2) ? 11'd63 : 11'd255;
            ez = (e == 11'd0);
            ef = (e == em);
            es = {1'b0, e} + {9'd0, sh};
            w  = v;
            if (!ez && !ef) begin
                if (es >= {1'b0, em}) begin    // overflow: infinity of the format
                    w = (f == 2'd0) ? {s, 11'h7ff, 52'd0} : (f == 2'd2) ? {48'd0, s, 6'h3f, 9'd0} :
                                      {32'd0, s, 8'hff, 23'd0};
                end else begin
                    case (f)
                        2'd0:    w[62:52] = es[10:0];
                        2'd2:    w[14:9]  = es[5:0];
                        default: w[30:23] = es[7:0];
                    endcase
                end
            end
            case (op)
                3'd0:    rrn_rep = rrn_one(3'd0, f, oh, w);                   // fadd
                3'd3:    rrn_rep = (f == 2'd0) ? (v << sh) :                   // iadd
                                   (f == 2'd2) ? {48'd0, v[15:0] << sh} : {32'd0, v[31:0] << sh};
                3'd5,
                3'd7:    rrn_rep = {63'd0, v != 64'd0};                       // and, or
                default: rrn_rep = v;                                         // max, min, band, bor
            endcase
        end
    endfunction

    assign rr_out = (r_rn & ~r_fadd) ? rnd_r(rr_res[31:0]) : rr_res;

    // the value of the current item (0 while clearing after reset)
    wire          clr_on = (ph == P_CLEAR);
    wire [63:0] kw_n   = put_lane(kw, o_fmt, kj, rr_out);
    wire        k_dir  = ~k_red;
    wire        k_lane_last = (kj == kj_last);
    // an item is written in the clock where its value is ready
    wire        k_wr   = (ph == P_COMMIT) & (k_dir | k_zero | (krun & rr_done & k_lane_last));
    // an absent MAB sends 0, or (REPLICA) the value of the MAB it copies (sidx drops its MAB bits)
    wire        k_vz   = clr_on | (k_dir ? (((REPLICA == 0) & ({1'b0, k_mab} >= NM)) | k_nos) : k_zero);
    wire [63:0] k_val  = k_vz ? 64'd0 : ~k_dir ? kw_n : k_k ? sb_rdata[63:0] : sb_rdata[127:64];
    assign sb_raddr = sidx(k_red ? rr_mab : k_mab, k_p, kc);

    // ------------------------------------------------------------------ port B
    wire          k_mw   = k_wr & l1bm_me;
    wire b_ok  = (b_req_addr < (23'd1 << AW));
    wire pe_w  = clr_on | k_mw;
    assign b_req_ready = b_req_we ? ~pe_w : ~pe_re;
    wire b_go  = b_req_valid & b_req_ready & b_ok;
    wire b_wgo = b_go & b_req_we;
    wire b_rgo = b_go & ~b_req_we;
    assign b_req_err = b_req_valid & b_req_ready & ~b_ok;

    // memory and $lbi writes
    assign m_we    = clr_on ? 2'b11 : k_mw ? 2'b11 : b_wgo ? {&b_req_wmask[7:4], &b_req_wmask[3:0]} : 2'b00;
    assign m_waddr = clr_on ? clr_a : k_mw ? k_addr[AW-1:0] : b_req_addr[AW-1:0];
    assign m_wdata = pe_w ? k_val : b_req_wdata;
    wire          k_lw   = k_wr & ~nofwd & (k_pos < (1 << LBW));
    assign li_we0   = (clr_on & (clr_a < (1 << LAW))) | (k_lw & ~k_k);
    assign li_we1   = (clr_on & (clr_a < (1 << LAW))) | (k_lw & k_k);
    assign li_waddr = clr_on ? clr_a[LAW-1:0] : {kc, k_pos[LBW-1:0]};
    assign li_wdata = k_val;
    assign m_re    = pe_re | b_rgo;
    assign m_raddr = pe_re ? pe_raddr[AW-1:0] : b_req_addr[AW-1:0];
    assign b_rsp_rdata = m_rdata;

    // ------------------------------------------------------------------ sequencer
    always @(posedge clk) begin
        if (rst) begin
            ph          <= (CLEAR != 0) ? P_CLEAR : P_IDLE;
            cpend       <= 1'b0;
            clr_a       <= {AW{1'b0}};
            done        <= 1'b0;
            b_rsp_valid <= 1'b0;
            t_bmode     <= 2'b01;
            t_wl        <= 1'b0;
            t_adr       <= 6'd0;
            kc          <= 2'd0;
            ko          <= 6'd0;
            kj          <= 2'd0;
            krun        <= 1'b0;
        end else begin
            done        <= 1'b0;
            b_rsp_valid <= b_rgo;
            case (ph)
                P_CLEAR: begin
                    clr_a <= clr_a + 1'b1;
                    if (&clr_a) ph <= P_IDLE;
                end
                P_IDLE: if (start) begin
                    ph    <= P_STEP;
                    cpend <= 1'b0;
                end
                P_STEP: if (commit && (rs != R_IDLE)) begin
                    cpend <= 1'b1;       // a result read is in flight: commit after it
                end else if ((commit || cpend) && (rs == R_IDLE)) begin
                    kc   <= 2'd0;
                    ko   <= 6'd0;
                    kj   <= 2'd0;
                    krun <= 1'b0;
                    kw   <= 64'd0;
                    if (p2l_w & ~chk_trap & ~chk_unsup) begin
                        ph <= P_COMMIT;
                    end else begin
                        ph   <= P_IDLE;
                        done <= 1'b1;
                    end
                end
                P_COMMIT: begin
                    if (rr_start) krun <= 1'b1;
                    if (krun & rr_done) begin
                        kw   <= k_lane_last ? 64'd0 : kw_n;
                        kj   <= k_lane_last ? 2'd0 : kj + 2'd1;
                        krun <= 1'b0;
                    end
                    if (k_wr) begin
                        ko <= k_last ? 6'd0 : ko + 6'd1;
                        if (k_last) begin
                            kc <= kc + 2'd1;
                            if (kc == 2'd3) begin
                                if (!nofwd) begin
                                    t_bmode <= wbm;
                                    t_wl    <= l1bm_wl;
                                    t_adr   <= lsh;
                                end
                                ph   <= P_IDLE;
                                done <= 1'b1;
                            end
                        end
                    end
                end
                default: ph <= P_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial if ((RRN == 2) && (N_MAB != 1)) $display("mn_l1bm: ERROR RRN = 2 needs N_MAB = 1");
    initial if ((REPLICA != 0) && ((N_MAB & (N_MAB - 1)) != 0))
        $display("mn_l1bm: ERROR REPLICA needs N_MAB to be a power of 2");
    always @(posedge clk) begin
        if (!rst && res_req && !res_ready)
            $display("mn_l1bm: ERROR res_req while not ready");
        if (!rst && start && !idle)
            $display("mn_l1bm: ERROR start while not idle");
    end
`endif
endmodule
`default_nettype wire

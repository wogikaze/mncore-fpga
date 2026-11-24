// mn_pe_lsu: one PE's local-memory sequencer (WP14).
//
// Executes the memory side of one PE step (one j word) in three phases, so that every read
// of the step sees the state before the step (SDM 3.6.3.9, viz/core machine.rs):
//   1. start : the LM addresses of the 4 cycles are computed (mn_pe_agen) and latched, and
//              every access of the step is range checked. Out of range -> trap (E_RANGE),
//              nothing is read or written, done.
//   2. READ  : every memory the step reads (rd_use) is read for all 4 cycles into a read
//              buffer (LUT RAM), 1 or 2 long words per cycle, already in bus layout.
//   3. EXEC  : opr_* give the operands of any cycle (opr_cycle). The core returns the unit
//              outputs of cycle 0..3 in order (res_valid / res_ready; res_cycle is the
//              expected cycle; res_* must stay stable until res_ready). For each result the
//              write path selects, zero-flushes, masks and writes GRF0/GRF1/LM0/LM1 (store
//              channels), T, $mb/$nb and $omr.
//
// Bus layout (128 bits per cycle, the SDM "2 長語"):
//   [127:96] word 0 (MSB), [95:64] word 1, [63:32] word 2, [31:0] word 3.
//   A word access uses word 0, a long word access words 0-1, a 2-long-word access all 4.
//   Reads fill the unused words with 0.
// Masks (SDM 3.6.2, machine.rs word_enabled / merge_word / apply_flush): 4 flags per cycle,
//   bit 3 first. Long-word masks (mrc.wl = 0) act on the 4 half words of the MSB long word
//   and leave the LSB long word alone; 2-long-word masks (mrc.wl = 1) act on the 4 words.
//   Half-word masks are done by read-modify-write on the store channel (rare: only flags of
//   16-bit lanes give a half-word pattern), so the store needs 32-bit write lanes only.
//   Measured on the official emulator where viz/core differs (the RTL follows the emulator):
//   - T with a long-word mask: a cycle whose 4 flags are all 0 writes nothing, not even the
//     LSB long word.
//   - $mb / $nb with a mask: written only if the half word holding the 12 bits is enabled
//     ([111:96] for the word access $mb, [79:64] for $lmb).
//   - A mask register written in a step is used by masks from the next step (SDM 3.6.2).
//
// Write path: one shared 64-bit datapath. Per cycle, the first clock latches what to write
// (from the result's mask flags); then come the beats. A beat writes one long word half (MSB
// long word first, then LSB) of one unit's output (isel) to every destination that takes it.
// A single-unit word takes 1 beat (2 with a 2-long-word destination or T), so with
// mn_pe_store (IREG = 1) a nop takes 11 clocks and a long-word copy about 16.
//
// The j word (and rd_use) must stay stable from start until done.
// rd_use = {LM1, LM0, GRF1, GRF0}: memories the step reads as an operand (ALU / MAU / L1BM
//   inputs). It decides which reads are made and range checked; mn_pe_rduse computes it.
// zf_*: the zero flush of the cycle being accepted, for the core's forwarding registers:
//   unit zf_sel's output is ANDed with zf_mask when zf_en (valid with res_ready).
// Store channels: 0 GRF0, 1 GRF1, 2 LM0, 3 LM1, contract section 6 bus (mn_pe_store).
// Host port: WR_MEM / RD_MEM path (rtl/board/PROTOCOL.md section 5, mw_* / mr_*),
//   accepted only between steps, one read outstanding. Space IDs follow PROTOCOL.md v1:
//   0x01 LM0, 0x02 LM1, 0x03 GRF0, 0x04 GRF1 (long words), 0x05 T (addr 2c = MSB long word
//   of cycle c, 2c+1 = LSB long word). Design-specific (0x10 and up):
//   0x10 OMR mask register (addr = entry 1..15, data[15:0]; bits 4c+3..4c are the flags of
//        cycle c, bit 4c+3 for the MSB element; entry 0 reads as ffff),
//   0x11 BAR base address registers (addr 0 $mb, 1 $nb; data[11:0]).
//   wmask bit i = byte [8i+7:8i]. GRF/LM writes use whole 32-bit words (nibbles 0 or f).
//   hp_req_err = 1 in the accepting clock: space or address out of range; the request is
//   dropped (no write, no read response), like mw_err / mr_err.
// Reset clears the sequencer and $mb/$nb. Memory, T and the mask registers are RAM and are
// cleared through the host port, like the chip's d set.
module mn_pe_lsu #(
    parameter LM_AW  = 9,  // LM0/LM1 depth = 2**LM_AW long words (chip: 11)
    parameter GRF_AW = 8   // GRF0/GRF1 depth = 2**GRF_AW long words (chip: 8)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [1:0]   subpe,        // PE number in the MAB, for j<madpe>
    // ---- step
    input  wire         start,
    output wire         idle,         // start is accepted when idle = 1
    input  wire [425:0] jw,
    input  wire [3:0]   rd_use,       // {LM1, LM0, GRF1, GRF0}
    output wire         busy,
    output wire         opr_valid,
    input  wire [1:0]   opr_cycle,
    output wire [127:0] opr_grf0,
    output wire [127:0] opr_grf1,
    output wire [127:0] opr_lm0,
    output wire [127:0] opr_lm1,
    output wire [127:0] opr_t,
    input  wire         res_valid,
    output wire         res_ready,
    output wire [1:0]   res_cycle,
    input  wire [127:0] res_mau,      // isel 00
    input  wire [127:0] res_alu,      // isel 01
    input  wire [127:0] res_l1bm,     // isel 10
    input  wire [127:0] res_mread,    // isel 11
    input  wire [3:0]   res_alu_flags,
    input  wire [3:0]   res_mau_flags,
    output wire         zf_en,
    output wire [1:0]   zf_sel,
    output wire [127:0] zf_mask,
    output reg          done,         // 1-clock pulse after the step (also after a trap)
    output reg          trap,         // E_RANGE; held until the next start
    output reg          trap_wr,      // 1: the access is a write
    output reg  [1:0]   trap_mem,     // 0 GRF0, 1 GRF1, 2 LM0, 3 LM1
    output reg  [1:0]   trap_cycle,
    output reg  [11:0]  trap_addr,    // word address
    output wire         unsup,        // a used access has word length 11
    // ---- host port
    input  wire         hp_req_valid,
    output wire         hp_req_ready,
    input  wire         hp_req_we,
    input  wire [7:0]   hp_req_space,
    input  wire [22:0]  hp_req_addr,
    input  wire [63:0]  hp_req_wdata,
    input  wire [7:0]   hp_req_wmask,
    output wire         hp_req_err,
    output wire         hp_rsp_valid,
    output wire [63:0]  hp_rsp_rdata,
    // ---- store channels
    output reg  [3:0]   st_req_valid,
    input  wire [3:0]   st_req_ready,
    output reg  [3:0]   st_req_we,
    output reg  [91:0]  st_req_addr,
    output reg  [255:0] st_req_wdata,
    output reg  [31:0]  st_req_wmask,
    input  wire [3:0]   st_rsp_valid,
    input  wire [255:0] st_rsp_rdata
);
    // ------------------------------------------------------------------ j word fields
    localparam P_LL = 0, P_IMR = 2, P_MWL = 7, P_TGT = 8, P_ZERO = 14, P_ZSEL = 15;
    localparam P_OMR = 17, P_IFSEL = 21, P_T_WR = 22, P_T_ISEL = 23;
    localparam P_G0_WR = 25, P_G0_ISEL = 26, P_G0_WWL = 37, P_G0_RWL = 39;
    localparam P_G1_WR = 50, P_G1_ISEL = 51, P_G1_WWL = 62, P_G1_RWL = 64;
    localparam P_M0_WR = 75, P_M0_ISEL = 76, P_M0_MAADJ = 91, P_M0_MADPE = 92, P_M0_WL = 94;
    localparam P_M1_WR = 96, P_M1_ISEL = 97, P_M1_MAADJ = 111, P_M1_MADPE = 112, P_M1_WL = 114;
    localparam P_ALUOP = 147;
    // host port spaces (PROTOCOL.md v1; 0x10 and 0x11 are design-specific)
    localparam [7:0] SP_LM0 = 8'h01, SP_LM1 = 8'h02, SP_GRF0 = 8'h03, SP_GRF1 = 8'h04;
    localparam [7:0] SP_T = 8'h05, SP_OMR = 8'h10, SP_BAR = 8'h11;

    wire [1:0] ll     = jw[425-P_LL -: 2];
    wire [4:0] imr    = jw[425-P_IMR -: 5];
    wire       mwl    = jw[425-P_MWL];
    wire [5:0] tgt    = jw[425-P_TGT -: 6];   // rf0, rf1, tr, lm0, lm1, mr
    wire       zero   = jw[425-P_ZERO];
    wire [1:0] zsel   = jw[425-P_ZSEL -: 2];
    wire [3:0] omr    = jw[425-P_OMR -: 4];
    wire       ifsel  = jw[425-P_IFSEL];
    wire       t_wr   = jw[425-P_T_WR];
    wire [1:0] t_isel = jw[425-P_T_ISEL -: 2];
    wire [4:0] aluop  = jw[425-P_ALUOP -: 5];
    wire       m0_wr  = jw[425-P_M0_WR];
    wire       m0_mj  = jw[425-P_M0_MAADJ];
    wire [1:0] m0_mp  = jw[425-P_M0_MADPE -: 2];
    wire       m1_wr  = jw[425-P_M1_WR];
    wire       m1_mj  = jw[425-P_M1_MAADJ];
    wire [1:0] m1_mp  = jw[425-P_M1_MADPE -: 2];

    // ll: 01 normal, 11 noforward (writes happen), 00 nop, 10 invalid (E_DECODE elsewhere)
    wire act    = (ll == 2'b01) | (ll == 2'b11);
    // imm / immu: the LM0 fields carry the immediate (contract section 2)
    wire is_imm = (aluop == 5'b11111);
    wire m0_barm = m0_wr & ~m0_mj & (m0_mp == 2'b11);  // $mb write (UNKNOWN.md C.6)
    wire m1_barm = m1_wr & ~m1_mj & (m1_mp == 2'b11);  // $nb write

    // per memory M (0 GRF0, 1 GRF1, 2 LM0, 3 LM1)
    wire [1:0] rwl  [0:3];
    wire [1:0] wwl  [0:3];
    wire [1:0] isel [0:3];
    wire [3:0] we_m;    // memory write enabled by the word
    wire [3:0] tgt_m;   // write mask target bit
    assign rwl[0]  = jw[425-P_G0_RWL -: 2];  assign wwl[0]  = jw[425-P_G0_WWL -: 2];
    assign rwl[1]  = jw[425-P_G1_RWL -: 2];  assign wwl[1]  = jw[425-P_G1_WWL -: 2];
    assign rwl[2]  = jw[425-P_M0_WL -: 2];   assign wwl[2]  = jw[425-P_M0_WL -: 2];
    assign rwl[3]  = jw[425-P_M1_WL -: 2];   assign wwl[3]  = jw[425-P_M1_WL -: 2];
    assign isel[0] = jw[425-P_G0_ISEL -: 2];
    assign isel[1] = jw[425-P_G1_ISEL -: 2];
    assign isel[2] = jw[425-P_M0_ISEL -: 2];
    assign isel[3] = jw[425-P_M1_ISEL -: 2];
    assign we_m[0] = act & jw[425-P_G0_WR];
    assign we_m[1] = act & jw[425-P_G1_WR];
    assign we_m[2] = act & ~is_imm & m0_wr & ~m0_barm;
    assign we_m[3] = act & m1_wr & ~m1_barm;
    assign tgt_m   = {tgt[1], tgt[2], tgt[4], tgt[5]};   // lm1, lm0, rf1, rf0
    wire   tgt_t   = tgt[3];
    wire   tgt_mr  = tgt[0];
    wire   bar0_we = act & ~is_imm & m0_barm;
    wire   bar1_we = act & m1_barm;
    wire   t_we    = act & t_wr;
    wire   mr_we   = act & (omr != 4'd0);
    wire [3:0] ru_now = rd_use & {act, act & ~is_imm, act, act};
    wire   mask_on = (imr != 5'd0);

    // ------------------------------------------------------------------ state
    localparam S_IDLE = 2'd0, S_READ = 2'd1, S_EXEC = 2'd2;
    localparam X_S0 = 2'd0, X_RMW = 2'd1, X_WR = 2'd2;

    reg  [1:0]  state, xs, wc;
    reg  [11:0] bar0, bar1;
    reg  [47:0] m0a_l, m1a_l;     // LM word addresses of cycle 0..3, latched at start
    reg  [3:0]  ru;               // rd_use latched at start
    reg  [3:0]  qi [0:3];         // READ: requests issued per memory
    reg  [3:0]  ri [0:3];         // READ: responses received per memory
    reg  [3:0]  fcur;             // mask flags of the cycle being written
    reg  [6:0]  pend0, pend1;     // EXEC: destinations still to write (MSB / LSB long word)
    reg  [3:0]  prmw, iss, got;   // EXEC: read-modify-write memories, read issued, data back
    reg         loc_pend;         // EXEC: $omr write still to do (after a read-modify-write)
    reg  [255:0] old;             // RMW: old MSB long word, 64 bits per memory
    reg         hp_wait;          // host port: a read is outstanding
    reg         hp_lrsp;          // host port: local (non-store) read response pending
    reg  [63:0] hp_ldata;
    reg  [1:0]  hp_ch;            // host port: store channel of the outstanding read

    assign idle      = (state == S_IDLE) & ~hp_wait;
    assign busy      = (state != S_IDLE);
    assign opr_valid = (state == S_EXEC);
    assign res_cycle = wc;

    // ------------------------------------------------------------------ addresses
    wire [47:0] tind;
    wire [35:0] g0r_a, g0w_a, g1r_a, g1w_a;
    wire [47:0] m0_a, m1_a;
    wire [3:0]  g0r_ok, g0w_ok, g1r_ok, g1w_ok, m0_ok, m1_ok;
    mn_pe_agen #(.LM_AW(LM_AW), .GRF_AW(GRF_AW)) u_agen (
        .jw(jw), .subpe(subpe), .bar0(bar0), .bar1(bar1), .tind(tind),
        .g0r_a(g0r_a), .g0w_a(g0w_a), .g1r_a(g1r_a), .g1w_a(g1w_a), .m0_a(m0_a), .m1_a(m1_a),
        .g0r_ok(g0r_ok), .g0w_ok(g0w_ok), .g1r_ok(g1r_ok), .g1w_ok(g1w_ok), .m0_ok(m0_ok), .m1_ok(m1_ok)
    );

    // [M*4+c]: read / write word address after start (LM latched)
    wire [11:0]  ra  [0:15];
    wire [11:0]  wa  [0:15];
    wire [191:0] ra0, wa0;   // at start (for the trap report), 12 bits per [M*4+c]
    wire [15:0]  rok, wok;   // [M*4+c]
    genvar c, m;
    generate
        for (c = 0; c < 4; c = c + 1) begin : g_adr
            assign ra[0*4+c] = {3'd0, g0r_a[9*c +: 9]};  assign wa[0*4+c] = {3'd0, g0w_a[9*c +: 9]};
            assign ra[1*4+c] = {3'd0, g1r_a[9*c +: 9]};  assign wa[1*4+c] = {3'd0, g1w_a[9*c +: 9]};
            assign ra[2*4+c] = m0a_l[12*c +: 12];        assign wa[2*4+c] = m0a_l[12*c +: 12];
            assign ra[3*4+c] = m1a_l[12*c +: 12];        assign wa[3*4+c] = m1a_l[12*c +: 12];
            assign ra0[12*(0*4+c) +: 12] = {3'd0, g0r_a[9*c +: 9]};
            assign ra0[12*(1*4+c) +: 12] = {3'd0, g1r_a[9*c +: 9]};
            assign ra0[12*(2*4+c) +: 12] = m0_a[12*c +: 12];
            assign ra0[12*(3*4+c) +: 12] = m1_a[12*c +: 12];
            assign wa0[12*(0*4+c) +: 12] = {3'd0, g0w_a[9*c +: 9]};
            assign wa0[12*(1*4+c) +: 12] = {3'd0, g1w_a[9*c +: 9]};
            assign wa0[12*(2*4+c) +: 12] = m0_a[12*c +: 12];
            assign wa0[12*(3*4+c) +: 12] = m1_a[12*c +: 12];
            assign rok[0*4+c] = g0r_ok[c];  assign wok[0*4+c] = g0w_ok[c];
            assign rok[1*4+c] = g1r_ok[c];  assign wok[1*4+c] = g1w_ok[c];
            assign rok[2*4+c] = m0_ok[c];   assign wok[2*4+c] = m0_ok[c];
            assign rok[3*4+c] = m1_ok[c];   assign wok[3*4+c] = m1_ok[c];
        end
    endgenerate

    // ------------------------------------------------------------------ mask registers
    // One LUT RAM per cycle nibble (16 entries x 4 bits): $omr writes one nibble, no
    // read-modify-write. Read index: the host address between steps, imr otherwise.
    wire        hp_acc;
    wire        hp_in;
    wire [7:0]  sp = hp_req_space;
    wire        hp_mr_wr = hp_acc & hp_req_we & hp_in & (sp == SP_OMR) & (hp_req_addr[3:0] != 4'd0);
    wire [3:0]  omr_nib;
    wire        omr_go;
    wire [3:0]  mr_idx = ((state == S_IDLE) && !start) ? hp_req_addr[3:0] : imr[3:0];
    wire [3:0]  mr_wa  = (state == S_IDLE) ? hp_req_addr[3:0] : omr;
    wire [15:0] mr_rd;
    generate
        for (c = 0; c < 4; c = c + 1) begin : g_mr
            wire we = (state == S_IDLE) ? (hp_mr_wr & hp_req_wmask[c/2]) : (omr_go & (wc == c));
            wire [3:0] wd = (state == S_IDLE) ? hp_req_wdata[4*c +: 4] : omr_nib;
            mn_ram_lut #(.W(4), .AW(4), .NR(1)) u_mr (
                .clk(clk), .we(we), .waddr(mr_wa), .wdata(wd), .raddr(mr_idx), .rdata(mr_rd[4*c +: 4]));
        end
    endgenerate

    // flags of cycle c from imr: 1xxxx fixed pattern (bit 3-c), 00000 all ones, else $imr<n>
    wire [15:0] mr_sel = (mr_idx == 4'd0) ? 16'hffff : mr_rd;
    wire [3:0]  f_all [0:3];
    generate
        for (c = 0; c < 4; c = c + 1) begin : g_flag
            assign f_all[c] = imr[4] ? {4{imr[3-c]}} : mr_sel[4*c +: 4];
        end
    endgenerate
    wire [3:0] f_now = (xs == X_S0) ? f_all[wc] : fcur;

    // half-word enables of the 128-bit bus (bit 7 = [127:112]) from 4 flags
    function [7:0] hen(input [3:0] f, input ll2);
        hen = ll2 ? {f[3], f[3], f[2], f[2], f[1], f[1], f[0], f[0]} : {f, 4'hf};
    endfunction
    // half words a write of word length wl touches
    function [7:0] wlmask(input [1:0] wl);
        wlmask = (wl == 2'b00) ? 8'hc0 : (wl == 2'b01) ? 8'hf0 : 8'hff;
    endfunction
    function [31:0] merge32(input [31:0] o, input [31:0] n, input [1:0] h);
        merge32 = {h[1] ? n[31:16] : o[31:16], h[0] ? n[15:0] : o[15:0]};
    endfunction
    wire [7:0] h_now = hen(f_now, mwl);   // half-word enables of the cycle being written

    // ------------------------------------------------------------------ range check at start
    // err[c*8 + w*4 + M]: cycle c, w = 1 write / 0 read, memory M; the lowest index is reported
    wire [31:0] errv;
    generate
        for (m = 0; m < 4; m = m + 1) begin : g_chk
            for (c = 0; c < 4; c = c + 1) begin : g_c
                wire [7:0] hw = (tgt_m[m] & mask_on) ? hen(f_all[c], mwl) : 8'hff;
                wire anyw = we_m[m] & (|(hw & wlmask(wwl[m])));
                assign errv[c*8 + m]     = ru_now[m] & ~rok[m*4+c];
                assign errv[c*8 + 4 + m] = anyw & ~wok[m*4+c];
            end
        end
    endgenerate
    reg [4:0] e_idx;
    integer ei;
    always @* begin
        e_idx = 5'd0;
        for (ei = 31; ei >= 0; ei = ei - 1)
            if (errv[ei]) e_idx = ei[4:0];
    end
    wire [3:0]  e_sel  = {e_idx[1:0], e_idx[4:3]};   // M*4 + c
    wire [11:0] e_addr = e_idx[2] ? wa0[12*e_sel +: 12] : ra0[12*e_sel +: 12];

    assign unsup = ((ru_now[0] & (rwl[0] == 2'b11)) | (we_m[0] & (wwl[0] == 2'b11))) |
                   ((ru_now[1] & (rwl[1] == 2'b11)) | (we_m[1] & (wwl[1] == 2'b11))) |
                   ((ru_now[2] | we_m[2]) & (rwl[2] == 2'b11)) |
                   ((ru_now[3] | we_m[3]) & (rwl[3] == 2'b11));

    // ------------------------------------------------------------------ zero flush info
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_zf
            assign zf_mask[16*i +: 16] = {16{h_now[i]}};
        end
    endgenerate
    assign zf_en  = zero;
    assign zf_sel = zsel;

    // ------------------------------------------------------------------ READ phase
    wire [3:0]  rq_v;            // request valid
    wire [91:0] rq_a;            // request address, 23 bits per memory
    wire [3:0]  rd_fin;          // all responses received after this clock
    wire [511:0] opr_m;          // operands per memory, 128 bits each
    generate
        for (m = 0; m < 4; m = m + 1) begin : g_rd
            wire       dl   = rwl[m][1];
            wire [3:0] nreq = ru[m] ? (dl ? 4'd8 : 4'd4) : 4'd0;
            wire [1:0] cq   = dl ? qi[m][2:1] : qi[m][1:0];
            wire       hq   = dl & qi[m][0];
            wire [1:0] cr   = dl ? ri[m][2:1] : ri[m][1:0];
            wire       hr   = dl & ri[m][0];
            wire [47:0] rav = {ra[m*4+3], ra[m*4+2], ra[m*4+1], ra[m*4]};   // cycles 3..0
            wire [10:0] aq  = rav[12*cq + 1 +: 11];  // long word address
            assign rq_v[m] = (qi[m] < nreq);
            assign rq_a[23*m +: 23] = {12'd0, aq + {10'd0, hq}};
            assign rd_fin[m] = (ri[m] == nreq) | ((ri[m] + 4'd1 == nreq) & st_rsp_valid[m]);

            // read buffer in bus layout: hi = MSB long word, lo = LSB long word (0 unless 2 long words)
            wire        rb_we = (state == S_READ) & st_rsp_valid[m];
            wire [63:0] rsp   = st_rsp_rdata[64*m +: 64];
            wire        lane  = rav[12*cr];
            wire [63:0] hi_wd = (rwl[m] == 2'b00) ? {(lane ? rsp[31:0] : rsp[63:32]), 32'd0} : rsp;
            mn_ram_lut #(.W(64), .AW(2), .NR(1)) u_rbh (
                .clk(clk), .we(rb_we & ~hr), .waddr(cr), .wdata(hi_wd),
                .raddr(opr_cycle), .rdata(opr_m[128*m + 64 +: 64]));
            mn_ram_lut #(.W(64), .AW(2), .NR(1)) u_rbl (
                .clk(clk), .we(rb_we & (hr | ~dl)), .waddr(cr), .wdata(rsp & {64{hr}}),
                .raddr(opr_cycle), .rdata(opr_m[128*m +: 64]));
        end
    endgenerate
    assign opr_grf0 = opr_m[127:0];
    assign opr_grf1 = opr_m[255:128];
    assign opr_lm0  = opr_m[383:256];
    assign opr_lm1  = opr_m[511:384];

    // ------------------------------------------------------------------ EXEC: what to write
    // destinations d: 0 GRF0, 1 GRF1, 2 LM0, 3 LM1 (store), 4 T, 5 $mb, 6 $nb
    wire [3:0] n0, n1, rmw;    // store: MSB / LSB long word to write, MSB needs read-modify-write
    wire [7:0] l0, l1;         // store lane enables {[63:32], [31:0]} of the MSB / LSB beat
    wire [15:0] hv;            // store: half enables of the MSB beat {lane 1 hi, lo, lane 0 hi, lo}
    wire [91:0] xa;            // store: long word address of the MSB beat, 23 bits per memory
    generate
        for (m = 0; m < 4; m = m + 1) begin : g_need
            wire [47:0] wav = {wa[m*4+3], wa[m*4+2], wa[m*4+1], wa[m*4]};
            wire [11:0] a   = wav[12*wc +: 12];
            assign xa[23*m +: 23] = {12'd0, a[11:1]};
            wire [7:0]  hw  = ((tgt_m[m] & mask_on) ? h_now : 8'hff) & wlmask(wwl[m]);
            wire        wrd = (wwl[m] == 2'b00);
            wire [1:0]  h1h = hw[7:6];                    // halves of the word in lane 1
            wire [1:0]  h0h = wrd ? hw[7:6] : hw[5:4];    // halves of the word in lane 0
            wire        e1  = wrd ? (~a[0] & (|hw[7:6])) : (|hw[7:6]);
            wire        e0  = wrd ? ( a[0] & (|hw[7:6])) : (|hw[5:4]);
            assign l0[2*m +: 2] = {e1, e0};
            assign l1[2*m +: 2] = wwl[m][1] ? {|hw[3:2], |hw[1:0]} : 2'b00;
            assign hv[4*m +: 4] = {h1h, h0h};
            assign rmw[m] = (e1 & (h1h != 2'b11)) | (e0 & (h0h != 2'b11));
            assign n0[m]  = we_m[m] & (e1 | e0);
            assign n1[m]  = we_m[m] & (|l1[2*m +: 2]);
        end
    endgenerate
    // T: a cycle with all flags 0 writes nothing (see the header)
    wire [7:0] t_hw   = (tgt_t & mask_on) ? h_now : 8'hff;
    wire       t_on   = ~(tgt_t & mask_on) | (f_now != 4'd0);
    wire [3:0] t_l0   = t_hw[7:4];
    wire [1:0] t_l1   = t_on ? {|t_hw[3:2], |t_hw[1:0]} : 2'b00;
    // $mb / $nb: the half word holding the 12 bits must be enabled (see the header)
    wire b0_on = bar0_we & (~(tgt_m[2] & mask_on) | ((wwl[2] == 2'b00) ? h_now[6] : h_now[4]));
    wire b1_on = bar1_we & (~(tgt_m[3] & mask_on) | ((wwl[3] == 2'b00) ? h_now[6] : h_now[4]));
    wire [6:0] need0 = {b1_on, b0_on, t_we & (|t_l0), n0};
    wire [6:0] need1 = {2'b00, t_we & (|t_l1), n1};
    wire [13:0] isel_d = {isel[3], isel[2], t_isel, isel[3], isel[2], isel[1], isel[0]};
    wire any_rmw = |(rmw & n0);

    // ------------------------------------------------------------------ EXEC: beats
    wire res_go = (state == S_EXEC) & (xs == X_S0) & res_valid;
    wire active = (state == S_EXEC) & (xs == X_WR);
    // A beat: half (MSB long word first), unit (the lowest pending destination's isel) and the
    // destinations that take that unit. It is picked one clock ahead into bh / bu / bset, so
    // the choice is not on the write-data path.
    function [9:0] pick(input [6:0] e0, input [6:0] e1, input [13:0] sd);
        reg       h;
        reg [6:0] eh, st;
        reg [1:0] u;
        integer   q;
        begin
            h  = (e0 == 7'd0);
            eh = h ? e1 : e0;
            u  = 2'd0;
            for (q = 6; q >= 0; q = q - 1)
                if (eh[q]) u = sd[2*q +: 2];
            for (q = 0; q < 7; q = q + 1)
                st[q] = eh[q] & (sd[2*q +: 2] == u);
            pick = {h, u, st};
        end
    endfunction
    reg        bh;                 // this beat: 0 MSB long word, 1 LSB long word
    reg  [1:0] bu;                 // this beat: unit (isel)
    reg  [6:0] bset;               // this beat: destinations not yet written
    wire       h_cur = bh;
    wire [1:0] u_cur = bu;
    wire [6:0] beat  = bset;
    wire [6:0] done_d = bset & {3'b111, st_req_ready};
    wire [6:0] brem   = bset & ~done_d;
    wire [6:0] eff0_n = bh ? 7'd0 : (pend0 & ~done_d);
    wire [6:0] eff1_n = bh ? (pend1 & ~done_d) : pend1;
    wire       acc    = active & (eff0_n == 7'd0) & (eff1_n == 7'd0);
    wire [9:0] b_first = pick(need0, need1, isel_d);    // first beat of a cycle
    wire [9:0] b_next  = pick(eff0_n, eff1_n, isel_d);  // beat after this one
    assign res_ready = acc;

    // shared write data: the selected unit's long word, zero-flushed
    wire [127:0] usel = (u_cur == 2'b00) ? res_mau : (u_cur == 2'b01) ? res_alu :
                        (u_cur == 2'b10) ? res_l1bm : res_mread;
    wire [63:0]  uh   = h_cur ? usel[63:0] : usel[127:64];
    wire [3:0]   zh   = h_cur ? h_now[3:0] : h_now[7:4];
    wire         zhit = zero & (zsel == u_cur);
    wire [63:0]  wx;   // unit data of this beat
    wire [63:0]  wd;   // write data: wx, or the host's between steps
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_wd
            assign wx[16*i +: 16] = uh[16*i +: 16] & {16{~zhit | zh[i]}};
        end
    endgenerate

    assign wd = (state == S_IDLE) ? hp_req_wdata : wx;

    // $omr: nibble wc <- unit flags AND the write mask (a masked-off flag is written as 0)
    assign omr_nib = (ifsel ? res_mau_flags : res_alu_flags) & ((tgt_mr & mask_on) ? f_now : 4'hf);
    assign omr_go  = mr_we & active & loc_pend;

    // ------------------------------------------------------------------ T register
    wire [127:0] t_rd;
    wire         hp_t_wr = hp_acc & hp_req_we & hp_in & (sp == SP_T);
    wire [3:0]   t_we_hi = (state == S_IDLE) ?
                     ((hp_t_wr & ~hp_req_addr[0]) ? {|hp_req_wmask[7:6], |hp_req_wmask[5:4],
                                                     |hp_req_wmask[3:2], |hp_req_wmask[1:0]} : 4'd0) :
                     ((active & beat[4] & ~h_cur) ? t_l0 : 4'd0);
    wire [1:0]   t_we_lo = (state == S_IDLE) ?
                     ((hp_t_wr & hp_req_addr[0]) ? {|hp_req_wmask[7:4], |hp_req_wmask[3:0]} : 2'd0) :
                     ((active & beat[4] & h_cur) ? t_l1 : 2'd0);
    wire [1:0]   t_wa = (state == S_IDLE) ? hp_req_addr[2:1] : wc;
    wire [63:0]  t_wd = wd;
    wire [1:0]   t_ra = (state == S_IDLE) ? hp_req_addr[2:1] : opr_cycle;
    mn_pe_treg u_treg (
        .clk(clk), .waddr(t_wa), .we_hi(t_we_hi), .we_lo(t_we_lo), .wdata(t_wd),
        .raddr(t_ra), .rdata(t_rd), .tind(tind));
    assign opr_t = t_rd;

    // ------------------------------------------------------------------ host port
    // store channel of a space: LM0 -> 2, LM1 -> 3, GRF0 -> 0, GRF1 -> 1
    wire        hp_st = (sp == SP_LM0) | (sp == SP_LM1) | (sp == SP_GRF0) | (sp == SP_GRF1);
    wire [1:0]  hp_sc = (sp == SP_LM0) ? 2'd2 : (sp == SP_LM1) ? 2'd3 : (sp == SP_GRF1) ? 2'd1 : 2'd0;
    wire [22:0] hp_lim = ((sp == SP_GRF0) | (sp == SP_GRF1)) ? (23'd1 << GRF_AW) :
                         ((sp == SP_LM0)  | (sp == SP_LM1))  ? (23'd1 << LM_AW) :
                         (sp == SP_T) ? 23'd8 : (sp == SP_OMR) ? 23'd16 : (sp == SP_BAR) ? 23'd2 : 23'd0;
    assign hp_in = (hp_req_addr < hp_lim);
    assign hp_req_err   = ~hp_in;
    assign hp_req_ready = (state == S_IDLE) & ~hp_wait & ~start &
                          ~(hp_st & hp_in & ~st_req_ready[hp_sc]);
    assign hp_acc = hp_req_valid & hp_req_ready;
    wire        hp_str = hp_acc & hp_st & hp_in;   // goes to a store channel
    assign hp_rsp_valid = hp_lrsp | (hp_wait & ~hp_lrsp & (state == S_IDLE) & st_rsp_valid[hp_ch]);
    assign hp_rsp_rdata = hp_lrsp ? hp_ldata : st_rsp_rdata[64*hp_ch +: 64];

    // ------------------------------------------------------------------ store request mux
    integer k;
    reg [63:0] ld;   // MSB beat lane data before the merge
    wire [7:0] wwl_f = {wwl[3], wwl[2], wwl[1], wwl[0]};
    always @* begin
        ld           = 64'd0;
        st_req_valid = 4'd0;
        st_req_we    = 4'd0;
        st_req_addr  = 92'd0;
        st_req_wdata = 256'd0;
        st_req_wmask = 32'd0;
        for (k = 0; k < 4; k = k + 1) begin
            case (state)
                S_IDLE: begin
                    st_req_valid[k]          = hp_str & (hp_sc == k[1:0]);
                    st_req_we[k]             = hp_req_we;
                    st_req_addr[23*k +: 23]  = hp_req_addr;
                    st_req_wdata[64*k +: 64] = wd;
                    st_req_wmask[8*k +: 8]   = hp_req_wmask;
                end
                S_READ: begin
                    st_req_valid[k]          = rq_v[k];
                    st_req_addr[23*k +: 23]  = rq_a[23*k +: 23];
                end
                default: begin   // S_EXEC
                    st_req_addr[23*k +: 23]  = xa[23*k +: 23] | {22'd0, h_cur};
                    if (xs == X_RMW) begin
                        st_req_valid[k]      = prmw[k] & ~iss[k];
                    end else begin
                        st_req_valid[k]      = active & beat[k];
                        st_req_we[k]         = 1'b1;
                        if (h_cur) begin
                            st_req_wdata[64*k +: 64] = wd;
                            st_req_wmask[8*k +: 8]   = {{4{l1[2*k+1]}}, {4{l1[2*k]}}};
                        end else begin
                            // a word access puts word 0 in the lane of its address
                            ld = (wwl_f[2*k +: 2] == 2'b00) ? {wd[63:32], wd[63:32]} : wd;
                            st_req_wdata[64*k +: 64] = prmw[k] ?
                                {merge32(old[64*k + 32 +: 32], ld[63:32], hv[4*k+2 +: 2]),
                                 merge32(old[64*k +: 32],      ld[31:0],  hv[4*k +: 2])} : ld;
                            st_req_wmask[8*k +: 8]   = {{4{l0[2*k+1]}}, {4{l0[2*k]}}};
                        end
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------------ sequencer
    wire start_go = start & idle;
    integer j;
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            xs       <= X_S0;
            wc       <= 2'd0;
            done     <= 1'b0;
            trap     <= 1'b0;
            trap_wr  <= 1'b0;
            trap_mem <= 2'd0;
            trap_cycle <= 2'd0;
            trap_addr  <= 12'd0;
            bar0     <= 12'd0;
            bar1     <= 12'd0;
            hp_wait  <= 1'b0;
            hp_lrsp  <= 1'b0;
            loc_pend <= 1'b0;
            pend0 <= 7'd0; pend1 <= 7'd0; prmw <= 4'd0; iss <= 4'd0; got <= 4'd0;
            bh <= 1'b0; bu <= 2'd0; bset <= 7'd0;
            ru <= 4'd0;
            for (j = 0; j < 4; j = j + 1) begin qi[j] <= 4'd0; ri[j] <= 4'd0; end
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    // host port
                    hp_lrsp <= 1'b0;
                    if (hp_rsp_valid) hp_wait <= 1'b0;
                    if (hp_acc && hp_in) begin
                        if (!hp_req_we) begin
                            hp_wait <= 1'b1;
                            hp_ch   <= hp_sc;
                            if (!hp_st) begin
                                hp_lrsp  <= 1'b1;
                                hp_ldata <= (sp == SP_T)   ? (hp_req_addr[0] ? t_rd[63:0] : t_rd[127:64]) :
                                            (sp == SP_OMR) ? {48'd0, mr_sel} :
                                                             {52'd0, hp_req_addr[0] ? bar1 : bar0};
                            end
                        end else if (sp == SP_BAR && (|hp_req_wmask[1:0])) begin
                            if (hp_req_addr[0]) bar1 <= hp_req_wdata[11:0];
                            else                bar0 <= hp_req_wdata[11:0];
                        end
                    end
                    // step start
                    if (start_go) begin
                        trap <= 1'b0;
                        if (errv != 32'd0) begin
                            trap       <= 1'b1;
                            trap_wr    <= e_idx[2];
                            trap_mem   <= e_idx[1:0];
                            trap_cycle <= e_idx[4:3];
                            trap_addr  <= e_addr;
                            done       <= 1'b1;
                        end else begin
                            state <= S_READ;
                            m0a_l <= m0_a;
                            m1a_l <= m1_a;
                            ru    <= ru_now;
                            for (j = 0; j < 4; j = j + 1) begin qi[j] <= 4'd0; ri[j] <= 4'd0; end
                            wc <= 2'd0;
                            xs <= X_S0;
                        end
                    end
                end
                S_READ: begin
                    for (j = 0; j < 4; j = j + 1) begin
                        if (rq_v[j] && st_req_ready[j]) qi[j] <= qi[j] + 4'd1;
                        if (st_rsp_valid[j])            ri[j] <= ri[j] + 4'd1;
                    end
                    if (rd_fin == 4'hf) state <= S_EXEC;
                end
                default: begin   // S_EXEC
                    case (xs)
                        X_S0: if (res_go) begin
                            // latch what this cycle writes; the beats follow in X_WR
                            fcur     <= f_all[wc];
                            {bh, bu, bset} <= b_first;
                            prmw     <= rmw & n0;
                            pend0    <= need0;
                            pend1    <= need1;
                            iss      <= 4'd0;
                            got      <= 4'd0;
                            loc_pend <= 1'b1;
                            xs       <= any_rmw ? X_RMW : X_WR;
                        end
                        X_RMW: begin
                            iss <= iss | (prmw & st_req_ready);
                            got <= got | (prmw & st_rsp_valid);
                            for (j = 0; j < 4; j = j + 1)
                                if (st_rsp_valid[j] && prmw[j]) old[64*j +: 64] <= st_rsp_rdata[64*j +: 64];
                            if (((got | st_rsp_valid) & prmw) == prmw) xs <= X_WR;
                        end
                        default: begin   // X_WR
                            pend0    <= eff0_n;
                            pend1    <= eff1_n;
                            loc_pend <= 1'b0;
                            if (brem != 7'd0) bset <= brem;            // store not ready: retry
                            else              {bh, bu, bset} <= b_next;
                        end
                    endcase
                    if (acc) begin
                        xs   <= X_S0;
                        prmw <= 4'd0;
                        wc   <= wc + 2'd1;
                        if (wc == 2'd3) begin
                            state <= S_IDLE;
                            done  <= 1'b1;
                        end
                    end
                    // $mb / $nb: 12 bits of word 0 ($mb) or word 1 ($lmb) of the MSB long word
                    if (active && beat[5]) bar0 <= (wwl[2] == 2'b00) ? wd[43:32] : wd[11:0];
                    if (active && beat[6]) bar1 <= (wwl[3] == 2'b00) ? wd[43:32] : wd[11:0];
                end
            endcase
        end
    end
endmodule

// mn_core: the MN-Core of the reduced topology: instruction memory, sequencer and one PE (the
// 1-PE mode, WP20) or one MAB of 4 PEs on a time-multiplexed datapath (N_PE = 4, WP30), and with
// M2 = 1 (WP37) the L1BM, the L2BM and the MV unit of one L1B / L2B / group (the M2 topology,
// contract 06 section 3: N_L2B = N_L1B = N_MAB = 1).
//
// The ports are the core side of brd_host_if (rtl/board/PROTOCOL.md section 5): memory
// write / read ports (mw_*, mr_*), RUN control and status, and with M2 = 1 the SDRAM bus of the
// PDM / DRAM (sd_*, contract 06 section 6; sdr_bus64 at the board top). Connect rst to the system
// reset OR brd_host_if's core_rst. Single clock.
//
// N_PE = 4 (WP30): the PEs are n?c?b?m?p0..p3 of the MAB at PE_LOC (PE_LOC[1:0] = 0); mn_mab
// runs each word on the 4 PEs (rtl/mab/mn_mab.v: check-only pass, msl / msr / bfn / bfe,
// normal pass). The PE spaces exist at the 4 locations; the clear after reset covers the 4 PEs.
// LM_AW = 8 keeps the 4 PEs' memories in 16 BSRAM (contract LM_DEPTH 256). BFN = 0 leaves the
// block-float unit out (bfn / bfe stop with E_UNSUPPORTED). An E_RANGE stops the word before
// any PE writes; core_trap is the detail of the PE that trapped (its number is mn_mab's
// trap_pe, not a port of mn_core, whose ports stay those of brd_host_if).
// MAT = 1 (N_PE = 4, WP36) adds the matrix register of the MAB (rtl/mab/mn_mab_mat.v): ?mwrite,
// ?mread / $mreadf and the matrix MAU in f / g / h (d stays E_UNSUPPORTED pe_mauc_dmode). The
// matrix register is cleared by reset (like the official emulator's initial state); it has no
// host space.
//
// M2 = 1 (N_PE = 4, WP37): the units of the L1B n?c?b? (PE_LOC[15:6]), its L2B and its group:
//   - mn_l1bm (N_MAB = 1, RRN L1_RRN): the L1BM, $lbi, $lbf and the PE <-> L1BM transfers;
//   - mn_l2bm (N_L1B = 1, RRN L2_RRN, DAR L2_DAR): the L2BM, the L2BM instructions (and DAR);
//   - mn_mv: the m words between the L2BM and the PDM / DRAM in the SDRAM (sd_*), the MV tags.
//   REPLICA = 1: the replica rule of mncore/wp/WP-3x.md in mn_l1bm and mn_l2bm (absent MABs /
//   L1Bs are copies of the implemented ones in reductions and gathers); 0 (default): the zero rule
//   of contract 06 section 3.
//   A j word with an L1BM / L2BM part (the decoder's L1BM group, mn_l2bm act): E_RANGE first when
//   a unit's range check fails (chk_trap; nothing runs); else mn_mab runs its check-only pass on
//   the 4 PEs (E_RANGE, then E_UNSUPPORTED with the units' chk_unsup), then starts the units (its
//   ugo) and runs the normal pass, where the PEs give their PE -> L1BM operands and take their L1BM
//   -> PE values; then mn_l2bm's first half ends (pre_done), mn_l1bm commits (its L1BM / $lbi
//   writes), and mn_l2bm commits (its L1BM writes): the order of the official emulator inside a
//   word (rtl/l1bm/README.md, rtl/l2bm/README.md). Other executed j words pulse mn_l2bm's skip.
//   An L2BM word waits until no MV runs (the official completes an MV at its issue); PE / L1BM
//   words run while an MV transfers in the background.
//   m word (valid): started on mn_mv when it is ready; its check gives OK (the transfer goes on in
//   the background), E_RANGE (info = entry) or E_UNSUPPORTED (info = 0x80 | m field). valid = 0
//   is skipped.
//   wait (j word with wd != 0, also ll = 00): after the MVs before it complete, one completion of
//   the tag is taken and the word runs; none stops the RUN with reason 4 WAIT (info = the tag: the
//   official blocks for ever there, the rest of the program does not run); two or more stop with
//   E_UNSUPPORTED wd (the official aborts).
//   The RUN ends (core_busy = 0) when the MV in flight is complete (PROTOCOL.md: all issued work).
//   Host spaces: 0x06 L1BM (loc = the L1B, m = p = 0) through mn_l1bm's port B, shared with
//   mn_l2bm's L1BM port during a RUN; 0x07 L2BM, 0x08 PDM, 0x09 DRAM through mn_mv (loc 0).
//   Reset: the units clear the L1BM / $lbi, the L2BM (and DAR) and the MV tags; with SDCLR = 1
//   the DRAM and PDM ranges of the SDRAM are written with 0 (the official starts them at 0), the
//   host's MV spaces and a RUN wait for it. The SDRAM controller itself is not reset by the core.
//
// Instruction memory (space 0x00 IMEM): 2**IMEM_AW entries of 448 bits (PROTOCOL.md section 3:
//   [447:446] type 01 j / 10 m, [425:0] jw, m words in [81:0]); lane k (0..6) of entry e is
//   long word e*8 + k. Stored as {type, jw} = 428 bits (12 BSRAM for 512 entries). Lanes 0..5
//   are staged in registers and the entry is written with lane 6, so an entry is written
//   whole, lanes 0..6 in order (WR_IMEM does this; mask must be 0xFF). Reading IMEM back
//   (RD_MEM space 0) is optional (IMEM_RD = 1); otherwise mr_err.
// PE spaces (location PE_LOC only, or PE_LOC + p for p < N_PE; loc = n<<10 | c<<9 | b<<6 |
//   m<<2 | p): 0x01 LM0, 0x02 LM1, 0x03 GRF0, 0x04 GRF1, 0x05 T, 0x10 OMR, 0x11 BAR (mn_pe_lsu
//   host port, mn_mab_mem with 4 PEs). Other spaces and locations are rejected (mw_err /
//   mr_err). The ports are served only while not running.
//
// Reset (rst, e.g. the RESET command): clears the sequencers and, with CLEAR = 1, then writes
//   0 to the whole PE state through the PE host port (GRF0, GRF1, LM0, LM1, T, OMR 1..15,
//   $mb/$nb of each PE; one long word per clock, N_PE * (2*2**GRF_AW + 2*2**LM_AW + 26)
//   clocks), like the official emulator's initial state (PROTOCOL.md: only RESET clears the
//   architectural state). During the clear mw_ready / mr_ready are 0 (requests wait) and
//   core_busy stays 0; a RUN that arrives meanwhile starts after it. The forwarding registers
//   are not cleared (reading one before its unit ran is an error in the emulator).
//
// RUN(start, count): executes entries start .. start+count-1 in order, then stops.
//   - j word, ll = 01 / 11: one PE step (mn_pe_core), on the 4 PEs with N_PE = 4.
//   - j word, ll = 00 (nop): nothing. Without the MV unit (M2 = 0) its wait field (wd) is
//     ignored: there is nothing to wait for (the official emulator blocks for ever on a wait for
//     a tag that was never issued, also in an ll = 00 word; WP20 report).
//   - j word, ll = 10: E_DECODE, info 0.
//   - m word: M2 = 0: E_UNSUPPORTED (no MV unit), info 0x80 (m field 0, valid); an m word with
//     valid = 0 is skipped. M2 = 1: see above.
//   - entry type 00 / 11: E_DECODE, info 0x100 | type. pc beyond IMEM: E_DECODE, info 0x200.
//   Stop record (valid while core_busy = 0): core_reason 0 OK / 1 E_RANGE / 2 E_UNSUPPORTED /
//   3 E_DECODE / 4 WAIT (M2); core_pc = the entry that stopped, or the next one after OK;
//   core_steps = entries completed in this RUN; core_info = E_RANGE: entry number of the word,
//   E_UNSUPPORTED: field index (bit 7 = m word field; j fields MN_J_<field>_IDX, m fields
//   MN_M_<field>_IDX), E_DECODE: see above, WAIT: the tag. core_trap = E_RANGE detail of a PE
//   memory {write, memory (0 GRF0, 1 GRF1, 2 LM0, 3 LM1), cycle, word address}.
// The architectural state (memories, T, masks, $mb/$nb, forwarding registers, L1BM, $lbi,
// $lbf, L2BM, DAR, PDM, DRAM, MV tags) stays across RUNs.
// FPALU = 0 / MAU = 0 leave the FP-side ALU / the MAU out (area); their instructions then stop
// with E_UNSUPPORTED pe_aluc_aluop / pe_mauc_enfma (mn_pe_core). FPALU = 2 is the FP ALU without
// floor / ftoi, FPALU = 3 also without fmax / fmin (WP21 area options; mn_pe_core).
`default_nettype none
module mn_core #(
    parameter IMEM_AW = 9,           // instruction memory: 2**IMEM_AW entries
    parameter IMEM_RD = 0,           // 1: RD_MEM can read the instruction memory back
    parameter LM_AW   = 9,           // LM0/LM1: 2**LM_AW long words
    parameter GRF_AW  = 8,           // GRF0/GRF1: 2**GRF_AW long words
    parameter CLEAR   = 1,           // 1: clear the PE state after reset
    parameter FPALU   = 1,           // FP-side ALU: 1 full, 0 none, 2 / 3 reduced (mn_pe_core)
    parameter MAU     = 1,           // 0: no MAU (mn_mau_vec)
    parameter N_PE    = 1,           // 1: one PE (M1); 4: one MAB, time-multiplexed (WP30)
    /* verilator lint_off UNUSEDPARAM */
    // the MAB's and the units' parameters: only read by the generate blocks of N_PE = 4 (a 1-PE
    // build without the files of mn_mab and the units does not see those reads)
    parameter BFN     = 1,           // N_PE = 4: bfn / bfe (mn_fp_alu_bfn)
    parameter MAT     = 0,           // N_PE = 4: matrix register, ?mwrite / ?mread / matrix MAU (WP36)
    parameter M2      = 0,           // N_PE = 4: the L1BM, L2BM and MV units (WP37)
    parameter L1_RRN  = 2,           // M2: mn_l1bm RRN (2: the small N_MAB = 1 reductions)
    parameter L2_RRN  = 2,           // M2: mn_l2bm RRN (2: the small N_L1B = 1 reductions)
    parameter L2_DAR  = 0,           // M2: mn_l2bm DAR (1: DAR and DAR buffer, BSRAM 3)
    parameter REPLICA = 0,           // M2: 1 the replica rule, 0 the zero rule (WP-3x)
    parameter L1_AW   = 10,          // M2: L1BM 2**L1_AW long words (contract L1BM_DEPTH)
    parameter L2_AW   = 11,          // M2: L2BM 2**L2_AW long words (contract L2BM_DEPTH)
    parameter PDM_AW  = 17,          // M2: PDM 2**PDM_AW long words (contract PDM_DEPTH)
    parameter DRAM_AW = 19,          // M2: DRAM 2**DRAM_AW long words (contract DRAM_DEPTH)
    parameter [19:0] PDM_BASE  = 20'h80000,   // M2: PDM / DRAM in the SDRAM (long words)
    parameter [19:0] DRAM_BASE = 20'h00000,
    parameter SDCLR   = 0,           // M2: 1 write 0 to the DRAM and PDM after reset
    /* verilator lint_on UNUSEDPARAM */
    parameter [15:0] PE_LOC = 16'h0  // location of the PE (n0c0b0m0p0), or of PE 0 of the MAB
) (
    input  wire         clk,
    input  wire         rst,
    // memory write port
    input  wire         mw_valid,
    output wire         mw_ready,
    output wire         mw_err,
    input  wire [7:0]   mw_space,
    input  wire [15:0]  mw_loc,
    input  wire [22:0]  mw_addr,
    input  wire [63:0]  mw_data,
    input  wire [7:0]   mw_mask,
    // memory read port
    input  wire         mr_valid,
    output wire         mr_ready,
    output wire         mr_err,
    input  wire [7:0]   mr_space,
    input  wire [15:0]  mr_loc,
    input  wire [22:0]  mr_addr,
    output wire         mr_rsp_valid,
    output wire [63:0]  mr_rsp_data,
    // run control / status
    input  wire         run_start,
    input  wire [15:0]  run_pc,
    input  wire [31:0]  run_count,
    output wire         core_busy,
    output wire [7:0]   core_reason,
    output wire [31:0]  core_info,
    output wire [15:0]  core_pc,
    output wire [31:0]  core_steps,
    output wire [16:0]  core_trap,
    // SDRAM bus of the PDM / DRAM (M2; sdr_bus64, contract 06 section 6)
    output wire         sd_req_valid,
    input  wire         sd_req_ready,
    output wire         sd_req_we,
    output wire [22:0]  sd_req_addr,
    output wire [63:0]  sd_req_wdata,
    output wire [7:0]   sd_req_wmask,
    input  wire         sd_rsp_valid,
    input  wire [63:0]  sd_rsp_rdata,
    input  wire         sd_err_addr,
    // indicators (M2): an MV runs or the SDRAM is being cleared; an SDRAM address error (sticky)
    output wire         unit_busy,
    output wire         unit_err
);
`include "mn_jfields.vh"
`include "mn_mfields.vh"

    localparam MU = (M2 != 0) && (N_PE > 1);   // the L1BM / L2BM / MV units
    localparam [2:0] R_OK = 3'd0, R_RANGE = 3'd1, R_UNSUP = 3'd2, R_DECODE = 3'd3, R_WAIT = 3'd4;
    localparam [7:0] SP_IMEM = 8'h00;
    localparam [16:0] DEPTH = 17'd1 << IMEM_AW;

    // ------------------------------------------------------------------ state
    localparam [3:0] S_IDLE = 4'd0, S_FETCH = 4'd1, S_DEC = 4'd2, S_EXEC = 4'd3, S_WT = 4'd4,
                     S_JX = 4'd5, S_PE = 4'd6, S_L2P = 4'd7, S_L1C = 4'd8, S_L2C = 4'd9,
                     S_MS = 4'd10, S_MA = 4'd11, S_END = 4'd12;
    // where a stop or the last entry goes: with the MV unit, S_END waits for the MV in flight
    localparam [3:0] S_STOP = MU ? S_END : S_IDLE;
    reg  [3:0]  s;
    reg  [15:0] pc;
    reg  [31:0] left;
    reg  [15:0] steps;      // a RUN stops at the end of IMEM, so it never runs 2**16 entries
    reg  [2:0]  reason;
    reg  [15:0] info;       // the upper half of core_info is always 0
    reg         clr;        // clearing the PE state after reset
    reg         run_pend;   // RUN received during the clear
    wire        busy = (s != S_IDLE);
    wire        units_rdy;  // the units have cleared their memories after reset (M2)
    wire        sd_clr;     // the DRAM / PDM are being cleared (M2, SDCLR)

    assign core_busy   = busy | run_pend;
    assign core_reason = {5'd0, reason};
    assign core_info   = {16'd0, info};
    assign core_pc     = pc;
    assign core_steps  = {16'd0, steps};

    // ------------------------------------------------------------------ instruction memory
    wire [19:0] depth20 = {3'd0, DEPTH};
    wire [2:0]  w_lane  = mw_addr[2:0];
    wire [19:0] w_entry = mw_addr[22:3];
    wire        w_im    = (mw_space == SP_IMEM);
    wire        w_im_ok = (mw_loc == 16'd0) && (w_lane != 3'd7) && (w_entry < depth20) &&
                          (mw_mask == 8'hFF);
    reg [383:0] stage;
    wire        im_wr   = mw_valid & ~busy & ~clr & w_im & w_im_ok;
    genvar      gl;
    generate
        // one register per lane with a constant index: clock-enabled FFs, no shifter
        for (gl = 0; gl < 6; gl = gl + 1) begin : g_stage
            always @(posedge clk) begin
                if (im_wr && (w_lane == gl)) stage[64*gl +: 64] <= mw_data;
            end
        end
    endgenerate
    wire [2:0]  r_lane  = mr_addr[2:0];
    wire [19:0] r_entry = mr_addr[22:3];
    wire        r_im    = (mr_space == SP_IMEM);
    wire        r_im_ok = (IMEM_RD != 0) && (mr_loc == 16'd0) && (r_lane != 3'd7) &&
                          (r_entry < depth20);
    wire        im_rd   = mr_valid & ~busy & ~clr & r_im & r_im_ok;

    wire [427:0] imem_q;
    wire         imem_re = (s == S_FETCH) | im_rd;
    wire [IMEM_AW-1:0] imem_ra = busy ? pc[IMEM_AW-1:0] : r_entry[IMEM_AW-1:0];
    mn_ram_1r1w #(.W(428), .AW(IMEM_AW), .NWE(1), .OREG(0)) u_imem (
        .clk(clk), .we(im_wr & (w_lane == 3'd6)), .waddr(w_entry[IMEM_AW-1:0]),
        .wdata({mw_data[63:62], mw_data[41:0], stage}),
        .re(imem_re), .raddr(imem_ra), .rdata(imem_q));

    // IMEM read-back response (IMEM_RD), one clock after the request
    wire        im_rsp;
    wire [63:0] im_data;
    generate
        if (IMEM_RD != 0) begin : g_imrd
            reg       rsp_q;
            reg [2:0] lane_q;
            always @(posedge clk) begin
                if (rst) rsp_q <= 1'b0;
                else     rsp_q <= im_rd;
                if (im_rd) lane_q <= r_lane;
            end
            wire [447:0] ent = {imem_q[427:426], 20'd0, imem_q[425:0]};
            assign im_rsp  = rsp_q;
            assign im_data = ent[64*lane_q +: 64];
        end else begin : g_noimrd
            assign im_rsp  = 1'b0;
            assign im_data = 64'd0;
        end
    endgenerate

    // ------------------------------------------------------------------ clear after reset
    // GRF0, GRF1, LM0, LM1, T, OMR (entries 0..15; entry 0 is read-only and ignores the write),
    // BAR: one long word per clock through the PE host port
    localparam [10:0] GRF_LAST = (11'd1 << GRF_AW) - 11'd1;
    localparam [10:0] LM_LAST  = (11'd1 << LM_AW) - 11'd1;
    localparam [31:0] PE_LAST32 = N_PE - 1;
    localparam [1:0]  PE_LAST  = PE_LAST32[1:0];
    reg  [2:0]  clr_sp;
    reg  [10:0] clr_a;
    reg  [1:0]  clr_pe;
    wire [7:0]  clr_space = (clr_sp == 3'd0) ? 8'h03 : (clr_sp == 3'd1) ? 8'h04 :
                            (clr_sp == 3'd2) ? 8'h01 : (clr_sp == 3'd3) ? 8'h02 :
                            (clr_sp == 3'd4) ? 8'h05 : (clr_sp == 3'd5) ? 8'h10 : 8'h11;
    wire [10:0] clr_last  = (clr_sp <= 3'd1) ? GRF_LAST : (clr_sp <= 3'd3) ? LM_LAST :
                            (clr_sp == 3'd4) ? 11'd7 : (clr_sp == 3'd5) ? 11'd15 : 11'd1;

    // ------------------------------------------------------------------ PE
    wire         pe_ready, pe_done, pe_start;
    wire [1:0]   pe_st;
    wire [6:0]   pe_field;
    wire         hp_req_valid, hp_req_ready, hp_req_err, hp_rsp_valid;
    wire [63:0]  hp_rsp_rdata;

    always @(posedge clk) begin
        if (rst) begin
            clr    <= (CLEAR != 0);
            clr_sp <= 3'd0;
            clr_a  <= 11'd0;
            clr_pe <= 2'd0;
        end else if (clr && hp_req_ready) begin
            if (clr_a == clr_last) begin
                clr_a  <= 11'd0;
                clr_sp <= clr_sp + 3'd1;
                if (clr_sp == 3'd6) begin
                    clr_sp <= 3'd0;
                    clr_pe <= clr_pe + 2'd1;
                    if (clr_pe == PE_LAST) clr <= 1'b0;
                end
            end else begin
                clr_a <= clr_a + 11'd1;
            end
        end
    end

    function is_pe_space(input [7:0] sp);
        is_pe_space = (sp == 8'h01) || (sp == 8'h02) || (sp == 8'h03) || (sp == 8'h04) ||
                      (sp == 8'h05) || (sp == 8'h10) || (sp == 8'h11);
    endfunction
    // the PE locations: PE_LOC (one PE) or the MAB PE_LOC[15:2] with p = 0..3 (N_PE = 4)
    function is_pe_loc(input [15:0] l);
        is_pe_loc = (N_PE > 1) ? (l[15:2] == PE_LOC[15:2]) : (l == PE_LOC);
    endfunction
    wire w_pe = is_pe_space(mw_space) && is_pe_loc(mw_loc);
    wire r_pe = is_pe_space(mr_space) && is_pe_loc(mr_loc);
    assign hp_req_valid = clr | (~busy & ((mw_valid & w_pe) | (mr_valid & r_pe)));
    wire [1:0] hp_pe = clr ? clr_pe : mw_valid ? mw_loc[1:0] : mr_loc[1:0];

    // ------------------------------------------------------------------ the units' host spaces (M2)
    // 0x06 L1BM at the L1B of the core (m = p = 0); 0x07 L2BM, 0x08 PDM, 0x09 DRAM (mn_mv, loc 0)
    wire [15:0] l1_loc = {PE_LOC[15:6], 6'd0};
    wire w_l1 = MU & (mw_space == 8'h06);
    wire r_l1 = MU & (mr_space == 8'h06);
    wire w_mv = MU & ((mw_space == 8'h07) | (mw_space == 8'h08) | (mw_space == 8'h09));
    wire r_mv = MU & ((mr_space == 8'h07) | (mr_space == 8'h08) | (mr_space == 8'h09));
    wire w_l1_ok = (mw_loc == l1_loc), r_l1_ok = (mr_loc == l1_loc);
    wire l1h_ready, l1h_err, l1h_rsp;            // L1BM port B for the host
    wire [63:0] l1h_data;
    wire mvh_w_ready, mvh_w_err, mvh_r_ready, mvh_r_err, mvh_rsp;
    wire [63:0] mvh_data;

    assign mw_ready = ~busy & ~clr & (w_pe ? hp_req_ready : w_l1 ? (~w_l1_ok | l1h_ready) :
                                      w_mv ? (~sd_clr & mvh_w_ready) : 1'b1);
    assign mw_err   = w_pe ? hp_req_err : w_im ? ~w_im_ok : w_l1 ? (~w_l1_ok | l1h_err) :
                      w_mv ? mvh_w_err : 1'b1;
    assign mr_ready = ~busy & ~clr & (r_pe ? hp_req_ready : r_l1 ? (~r_l1_ok | l1h_ready) :
                                      r_mv ? (~sd_clr & mvh_r_ready) : 1'b1);
    assign mr_err   = r_pe ? hp_req_err : r_im ? ~r_im_ok : r_l1 ? (~r_l1_ok | l1h_err) :
                      r_mv ? mvh_r_err : 1'b1;
    assign mr_rsp_valid = hp_rsp_valid | im_rsp | l1h_rsp | mvh_rsp;
    assign mr_rsp_data  = hp_rsp_valid ? hp_rsp_rdata : l1h_rsp ? l1h_data : mvh_rsp ? mvh_data : im_data;

    wire [425:0] jw = imem_q[425:0];
    wire         trap_wr;
    wire [1:0]   trap_mem, trap_cycle;
    wire [11:0]  trap_addr;
    assign core_trap = {trap_wr, trap_mem, trap_cycle, trap_addr};

    wire [7:0]   hp_space = clr ? clr_space : mw_valid ? mw_space : mr_space;
    wire [22:0]  hp_addr  = clr ? {12'd0, clr_a} : mw_valid ? mw_addr : mr_addr;
    wire [63:0]  hp_wdata = mw_data & {64{~clr}};
    wire [7:0]   hp_wmask = mw_mask | {8{clr}};

    // the units' signals of the PE datapath (M2)
    wire         ugo;
    wire [1:0]   cur_pe;
    wire         x_act, x_unsup;
    wire [6:0]   x_field;
    wire         lu_src, lu_lbf, ls_we, lr_req, lr_ready, lr_valid, lb_we;
    wire [1:0]   ls_cycle, lr_cycle, lb_rcycle, lb_wcycle;
    wire [127:0] ls_data, lr_data, lb_rdata, lb_wdata;
    generate
        if (N_PE == 1) begin : g_pe
            // one PE (M1): mn_pe_core as in WP20 (the files of the 1-PE builds stay the same)
            /* verilator lint_off UNUSEDSIGNAL */
            // xg_* / xpe_op / prechk / the matrix unit's / the L1BM unit's ports: only for N_PE = 4;
            // hp_pe: one PE
            wire         u_xg_valid, u_prechk;
            wire [1:0]   u_xg_cycle, u_xz_cycle, u_xpe_op;
            wire [127:0] u_xg_x;
            wire [1:0]   unused_hp_pe = hp_pe;
            wire         u_mg_valid, u_mt_req, u_mw_req, u_mr_req, u_mr_acc, u_mr_upd, u_ma_upd, u_fr_req;
            wire         u_fr_sel, u_fr_acc;
            wire [1:0]   u_mg_cycle, u_mt_cycle, u_mr_cycle, u_fr_cycle;
            wire [63:0]  u_mg_x;
            wire [127:0] u_mt_y, u_mw_b;
            wire [7:0]   u_mr_hen, u_ma_hen;
            /* verilator lint_on UNUSEDSIGNAL */
            mn_pe_core #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .FPALU(FPALU), .MAU(MAU),
                         .POS_N({30'd0, PE_LOC[11:10]}), .POS_C({31'd0, PE_LOC[9]}), .POS_B({29'd0, PE_LOC[8:6]}),
                         .POS_M({28'd0, PE_LOC[5:2]}), .POS_P({30'd0, PE_LOC[1:0]})) u_pe (
                .clk(clk), .rst(rst),
                .start(pe_start), .ready(pe_ready), .jw(jw), .pe(2'd0), .rd_only(1'b0),
                .done(pe_done), .st(pe_st), .st_field(pe_field),
                .trap_wr(trap_wr), .trap_mem(trap_mem), .trap_cycle(trap_cycle), .trap_addr(trap_addr),
                .xpe_op(u_xpe_op), .prechk(u_prechk), .xg_valid(u_xg_valid), .xg_cycle(u_xg_cycle),
                .xg_x(u_xg_x), .xz_cycle(u_xz_cycle), .xz_z(128'd0),
                .mg_valid(u_mg_valid), .mg_cycle(u_mg_cycle), .mg_x(u_mg_x),
                .mt_req(u_mt_req), .mw_req(u_mw_req), .mt_cycle(u_mt_cycle), .mt_y(u_mt_y), .mw_b(u_mw_b),
                .mt_done(1'b0), .mt_z(128'd0), .mt_flags(4'd0), .mw_done(1'b0),
                .mr_req(u_mr_req), .mr_cycle(u_mr_cycle), .mr_rdy(1'b0), .mr_val(128'd0),
                .mr_acc(u_mr_acc), .mr_upd(u_mr_upd), .mr_hen(u_mr_hen), .ma_upd(u_ma_upd), .ma_hen(u_ma_hen),
                .fr_req(u_fr_req), .fr_sel(u_fr_sel), .fr_cycle(u_fr_cycle), .fr_rdy(1'b0), .fr_val(128'd0),
                .fr_acc(u_fr_acc),
                .x_act(1'b0), .x_unsup(1'b0), .x_field(7'd0), .lu_src(1'b0), .lu_lbf(1'b0),
                .ls_we(ls_we), .ls_cycle(ls_cycle), .ls_data(ls_data),
                .lr_req(lr_req), .lr_ready(1'b0), .lr_cycle(lr_cycle), .lr_valid(1'b0), .lr_data(128'd0),
                .lb_rcycle(lb_rcycle), .lb_rdata(128'd0), .lb_we(lb_we), .lb_wcycle(lb_wcycle),
                .lb_wdata(lb_wdata),
                .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(clr | mw_valid),
                .hp_pe(2'd0), .hp_req_space(hp_space), .hp_req_addr(hp_addr), .hp_req_wdata(hp_wdata),
                .hp_req_wmask(hp_wmask), .hp_req_err(hp_req_err),
                .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata)
            );
            assign ugo    = 1'b0;
            assign cur_pe = 2'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            // one PE has no units (M2 needs N_PE = 4): their answers have no reader
            wire unused_pe1 = ^{x_act, x_unsup, x_field, lu_src, lu_lbf, lr_ready, lr_valid, lr_data, lb_rdata};
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_mab
            // the 4 PEs of a MAB on one time-multiplexed datapath (WP30)
            /* verilator lint_off UNUSEDSIGNAL */
            wire [1:0] trap_pe;   // the PE of an E_RANGE (not a port: the ports are brd_host_if's)
            /* verilator lint_on UNUSEDSIGNAL */
            mn_mab #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .FPALU(FPALU), .MAU(MAU), .N_PE(N_PE), .BFN(BFN),
                     .MAT(MAT), .BM(MU ? 1 : 0),
                     .POS_N({30'd0, PE_LOC[11:10]}), .POS_C({31'd0, PE_LOC[9]}), .POS_B({29'd0, PE_LOC[8:6]}),
                     .POS_M({28'd0, PE_LOC[5:2]}), .POS_P(0)) u_mab (
                .clk(clk), .rst(rst),
                .start(pe_start), .ready(pe_ready), .jw(jw), .done(pe_done), .st(pe_st), .st_field(pe_field),
                .trap_wr(trap_wr), .trap_mem(trap_mem), .trap_cycle(trap_cycle), .trap_addr(trap_addr),
                .trap_pe(trap_pe),
                .ugo(ugo), .cur_pe(cur_pe), .x_act(x_act), .x_unsup(x_unsup), .x_field(x_field),
                .lu_src(lu_src), .lu_lbf(lu_lbf), .ls_we(ls_we), .ls_cycle(ls_cycle), .ls_data(ls_data),
                .lr_req(lr_req), .lr_ready(lr_ready), .lr_cycle(lr_cycle), .lr_valid(lr_valid), .lr_data(lr_data),
                .lb_rcycle(lb_rcycle), .lb_rdata(lb_rdata), .lb_we(lb_we), .lb_wcycle(lb_wcycle),
                .lb_wdata(lb_wdata),
                .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(clr | mw_valid),
                .hp_pe(hp_pe), .hp_req_space(hp_space), .hp_req_addr(hp_addr), .hp_req_wdata(hp_wdata),
                .hp_req_wmask(hp_wmask), .hp_req_err(hp_req_err),
                .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata)
            );
        end
    endgenerate

    // ------------------------------------------------------------------ the entry
    wire [1:0] e_type = imem_q[427:426];
    wire [1:0] e_ll   = imem_q[425:424];   // `MN_J_LL
    wire [7:0] e_wd   = `MN_J_WD(jw);
    wire       e_mval = imem_q[81];        // `MN_M_VALID
    wire       e_exec = (e_type == 2'b01) & e_ll[0];
    wire       pc_ok  = ({1'b0, pc} < DEPTH);
    localparam [31:0] I_MV32 = 32'h80 | MN_M_VALID_IDX;
    localparam [31:0] I_LL32 = MN_J_LL_IDX, I_WD32 = MN_J_WD_IDX, I_MF32 = 32'h80;
    localparam [15:0] I_MV = I_MV32[15:0], I_LL = I_LL32[15:0], I_WD = I_WD32[15:0], I_MF = I_MF32[15:0];

    // ------------------------------------------------------------------ the units (M2)
    reg          l1_start, l1_commit, l2_start, l2_commit, l2_skip, mv_start, wt_take;
    wire         l1_act, l2_act, l1_trap, l2_trap, l1_idle, l2_idle, l1_done, l2_done, l2_pre;
    wire         mv_ready, mv_acc, mv_busy;
    wire [1:0]   mv_acc_st, mv_wt_cnt;
    wire [3:0]   mv_acc_field;
    generate
        if (MU) begin : g_units
            // ---- the L1BM / L2BM fields of the word (mn_pe_core decodes the PE fields)
            wire [1:0]  d_ll, d_bmode, d_bdmode, d_l2dmode;
            wire        d_lwrite, d_rmode, d_me, d_dmode, d_ext, d_rout, d_wl;
            wire        d_gwrite, d_l2lwrite, d_darsend, d_darwrite;
            wire [12:0] d_ladr;
            wire [3:0]  d_mabadr, d_opcode, d_l2opcode;
            wire [2:0]  d_isel, d_l1adr, d_immode;
            wire [9:0]  d_gadr;
            wire [10:0] d_l2ladr;
            wire [14:0] d_grp;
            /* verilator lint_off PINMISSING */
            // only the fields of the units (the decoder has an output for every field)
            mn_dec_j u_dec (
                .jw(jw), .ll(d_ll),
                .l1bm_bmode(d_bmode), .l1bm_lwrite(d_lwrite), .l1bm_rmode(d_rmode), .l1bm_me(d_me),
                .l1bm_ladr(d_ladr), .l1bm_dmode(d_dmode), .l1bm_ext(d_ext), .l1bm_round_out(d_rout),
                .l1bm_mabadr(d_mabadr), .l1bm_opcode(d_opcode), .l1bm_isel(d_isel), .l1bm_wl(d_wl),
                .l1bm_gwrite(d_gwrite), .l1bm_gadr(d_gadr), .l2bm_lwrite(d_l2lwrite), .l2bm_bdmode(d_bdmode),
                .l2bm_ladr(d_l2ladr), .l2bm_l1adr(d_l1adr), .l2bm_immode(d_immode), .l2bm_dmode(d_l2dmode),
                .l2bm_opcode(d_l2opcode), .l2bm_darsend(d_darsend), .l2bm_darwrite(d_darwrite),
                .grp(d_grp));
            /* verilator lint_on PINMISSING */
            // the word has an L1BM part (an L1BM field not at its default, or a destination with
            // isel 10; ll = 01 / 11) / an L2BM instruction (mn_l2bm act)
            assign l1_act = d_grp[MN_J_GRP_L1BM];
            assign x_act  = l1_act | l2_act;

            // ---- L1BM unit (L1B of the core; one MAB)
            wire        l1_unsup, l2_unsup;
            wire [6:0]  l1_field, l2_field;
            wire        l1_res_ready, l1_res_valid;
            wire [127:0] l1_res_data;
            wire [12:0] l1_chk_addr;
            wire        b_valid, b_ready, b_we, b_err, b_rsp;
            wire [22:0] b_addr;
            wire [63:0] b_wdata, b_rdata;
            wire [7:0]  b_wmask;
            wire        lb_req_valid, lb_req_we;
            wire [2:0]  lb_req_l1b;
            wire [22:0] lb_req_addr;
            wire [63:0] lb_req_wdata;
            wire [7:0]  lb_req_wmask;
            mn_l1bm #(.N_MAB(1), .AW(L1_AW), .RRN(L1_RRN), .CLEAR(1), .REPLICA(REPLICA)) u_l1 (
                .clk(clk), .rst(rst),
                .ll(d_ll), .l1bm_bmode(d_bmode), .l1bm_lwrite(d_lwrite), .l1bm_rmode(d_rmode), .l1bm_me(d_me),
                .l1bm_ladr(d_ladr), .l1bm_dmode(d_dmode), .l1bm_ext(d_ext), .l1bm_round_out(d_rout),
                .l1bm_mabadr(d_mabadr), .l1bm_opcode(d_opcode), .l1bm_isel(d_isel), .l1bm_wl(d_wl),
                .use_src(lu_src), .lbf_upd(lu_lbf), .chk_trap(l1_trap), .chk_addr(l1_chk_addr),
                .chk_unsup(l1_unsup), .chk_field(l1_field),
                .start(l1_start), .idle(l1_idle), .commit(l1_commit), .done(l1_done),
                .src_we(ls_we), .src_mab(4'd0), .src_pe(cur_pe), .src_cycle(ls_cycle), .src_data(ls_data),
                .res_req(lr_req), .res_ready(l1_res_ready), .res_mab(4'd0), .res_pe(cur_pe),
                .res_cycle(lr_cycle), .res_valid(l1_res_valid), .res_data(l1_res_data),
                .lbf_rmab(4'd0), .lbf_rpe(cur_pe), .lbf_rcycle(lb_rcycle), .lbf_rdata(lb_rdata),
                .lbf_we(lb_we), .lbf_wmab(4'd0), .lbf_wpe(cur_pe), .lbf_wcycle(lb_wcycle), .lbf_wdata(lb_wdata),
                .b_req_valid(b_valid), .b_req_ready(b_ready), .b_req_we(b_we), .b_req_addr(b_addr),
                .b_req_wdata(b_wdata), .b_req_wmask(b_wmask), .b_req_err(b_err),
                .b_rsp_valid(b_rsp), .b_rsp_rdata(b_rdata));
            assign lr_ready = l1_res_ready;
            assign lr_valid = l1_res_valid;
            assign lr_data  = l1_res_data;
            assign x_unsup  = l1_unsup | l2_unsup;
            assign x_field  = l1_unsup ? l1_field : l2_field;

            // port B: mn_l2bm's L1BM port during a RUN, the host's space 0x06 between RUNs
            wire h_l1  = ~busy & ~clr & ((mw_valid & w_l1 & w_l1_ok) | (mr_valid & ~mw_valid & r_l1 & r_l1_ok));
            assign b_valid = busy ? lb_req_valid : h_l1;
            assign b_we    = busy ? lb_req_we : mw_valid;
            assign b_addr  = busy ? lb_req_addr : (mw_valid ? mw_addr : mr_addr);
            assign b_wdata = busy ? lb_req_wdata : mw_data;
            assign b_wmask = busy ? lb_req_wmask : mw_mask;
            assign l1h_ready = ~busy & b_ready;
            assign l1h_err   = b_err;
            assign l1h_rsp   = ~busy & b_rsp;
            assign l1h_data  = b_rdata;

            // ---- L2BM unit (L2B of the core; one L1B)
            wire        cb_req_valid, cb_req_ready, cb_req_we, cb_req_err, cb_rsp_valid;
            wire [22:0] cb_req_addr;
            wire [63:0] cb_req_wdata, cb_rsp_rdata;
            wire [7:0]  cb_req_wmask;
            wire        dar_re;
            wire [9:0]  dar_raddr;
            wire [31:0] dar_rdata;
            mn_l2bm #(.N_L1B(1), .AW(L2_AW), .L1AW(L1_AW), .RRN(L2_RRN), .DAR(L2_DAR), .CLEAR(1),
                      .REPLICA(REPLICA)) u_l2 (
                .clk(clk), .rst(rst),
                .ll(d_ll), .l1bm_gwrite(d_gwrite), .l1bm_gadr(d_gadr), .l2bm_lwrite(d_l2lwrite),
                .l2bm_bdmode(d_bdmode), .l2bm_ladr(d_l2ladr), .l2bm_l1adr(d_l1adr), .l2bm_immode(d_immode),
                .l2bm_dmode(d_l2dmode), .l2bm_opcode(d_l2opcode), .l2bm_darsend(d_darsend),
                .l2bm_darwrite(d_darwrite),
                .l1bm_bmode(d_bmode), .l1bm_lwrite(d_lwrite), .l1bm_me(d_me), .l1bm_ladr(d_ladr), .l1bm_wl(d_wl),
                .act(l2_act), .chk_trap(l2_trap), .chk_unsup(l2_unsup), .chk_field(l2_field),
                .start(l2_start), .idle(l2_idle), .pre_done(l2_pre), .commit(l2_commit), .done(l2_done),
                .skip(l2_skip),
                .lb_req_valid(lb_req_valid), .lb_req_ready(busy & b_ready), .lb_req_l1b(lb_req_l1b),
                .lb_req_we(lb_req_we), .lb_req_addr(lb_req_addr), .lb_req_wdata(lb_req_wdata),
                .lb_req_wmask(lb_req_wmask), .lb_req_err(busy & b_err), .lb_rsp_valid(busy & b_rsp),
                .lb_rsp_rdata(b_rdata),
                .b_req_valid(cb_req_valid), .b_req_ready(cb_req_ready), .b_req_we(cb_req_we),
                .b_req_addr(cb_req_addr), .b_req_wdata(cb_req_wdata), .b_req_wmask(cb_req_wmask),
                .b_req_err(cb_req_err), .b_rsp_valid(cb_rsp_valid), .b_rsp_rdata(cb_rsp_rdata),
                .dar_re(dar_re), .dar_raddr(dar_raddr), .dar_rdata(dar_rdata));

            // ---- MV unit (the group of the core: its L2BM, PDM and DRAM)
            wire        mv_sd_valid, mv_sd_we, mv_err;
            wire [22:0] mv_sd_addr;
            wire [63:0] mv_sd_wdata;
            wire [7:0]  mv_sd_wmask;
            mn_mv #(.L2AW(L2_AW), .PDM_AW(PDM_AW), .DRAM_AW(DRAM_AW), .PDM_BASE(PDM_BASE),
                    .DRAM_BASE(DRAM_BASE)) u_mv (
                .clk(clk), .rst(rst),
                .start(mv_start), .mw(imem_q[81:0]), .ready(mv_ready), .acc(mv_acc), .acc_st(mv_acc_st),
                .acc_field(mv_acc_field), .busy(mv_busy),
                .wt_tag(e_wd), .wt_cnt(mv_wt_cnt), .wt_take(wt_take),
                .cb_req_valid(cb_req_valid), .cb_req_ready(cb_req_ready), .cb_req_we(cb_req_we),
                .cb_req_addr(cb_req_addr), .cb_req_wdata(cb_req_wdata), .cb_req_wmask(cb_req_wmask),
                .cb_req_err(cb_req_err), .cb_rsp_valid(cb_rsp_valid), .cb_rsp_rdata(cb_rsp_rdata),
                .dar_re(dar_re), .dar_raddr(dar_raddr), .dar_rdata(dar_rdata),
                .sd_req_valid(mv_sd_valid), .sd_req_ready(sd_req_ready & ~sd_clr), .sd_req_we(mv_sd_we),
                .sd_req_addr(mv_sd_addr), .sd_req_wdata(mv_sd_wdata), .sd_req_wmask(mv_sd_wmask),
                .sd_rsp_valid(sd_rsp_valid), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(sd_err_addr),
                .err_sdr(mv_err),
                .hw_valid(mw_valid & ~busy & ~clr & ~sd_clr & w_mv), .hw_ready(mvh_w_ready), .hw_err(mvh_w_err),
                .hw_space(mw_space), .hw_loc(mw_loc), .hw_addr(mw_addr), .hw_data(mw_data), .hw_mask(mw_mask),
                .hr_valid(mr_valid & ~busy & ~clr & ~sd_clr & r_mv), .hr_ready(mvh_r_ready), .hr_err(mvh_r_err),
                .hr_space(mr_space), .hr_loc(mr_loc), .hr_addr(mr_addr), .hr_rsp_valid(mvh_rsp),
                .hr_rsp_data(mvh_data));

            // ---- clear of the DRAM and PDM after reset (SDCLR): 0 into every long word, DRAM first
            if (SDCLR != 0) begin : g_sdclr
                localparam [20:0] D_LAST = (21'd1 << DRAM_AW) - 21'd1;
                localparam [20:0] P_LAST = (21'd1 << PDM_AW) - 21'd1;
                reg        sc_on, sc_pdm;
                reg [20:0] sc_a;
                always @(posedge clk) begin
                    if (rst) begin
                        sc_on  <= 1'b1;
                        sc_pdm <= 1'b0;
                        sc_a   <= 21'd0;
                    end else if (sc_on && sd_req_ready) begin
                        sc_a <= sc_a + 21'd1;
                        if (!sc_pdm && sc_a == D_LAST) begin
                            sc_pdm <= 1'b1;
                            sc_a   <= 21'd0;
                        end else if (sc_pdm && sc_a == P_LAST) begin
                            sc_on <= 1'b0;
                        end
                    end
                end
                assign sd_clr       = sc_on;
                assign sd_req_valid = sc_on | mv_sd_valid;
                assign sd_req_we    = sc_on | mv_sd_we;
                assign sd_req_addr  = sc_on ? {3'd0, (sc_pdm ? PDM_BASE : DRAM_BASE) | sc_a[19:0]} : mv_sd_addr;
                assign sd_req_wdata = sc_on ? 64'd0 : mv_sd_wdata;
                assign sd_req_wmask = sc_on ? 8'hff : mv_sd_wmask;
                /* verilator lint_off UNUSEDSIGNAL */
                wire unused_sc = sc_a[20];   // the counter's carry: the last address is compared
                /* verilator lint_on UNUSEDSIGNAL */
            end else begin : g_nosdclr
                assign sd_clr       = 1'b0;
                assign sd_req_valid = mv_sd_valid;
                assign sd_req_we    = mv_sd_we;
                assign sd_req_addr  = mv_sd_addr;
                assign sd_req_wdata = mv_sd_wdata;
                assign sd_req_wmask = mv_sd_wmask;
            end
            assign units_rdy = l1_idle & l2_idle & ~mv_busy & ~sd_clr;
            assign unit_busy = mv_busy | sd_clr;
            assign unit_err  = mv_err;
            /* verilator lint_off UNUSEDSIGNAL */
            // the decoder's other outputs; the unit's report address; one L1B (lb_req_l1b is 0)
            wire unused_u = ^{d_grp, l1_chk_addr, lb_req_l1b};
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_nounits
            assign l1_act = 1'b0;
            assign l2_act = 1'b0;
            assign l1_trap = 1'b0;
            assign l2_trap = 1'b0;
            assign l1_idle = 1'b1;
            assign l2_idle = 1'b1;
            assign l1_done = 1'b0;
            assign l2_done = 1'b0;
            assign l2_pre  = 1'b0;
            assign mv_ready = 1'b0;
            assign mv_acc   = 1'b0;
            assign mv_busy  = 1'b0;
            assign mv_acc_st = 2'd0;
            assign mv_wt_cnt = 2'd0;
            assign mv_acc_field = 4'd0;
            assign x_act    = 1'b0;
            assign x_unsup  = 1'b0;
            assign x_field  = 7'd0;
            assign lu_src   = 1'b0;
            assign lu_lbf   = 1'b0;
            assign lr_ready = 1'b0;
            assign lr_valid = 1'b0;
            assign lr_data  = 128'd0;
            assign lb_rdata = 128'd0;
            assign l1h_ready = 1'b0;
            assign l1h_err   = 1'b1;
            assign l1h_rsp   = 1'b0;
            assign l1h_data  = 64'd0;
            assign mvh_w_ready = 1'b0;
            assign mvh_w_err   = 1'b1;
            assign mvh_r_ready = 1'b0;
            assign mvh_r_err   = 1'b1;
            assign mvh_rsp     = 1'b0;
            assign mvh_data    = 64'd0;
            assign sd_clr       = 1'b0;
            assign units_rdy    = 1'b1;
            assign unit_busy    = 1'b0;
            assign unit_err     = 1'b0;
            assign sd_req_valid = 1'b0;
            assign sd_req_we    = 1'b0;
            assign sd_req_addr  = 23'd0;
            assign sd_req_wdata = 64'd0;
            assign sd_req_wmask = 8'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            // no units: their requests and the SDRAM bus have no reader
            wire unused_u = ^{ugo, cur_pe, ls_we, ls_cycle, ls_data, lr_req, lr_cycle, lb_rcycle, lb_we, lb_wcycle,
                              lb_wdata, l1_start, l1_commit, l2_start, l2_commit, l2_skip, mv_start, wt_take,
                              e_wd, w_l1_ok, r_l1_ok, sd_req_ready, sd_rsp_valid, sd_rsp_rdata, sd_err_addr};
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    // ------------------------------------------------------------------ sequencer
    // M2 = 0: S_DEC starts the PE word (S_EXEC). M2: S_DEC -> S_WT (wait) -> S_JX, which checks the
    // units' ranges and starts mn_mab when the units are idle (an L2BM word: also no MV running)
    wire hold   = clr | ~units_rdy;
    wire jx_go  = e_exec & pe_ready & l1_idle & l2_idle & ~(l2_act & mv_busy) & ~l1_trap & ~l2_trap;
    assign pe_start = MU ? ((s == S_JX) & jx_go) : ((s == S_DEC) & e_exec & pe_ready);

    always @(posedge clk) begin
        if (rst) begin
            s         <= S_IDLE;
            pc        <= 16'd0;
            left      <= 32'd0;
            steps     <= 16'd0;
            reason    <= R_OK;
            info      <= 16'd0;
            run_pend  <= 1'b0;
            l1_start  <= 1'b0;
            l1_commit <= 1'b0;
            l2_start  <= 1'b0;
            l2_commit <= 1'b0;
            l2_skip   <= 1'b0;
            mv_start  <= 1'b0;
            wt_take   <= 1'b0;
        end else begin
            l1_start  <= 1'b0;
            l1_commit <= 1'b0;
            l2_start  <= 1'b0;
            l2_commit <= 1'b0;
            l2_skip   <= 1'b0;
            mv_start  <= 1'b0;
            wt_take   <= 1'b0;
            case (s)
                S_IDLE: begin
                    if (hold) begin
                        if (run_start) run_pend <= 1'b1;
                    end else if (run_start || run_pend) begin
                        run_pend <= 1'b0;
                        pc       <= run_pc;
                        left     <= run_count;
                        steps    <= 16'd0;
                        reason   <= R_OK;
                        info     <= 16'd0;
                        if (run_count != 32'd0) s <= S_FETCH;
                    end
                end
                S_FETCH: begin
                    if (pc_ok) s <= S_DEC;
                    else begin
                        reason <= R_DECODE;
                        info   <= 16'h200;
                        s      <= S_STOP;
                    end
                end
                S_DEC: begin
                    if (e_type == 2'b01) begin
                        if (e_ll == 2'b10) begin
                            reason <= R_DECODE;
                            info   <= I_LL;
                            s      <= S_STOP;
                        end else if (MU) begin
                            s <= (e_wd != 8'd0) ? S_WT : S_JX;
                        end else if (e_ll == 2'b00) begin
                            // nop (also 'nop ; wait'): next entry
                            next_entry;
                        end else if (pe_ready) begin
                            s <= S_EXEC;
                        end
                    end else if (e_type == 2'b10) begin
                        if (!e_mval) begin
                            next_entry;
                        end else if (MU) begin
                            s <= S_MS;
                        end else begin
                            reason <= R_UNSUP;
                            info   <= I_MV;
                            s      <= S_IDLE;
                        end
                    end else begin
                        reason <= R_DECODE;
                        info   <= 16'h100 | {14'd0, e_type};
                        s      <= S_STOP;
                    end
                end
                S_WT: if (!mv_busy) begin
                    // the wait, after the MVs before it completed (the official completes them at issue)
                    if (mv_wt_cnt == 2'd0) begin
                        reason <= R_WAIT;
                        info   <= {8'd0, e_wd};
                        s      <= S_STOP;
                    end else if (mv_wt_cnt != 2'd1) begin
                        reason <= R_UNSUP;
                        info   <= I_WD;
                        s      <= S_STOP;
                    end else begin
                        wt_take <= 1'b1;
                        s       <= S_JX;
                    end
                end
                S_JX: begin
                    if (!e_ll[0]) begin
                        // nop (ll = 00, after its wait): next entry
                        l2_skip <= 1'b1;
                        next_entry;
                    end else if (l1_trap || l2_trap) begin
                        // a unit's access beyond its capacity: nothing runs
                        reason <= R_RANGE;
                        info   <= pc;
                        s      <= S_STOP;
                    end else if (jx_go) begin
                        s <= S_PE;
                    end
                end
                S_PE: begin
                    // the units start when mn_mab's check-only pass is over (a word that runs)
                    if (ugo) begin
                        l1_start <= l1_act;
                        l2_start <= l2_act;
                    end
                    if (pe_done) begin
                        if (pe_st != 2'd0) begin
                            reason <= (pe_st == 2'd1) ? R_RANGE : R_UNSUP;
                            info   <= (pe_st == 2'd1) ? pc : {9'd0, pe_field};
                            s      <= S_STOP;
                        end else if (l2_act) begin
                            s <= S_L2P;
                        end else if (l1_act) begin
                            l1_commit <= 1'b1;
                            s         <= S_L1C;
                        end else begin
                            l2_skip <= 1'b1;
                            next_entry;
                        end
                    end
                end
                S_L2P: if (l2_pre) begin
                    // mn_l2bm's first half (L1BM reads, L2BM writes) is over: commit the L1BM unit
                    if (l1_act) begin
                        l1_commit <= 1'b1;
                        s         <= S_L1C;
                    end else begin
                        l2_commit <= 1'b1;
                        s         <= S_L2C;
                    end
                end
                S_L1C: if (l1_done) begin
                    if (l2_act) begin
                        l2_commit <= 1'b1;
                        s         <= S_L2C;
                    end else begin
                        l2_skip <= 1'b1;
                        next_entry;
                    end
                end
                S_L2C: if (l2_done) next_entry;
                S_MS: if (mv_ready) begin
                    mv_start <= 1'b1;
                    s        <= S_MA;
                end
                S_MA: if (mv_acc) begin
                    if (mv_acc_st == 2'd0) begin
                        next_entry;
                    end else if (mv_acc_st == 2'd1) begin
                        reason <= R_RANGE;
                        info   <= pc;
                        s      <= S_STOP;
                    end else begin
                        reason <= R_UNSUP;
                        info   <= I_MF | {12'd0, mv_acc_field};
                        s      <= S_STOP;
                    end
                end
                S_EXEC: begin   // M2 = 0
                    if (pe_done) begin
                        if (pe_st == 2'd0) begin
                            next_entry;
                        end else begin
                            reason <= (pe_st == 2'd1) ? R_RANGE : R_UNSUP;
                            info   <= (pe_st == 2'd1) ? pc : {9'd0, pe_field};
                            s      <= S_IDLE;
                        end
                    end
                end
                default: if (!mv_busy) s <= S_IDLE;   // S_END: the MV in flight completes
            endcase
        end
    end
    task next_entry;
        begin
            steps <= steps + 16'd1;
            pc    <= pc + 16'd1;
            left  <= left - 32'd1;
            s     <= (left == 32'd1) ? S_STOP : S_FETCH;
        end
    endtask
endmodule
`default_nettype wire

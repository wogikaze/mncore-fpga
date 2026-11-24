// mn_core: the MN-Core of the 1-PE mode (WP20): instruction memory, sequencer, one PE.
//
// The ports are the core side of brd_host_if (rtl/board/PROTOCOL.md section 5): memory
// write / read ports (mw_*, mr_*), RUN control and status. Connect rst to the system reset
// OR brd_host_if's core_rst. Single clock.
//
// Instruction memory (space 0x00 IMEM): 2**IMEM_AW entries of 448 bits (PROTOCOL.md section 3:
//   [447:446] type 01 j / 10 m, [425:0] jw, m words in [81:0]); lane k (0..6) of entry e is
//   long word e*8 + k. Stored as {type, jw} = 428 bits (12 BSRAM for 512 entries). Lanes 0..5
//   are staged in registers and the entry is written with lane 6, so an entry is written
//   whole, lanes 0..6 in order (WR_IMEM does this; mask must be 0xFF). Reading IMEM back
//   (RD_MEM space 0) is optional (IMEM_RD = 1); otherwise mr_err.
// PE spaces (location PE_LOC only; loc = n<<10 | c<<9 | b<<6 | m<<2 | p): 0x01 LM0, 0x02 LM1,
//   0x03 GRF0, 0x04 GRF1, 0x05 T, 0x10 OMR, 0x11 BAR (mn_pe_lsu host port). Other spaces and
//   locations are rejected (mw_err / mr_err). The ports are served only while not running.
//
// RUN(start, count): executes entries start .. start+count-1 in order, then stops.
//   - j word, ll = 01 / 11: one PE step (mn_pe_core).
//   - j word, ll = 00 (nop): nothing. Its wait field (wd) is ignored: there is no MV unit,
//     so there is nothing to wait for (the official emulator blocks on a wait for a tag that
//     was never issued; WP20 report).
//   - j word, ll = 10: E_DECODE, info 0.
//   - m word: E_UNSUPPORTED (no MV unit), info 0x80 (m field 0, valid); an m word with
//     valid = 0 is skipped.
//   - entry type 00 / 11: E_DECODE, info 0x100 | type. pc beyond IMEM: E_DECODE, info 0x200.
//   Stop record (valid while core_busy = 0): core_reason 0 OK / 1 E_RANGE / 2 E_UNSUPPORTED /
//   3 E_DECODE; core_pc = the entry that stopped, or the next one after OK; core_steps =
//   entries completed in this RUN; core_info = E_RANGE: entry number of the word,
//   E_UNSUPPORTED: field index (bit 7 = m word field; j fields MN_J_<field>_IDX, m fields
//   MN_M_<field>_IDX), E_DECODE: see above. core_trap = E_RANGE detail
//   {write, memory (0 GRF0, 1 GRF1, 2 LM0, 3 LM1), cycle, word address}.
// The architectural state (memories, T, masks, $mb/$nb, forwarding registers) stays across
// RUNs. rst clears the sequencers and $mb/$nb only; the memories are RAM (cleared by the host,
// like d set on the chip; they are 0 after FPGA configuration).
`default_nettype none
module mn_core #(
    parameter IMEM_AW = 9,           // instruction memory: 2**IMEM_AW entries
    parameter IMEM_RD = 0,           // 1: RD_MEM can read the instruction memory back
    parameter LM_AW   = 9,           // LM0/LM1: 2**LM_AW long words
    parameter GRF_AW  = 8,           // GRF0/GRF1: 2**GRF_AW long words
    parameter [15:0] PE_LOC = 16'h0  // location of the PE (n0c0b0m0p0)
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
    output wire [16:0]  core_trap
);
`include "mn_jfields.vh"
`include "mn_mfields.vh"

    localparam [1:0] R_OK = 2'd0, R_RANGE = 2'd1, R_UNSUP = 2'd2, R_DECODE = 2'd3;
    localparam [7:0] SP_IMEM = 8'h00;
    localparam [16:0] DEPTH = 17'd1 << IMEM_AW;

    // ------------------------------------------------------------------ state
    localparam [1:0] S_IDLE = 2'd0, S_FETCH = 2'd1, S_DEC = 2'd2, S_EXEC = 2'd3;
    reg  [1:0]  s;
    reg  [15:0] pc;
    reg  [31:0] left;
    reg  [31:0] steps;
    reg  [1:0]  reason;
    reg  [31:0] info;
    wire        busy = (s != S_IDLE);

    assign core_busy   = busy;
    assign core_reason = {6'd0, reason};
    assign core_info   = info;
    assign core_pc     = pc;
    assign core_steps  = steps;

    // ------------------------------------------------------------------ instruction memory
    wire [19:0] depth20 = {3'd0, DEPTH};
    wire [2:0]  w_lane  = mw_addr[2:0];
    wire [19:0] w_entry = mw_addr[22:3];
    wire        w_im    = (mw_space == SP_IMEM);
    wire        w_im_ok = (mw_loc == 16'd0) && (w_lane != 3'd7) && (w_entry < depth20) &&
                          (mw_mask == 8'hFF);
    reg [383:0] stage;
    wire        im_wr   = mw_valid & ~busy & w_im & w_im_ok;
    always @(posedge clk) begin
        if (im_wr && (w_lane != 3'd6)) stage[64*w_lane +: 64] <= mw_data;
    end
    wire [2:0]  r_lane  = mr_addr[2:0];
    wire [19:0] r_entry = mr_addr[22:3];
    wire        r_im    = (mr_space == SP_IMEM);
    wire        r_im_ok = (IMEM_RD != 0) && (mr_loc == 16'd0) && (r_lane != 3'd7) &&
                          (r_entry < depth20);
    wire        im_rd   = mr_valid & ~busy & r_im & r_im_ok;

    wire [427:0] imem_q;
    wire         imem_re = (s == S_FETCH) | im_rd;
    wire [IMEM_AW-1:0] imem_ra = busy ? pc[IMEM_AW-1:0] : r_entry[IMEM_AW-1:0];
    mn_ram_1r1w #(.W(428), .AW(IMEM_AW), .NWE(1), .OREG(0)) u_imem (
        .clk(clk), .we(im_wr & (w_lane == 3'd6)), .waddr(w_entry[IMEM_AW-1:0]),
        .wdata({mw_data[63:62], mw_data[41:0], stage}),
        .re(imem_re), .raddr(imem_ra), .rdata(imem_q));

    // IMEM read-back response (IMEM_RD), one clock after the request
    reg        im_rsp;
    reg [2:0]  im_lane;
    always @(posedge clk) begin
        if (rst) im_rsp <= 1'b0;
        else     im_rsp <= im_rd;
        if (im_rd) im_lane <= r_lane;
    end
    wire [447:0] im_entry = {imem_q[427:426], 20'd0, imem_q[425:0]};
    wire [63:0]  im_data  = im_entry[64*im_lane +: 64];

    // ------------------------------------------------------------------ PE
    wire         pe_ready, pe_done, pe_start;
    wire [1:0]   pe_st;
    wire [6:0]   pe_field;
    wire         hp_req_valid, hp_req_ready, hp_req_err, hp_rsp_valid;
    wire [63:0]  hp_rsp_rdata;

    function is_pe_space(input [7:0] sp);
        is_pe_space = (sp == 8'h01) || (sp == 8'h02) || (sp == 8'h03) || (sp == 8'h04) ||
                      (sp == 8'h05) || (sp == 8'h10) || (sp == 8'h11);
    endfunction
    wire w_pe = is_pe_space(mw_space) && (mw_loc == PE_LOC);
    wire r_pe = is_pe_space(mr_space) && (mr_loc == PE_LOC);
    assign hp_req_valid = ~busy & ((mw_valid & w_pe) | (mr_valid & r_pe));

    assign mw_ready = ~busy & (w_pe ? hp_req_ready : 1'b1);
    assign mw_err   = w_pe ? hp_req_err : w_im ? ~w_im_ok : 1'b1;
    assign mr_ready = ~busy & (r_pe ? hp_req_ready : 1'b1);
    assign mr_err   = r_pe ? hp_req_err : r_im ? ~r_im_ok : 1'b1;
    assign mr_rsp_valid = hp_rsp_valid | im_rsp;
    assign mr_rsp_data  = hp_rsp_valid ? hp_rsp_rdata : im_data;

    wire [425:0] jw = imem_q[425:0];
    wire         trap_wr;
    wire [1:0]   trap_mem, trap_cycle;
    wire [11:0]  trap_addr;
    assign core_trap = {trap_wr, trap_mem, trap_cycle, trap_addr};

    mn_pe_core #(.LM_AW(LM_AW), .GRF_AW(GRF_AW),
                 .POS_N(PE_LOC[11:10]), .POS_C(PE_LOC[9]), .POS_B(PE_LOC[8:6]),
                 .POS_M(PE_LOC[5:2]), .POS_P(PE_LOC[1:0])) u_pe (
        .clk(clk), .rst(rst),
        .start(pe_start), .ready(pe_ready), .jw(jw), .done(pe_done), .st(pe_st), .st_field(pe_field),
        .trap_wr(trap_wr), .trap_mem(trap_mem), .trap_cycle(trap_cycle), .trap_addr(trap_addr),
        .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(mw_valid),
        .hp_req_space(mw_valid ? mw_space : mr_space), .hp_req_addr(mw_valid ? mw_addr : mr_addr),
        .hp_req_wdata(mw_data), .hp_req_wmask(mw_mask), .hp_req_err(hp_req_err),
        .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata)
    );

    // ------------------------------------------------------------------ sequencer
    wire [1:0] e_type = imem_q[427:426];
    wire [1:0] e_ll   = imem_q[425:424];   // `MN_J_LL
    wire       e_mval = imem_q[81];        // `MN_M_VALID
    wire       e_exec = (e_type == 2'b01) & e_ll[0];
    assign pe_start = (s == S_DEC) & e_exec & pe_ready;
    wire       pc_ok  = ({1'b0, pc} < DEPTH);
    localparam [31:0] I_MV = 32'h80 | MN_M_VALID_IDX;

    always @(posedge clk) begin
        if (rst) begin
            s      <= S_IDLE;
            pc     <= 16'd0;
            left   <= 32'd0;
            steps  <= 32'd0;
            reason <= R_OK;
            info   <= 32'd0;
        end else begin
            case (s)
                S_IDLE: if (run_start) begin
                    pc     <= run_pc;
                    left   <= run_count;
                    steps  <= 32'd0;
                    reason <= R_OK;
                    info   <= 32'd0;
                    if (run_count != 32'd0) s <= S_FETCH;
                end
                S_FETCH: begin
                    if (pc_ok) s <= S_DEC;
                    else begin
                        reason <= R_DECODE;
                        info   <= 32'h200;
                        s      <= S_IDLE;
                    end
                end
                S_DEC: begin
                    if (e_type == 2'b01) begin
                        if (e_ll == 2'b10) begin
                            reason <= R_DECODE;
                            info   <= MN_J_LL_IDX;
                            s      <= S_IDLE;
                        end else if (e_ll == 2'b00) begin
                            // nop (also 'nop ; wait'): next entry
                            steps <= steps + 32'd1;
                            pc    <= pc + 16'd1;
                            left  <= left - 32'd1;
                            s     <= (left == 32'd1) ? S_IDLE : S_FETCH;
                        end else if (pe_ready) begin
                            s <= S_EXEC;
                        end
                    end else if (e_type == 2'b10) begin
                        if (e_mval) begin
                            reason <= R_UNSUP;
                            info   <= I_MV;
                            s      <= S_IDLE;
                        end else begin
                            steps <= steps + 32'd1;
                            pc    <= pc + 16'd1;
                            left  <= left - 32'd1;
                            s     <= (left == 32'd1) ? S_IDLE : S_FETCH;
                        end
                    end else begin
                        reason <= R_DECODE;
                        info   <= 32'h100 | {30'd0, e_type};
                        s      <= S_IDLE;
                    end
                end
                default: begin   // S_EXEC
                    if (pe_done) begin
                        if (pe_st == 2'd0) begin
                            steps <= steps + 32'd1;
                            pc    <= pc + 16'd1;
                            left  <= left - 32'd1;
                            s     <= (left == 32'd1) ? S_IDLE : S_FETCH;
                        end else begin
                            reason <= (pe_st == 2'd1) ? R_RANGE : R_UNSUP;
                            info   <= (pe_st == 2'd1) ? {16'd0, pc} : {25'd0, pe_field};
                            s      <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire

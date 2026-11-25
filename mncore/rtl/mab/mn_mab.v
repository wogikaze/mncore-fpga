// mn_mab: one MAB of N_PE PEs on one time-multiplexed PE datapath (WP30).
//
// mn_core gives one j word at a time (start / ready, jw stable until done). The word is executed
// on PE 0 .. N_PE-1 one after the other by mn_pe_core (one physical datapath; the PE number
// selects the state: memories, T, $omr, $mb / $nb in mn_mab_mem, forwarding registers, fixed
// operands). With N_PE = 1 this module is mn_pe_core itself (M1).
//
// Order of the steps of one word (N_PE = 4):
//   1. check-only pass, when mn_pe_core says prechk (the word accesses LM0 / LM1, or is msl / msr /
//      bfn / bfe): on PE 0..3, mn_pe_core range checks the word (and for msl / msr / bfn / bfe
//      gathers the ALU input x of the 4 cycles into the exchange buffer) and writes nothing.
//      An E_RANGE on any PE stops the word before any PE wrote (contract 06 section 3); so does
//      an unsupported word (E_UNSUPPORTED, after the range check of all 4 PEs).
//   2. bfn / bfe: the block-float conversion (mn_fp_alu_bfn, WP13) of each cycle c takes x of
//      the 4 PEs (x[128*p +: 128] = PE p, contract 06 section 6) and its results replace them
//      in the buffer.
//   3. normal pass on PE 0..3: the word is executed; the ALU result of msl / msr / bfn / bfe is
//      taken from the buffer: msl gives PE p the x of PE p-1 (mod 4), msr the x of PE p+1
//      (SDM 3.6.12.4), as {MSB long word of x, 0} with flags 0 (official emulator, WP30);
//      bfn / bfe give PE p its conversion result. Without step 1, an E_RANGE or E_UNSUPPORTED
//      of PE 0 stops the word before anything is written: the PEs then have the same addresses.
//   Every read of the word sees the state before the word: the PEs only write their own state,
//   and the inputs of the other PEs (msl / msr / bfn / bfe) were taken in step 1.
// Stop record (done, st, st_field, trap_*): as mn_pe_core's; trap_pe is the PE of an E_RANGE.
//
// Exchange buffer: LUT RAM {PE, cycle} x 128 bits (64 bits, the MSB long word of x, if BFN = 0).
// BFN = 0 leaves out bfn / bfe (mn_fp_alu_bfn, about 3,000 LUT; WP13): they stop with
// E_UNSUPPORTED pe_aluc_aluop.
//
// MAT = 1 (N_PE = 4, WP36): the matrix register of the MAB and its units (mn_mab_mat): ?mwrite,
// ?mread / $mreadf and the matrix MAU (f, g, h). mn_pe_core asks it for the work of each step
// (the x of an mfma is gathered in the check-only pass, which every mfma word gets). MAT = 0:
// those words stop with E_UNSUPPORTED (pe_mauc_mmode / pe_mauc_mw) and $mreadf reads 0.
//
// Host port: mn_pe_core's; hp_pe is the PE (N_PE = 4).
`default_nettype none
module mn_mab #(
    parameter LM_AW  = 8,
    parameter GRF_AW = 8,
    parameter FPALU  = 1,
    parameter MAU    = 1,
    parameter N_PE   = 4,   // 1 or 4
    parameter BFN    = 1,   // N_PE = 4: bfn / bfe
    parameter MAT    = 0,   // N_PE = 4: the matrix register and matrix MAU (WP36)
    parameter integer POS_N = 0,   // chip coordinates of the MAB (contract 06 section 3)
    parameter integer POS_C = 0,
    parameter integer POS_B = 0,
    parameter integer POS_M = 0,
    parameter integer POS_P = 0    // N_PE = 1: the PE in the MAB
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    output wire         ready,
    input  wire [425:0] jw,
    output wire         done,
    output wire [1:0]   st,
    output wire [6:0]   st_field,
    output wire         trap_wr,
    output wire [1:0]   trap_mem,
    output wire [1:0]   trap_cycle,
    output wire [11:0]  trap_addr,
    output wire [1:0]   trap_pe,
    input  wire         hp_req_valid,
    output wire         hp_req_ready,
    input  wire         hp_req_we,
    input  wire [1:0]   hp_pe,
    input  wire [7:0]   hp_req_space,
    input  wire [22:0]  hp_req_addr,
    input  wire [63:0]  hp_req_wdata,
    input  wire [7:0]   hp_req_wmask,
    output wire         hp_req_err,
    output wire         hp_rsp_valid,
    output wire [63:0]  hp_rsp_rdata
);
    wire         c_start, c_ready, c_done;
    wire [1:0]   c_st;
    wire [6:0]   c_field;
    wire [1:0]   c_pe;
    wire         c_rdo;
    wire [1:0]   xpe_op;
    wire         prechk, xg_valid;
    wire [1:0]   xg_cycle, xz_cycle;
    wire [127:0] xg_x, xz_z;
    // matrix unit (MAT = 1)
    wire         mg_valid, mt_req, mw_req, mt_done, mw_done, mr_req, mr_rdy, mr_acc, mr_upd;
    wire         fr_req, fr_rdy, fr_acc, mat_busy;
    wire [1:0]   mg_cycle, mt_cycle, mr_cycle, fr_cycle;
    wire [63:0]  mg_x;
    wire [127:0] mt_y, mw_b, mt_z, mr_val, mr_mask, fr_val;
    wire [3:0]   mt_flags;

    mn_pe_core #(.LM_AW(LM_AW), .GRF_AW(GRF_AW), .FPALU(FPALU), .MAU(MAU), .N_PE(N_PE), .BFN(BFN),
                 .MAT(MAT),
                 .POS_N(POS_N), .POS_C(POS_C), .POS_B(POS_B), .POS_M(POS_M), .POS_P(POS_P)) u_pe (
        .clk(clk), .rst(rst),
        .start(c_start), .ready(c_ready), .jw(jw), .pe(c_pe), .rd_only(c_rdo),
        .done(c_done), .st(c_st), .st_field(c_field),
        .trap_wr(trap_wr), .trap_mem(trap_mem), .trap_cycle(trap_cycle), .trap_addr(trap_addr),
        .xpe_op(xpe_op), .prechk(prechk), .xg_valid(xg_valid), .xg_cycle(xg_cycle), .xg_x(xg_x),
        .xz_cycle(xz_cycle), .xz_z(xz_z),
        .mg_valid(mg_valid), .mg_cycle(mg_cycle), .mg_x(mg_x),
        .mt_req(mt_req), .mw_req(mw_req), .mt_cycle(mt_cycle), .mt_y(mt_y), .mw_b(mw_b),
        .mt_done(mt_done), .mt_z(mt_z), .mt_flags(mt_flags), .mw_done(mw_done),
        .mr_req(mr_req), .mr_cycle(mr_cycle), .mr_rdy(mr_rdy), .mr_val(mr_val),
        .mr_acc(mr_acc), .mr_upd(mr_upd), .mr_mask(mr_mask),
        .fr_req(fr_req), .fr_cycle(fr_cycle), .fr_rdy(fr_rdy), .fr_val(fr_val), .fr_acc(fr_acc),
        .hp_req_valid(hp_req_valid), .hp_req_ready(hp_req_ready), .hp_req_we(hp_req_we), .hp_pe(hp_pe),
        .hp_req_space(hp_req_space), .hp_req_addr(hp_req_addr), .hp_req_wdata(hp_req_wdata),
        .hp_req_wmask(hp_req_wmask), .hp_req_err(hp_req_err),
        .hp_rsp_valid(hp_rsp_valid), .hp_rsp_rdata(hp_rsp_rdata)
    );

    generate
        if (N_PE > 1 && MAT != 0) begin : g_mat
            mn_mab_mat u_mat (
                .clk(clk), .rst(rst), .busy(mat_busy), .jw(jw), .pe(c_pe),
                .xg_valid(mg_valid), .xg_cycle(mg_cycle), .xg_x(mg_x),
                .mt_req(mt_req), .mt_cycle(mt_cycle), .mt_y(mt_y),
                .mt_done(mt_done), .mt_z(mt_z), .mt_flags(mt_flags),
                .mw_req(mw_req), .mw_cycle(mt_cycle), .mw_b(mw_b), .mw_done(mw_done),
                .mr_req(mr_req), .mr_cycle(mr_cycle), .mr_rdy(mr_rdy), .mr_val(mr_val),
                .mr_acc(mr_acc), .mr_upd(mr_upd), .mr_mask(mr_mask),
                .fr_req(fr_req), .fr_cycle(fr_cycle), .fr_rdy(fr_rdy), .fr_val(fr_val), .fr_acc(fr_acc));
        end else begin : g_nomat
            assign mat_busy = 1'b0;
            assign mt_done  = 1'b0;
            assign mt_z     = 128'd0;
            assign mt_flags = 4'd0;
            assign mw_done  = 1'b0;
            assign mr_rdy   = 1'b0;
            assign mr_val   = 128'd0;
            assign fr_rdy   = 1'b0;
            assign fr_val   = 128'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            // no matrix unit: mn_pe_core makes no requests (MAT = 0)
            wire unused_mat = ^{mg_valid, mg_cycle, mg_x, mt_req, mw_req, mt_cycle, mt_y, mw_b, mr_req,
                                mr_cycle, mr_acc, mr_upd, mr_mask, fr_req, fr_cycle, fr_acc};
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    generate
        if (N_PE == 1) begin : g_one
            // one PE: mn_pe_core is the MAB
            assign c_start  = start;
            assign ready    = c_ready;
            assign done     = c_done;
            assign st       = c_st;
            assign st_field = c_field;
            assign c_pe     = 2'd0;
            assign c_rdo    = 1'b0;
            assign trap_pe  = 2'd0;
            assign xz_z     = 128'd0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_one = ^{xpe_op, prechk, xg_valid, xg_cycle, xg_x, xz_cycle, mat_busy};
            /* verilator lint_on UNUSEDSIGNAL */
        end else begin : g_mab
            localparam XW = (BFN != 0) ? 128 : 64;   // exchange buffer width
            localparam [2:0] M_IDLE = 3'd0, M_GO = 3'd1, M_WAIT = 3'd2, M_BF = 3'd3, M_END = 3'd4;
            localparam [31:0] PE_LAST32 = N_PE - 1;
            localparam [1:0]  PE_LAST = PE_LAST32[1:0];
            reg  [2:0] m;
            reg  [1:0] p;          // PE of the current step
            reg        pass_r;     // check-only pass
            reg        uns;        // E_UNSUPPORTED in the check-only pass
            reg  [6:0] ufld;
            reg  [1:0] op_q;       // msl 1, msr 2, bfn / bfe 3
            reg        d_q;
            reg  [1:0] st_q, tpe_q;
            reg  [6:0] fld_q;
            wire       bf_fin;     // the block-float conversion of the 4 cycles is done

            assign ready    = (m == M_IDLE) & c_ready & ~mat_busy;
            assign done     = d_q;
            assign st       = st_q;
            assign st_field = fld_q;
            assign trap_pe  = tpe_q;
            assign c_start  = (m == M_GO);
            assign c_pe     = p;
            assign c_rdo    = pass_r;

            always @(posedge clk) begin
                if (rst) begin
                    m      <= M_IDLE;
                    p      <= 2'd0;
                    pass_r <= 1'b0;
                    uns    <= 1'b0;
                    ufld   <= 7'd0;
                    op_q   <= 2'd0;
                    d_q    <= 1'b0;
                    st_q   <= 2'd0;
                    fld_q  <= 7'd0;
                    tpe_q  <= 2'd0;
                end else begin
                    d_q <= 1'b0;
                    case (m)
                        M_IDLE: if (start && c_ready) begin
                            op_q   <= xpe_op;
                            p      <= 2'd0;
                            pass_r <= prechk;
                            uns    <= 1'b0;
                            m      <= M_GO;
                        end
                        M_GO: if (c_ready) m <= M_WAIT;   // mn_pe_core takes the start
                        M_WAIT: if (c_done) begin
                            if (c_st == 2'd1) begin
                                // E_RANGE (in the check-only pass, before any write)
                                st_q  <= 2'd1;
                                tpe_q <= p;
                                m     <= M_END;
                            end else if (pass_r) begin
                                if (c_st == 2'd2 && !uns) begin
                                    uns  <= 1'b1;
                                    ufld <= c_field;
                                end
                                if (p != PE_LAST) begin
                                    p <= p + 2'd1;
                                    m <= M_GO;
                                end else if (uns || c_st == 2'd2) begin
                                    st_q  <= 2'd2;
                                    fld_q <= uns ? ufld : c_field;
                                    m     <= M_END;
                                end else begin
                                    pass_r <= 1'b0;
                                    p      <= 2'd0;
                                    m      <= (op_q == 2'd3) ? M_BF : M_GO;
                                end
                            end else if (c_st == 2'd2) begin
                                st_q  <= 2'd2;
                                fld_q <= c_field;
                                m     <= M_END;
                            end else if (p != PE_LAST) begin
                                p <= p + 2'd1;
                                m <= M_GO;
                            end else begin
                                st_q <= 2'd0;
                                m    <= M_END;
                            end
                        end
                        M_BF: if (bf_fin) m <= M_GO;
                        default: begin   // M_END: report the stop record
                            d_q <= 1'b1;
                            m   <= M_IDLE;
                        end
                    endcase
                end
            end

            // ---------------------------------------------------------- exchange buffer
            // {PE, cycle}: x of the check-only pass, replaced by the bfn / bfe results
            wire          xb_we;
            wire [3:0]    xb_wa, xb_ra;
            wire [XW-1:0] xb_wd, xb_rd;
            mn_ram_lut #(.W(XW), .AW(4), .NR(1)) u_xb (
                .clk(clk), .we(xb_we), .waddr(xb_wa), .wdata(xb_wd), .raddr(xb_ra), .rdata(xb_rd));
            // the PE whose buffer entry gives the result of PE p
            wire [1:0] src = (op_q == 2'd1) ? p - 2'd1 : (op_q == 2'd2) ? p + 2'd1 : p;
            wire       bf_we;
            wire [3:0] bf_wa, bf_ra;
            wire [XW-1:0] bf_wd;
            assign xb_we = (xg_valid & pass_r) | bf_we;
            assign xb_wa = bf_we ? bf_wa : {p, xg_cycle};
            assign xb_wd = bf_we ? bf_wd : xg_x[127 -: XW];
            assign xb_ra = (m == M_BF) ? bf_ra : {src, xz_cycle};

            // ---------------------------------------------------------- block float (bfn / bfe)
            if (BFN != 0) begin : g_bfn
                // msl / msr: {MSB long word of x, 0}; bfn / bfe: the result
                assign xz_z = (op_q == 2'd3) ? xb_rd : {xb_rd[127:64], 64'd0};
                // per cycle bc: load x of PE 0..2 into stg (bs 0..2), issue with PE 3 straight
                // from the buffer (bs 3), wait (bs 4), write the 4 results back (bs 5, one PE per
                // clock), release the result (bs 6)
                reg  [2:0]   bs;
                reg  [1:0]   bc, bk;
                reg  [383:0] stg;
                wire         bf_iv, bf_ir, bf_ov, bf_oerr;
                wire [511:0] bf_z;
                /* verilator lint_off UNUSEDSIGNAL */
                wire [15:0]  bf_fl;   // always 0
                /* verilator lint_on UNUSEDSIGNAL */
                assign bf_iv  = (m == M_BF) & (bs == 3'd3);
                assign bf_ra  = {(bs == 3'd3) ? 2'd3 : bs[1:0], bc};
                assign bf_we  = (m == M_BF) & (bs == 3'd5);
                assign bf_wa  = {bk, bc};
                assign bf_wd  = bf_z[128*bk +: 128];
                assign bf_fin = (m == M_BF) & (bs == 3'd6) & (bc == 2'd3);
                mn_fp_alu_bfn #(.RND(0)) u_bfn (
                    .clk(clk), .rst(rst), .in_valid(bf_iv), .in_ready(bf_ir),
                    .pe_aluc_dmode(jw[425-145 -: 2]), .pe_aluc_aluop(jw[425-147 -: 5]),
                    .pe_aluc_rounda(1'b0), .pe_aluc_iselb(jw[425-159 -: 3]),
                    .x({xb_rd, stg}), .out_valid(bf_ov), .out_ready((m == M_BF) & (bs == 3'd6)),
                    .z(bf_z), .flags(bf_fl), .out_err(bf_oerr));
                always @(posedge clk) begin
                    if (rst) begin
                        bs <= 3'd0;
                        bc <= 2'd0;
                        bk <= 2'd0;
                    end else if (m == M_BF) begin
                        case (bs)
                            3'd0, 3'd1, 3'd2: begin
                                stg[128*bs[1:0] +: 128] <= xb_rd;
                                bs <= bs + 3'd1;
                            end
                            3'd3: if (bf_ir) bs <= 3'd4;
                            3'd4: if (bf_ov) begin
                                bk <= 2'd0;
                                bs <= 3'd5;
                            end
                            3'd5: begin
                                bk <= bk + 2'd1;
                                if (bk == 2'd3) bs <= 3'd6;
                            end
                            default: begin   // 6: the result is taken
                                bc <= bc + 2'd1;
                                bs <= 3'd0;
                            end
                        endcase
                    end else begin
                        bs <= 3'd0;
                        bc <= 2'd0;
                    end
                end
`ifndef SYNTHESIS
                always @(posedge clk) begin
                    if (!rst && m == M_BF && bs == 3'd5 && bk == 2'd0 && bf_oerr)
                        $display("mn_mab: ERROR mn_fp_alu_bfn did not take the instruction (out_err)");
                end
`endif
            end else begin : g_nobfn
                // the buffer holds the MSB long word of x (msl / msr only)
                assign xz_z   = {xb_rd, 64'd0};
                /* verilator lint_off UNUSEDSIGNAL */
                // msl / msr move the MSB long word of x only
                wire unused_xlo = ^xg_x[63:0];
                /* verilator lint_on UNUSEDSIGNAL */
                assign bf_we  = 1'b0;
                assign bf_wa  = 4'd0;
                assign bf_ra  = 4'd0;
                assign bf_wd  = {XW{1'b0}};
                assign bf_fin = 1'b1;
            end
        end
    endgenerate
endmodule
`default_nettype wire

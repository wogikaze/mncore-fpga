// mn_top_multi: one member of the set of function-specific bitstreams of the M2 topology (WP38),
// on the Tang Nano 20K. mncore/tools/host/mnrun.py runs a program across the members, switching
// the FPGA SRAM image between the parts of the program (mncore/fpga/multi/README.md).
//
// brd_host_if (UART host protocol, rtl/board/PROTOCOL.md) + mn_core (N_PE = 4: one MAB of 4 PEs,
// time-multiplexed) + sdr_bus64 on the embedded SDRAM, like mn_top_m2 (WP37), with two changes
// that let a program continue on another member:
//   1. The DRAM and PDM ranges of the SDRAM are cleared by the RESET command only, not by the
//      configuration (mn_core SDCLR = 0; the clear is here). A program that has started keeps its
//      DRAM / PDM when the host loads another member (the SDRAM keeps its content without refresh
//      for the few seconds of the reconfiguration; mnrun.py checks it, WP38 report).
//   2. Every member has the SDRAM and serves the host spaces 0x08 PDM and 0x09 DRAM, also when its
//      core has no MV unit (UNITS < 2): then this top serves them itself (the bridge below), so the
//      DRAM / PDM are refreshed and reachable whatever member is loaded.
//
// UNITS (the M2 units of mn_core; the INFO space depths show them):
//   2: L1BM, L2BM and MV (mn_core M2 = 1 with the real mn_l2bm / mn_mv): the M2 core of WP37.
//   1: L1BM only: mn_core M2 = 1, built with the stubs mncore/fpga/multi/stub/mn_l2bm.v and
//      mn_mv.v instead of the real units (files_l1.txt; L2BM words and m words stop with
//      E_UNSUPPORTED, the L2BM space 0x07 has depth 0). Area: it leaves room for the MAU.
//   0: none: mn_core M2 = 0 (the MAB of mn_top_mab, WP30).
// FPALU / MAU / BFN / MAT / REPLICA / L1_RRN as mn_core.
// SDRAM = 0 (UNITS < 2 only; area: the controller and the bridge are LUT_eq about 1,000): no SDRAM
// controller. The member puts the SDRAM into self refresh after its configuration, so that the DRAM /
// PDM keep their content while it is loaded, and has no PDM / DRAM spaces (INFO depth 0): mnrun.py
// keeps the d set / d get of the PDM / DRAM of such a segment for the next member with the SDRAM.
//
// INFO (PROTOCOL.md section 3): design ID DESIGN_ID (0x05 proposed: mn_top_multi), flags bit 0 (a
// real core), bits 3..2 FPALU, bit 4 MAU, bit 5 BFN, bit 6 MAT, bit 7 REPLICA (as 0x03 / 0x04),
// topology 1/1/1/1/4, the depths of 0x00 IMEM, 0x01..0x05 (the PE spaces), 0x06 L1BM (UNITS >= 1),
// 0x07 L2BM (UNITS = 2), 0x08 PDM and 0x09 DRAM (always). OMR (0x10) and BAR (0x11) are served too.
//
// The RESET command: core_rst resets the core (the PEs, L1BM / $lbi, L2BM, MV tags are cleared by
// the core) and starts the clear of the DRAM (2**DRAM_AW long words) and the PDM (2**PDM_AW) here.
// While it runs the SDRAM bus is the clear's: the core's MV requests and the host's PDM / DRAM
// requests wait. The power-on core_rst (configuration, button S1) does not clear them.
//
// LED: only LED 0, steadily on at the lowest brightness (contract 06 section 7).
`default_nettype none
module mn_top_multi #(
    parameter CLK_HZ        = 27000000,
    parameter BAUD          = 1000000,
    parameter TIMEOUT_CYC   = CLK_HZ / 50,
    parameter PROBATION_CYC = CLK_HZ,
    parameter IMEM_AW       = 9,
    parameter LM_AW         = 8,
    parameter GRF_AW        = 8,
    parameter UNITS         = 2,         // 2 L1BM + L2BM + MV, 1 L1BM only (stubs), 0 none
    parameter SDRAM         = 1,         // 0: no SDRAM controller (UNITS < 2 only): self refresh, see above
    parameter FPALU         = 0,
    parameter MAU           = 0,
    parameter BFN           = 0,
    parameter MAT           = 0,
    parameter REPLICA       = 0,
    parameter L1_RRN        = 2,
    parameter L2_RRN        = 2,
    parameter L2_DAR        = 0,
    parameter L1_AW         = 10,
    parameter L2_AW         = 11,
    parameter PDM_AW        = 17,
    parameter DRAM_AW       = 19,
    parameter [19:0] PDM_BASE  = 20'h80000,
    parameter [19:0] DRAM_BASE = 20'h00000,
    parameter integer SDR_HZ    = 54000000,   // SDRAM clock: 27 MHz * (FBDIV_SEL + 1) / (IDIV_SEL + 1)
    parameter integer IDIV_SEL  = 0,
    parameter integer FBDIV_SEL = 1,
    parameter integer ODIV_SEL  = 16,
    parameter integer PSDA      = 11,         // the PLL phase of the SDRAM clock (rtl/sdram/README.md)
    parameter integer CL        = 2,
    parameter integer RDX       = 1,
    parameter [7:0] DESIGN_ID   = 8'h05,
    parameter LED_DIM_BITS  = 10            // LED 0 duty = 1 / 2**LED_DIM_BITS
) (
    input  wire        clk,
    input  wire        btn_rst,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire [5:0]  led,
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    localparam M2C = (UNITS != 0) ? 1 : 0;        // mn_core M2
    localparam OWN = (UNITS != 2) ? 1 : 0;        // this top serves the PDM / DRAM spaces
    localparam [15:0]  IMEM_DEPTH = 16'd1 << IMEM_AW;
    localparam [31:0]  D_IMEM = 32'd8 << IMEM_AW;
    localparam [31:0]  D_LM   = 32'd1 << LM_AW;
    localparam [31:0]  D_GRF  = 32'd1 << GRF_AW;
    localparam [31:0]  D_T    = 32'd8;
    localparam [31:0]  D_L1   = (UNITS >= 1) ? (32'd1 << L1_AW) : 32'd0;
    localparam [31:0]  D_L2   = (UNITS == 2) ? (32'd1 << L2_AW) : 32'd0;
    localparam [31:0]  D_P    = (SDRAM != 0) ? (32'd1 << PDM_AW) : 32'd0;
    localparam [31:0]  D_D    = (SDRAM != 0) ? (32'd1 << DRAM_AW) : 32'd0;
    localparam [511:0] SPACE_DEPTH = {192'd0, D_D, D_P, D_L2, D_L1, D_T, D_GRF, D_GRF, D_LM, D_LM, D_IMEM};
    // INFO flags: bit0 a real core; bits 3..2 FPALU, bit 4 MAU, bit 5 BFN, bit 6 MAT, bit 7 REPLICA
    localparam [31:0]  FLAGS32 = 32'h01 + ((FPALU % 4) * 4) + ((MAU != 0) ? 16 : 0) + ((BFN != 0) ? 32 : 0) +
                                 ((MAT != 0) ? 64 : 0) + ((REPLICA != 0) ? 128 : 0);
    localparam [7:0]   INFO_FL = FLAGS32[7:0];

    // ---------------------------------------------------------------- clocks and reset
    wire lock;
    // Power-on reset from the FPGA configuration init values; held until the PLL locks
    /* verilator lint_off PROCASSINIT */
    reg [5:0] por_cnt = 6'd0;
    reg [1:0] btn_sync = 2'b00;
    reg [1:0] lock_sync = 2'b00;
    reg       rst = 1'b1;
    /* verilator lint_on PROCASSINIT */
    always @(posedge clk) begin
        btn_sync  <= {btn_sync[0], btn_rst};
        lock_sync <= {lock_sync[0], lock};
        if (btn_sync[1] || !lock_sync[1]) por_cnt <= 6'd0;
        else if (por_cnt != 6'h3f) por_cnt <= por_cnt + 1'b1;
        rst <= (por_cnt != 6'h3f);
    end

    // ---------------------------------------------------------------- host interface
    wire        mw_valid, mw_ready, mw_err;
    wire [7:0]  mw_space, mw_mask;
    wire [15:0] mw_loc;
    wire [22:0] mw_addr;
    wire [63:0] mw_data;
    wire        mr_valid, mr_ready, mr_err;
    wire [7:0]  mr_space;
    wire [15:0] mr_loc;
    wire [22:0] mr_addr;
    wire        mr_rsp_valid;
    wire [63:0] mr_rsp_data;
    wire        run_start;
    wire [15:0] run_pc;
    wire [31:0] run_count;
    wire        core_rst;
    wire        core_busy;
    wire [7:0]  core_reason;
    wire [31:0] core_info;
    wire [15:0] core_pc;
    wire [31:0] core_steps;
    wire        dbg_rx_byte, dbg_tx_byte, dbg_err, dbg_probation;
    brd_host_if #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_CYC(TIMEOUT_CYC), .PROBATION_CYC(PROBATION_CYC),
        .DESIGN_ID(DESIGN_ID), .INFO_FLAGS(INFO_FL), .IMEM_DEPTH(IMEM_DEPTH),
        .TOPO(40'h04_01_01_01_01),       // byte0 n .. byte4 p: 1 group, 1 L2B, 1 L1B, 1 MAB, 4 PEs
        .SPACE_DEPTH(SPACE_DEPTH)
    ) u_host (
        .clk(clk), .rst(rst),
        .uart_rxd(uart_rx), .uart_txd(uart_tx),
        .mw_valid(mw_valid), .mw_ready(mw_ready), .mw_err(mw_err),
        .mw_space(mw_space), .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid), .mr_ready(mr_ready), .mr_err(mr_err),
        .mr_space(mr_space), .mr_loc(mr_loc), .mr_addr(mr_addr),
        .mr_rsp_valid(mr_rsp_valid), .mr_rsp_data(mr_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count), .core_rst(core_rst),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps),
        .dbg_rx_byte(dbg_rx_byte), .dbg_tx_byte(dbg_tx_byte), .dbg_err(dbg_err),
        .dbg_probation(dbg_probation));

    // ---------------------------------------------------------------- SDRAM
    wire        sd_req_valid, sd_req_ready, sd_req_we, sd_rsp_valid, init_done, err_addr;
    wire [22:0] sd_req_addr;
    wire [63:0] sd_req_wdata, sd_rsp_rdata;
    wire [7:0]  sd_req_wmask;
    genvar g;
    generate
        if (SDRAM != 0) begin : g_sdr
            // the controller on the rPLL's clock (mn_top_m2, WP37)
            wire sclk, pclk;
            sdr_gw_pll #(.IDIV_SEL(IDIV_SEL), .FBDIV_SEL(FBDIV_SEL), .ODIV_SEL(ODIV_SEL), .DYN_PHASE(0),
                         .PSDA(PSDA)) u_pll (
                .clkin(clk), .psda(4'd0), .clkout(sclk), .clkoutp(pclk), .lock(lock));
            sdr_gw_clkout u_ck (.clk(pclk), .q(O_sdram_clk));
            // the controller's reset: the system reset seen in the SDRAM clock (asserted with rst)
            /* verilator lint_off PROCASSINIT */
            reg [2:0] srst_sync = 3'b111;
            /* verilator lint_on PROCASSINIT */
            always @(posedge sclk) srst_sync <= {srst_sync[1:0], rst};
            wire srst = srst_sync[2] | rst;
            wire [31:0] dq_o, dq_oe;
            sdr_bus64 #(.ASYNC(1), .FREQ_HZ(SDR_HZ), .CL(CL)) u_sdr (
                .clk(clk), .rst(rst), .sclk(sclk), .srst(srst), .cfg_rdx(RDX[1:0]),
                .init_done(init_done), .err_addr(err_addr),
                .req_valid(sd_req_valid), .req_ready(sd_req_ready), .req_we(sd_req_we), .req_addr(sd_req_addr),
                .req_wdata(sd_req_wdata), .req_wmask(sd_req_wmask), .rsp_valid(sd_rsp_valid),
                .rsp_rdata(sd_rsp_rdata),
                .sdr_cke(O_sdram_cke), .sdr_cs_n(O_sdram_cs_n), .sdr_ras_n(O_sdram_ras_n),
                .sdr_cas_n(O_sdram_cas_n), .sdr_we_n(O_sdram_wen_n), .sdr_ba(O_sdram_ba), .sdr_a(O_sdram_addr),
                .sdr_dqm(O_sdram_dqm), .sdr_dq_o(dq_o), .sdr_dq_oe(dq_oe), .sdr_dq_i(IO_sdram_dq));
            for (g = 0; g < 32; g = g + 1) begin : g_dq
                assign IO_sdram_dq[g] = dq_oe[g] ? dq_o[g] : 1'bz;
            end
        end else begin : g_nosdr
            // No controller (area): the SDRAM is put into self refresh, so that the DRAM / PDM of the
            // program outlive this member: on a clock of 27 / 2 MHz (commands change on its falling
            // edge), NOPs, PRECHARGE ALL, then AUTO REFRESH with CKE low (SELF REFRESH ENTRY); CKE stays
            // low. The next member's controller exits it (CKE high, its 200 us wait) and initialises
            // the SDRAM again (PRECHARGE ALL, AUTO REFRESH, MODE REGISTER SET: the data stay).
            assign lock = 1'b1;
            reg       ph;              // the SDRAM clock
            reg [5:0] cnt;
            reg [2:0] sst;
            reg [3:0] cmd;             // {cs_n, ras_n, cas_n, we_n}
            reg       cke, a10;
            localparam [2:0] SR_NOP = 3'd0, SR_PRE = 3'd1, SR_TRP = 3'd2, SR_SRE = 3'd3, SR_HOLD = 3'd4;
            always @(posedge clk) begin
                if (rst) begin
                    ph  <= 1'b0;
                    cnt <= 6'd0;
                    sst <= SR_NOP;
                    cmd <= 4'b0111;
                    cke <= 1'b1;
                    a10 <= 1'b0;
                end else begin
                    ph <= ~ph;
                    if (ph) begin          // the SDRAM clock falls now: the next command
                        cnt <= cnt + 6'd1;
                        case (sst)
                            SR_NOP: if (&cnt) begin sst <= SR_PRE; cmd <= 4'b0010; a10 <= 1'b1; end
                            SR_PRE: begin sst <= SR_TRP; cmd <= 4'b0111; a10 <= 1'b0; cnt <= 6'd0; end
                            SR_TRP: if (cnt[2]) begin sst <= SR_SRE; cmd <= 4'b0001; cke <= 1'b0; end
                            SR_SRE: begin sst <= SR_HOLD; cmd <= 4'b1111; end
                            default: ;
                        endcase
                    end
                end
            end
            assign O_sdram_clk   = ph;
            assign O_sdram_cke   = cke;
            assign O_sdram_cs_n  = cmd[3];
            assign O_sdram_ras_n = cmd[2];
            assign O_sdram_cas_n = cmd[1];
            assign O_sdram_wen_n = cmd[0];
            assign O_sdram_ba    = 2'b00;
            assign O_sdram_addr  = {a10, 10'd0};
            assign O_sdram_dqm   = 4'b1111;
            for (g = 0; g < 32; g = g + 1) begin : g_dq
                assign IO_sdram_dq[g] = 1'bz;
            end
            assign sd_req_ready = 1'b0;
            assign sd_rsp_valid = 1'b0;
            assign sd_rsp_rdata = 64'd0;
            assign init_done    = 1'b0;
            assign err_addr     = 1'b0;
            /* verilator lint_off UNUSEDSIGNAL */
            wire unused_sd = ^{sd_req_valid, sd_req_we, sd_req_addr, sd_req_wdata, sd_req_wmask};
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    // ---------------------------------------------------------------- the clear of the DRAM / PDM
    // Started by the RESET command: the first core_rst (the power-on one) only arms it.
    reg        armed, crst_q, sc_on, sc_pdm;
    reg [20:0] sc_a;
    localparam [20:0] D_LAST = (21'd1 << DRAM_AW) - 21'd1;
    localparam [20:0] P_LAST = (21'd1 << PDM_AW) - 21'd1;
    always @(posedge clk) begin
        if (rst) begin
            armed  <= 1'b0;
            crst_q <= 1'b1;
            sc_on  <= 1'b0;
            sc_pdm <= 1'b0;
            sc_a   <= 21'd0;
        end else begin
            crst_q <= core_rst;
            if (!core_rst) armed <= 1'b1;
            if ((SDRAM != 0) && armed && core_rst && !crst_q) begin
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
    end

    // ---------------------------------------------------------------- the PDM / DRAM spaces (OWN)
    // The core has no MV unit: the host's spaces 0x08 PDM / 0x09 DRAM (loc 0 = n0) are served here,
    // with the checks and the SDRAM addresses of mn_mv's host port (rtl/mv/mn_mv.v).
    wire w_hm = (OWN != 0) & (SDRAM != 0) & ((mw_space == 8'h08) | (mw_space == 8'h09));
    wire r_hm = (OWN != 0) & (SDRAM != 0) & ((mr_space == 8'h08) | (mr_space == 8'h09));
    wire w_hm_ok = (mw_loc == 16'd0) & ((mw_space == 8'h08) ? ((mw_addr >> PDM_AW) == 23'd0)
                                                            : ((mw_addr >> DRAM_AW) == 23'd0));
    wire r_hm_ok = (mr_loc == 16'd0) & ((mr_space == 8'h08) ? ((mr_addr >> PDM_AW) == 23'd0)
                                                            : ((mr_addr >> DRAM_AW) == 23'd0));
    /* verilator lint_off UNUSEDSIGNAL */
    // the bits above the depths were checked
    wire [22:0] hm_a  = mw_valid ? mw_addr : mr_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        hm_p  = mw_valid ? (mw_space == 8'h08) : (mr_space == 8'h08);
    wire [19:0] hm_sa = hm_p ? (PDM_BASE | {{(20 - PDM_AW){1'b0}}, hm_a[PDM_AW-1:0]}) :
                               (DRAM_BASE | {{(20 - DRAM_AW){1'b0}}, hm_a[DRAM_AW-1:0]});
    wire        hm_w  = mw_valid & w_hm & w_hm_ok;               // a write before a read
    wire        hm_r  = ~mw_valid & mr_valid & r_hm & r_hm_ok;
    reg         hm_rd;                                            // a host read is in flight
    always @(posedge clk) begin
        if (rst) hm_rd <= 1'b0;
        else if (hm_r & ~sc_on & sd_req_ready) hm_rd <= 1'b1;
        else if (sd_rsp_valid) hm_rd <= 1'b0;
    end

    // ---------------------------------------------------------------- core
    wire        c_mw_ready, c_mw_err, c_mr_ready, c_mr_err, c_rsp_valid;
    wire [63:0] c_rsp_data;
    wire        c_sd_valid, c_sd_we;
    wire [22:0] c_sd_addr;
    wire [63:0] c_sd_wdata;
    wire [7:0]  c_sd_wmask;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [16:0] core_trap;   // E_RANGE detail: not reported by protocol version 1
    /* verilator lint_on UNUSEDSIGNAL */
    wire        unit_busy, unit_err;
    mn_core #(
        .IMEM_AW(IMEM_AW), .IMEM_RD(0), .LM_AW(LM_AW), .GRF_AW(GRF_AW), .CLEAR(1),
        .FPALU(FPALU), .MAU(MAU), .N_PE(4), .BFN(BFN), .MAT(MAT), .M2(M2C),
        .L1_RRN(L1_RRN), .L2_RRN(L2_RRN), .L2_DAR(L2_DAR), .REPLICA(REPLICA), .L1_AW(L1_AW), .L2_AW(L2_AW),
        .PDM_AW(PDM_AW), .DRAM_AW(DRAM_AW), .PDM_BASE(PDM_BASE), .DRAM_BASE(DRAM_BASE), .SDCLR(0),
        .PE_LOC(16'h0000)
    ) u_core (
        .clk(clk), .rst(rst | core_rst),
        .mw_valid(mw_valid & ~w_hm), .mw_ready(c_mw_ready), .mw_err(c_mw_err), .mw_space(mw_space),
        .mw_loc(mw_loc), .mw_addr(mw_addr), .mw_data(mw_data), .mw_mask(mw_mask),
        .mr_valid(mr_valid & ~r_hm), .mr_ready(c_mr_ready), .mr_err(c_mr_err), .mr_space(mr_space),
        .mr_loc(mr_loc), .mr_addr(mr_addr), .mr_rsp_valid(c_rsp_valid), .mr_rsp_data(c_rsp_data),
        .run_start(run_start), .run_pc(run_pc), .run_count(run_count),
        .core_busy(core_busy), .core_reason(core_reason), .core_info(core_info),
        .core_pc(core_pc), .core_steps(core_steps), .core_trap(core_trap),
        .sd_req_valid(c_sd_valid), .sd_req_ready(sd_req_ready & ~sc_on & (OWN == 0)), .sd_req_we(c_sd_we),
        .sd_req_addr(c_sd_addr), .sd_req_wdata(c_sd_wdata), .sd_req_wmask(c_sd_wmask),
        .sd_rsp_valid(sd_rsp_valid & (OWN == 0)), .sd_rsp_rdata(sd_rsp_rdata), .sd_err_addr(err_addr),
        .unit_busy(unit_busy), .unit_err(unit_err));

    // the host ports: the PDM / DRAM spaces here (OWN), the rest in the core
    assign mw_ready = w_hm ? (~w_hm_ok | (~sc_on & sd_req_ready)) : c_mw_ready;
    assign mw_err   = w_hm ? ~w_hm_ok : c_mw_err;
    assign mr_ready = r_hm ? (~r_hm_ok | (~sc_on & sd_req_ready & ~hm_rd)) : c_mr_ready;
    assign mr_err   = r_hm ? ~r_hm_ok : c_mr_err;
    assign mr_rsp_valid = c_rsp_valid | (hm_rd & sd_rsp_valid);
    assign mr_rsp_data  = (hm_rd & sd_rsp_valid) ? sd_rsp_rdata : c_rsp_data;

    // the SDRAM bus: the clear, else the core (UNITS = 2) or the host's PDM / DRAM requests (OWN)
    wire        o_valid = (OWN != 0) ? (hm_w | (hm_r & ~hm_rd)) : c_sd_valid;
    assign sd_req_valid = sc_on | o_valid;
    assign sd_req_we    = sc_on | ((OWN != 0) ? hm_w : c_sd_we);
    assign sd_req_addr  = sc_on ? {3'd0, (sc_pdm ? PDM_BASE : DRAM_BASE) | sc_a[19:0]} :
                          (OWN != 0) ? {3'd0, hm_sa} : c_sd_addr;
    assign sd_req_wdata = sc_on ? 64'd0 : (OWN != 0) ? mw_data : c_sd_wdata;
    assign sd_req_wmask = sc_on ? 8'hff : (OWN != 0) ? mw_mask : c_sd_wmask;

    // ---------------------------------------------------------------- LED
    // Only LED 0 is lit, steadily, at the lowest brightness (duty 1 / 2**LED_DIM_BITS): it just shows
    // that the design is loaded and running. The other LEDs stay off (contract 06 section 7).
    /* verilator lint_off UNUSEDSIGNAL */
    wire led_unused = dbg_rx_byte ^ dbg_tx_byte ^ dbg_err ^ dbg_probation ^ init_done ^ unit_busy ^ unit_err ^
                      sc_a[20];
    /* verilator lint_on UNUSEDSIGNAL */
    reg [LED_DIM_BITS-1:0] dim;
    always @(posedge clk) begin
        if (rst) dim <= {LED_DIM_BITS{1'b0}};
        else     dim <= dim + 1'b1;
    end
    assign led = {5'b11111, ~(dim == {LED_DIM_BITS{1'b0}})};
endmodule
`default_nettype wire

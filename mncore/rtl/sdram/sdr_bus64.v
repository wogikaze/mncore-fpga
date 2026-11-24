// sdr_bus64: the internal 64-bit memory bus (contract 06 section 6) on top of sdr_ctrl.
//
//   req_valid, req_ready, req_we, req_addr[22:0] (long words), req_wdata[63:0], req_wmask[7:0]
//   rsp_valid, rsp_rdata[63:0]   (one response per read, in request order, no back-pressure)
//
// Capacity is 8 MiB = 2**20 long words. req_addr[19:0] selects the long word; a request with
// req_addr[22:20] != 0 is executed on req_addr[19:0] and sets the sticky err_addr flag.
// Long word mapping: req_addr = { row[10:0], bank[1:0], colpair[6:0] }, so a sequential stream
// stays in one row for 128 long words (1 KiB) and then moves to the next bank.
//
// ASYNC = 0: the whole design runs on clk/rst (sclk/srst unused).
// ASYNC = 1: the bus side runs on clk/rst, the controller on sclk/srst. Requests and responses
//            cross through asynchronous FIFOs; the number of reads in flight is limited to
//            2**RAW so the response FIFO never overflows. Assert rst and srst together.
// cfg_rdx is in the controller domain and may change only while the controller is in reset.
// init_done is in the bus domain.
`default_nettype none

module sdr_bus64 #(
    parameter integer ASYNC     = 0,
    parameter integer QAW       = 3,       // request queue: 2**QAW entries
    parameter integer RAW       = 4,       // ASYNC: response queue / read credits: 2**RAW
    parameter integer FREQ_HZ   = 108000000,   // controller clock
    parameter integer CL        = 3,
    parameter integer T_RP_NS   = 20,
    parameter integer T_RCD_NS  = 20,
    parameter integer T_RC_NS   = 66,
    parameter integer T_RAS_NS  = 45,
    parameter integer T_RRD_NS  = 15,
    parameter integer T_WR_NS   = 15,
    parameter integer T_RFC_NS  = 66,
    parameter integer T_REFI_NS = 7800,
    parameter integer T_INIT_US = 200,
    parameter integer INIT_CYC  = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sclk,
    input  wire        srst,
    input  wire [1:0]  cfg_rdx,
    output wire        init_done,
    output reg         err_addr,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_we,
    input  wire [22:0] req_addr,
    input  wire [63:0] req_wdata,
    input  wire [7:0]  req_wmask,
    output reg         rsp_valid,
    output reg  [63:0] rsp_rdata,

    output wire        sdr_cke,
    output wire        sdr_cs_n,
    output wire        sdr_ras_n,
    output wire        sdr_cas_n,
    output wire        sdr_we_n,
    output wire [1:0]  sdr_ba,
    output wire [10:0] sdr_a,
    output wire [3:0]  sdr_dqm,
    output wire [31:0] sdr_dq_o,
    output wire [31:0] sdr_dq_oe,
    input  wire [31:0] sdr_dq_i
);
    localparam integer QW = 1 + 20 + 8 + 64;

    wire          c_clk = (ASYNC != 0) ? sclk : clk;
    wire          c_rst = (ASYNC != 0) ? srst : rst;

    wire          req_acc = req_valid && req_ready;
    wire [QW-1:0] q_in    = {req_we, req_addr[19:0], req_wmask, req_wdata};

    always @(posedge clk) begin
        if (rst) err_addr <= 1'b0;
        else if (req_acc && (req_addr[22:20] != 3'd0)) err_addr <= 1'b1;
    end

    // controller side of the request queue
    wire [QW-1:0] q_out;
    wire          q_empty;
    wire          cmd_ready;
    wire          q_pop = cmd_ready && !q_empty;

    wire          c_init_done;
    wire          rd_valid, rd_last;
    wire [31:0]   rd_data;

    sdr_ctrl #(
        .FREQ_HZ(FREQ_HZ), .CL(CL), .T_RP_NS(T_RP_NS), .T_RCD_NS(T_RCD_NS), .T_RC_NS(T_RC_NS),
        .T_RAS_NS(T_RAS_NS), .T_RRD_NS(T_RRD_NS), .T_WR_NS(T_WR_NS), .T_RFC_NS(T_RFC_NS),
        .T_REFI_NS(T_REFI_NS), .T_INIT_US(T_INIT_US), .INIT_CYC(INIT_CYC)
    ) u_ctrl (
        .clk(c_clk), .rst(c_rst), .cfg_rdx(cfg_rdx), .init_done(c_init_done),
        .cmd_valid(!q_empty), .cmd_ready(cmd_ready),
        .cmd_we(q_out[QW-1]), .cmd_addr(q_out[QW-2:72]), .cmd_wmask(q_out[71:64]), .cmd_wdata(q_out[63:0]),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_last(rd_last),
        .sdr_cke(sdr_cke), .sdr_cs_n(sdr_cs_n), .sdr_ras_n(sdr_ras_n), .sdr_cas_n(sdr_cas_n),
        .sdr_we_n(sdr_we_n), .sdr_ba(sdr_ba), .sdr_a(sdr_a), .sdr_dqm(sdr_dqm),
        .sdr_dq_o(sdr_dq_o), .sdr_dq_oe(sdr_dq_oe), .sdr_dq_i(sdr_dq_i)
    );

    // pack the two read beats (controller domain)
    reg  [31:0] lo;
    reg         pk_v;
    reg  [63:0] pk_d;
    always @(posedge c_clk) begin
        pk_v <= 1'b0;
        if (rd_valid && !rd_last) lo <= rd_data;
        if (rd_valid && rd_last) begin
            pk_v <= 1'b1;
            pk_d <= {rd_data, lo};
        end
        if (c_rst) pk_v <= 1'b0;
    end

    generate
        if (ASYNC == 0) begin : g_sync
            wire q_full;
            sdr_fifo #(.W(QW), .AW(QAW)) u_q (
                .clk(clk), .rst(rst), .we(req_acc), .wdata(q_in), .full(q_full),
                .re(q_pop), .rdata(q_out), .empty(q_empty)
            );
            assign req_ready = !q_full;
            assign init_done = c_init_done;

            always @(posedge clk) begin
                rsp_valid <= pk_v && !rst;
                if (pk_v) rsp_rdata <= pk_d;
            end
        end else begin : g_async
            wire q_full;
            sdr_afifo #(.W(QW), .AW(QAW)) u_q (
                .wclk(clk), .wrst(rst), .we(req_acc), .wdata(q_in), .wfull(q_full),
                .rclk(sclk), .rrst(srst), .re(q_pop), .rdata(q_out), .rempty(q_empty)
            );

            wire        r_empty;
            wire [63:0] r_data;
            /* verilator lint_off UNUSEDSIGNAL */
            wire        r_full;    // cannot fill up: reads in flight are limited by the credit counter
            /* verilator lint_on UNUSEDSIGNAL */
            sdr_afifo #(.W(64), .AW(RAW)) u_r (
                .wclk(sclk), .wrst(srst), .we(pk_v), .wdata(pk_d), .wfull(r_full),
                .rclk(clk), .rrst(rst), .re(!r_empty), .rdata(r_data), .rempty(r_empty)
            );

            // reads in flight (bus domain)
            reg [RAW:0] inflight;
            wire        rd_acc = req_acc && !req_we;
            assign req_ready = !q_full && (inflight != (1 << RAW));
            always @(posedge clk) begin
                if (rst) inflight <= {(RAW + 1){1'b0}};
                else inflight <= inflight + {{RAW{1'b0}}, rd_acc} - {{RAW{1'b0}}, rsp_valid};
            end

            always @(posedge clk) begin
                rsp_valid <= !r_empty && !rst;
                if (!r_empty) rsp_rdata <= r_data;
            end

            reg [1:0] id_sync;
            always @(posedge clk) begin
                if (rst) id_sync <= 2'b00;
                else id_sync <= {id_sync[0], c_init_done};
            end
            assign init_done = id_sync[1];
        end
    endgenerate
endmodule

`default_nettype wire

// Host interface: UART framing, CRC-8 check, command dispatch and responses.
// The wire protocol is specified in mncore/rtl/board/PROTOCOL.md (protocol version 1).
//
// Frame (both directions): 0xA5 | cmd u8 | len u16le | payload[len] | crc8
//   crc8 = CRC-8/SMBUS (poly 0x07, init 0x00, no reflection) over cmd, len and payload.
//   Responses use cmd | 0x80 and payload[0] = status.
//
// Core-side interfaces (all synchronous to clk):
//   memory write port  mw_*  : valid/ready; mw_err is sampled with mw_ready (1 = rejected, nothing written)
//   memory read port   mr_*  : valid/ready request, mr_err sampled with mr_ready (1 = rejected, no response);
//                              accepted requests return one mr_rsp_valid each, in order (may be the same cycle).
//   run control/status       : run_start pulse with run_pc/run_count, core_rst, core_busy and the stop record.
// The instruction memory is space 0 of the memory ports (WR_IMEM writes lanes 0..6 of each 448-bit entry to
// long-word address entry*8 + lane).
//
// The payload is buffered in pbuf (2**PBUF_AW bytes) and only executed after the CRC matched, so a corrupted
// frame never writes memory.  The same buffer holds response bodies (RD_MEM data, INFO, STATUS).
//
// Area (WP35): the counters are only as wide as the values they can take (word counters PBUF_AW - 2 bits,
// byte counters PBUF_AW + 1, the long-word address 24 bits plus a flag for the bits above), comparisons with
// constants are written as logic (yosys would make a carry chain of each), the up-counters that run until they
// reach a constant compare for equality, and the response bodies are selected by byte index from the fields.
// The behaviour at the pins is the same as before (PROTOCOL.md version 1).
module brd_host_if #(
    parameter CLK_HZ        = 27000000,
    parameter BAUD          = 1000000,     // reset baud rate (must be < 8 Mbaud for the divider formula)
    parameter DIVW          = 24,
    parameter PBUF_AW       = 11,          // payload buffer = 2**PBUF_AW bytes (7 .. 15)
    parameter RXF_AW        = 11,          // UART receive FIFO depth (log2 bytes)
    parameter TXF_AW        = 11,          // UART transmit FIFO depth (log2 bytes)
    parameter TIMEOUT_CYC   = CLK_HZ / 50, // inter-byte timeout inside a frame (20 ms)
    parameter PROBATION_CYC = CLK_HZ,      // SET_BAUD reverts unless a good frame arrives within this time
    parameter CORE_RST_CYC  = 16,          // length of core_rst after a RESET command
    parameter [7:0]   DESIGN_ID   = 8'h00,
    parameter [7:0]   INFO_FLAGS  = 8'h00,   // bit0: a real core is attached, bit1: run stub
    parameter [15:0]  IMEM_DEPTH  = 16'd0,   // instruction memory entries (448 bit)
    parameter [39:0]  TOPO        = 40'h0,   // byte0 n_grp, byte1 n_l2b, byte2 n_l1b, byte3 n_mab, byte4 n_pe
    parameter [511:0] SPACE_DEPTH = 512'h0   // u32 long-word depth of space id i at [32*i +: 32], 0 = absent
) (
    input  wire        clk,
    input  wire        rst,
    // UART pins
    input  wire        uart_rxd,
    output wire        uart_txd,
    // memory write port
    output wire        mw_valid,
    input  wire        mw_ready,
    input  wire        mw_err,
    output wire [7:0]  mw_space,
    output wire [15:0] mw_loc,
    output wire [22:0] mw_addr,
    output wire [63:0] mw_data,
    output wire [7:0]  mw_mask,
    // memory read port
    output wire        mr_valid,
    input  wire        mr_ready,
    input  wire        mr_err,
    output wire [7:0]  mr_space,
    output wire [15:0] mr_loc,
    output wire [22:0] mr_addr,
    input  wire        mr_rsp_valid,
    input  wire [63:0] mr_rsp_data,
    // run control / status
    output reg         run_start,
    output reg  [15:0] run_pc,
    output reg  [31:0] run_count,
    output reg         core_rst,
    input  wire        core_busy,
    input  wire [7:0]  core_reason,
    input  wire [31:0] core_info,
    input  wire [15:0] core_pc,
    input  wire [31:0] core_steps,
    // indicators
    output wire        dbg_rx_byte,
    output wire        dbg_tx_byte,
    output reg         dbg_err,
    output wire        dbg_probation
);
    // ------------------------------------------------------------------ constants
    localparam [7:0] PROTO_VER = 8'd1;
    localparam [7:0] SYNC      = 8'hA5;

    localparam [7:0] C_PING     = 8'h01;
    localparam [7:0] C_INFO     = 8'h02;
    localparam [7:0] C_WR_IMEM  = 8'h03;
    localparam [7:0] C_WR_MEM   = 8'h04;
    localparam [7:0] C_RD_MEM   = 8'h05;
    localparam [7:0] C_RUN      = 8'h06;
    localparam [7:0] C_STATUS   = 8'h07;
    localparam [7:0] C_RESET    = 8'h08;
    localparam [7:0] C_SET_BAUD = 8'h09;

    localparam [7:0] ST_OK      = 8'h00;
    localparam [7:0] ST_E_CRC   = 8'h01;
    localparam [7:0] ST_E_CMD   = 8'h02;
    localparam [7:0] ST_E_LEN   = 8'h03;
    localparam [7:0] ST_E_BUSY  = 8'h04;
    localparam [7:0] ST_E_RANGE = 8'h05;
    localparam [7:0] ST_E_ARG   = 8'h06;

    localparam [1:0] G_INFO = 2'd0, G_STATUS = 2'd1, G_ERR = 2'd2;
    localparam [15:0] INFO_LEN   = 16'd88;
    localparam [15:0] STATUS_LEN = 16'd27;

    localparam [16:0] PBUF_BYTES = 17'd1 << PBUF_AW;
    localparam [15:0] PBUF_U16   = PBUF_BYTES[15:0];
    localparam [15:0] RXF_U16    = 16'd1 << RXF_AW;
    localparam [15:0] TXF_U16    = 16'd1 << TXF_AW;
    localparam [31:0] CLK_U32    = CLK_HZ;
    localparam integer TMW = $clog2(TIMEOUT_CYC + 1);     // timeout counter width
    localparam integer PBW = $clog2(PROBATION_CYC + 1);   // probation counter width
    localparam [31:0]    TIMEOUT_U32   = TIMEOUT_CYC;
    localparam [31:0]    PROBATION_U32 = PROBATION_CYC;
    localparam [TMW-1:0] TIMEOUT_C     = TIMEOUT_U32[TMW-1:0];
    localparam [PBW-1:0] PROBATION_C   = PROBATION_U32[PBW-1:0];
    localparam [7:0]  CORE_RST_U8   = CORE_RST_CYC;
    localparam integer DIV_INIT_I = (CLK_HZ / BAUD) * 256 + ((CLK_HZ % BAUD) * 256 + BAUD / 2) / BAUD;
    localparam [31:0] DIV_INIT32 = DIV_INIT_I;
    localparam [DIVW-1:0] DIV_INIT = DIV_INIT32[DIVW-1:0];
    // DIV_MIN = 1024 (4 clocks per bit): SET_BAUD rejects values below it

    // counter widths (WP35)
    localparam integer NWW = PBUF_AW - 2;   // words of a frame: up to 2**PBUF_AW / 8
    localparam integer BLW = PBUF_AW + 1;   // bytes of a response body: up to 2**PBUF_AW
    localparam integer GIW = 7;             // generated body byte index: up to INFO_LEN = 88
    localparam [15:0] PBUF_LOW  = PBUF_U16 - 16'd1;                 // bits below 2**PBUF_AW
    localparam [15:0] NMAX_LOW  = (16'd1 << (PBUF_AW - 3)) - 16'd1; // bits below 2**(PBUF_AW - 3)

    // states
    localparam [4:0] S_RIDLE = 5'd0,  S_RCMD = 5'd1,  S_RLEN0 = 5'd2,  S_RLEN1 = 5'd3,
                     S_RPAY  = 5'd4,  S_RCRC = 5'd5,  S_DISP  = 5'd6,
                     S_WRD   = 5'd7,  S_WRD2 = 5'd8,  S_WREQ  = 5'd9,
                     S_RREQ  = 5'd10, S_RRSP = 5'd11, S_RST8  = 5'd12,
                     S_GEN   = 5'd13,
                     S_TA5   = 5'd14, S_TCMD = 5'd15, S_TLEN0 = 5'd16, S_TLEN1 = 5'd17,
                     S_TSTAT = 5'd18, S_TBF  = 5'd19, S_TBP   = 5'd20, S_TCRC  = 5'd21,
                     S_BAUDW = 5'd22;

    function [7:0] crc8;
        input [7:0] c;
        input [7:0] d;
        integer i;
        reg [7:0] x;
        begin
            x = c ^ d;
            for (i = 0; i < 8; i = i + 1)
                x = x[7] ? ({x[6:0], 1'b0} ^ 8'h07) : {x[6:0], 1'b0};
            crc8 = x;
        end
    endfunction

    // ------------------------------------------------------------------ UART
    reg  [DIVW-1:0] div;
    wire            rx_valid;
    wire [7:0]      rx_data;
    wire            rx_ready;
    wire            rx_ferr, rx_ovr;
    wire [15:0]     rx_meas;
    wire            tx_valid;
    wire            tx_ready;
    wire [7:0]      tx_data;
    wire            tx_idle;

    brd_uart_rx #(.DIVW(DIVW), .FIFO_AW(RXF_AW)) u_rx (
        .clk(clk), .rst(rst), .rxd(uart_rxd), .div_q8(div),
        .m_valid(rx_valid), .m_ready(rx_ready), .m_data(rx_data),
        .err_frame(rx_ferr), .err_overrun(rx_ovr), .byte_pulse(dbg_rx_byte), .meas(rx_meas)
    );

    brd_uart_tx #(.DIVW(DIVW), .FIFO_AW(TXF_AW)) u_tx (
        .clk(clk), .rst(rst), .div_q8(div),
        .s_valid(tx_valid), .s_ready(tx_ready), .s_data(tx_data),
        .txd(uart_txd), .idle(tx_idle), .byte_pulse(dbg_tx_byte)
    );

    // ------------------------------------------------------------------ state
    reg [4:0]  st;
    reg [7:0]  cmd;
    reg [15:0] len;
    reg [15:0] idx;          // payload byte index while receiving
    reg [7:0]  crc;
    reg [79:0] hdr;          // first 10 payload bytes, byte i at [8*i +: 8]
    reg [5:0]  m56;          // WR_IMEM: payload bytes after the header, modulo 56
    reg [TMW-1:0] tmo;

    reg [NWW-1:0] wi;        // word index in WR_MEM / WR_IMEM / RD_MEM (also the E_RANGE index)
    reg [NWW-1:0] nwords;
    reg [PBUF_AW-1:0] ptr;   // pbuf byte pointer (read for writes, write for reads)
    reg [2:0]  kk;           // byte within the 64-bit word
    reg [2:0]  lane;         // WR_IMEM lane 0..6
    reg        is_imem;
    // long-word address of the current word: ca, and ca_hi = bits 31..24 of the frame's address are not 0.
    // A word is only sent while the address is below 2**23 (ca_hi = 0, ca[23] = 0); the address grows by 1 or 2
    // per word, so ca never wraps before the command stops.
    reg [23:0] ca;
    reg        ca_hi;
    reg [63:0] wsr;          // assembled write word / read word shift register

    reg [7:0]  rstatus;
    reg [BLW-1:0] blen;
    reg [BLW-1:0] bi;
    reg [1:0]  gkind;
    reg [GIW-1:0] gi;
    reg [GIW-1:0] glen;

    reg [DIVW-1:0] div_prev;
    reg [DIVW-1:0] div_new;
    reg        baud_pending;
    reg        probation;
    reg [PBW-1:0] prob_cnt;
    reg [7:0]  crst_cnt;

    reg [15:0] cnt_crc, cnt_frame, cnt_ovr, cnt_tmo;

    // ------------------------------------------------------------------ decoded header fields
    wire [15:0] h_u16_0  = hdr[15:0];
    wire [7:0]  h_space  = hdr[7:0];
    wire [7:0]  h_mask   = hdr[15:8];
    wire [15:0] h_loc    = hdr[31:16];
    wire [31:0] h_addr   = hdr[63:32];
    wire [15:0] h_n      = hdr[79:64];
    wire [31:0] h_count  = hdr[47:16];
    wire [31:0] h_u32_0  = hdr[31:0];

    wire        rx_state = (st == S_RIDLE) || (st == S_RCMD) || (st == S_RLEN0) || (st == S_RLEN1) ||
                           (st == S_RPAY) || (st == S_RCRC);
    assign rx_ready = rx_state;
    wire        rx_fire = rx_valid && rx_ready;

    wire        addr_ok = ~ca_hi & ~ca[23];

    // comparisons with constants, as logic
    wire        idx_hdr  = (idx[15:4] == 12'd0) & ~(idx[3] & (idx[2] | idx[1]));   // idx < 10
    wire        idx_pbuf = ((idx >> PBUF_AW) == 16'd0);                          // idx < 2**PBUF_AW
    wire        len_big  = ((len >> (PBUF_AW + 1)) != 16'd0) |                   // len > 2**PBUF_AW
                           (len[PBUF_AW] & ((len & PBUF_LOW) != 16'd0));
    wire        n_big    = ((h_n >> (PBUF_AW - 2)) != 16'd0) |                   // h_n * 8 > 2**PBUF_AW
                           (h_n[PBUF_AW-3] & ((h_n & NMAX_LOW) != 16'd0));
    wire        div_bad  = ((h_u32_0 >> 10) == 32'd0) |                          // < DIV_MIN or too wide
                           ((h_u32_0 >> DIVW) != 32'd0);
    // words of WR_MEM ((len - 8) / 8) and WR_IMEM ((len - 2) / 8), with len <= 2**PBUF_AW
    /* verilator lint_off UNUSEDSIGNAL */   // bits 2..0 are below the word
    wire [PBUF_AW:0] nw_sub = len[PBUF_AW:0] - {{(PBUF_AW-3){1'b0}}, (cmd == C_WR_MEM), 1'b0, (cmd != C_WR_MEM), 1'b0};
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------ payload buffer
    wire                pb_we;
    wire [PBUF_AW-1:0]  pb_waddr;
    wire [7:0]          pb_wdata;
    wire                pb_re;
    wire [PBUF_AW-1:0]  pb_raddr;
    wire [7:0]          pb_rdata;
    reg  [7:0]          gen_byte;

    assign pb_we    = ((st == S_RPAY) && rx_fire && idx_pbuf) ||
                      (st == S_RST8) || (st == S_GEN);
    assign pb_waddr = (st == S_RPAY) ? idx[PBUF_AW-1:0] :
                      (st == S_RST8) ? ptr : {{(PBUF_AW-GIW){1'b0}}, gi};
    assign pb_wdata = (st == S_RPAY) ? rx_data :
                      (st == S_RST8) ? wsr[7:0] : gen_byte;
    assign pb_re    = (st == S_WRD) || (st == S_TBF);
    assign pb_raddr = (st == S_WRD) ? ptr : bi[PBUF_AW-1:0];

    brd_ram_1r1w #(.W(8), .AW(PBUF_AW)) u_pbuf (
        .clk(clk), .we(pb_we), .waddr(pb_waddr), .wdata(pb_wdata),
        .re(pb_re), .raddr(pb_raddr), .rdata(pb_rdata)
    );

    // ------------------------------------------------------------------ generated response bodies
    // INFO: constant except div (bytes 8..11); STATUS: the registers and the core's stop record;
    // the E_RANGE body: the word index. Byte gi of the body (little endian fields).
    wire [31:0]  div32 = {{(32-DIVW){1'b0}}, div};
    localparam [703:0] INFO_C = {TXF_U16, RXF_U16, SPACE_DEPTH, INFO_FLAGS, TOPO, IMEM_DEPTH,
                                 32'd0, CLK_U32, PBUF_U16, DESIGN_ID, PROTO_VER};
    wire [7:0]   hflags   = {6'd0, baud_pending, probation};
    wire [215:0] stat_vec = {hflags, div32, rx_meas, cnt_tmo, cnt_ovr, cnt_frame, cnt_crc,
                             core_steps, core_info, core_pc, core_reason, {7'd0, core_busy}};
    wire [7:0]   info_b = (gi[6:2] == 5'd2) ? div32[{gi[1:0], 3'b000} +: 8] : INFO_C[{gi, 3'b000} +: 8];
    wire [7:0]   stat_b = stat_vec[{gi[4:0], 3'b000} +: 8];
    wire [15:0]  wi16   = {{(16-NWW){1'b0}}, wi};
    wire [7:0]   err_b  = gi[1] ? 8'd0 : gi[0] ? wi16[15:8] : wi16[7:0];
    always @(*) begin
        case (gkind)
            G_INFO:   gen_byte = info_b;
            G_STATUS: gen_byte = stat_b;
            default:  gen_byte = err_b;
        endcase
    end

    // ------------------------------------------------------------------ transmit side
    wire [BLW-1:0] rlen_b = blen + 1'b1;   // blen <= 2**PBUF_AW, so no carry out
    wire [15:0]    rlen   = {{(16-BLW){1'b0}}, rlen_b};
    assign tx_valid = (st == S_TA5) || (st == S_TCMD) || (st == S_TLEN0) || (st == S_TLEN1) ||
                      (st == S_TSTAT) || (st == S_TBP) || (st == S_TCRC);
    assign tx_data  = (st == S_TA5)   ? SYNC :
                      (st == S_TCMD)  ? (cmd | 8'h80) :
                      (st == S_TLEN0) ? rlen[7:0] :
                      (st == S_TLEN1) ? rlen[15:8] :
                      (st == S_TSTAT) ? rstatus :
                      (st == S_TBP)   ? pb_rdata : crc;
    wire tx_fire = tx_valid && tx_ready;

    // one shared CRC-8 step: receive states hash rx_data (restarting at the cmd byte), transmit states tx_data
    // (the transmit side restarts by clearing crc when the sync byte goes out)
    wire [7:0] crc_next = crc8((st == S_RCMD) ? 8'd0 : crc, rx_state ? rx_data : tx_data);

    // ------------------------------------------------------------------ memory ports
    assign mw_valid = (st == S_WREQ) && addr_ok;
    assign mw_space = is_imem ? 8'h00 : h_space;
    assign mw_loc   = is_imem ? 16'h0000 : h_loc;
    assign mw_addr  = ca[22:0];
    assign mw_data  = wsr;
    assign mw_mask  = is_imem ? 8'hFF : h_mask;

    assign mr_valid = (st == S_RREQ) && addr_ok;
    assign mr_space = h_space;
    assign mr_loc   = h_loc;
    assign mr_addr  = ca[22:0];

    // next word address: + 2 after lane 6 of a WR_IMEM entry (lane 7 is not used), else + 1
    wire [23:0] ca_next = ca + {22'd0, is_imem & (lane == 3'd6), ~(is_imem & (lane == 3'd6))};
    // shared incrementers
    wire [15:0]    idx_next = idx + 1'b1;
    wire [NWW-1:0] wi_next = wi + 1'b1;
    wire [GIW-1:0] gi_next = gi + 1'b1;
    wire [BLW-1:0] bi_next = bi + 1'b1;

    assign dbg_probation = probation;

    // ------------------------------------------------------------------ main FSM
    integer hb;
    always @(posedge clk) begin
        if (rst) begin
            st           <= S_RIDLE;
            cmd          <= 8'd0;
            len          <= 16'd0;
            idx          <= 16'd0;
            crc          <= 8'd0;
            hdr          <= 80'd0;
            m56          <= 6'd0;
            tmo          <= {TMW{1'b0}};
            wi           <= {NWW{1'b0}};
            nwords       <= {NWW{1'b0}};
            ptr          <= {PBUF_AW{1'b0}};
            kk           <= 3'd0;
            lane         <= 3'd0;
            is_imem      <= 1'b0;
            ca           <= 24'd0;
            ca_hi        <= 1'b0;
            wsr          <= 64'd0;
            rstatus      <= 8'd0;
            blen         <= {BLW{1'b0}};
            bi           <= {BLW{1'b0}};
            gkind        <= G_INFO;
            gi           <= {GIW{1'b0}};
            glen         <= {GIW{1'b0}};
            div          <= DIV_INIT;
            div_prev     <= DIV_INIT;
            div_new      <= DIV_INIT;
            baud_pending <= 1'b0;
            probation    <= 1'b0;
            prob_cnt     <= {PBW{1'b0}};
            crst_cnt     <= CORE_RST_U8;
            core_rst     <= 1'b1;
            run_start    <= 1'b0;
            run_pc       <= 16'd0;
            run_count    <= 32'd0;
            cnt_crc      <= 16'd0;
            cnt_frame    <= 16'd0;
            cnt_ovr      <= 16'd0;
            cnt_tmo      <= 16'd0;
            dbg_err      <= 1'b0;
        end else begin
            run_start <= 1'b0;
            dbg_err   <= 1'b0;

            // core reset stretcher
            if (crst_cnt != 8'd0) begin
                crst_cnt <= crst_cnt - 1'b1;
                core_rst <= 1'b1;
            end else begin
                core_rst <= 1'b0;
            end

            // UART error counters (saturating)
            if (rx_ferr && cnt_frame != 16'hffff) cnt_frame <= cnt_frame + 1'b1;
            if (rx_ovr  && cnt_ovr   != 16'hffff) cnt_ovr   <= cnt_ovr + 1'b1;
            if (rx_ferr || rx_ovr) dbg_err <= 1'b1;

            // baud-rate probation: revert unless a good frame arrived in time. prob_cnt counts up from 0 by 1
            // and stops at PROBATION_C, so "reached" is an equality.
            if (probation) begin
                if (prob_cnt == PROBATION_C) begin
                    probation <= 1'b0;
                    div       <= div_prev;
                end else begin
                    prob_cnt <= prob_cnt + 1'b1;
                end
            end

            // inter-byte timeout inside a frame (tmo counts up from 0 by 1 and restarts at TIMEOUT_C)
            if (st == S_RCMD || st == S_RLEN0 || st == S_RLEN1 || st == S_RPAY || st == S_RCRC) begin
                if (rx_fire) begin
                    tmo <= {TMW{1'b0}};
                end else if (tmo == TIMEOUT_C) begin
                    tmo <= {TMW{1'b0}};
                    st  <= S_RIDLE;
                    if (cnt_tmo != 16'hffff) cnt_tmo <= cnt_tmo + 1'b1;
                    dbg_err <= 1'b1;
                end else begin
                    tmo <= tmo + 1'b1;
                end
            end else begin
                tmo <= {TMW{1'b0}};
            end

            case (st)
                // ---------------------------------------------------------- receive
                S_RIDLE: begin
                    if (rx_fire && rx_data == SYNC) st <= S_RCMD;
                end
                S_RCMD: begin
                    if (rx_fire) begin
                        cmd <= rx_data;
                        crc <= crc_next;
                        st  <= S_RLEN0;
                    end
                end
                S_RLEN0: begin
                    if (rx_fire) begin
                        len[7:0] <= rx_data;
                        crc      <= crc_next;
                        st       <= S_RLEN1;
                    end
                end
                S_RLEN1: begin
                    if (rx_fire) begin
                        len[15:8] <= rx_data;
                        crc       <= crc_next;
                        idx       <= 16'd0;
                        m56       <= 6'd0;
                        hdr       <= 80'd0;
                        st        <= ({rx_data, len[7:0]} == 16'd0) ? S_RCRC : S_RPAY;
                    end
                end
                S_RPAY: begin
                    if (rx_fire) begin
                        crc <= crc_next;
                        for (hb = 0; hb < 10; hb = hb + 1)
                            if (idx_hdr && idx[3:0] == hb[3:0]) hdr[8*hb +: 8] <= rx_data;
                        if (idx[15:1] != 15'd0) m56 <= (m56 == 6'd55) ? 6'd0 : (m56 + 1'b1);
                        idx <= idx_next;
                        if (idx_next == len) st <= S_RCRC;
                    end
                end
                S_RCRC: begin
                    if (rx_fire) begin
                        if (rx_data == crc) begin
                            probation <= 1'b0;          // a good frame commits a new baud rate
                            st        <= S_DISP;
                        end else begin
                            if (cnt_crc != 16'hffff) cnt_crc <= cnt_crc + 1'b1;
                            dbg_err <= 1'b1;
                            rstatus <= ST_E_CRC;
                            blen    <= {BLW{1'b0}};
                            st      <= S_TA5;
                        end
                    end
                end

                // ---------------------------------------------------------- dispatch
                S_DISP: begin
                    blen <= {BLW{1'b0}};
                    gi   <= {GIW{1'b0}};
                    wi   <= {NWW{1'b0}};
                    kk   <= 3'd0;
                    lane <= 3'd0;
                    if (len_big) begin
                        rstatus <= ST_E_LEN;
                        st      <= S_TA5;
                    end else begin
                        case (cmd)
                            C_PING: begin
                                rstatus <= ST_OK;
                                blen    <= len[BLW-1:0];   // len <= 2**PBUF_AW here
                                st      <= S_TA5;
                            end
                            C_INFO, C_STATUS: begin
                                if (len != 16'd0) begin
                                    rstatus <= ST_E_LEN;
                                    st      <= S_TA5;
                                end else begin
                                    rstatus <= ST_OK;
                                    gkind   <= (cmd == C_INFO) ? G_INFO : G_STATUS;
                                    glen    <= (cmd == C_INFO) ? INFO_LEN[GIW-1:0] : STATUS_LEN[GIW-1:0];
                                    st      <= S_GEN;
                                end
                            end
                            C_RESET: begin
                                if (len[15:1] != 15'd0) begin   // len > 1
                                    rstatus <= ST_E_LEN;
                                end else begin
                                    rstatus  <= ST_OK;
                                    crst_cnt <= CORE_RST_U8;
                                    core_rst <= 1'b1;
                                    if (len == 16'd1 && hdr[0]) begin
                                        cnt_crc   <= 16'd0;
                                        cnt_frame <= 16'd0;
                                        cnt_ovr   <= 16'd0;
                                        cnt_tmo   <= 16'd0;
                                    end
                                end
                                st <= S_TA5;
                            end
                            C_RUN: begin
                                if (len != 16'd6) begin
                                    rstatus <= ST_E_LEN;
                                end else if (core_busy || core_rst) begin
                                    rstatus <= ST_E_BUSY;
                                end else begin
                                    rstatus   <= ST_OK;
                                    run_pc    <= h_u16_0;
                                    run_count <= h_count;
                                    run_start <= 1'b1;
                                end
                                st <= S_TA5;
                            end
                            C_SET_BAUD: begin
                                if (len != 16'd4) begin
                                    rstatus <= ST_E_LEN;
                                end else if (div_bad) begin
                                    rstatus <= ST_E_ARG;
                                end else begin
                                    rstatus      <= ST_OK;
                                    div_new      <= h_u32_0[DIVW-1:0];
                                    baud_pending <= 1'b1;
                                end
                                st <= S_TA5;
                            end
                            C_WR_MEM, C_WR_IMEM: begin
                                is_imem <= (cmd == C_WR_IMEM);
                                if (cmd == C_WR_MEM ? (len[15:3] == 13'd0 || len[2:0] != 3'd0)
                                                    : (len[15:1] == 15'd0 || m56 != 6'd0)) begin
                                    rstatus <= ST_E_LEN;
                                    st      <= S_TA5;
                                end else if (core_busy) begin
                                    rstatus <= ST_E_BUSY;
                                    st      <= S_TA5;
                                end else begin
                                    nwords <= nw_sub[NWW+2:3];
                                    if (cmd == C_WR_MEM) begin
                                        ptr   <= {{(PBUF_AW-4){1'b0}}, 4'd8};
                                        ca    <= h_addr[23:0];
                                        ca_hi <= (h_addr[31:24] != 8'd0);
                                        st    <= (len == 16'd8) ? S_TA5 : S_WRD;
                                    end else begin
                                        ptr   <= {{(PBUF_AW-4){1'b0}}, 4'd2};
                                        ca    <= {5'd0, h_u16_0, 3'd0};
                                        ca_hi <= 1'b0;
                                        st    <= (len == 16'd2) ? S_TA5 : S_WRD;
                                    end
                                    rstatus <= ST_OK;
                                end
                            end
                            C_RD_MEM: begin
                                is_imem <= 1'b0;
                                if (len != 16'd10) begin
                                    rstatus <= ST_E_LEN;
                                    st      <= S_TA5;
                                end else if (n_big) begin
                                    rstatus <= ST_E_ARG;
                                    st      <= S_TA5;
                                end else if (core_busy) begin
                                    rstatus <= ST_E_BUSY;
                                    st      <= S_TA5;
                                end else begin
                                    rstatus  <= ST_OK;
                                    nwords   <= h_n[NWW-1:0];   // h_n <= 2**(PBUF_AW - 3) here
                                    ptr      <= {PBUF_AW{1'b0}};
                                    ca       <= h_addr[23:0];
                                    ca_hi    <= (h_addr[31:24] != 8'd0);
                                    st       <= (h_n == 16'd0) ? S_TA5 : S_RREQ;
                                end
                            end
                            default: begin
                                rstatus <= ST_E_CMD;
                                st      <= S_TA5;
                            end
                        endcase
                    end
                end

                // ---------------------------------------------------------- write loop
                S_WRD: st <= S_WRD2;
                S_WRD2: begin
                    wsr <= {pb_rdata, wsr[63:8]};
                    ptr <= ptr + 1'b1;
                    kk  <= kk + 1'b1;
                    st  <= (kk == 3'd7) ? S_WREQ : S_WRD;
                end
                S_WREQ: begin
                    // E_RANGE: the body is the index wi of the failed word (it does not change any more)
                    if (!addr_ok) begin
                        rstatus <= ST_E_RANGE;
                        gkind   <= G_ERR;
                        glen    <= 7'd4;
                        st      <= S_GEN;
                    end else if (mw_ready) begin
                        if (mw_err) begin
                            rstatus <= ST_E_RANGE;
                            gkind   <= G_ERR;
                            glen    <= 7'd4;
                            st      <= S_GEN;
                        end else begin
                            wi   <= wi_next;
                            ca   <= ca_next;
                            lane <= (is_imem && lane == 3'd6) ? 3'd0 : (lane + 1'b1);
                            st   <= (wi_next == nwords) ? S_TA5 : S_WRD;
                        end
                    end
                end

                // ---------------------------------------------------------- read loop
                S_RREQ: begin
                    if (!addr_ok) begin
                        rstatus <= ST_E_RANGE;
                        gkind   <= G_ERR;
                        glen    <= 7'd4;
                        st      <= S_GEN;
                    end else if (mr_ready) begin
                        if (mr_err) begin
                            rstatus <= ST_E_RANGE;
                            gkind   <= G_ERR;
                            glen    <= 7'd4;
                            st      <= S_GEN;
                        end else if (mr_rsp_valid) begin
                            wsr <= mr_rsp_data;
                            kk  <= 3'd0;
                            st  <= S_RST8;
                        end else begin
                            st <= S_RRSP;
                        end
                    end
                end
                S_RRSP: begin
                    if (mr_rsp_valid) begin
                        wsr <= mr_rsp_data;
                        kk  <= 3'd0;
                        st  <= S_RST8;
                    end
                end
                S_RST8: begin
                    wsr <= {8'd0, wsr[63:8]};
                    ptr <= ptr + 1'b1;
                    kk  <= kk + 1'b1;
                    if (kk == 3'd7) begin
                        wi <= wi_next;
                        ca <= ca_next;   // + 1 (is_imem = 0)
                        if (wi_next == nwords) begin
                            blen <= {nwords, 3'b000};
                            st   <= S_TA5;
                        end else begin
                            st <= S_RREQ;
                        end
                    end
                end

                // ---------------------------------------------------------- generated body
                S_GEN: begin
                    gi <= gi_next;
                    if (gi_next == glen) begin
                        blen <= {{(BLW-GIW){1'b0}}, glen};
                        st   <= S_TA5;
                    end
                end

                // ---------------------------------------------------------- transmit
                S_TA5: begin
                    if (tx_fire) begin
                        crc <= 8'd0;
                        bi  <= {BLW{1'b0}};
                        st  <= S_TCMD;
                    end
                end
                S_TCMD: begin
                    if (tx_fire) begin
                        crc <= crc_next;
                        st  <= S_TLEN0;
                    end
                end
                S_TLEN0: begin
                    if (tx_fire) begin
                        crc <= crc_next;
                        st  <= S_TLEN1;
                    end
                end
                S_TLEN1: begin
                    if (tx_fire) begin
                        crc <= crc_next;
                        st  <= S_TSTAT;
                    end
                end
                S_TSTAT: begin
                    if (tx_fire) begin
                        crc <= crc_next;
                        st  <= (blen == {BLW{1'b0}}) ? S_TCRC : S_TBF;
                    end
                end
                S_TBF: st <= S_TBP;
                S_TBP: begin
                    if (tx_fire) begin
                        crc <= crc_next;
                        bi  <= bi_next;
                        st  <= (bi_next == blen) ? S_TCRC : S_TBF;
                    end
                end
                S_TCRC: begin
                    if (tx_fire) st <= baud_pending ? S_BAUDW : S_RIDLE;
                end
                S_BAUDW: begin
                    // switch only after the OK response has fully left the transmitter
                    if (tx_idle) begin
                        div_prev     <= div;
                        div          <= div_new;
                        baud_pending <= 1'b0;
                        probation    <= 1'b1;
                        prob_cnt     <= {PBW{1'b0}};
                        st           <= S_RIDLE;
                    end
                end
                default: st <= S_RIDLE;
            endcase
        end
    end
endmodule

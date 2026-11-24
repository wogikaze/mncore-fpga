// sdr_ctrl: SDR SDRAM controller for the 64 Mbit SDRAM embedded in the GW2AR-18 (Tang Nano 20K).
//
// Geometry: 4 banks x 2048 rows x 256 columns x 32 bit = 8 MiB.
// One command moves one "pair" = two consecutive 32-bit columns (burst length 2).
//
//   cmd_addr[19:0] = { row[10:0], bank[1:0], colpair[6:0] }   (column = {colpair, beat})
//   write: cmd_wdata[31:0] / cmd_wmask[3:0] go to the even column (beat 0),
//          cmd_wdata[63:32] / cmd_wmask[7:4] to the odd column (beat 1). wmask bit = 1: write the byte.
//   read : two beats come back on rd_data (beat 0 first, rd_last on beat 1), in command order.
//
// Scheduling: open-page policy. Column commands are issued strictly in order. While the head
// request waits, ACTIVATE / PRECHARGE for the next request (if it targets another bank) can be
// issued early. Auto refresh every T_REFI_NS (precharge-all + refresh).
// For timing, the row-hit state of the two queued requests and all timing constraints are kept in
// registers; after any change of the queue or of the bank state the scheduler waits one cycle.
//
// Board-dependent read timing: the controller samples DQ with a plain register and takes beat 0 from
// it CL + cfg_rdx cycles after the clock edge that put the READ command on the pins. (nextpnr's IOB
// register packing is not used: it broke a UART on the board, see README.md.) cfg_rdx (0..3) and the phase of the SDRAM clock are calibrated on the
// board (see mncore/rtl/sdram/README.md). cfg_rdx may change only while rst is asserted.
//
// All SDRAM outputs are registered; sdr_dq_oe is one bit per DQ line (active high).
// The SDRAM clock itself is generated outside (PLL phase output + ODDR, see sdr_gw_clkout).
`default_nettype none

module sdr_ctrl #(
    parameter integer FREQ_HZ   = 108000000,
    parameter integer CL        = 3,      // CAS latency, 2 or 3 (CL2 only up to 100 MHz)
    parameter integer T_RP_NS   = 20,
    parameter integer T_RCD_NS  = 20,
    parameter integer T_RC_NS   = 66,
    parameter integer T_RAS_NS  = 45,
    parameter integer T_RRD_NS  = 15,
    parameter integer T_WR_NS   = 15,
    parameter integer T_RFC_NS  = 66,
    parameter integer T_REFI_NS = 7800,   // 8192 refreshes / 64 ms (2x the 4096 the part needs)
    parameter integer T_INIT_US = 200,
    parameter integer INIT_CYC  = 0       // > 0: power-up wait in cycles (simulation shortcut)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  cfg_rdx,
    output reg         init_done,

    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_we,
    input  wire [19:0] cmd_addr,
    input  wire [63:0] cmd_wdata,
    input  wire [7:0]  cmd_wmask,

    output reg         rd_valid,
    output reg  [31:0] rd_data,
    output reg         rd_last,

    output reg         sdr_cke,
    output reg         sdr_cs_n,
    output reg         sdr_ras_n,
    output reg         sdr_cas_n,
    output reg         sdr_we_n,
    output reg  [1:0]  sdr_ba,
    output reg  [10:0] sdr_a,
    output reg  [3:0]  sdr_dqm,
    output reg  [31:0] sdr_dq_o,
    output reg  [31:0] sdr_dq_oe,
    input  wire [31:0] sdr_dq_i
);
    // ------------------------------------------------------------------ timing (cycles)
    localparam integer FKHZ = FREQ_HZ / 1000;

    function integer ns2cyc;               // ceil(ns * f), at least 1
        input integer ns;
        integer c;
        begin
            c = (ns * FKHZ + 999999) / 1000000;
            ns2cyc = (c < 1) ? 1 : c;
        end
    endfunction

    localparam integer NRP   = ns2cyc(T_RP_NS);
    localparam integer NRCD  = ns2cyc(T_RCD_NS);
    localparam integer NRC   = ns2cyc(T_RC_NS);
    localparam integer NRAS0 = ns2cyc(T_RAS_NS);
    // tRC is enforced through tRAS + tRP (ACT -> PRE -> ACT on one bank)
    localparam integer NRAS  = (NRAS0 + NRP < NRC) ? NRC - NRP : NRAS0;
    localparam integer NRRD  = ns2cyc(T_RRD_NS);
    localparam integer NWR0  = ns2cyc(T_WR_NS);
    localparam integer NWR   = (NWR0 < 2) ? 2 : NWR0;
    localparam integer NRFC  = ns2cyc(T_RFC_NS);
    localparam integer NREFI = ns2cyc(T_REFI_NS);
    localparam integer NINIT = (INIT_CYC > 0) ? INIT_CYC : (T_INIT_US * FKHZ) / 1000;
    localparam integer NMRD  = 3;
    localparam integer NR2W  = CL + 4;     // READ -> WRITE (bus turnaround with one idle cycle)

    // timer loads = gap - 1
    localparam integer IRP   = NRP - 1;
    localparam integer IRCD  = NRCD - 1;
    localparam integer IRAS  = NRAS - 1;
    localparam integer IRRD  = NRRD - 1;
    localparam integer IRFC  = NRFC - 1;
    localparam integer IR2W  = NR2W - 1;
    localparam integer IINIT = NINIT - 1;
    localparam integer IREFI = NREFI - 1;
    localparam integer IMRD  = NMRD - 1;
    localparam [4:0]  L_RP    = IRP[4:0];
    localparam [4:0]  L_RCD   = IRCD[4:0];
    localparam [4:0]  L_RAS   = IRAS[4:0];
    localparam [4:0]  L_RRD   = IRRD[4:0];
    localparam [4:0]  L_WR    = NWR[4:0];  // WRITE -> PRE: 1 (second beat) + tWR
    localparam [4:0]  L_RFC   = IRFC[4:0];
    localparam [4:0]  L_R2W   = IR2W[4:0];
    localparam [4:0]  L_ONE   = 5'd1;      // gap of 2 (burst length)
    localparam [15:0] L_INIT  = IINIT[15:0];
    localparam [15:0] L_REFI  = IREFI[15:0];
    localparam [15:0] L_RP16  = IRP[15:0];
    localparam [15:0] L_RFC16 = IRFC[15:0];
    localparam [15:0] L_MRD16 = IMRD[15:0];

    // mode register: burst write, CL, sequential, BL = 2
    localparam [2:0]  CL3B = CL[2:0];
    localparam [3:0]  CL4B = CL[3:0];
    localparam [10:0] MODE = {1'b0, 1'b0, 2'b00, CL3B, 1'b0, 3'b001};

    // ------------------------------------------------------------------ state
    localparam [2:0] S_WAIT = 3'd0, S_REF1 = 3'd2, S_REF2 = 3'd3, S_MRS = 3'd4, S_RUN = 3'd5;
    reg [2:0]  st;
    reg [15:0] wcnt;
    reg        wz;                         // wcnt == 0

    // request window: head (h) and next (n), with registered bank-state flags
    reg        h_v, n_v;
    reg        h_we, n_we;
    reg [19:0] h_addr, n_addr;
    reg [63:0] h_wd, n_wd;
    reg [7:0]  h_wm, n_wm;
    reg        h_open, h_hit, n_open, n_hit, n_la;
    reg        h_stale, n_stale;           // the flags are one cycle old (queue / bank state changed)

    reg [3:0]  bk_open;
    reg [10:0] bk_row [0:3];

    reg [15:0] ref_t;
    reg        ref_z, ref_pend;

    reg        wb2;                        // second write beat pending
    reg [31:0] wb2_d;
    reg [3:0]  wb2_dqm;

    reg [11:0] rdsh;                       // READ tokens: rdsh[j] = a READ went to the pins j edges ago
    reg [31:0] dq_in_r;                    // input capture register
    wire [3:0] rx0 = CL4B + {2'b00, cfg_rdx};   // beat 0 position in rdsh

    wire [1:0]  hb = h_addr[8:7];
    wire [10:0] hr = h_addr[19:9];
    wire [1:0]  nb = n_addr[8:7];
    wire [10:0] nr = n_addr[19:9];

    // ------------------------------------------------------------------ decision
    // timer outputs (timers below): 1 = the constraint is met in this cycle
    wire [3:0] act_ok, rcd_ok, ras_ok, wr_ok, rdp_ok;
    wire       rrd_ok, rd_ok, w_ok;
    wire [3:0] pre_ok = ras_ok & wr_ok & rdp_ok;

    wire h_rw_ok  = rcd_ok[hb] && (h_we ? w_ok : rd_ok);
    wire h_pre_ok = pre_ok[hb];
    wire h_act_ok = act_ok[hb] && rrd_ok;
    wire n_pre_ok = pre_ok[nb];
    wire n_act_ok = act_ok[nb] && rrd_ok;
    wire all_pre_ok = &(pre_ok | ~bk_open);
    wire all_act_ok = &act_ok;

    // Priority: refresh (PREA, REF) > head column command > head PRE / ACT > next PRE / ACT.
    // The command is decided as one-hot "is_*" signals (at most one is 1).
    wire g_ref   = init_done && ref_pend;
    wire is_prea = g_ref && (|bk_open) && all_pre_ok;
    wire is_ref  = g_ref && !(|bk_open) && all_act_ok;

    wire g_h     = init_done && !ref_pend && !h_stale && h_v;
    wire c_col   = h_hit && h_rw_ok;
    wire c_hpre  = h_open && !h_hit && h_pre_ok;
    wire c_hact  = !h_open && h_act_ok;
    wire is_rd   = g_h && c_col && !h_we;
    wire is_wr   = g_h && c_col && h_we;
    wire is_hpre = g_h && c_hpre;
    wire is_hact = g_h && c_hact;

    wire g_n     = init_done && !ref_pend && !h_stale && !(h_v && (c_col || c_hpre || c_hact)) &&
                   n_v && !n_stale && n_la;
    wire is_npre = g_n && n_open && !n_hit && n_pre_ok;
    wire is_nact = g_n && !n_open && n_act_ok;

    wire is_act  = is_hact || is_nact;
    wire is_pre  = is_hpre || is_npre;
    wire dsel_n  = is_npre || is_nact;      // the ACT/PRE is for the next request, not the head
    wire pop     = is_rd || is_wr;

    wire [1:0]  db  = dsel_n ? nb : hb;
    wire [10:0] dr  = dsel_n ? nr : hr;

    // ------------------------------------------------------------------ timing constraint timers
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_bank
            // ACT allowed: tRP after PRE / PREA, tRFC after REF
            sdr_tmr u_act (.clk(clk), .rst(rst),
                .load((is_pre && (db == g)) || is_prea || is_ref),
                .val(is_ref ? L_RFC : L_RP), .ok(act_ok[g]));
            // READ / WRITE allowed: tRCD after ACT
            sdr_tmr u_rcd (.clk(clk), .rst(rst), .load(is_act && (db == g)),
                .val(L_RCD), .ok(rcd_ok[g]));
            // PRE allowed: tRAS after ACT, tWR after WRITE, end of burst after READ
            sdr_tmr u_ras (.clk(clk), .rst(rst), .load(is_act && (db == g)),
                .val(L_RAS), .ok(ras_ok[g]));
            sdr_tmr u_wr (.clk(clk), .rst(rst), .load(is_wr && (hb == g)),
                .val(L_WR), .ok(wr_ok[g]));
            sdr_tmr #(.W(1)) u_rdp (.clk(clk), .rst(rst), .load(is_rd && (hb == g)),
                .val(1'b1), .ok(rdp_ok[g]));
        end
    endgenerate

    sdr_tmr u_rrd (.clk(clk), .rst(rst), .load(is_act), .val(L_RRD), .ok(rrd_ok));
    sdr_tmr u_rd  (.clk(clk), .rst(rst), .load(pop), .val(L_ONE), .ok(rd_ok));
    sdr_tmr u_w   (.clk(clk), .rst(rst), .load(pop), .val(is_rd ? L_R2W : L_ONE), .ok(w_ok));

    // ------------------------------------------------------------------ request window
    assign cmd_ready = !n_v;
    wire acc = cmd_valid && !n_v;

    always @(posedge clk) begin
        if (rst) begin
            h_v <= 1'b0;
            n_v <= 1'b0;
        end else if (pop) begin
            if (n_v) begin
                h_v <= 1'b1; h_we <= n_we; h_addr <= n_addr; h_wd <= n_wd; h_wm <= n_wm;
                n_v <= 1'b0;
            end else if (acc) begin
                h_v <= 1'b1; h_we <= cmd_we; h_addr <= cmd_addr; h_wd <= cmd_wdata; h_wm <= cmd_wmask;
            end else begin
                h_v <= 1'b0;
            end
        end else if (acc) begin
            if (!h_v) begin
                h_v <= 1'b1; h_we <= cmd_we; h_addr <= cmd_addr; h_wd <= cmd_wdata; h_wm <= cmd_wmask;
            end else begin
                n_v <= 1'b1; n_we <= cmd_we; n_addr <= cmd_addr; n_wd <= cmd_wdata; n_wm <= cmd_wmask;
            end
        end
    end

    // Row-hit flags of the queued requests. By default they are recomputed from the current
    // registers (exact if nothing changes at this edge); a command that changes the bank state or
    // moves the queue updates them directly. Only a request that was just loaded from cmd_*
    // (or a row conflict that cannot be resolved without the compare) waits one cycle (*_stale).
    always @(posedge clk) begin
        h_open  <= bk_open[hb];
        h_hit   <= bk_open[hb] && (bk_row[hb] == hr);
        n_open  <= bk_open[nb];
        n_hit   <= bk_open[nb] && (bk_row[nb] == nr);
        h_stale <= 1'b0;
        n_stale <= 1'b0;
        if (is_hact) begin
            h_open <= 1'b1;
            h_hit  <= 1'b1;
            if (nb == hb) n_stale <= 1'b1;
        end
        if (is_nact) begin
            n_open <= 1'b1;
            n_hit  <= 1'b1;
        end
        if (is_pre) begin
            if (db == hb) begin h_open <= 1'b0; h_hit <= 1'b0; end
            if (db == nb) begin n_open <= 1'b0; n_hit <= 1'b0; end
        end
        if (is_prea) begin
            h_open <= 1'b0; h_hit <= 1'b0;
            n_open <= 1'b0; n_hit <= 1'b0;
        end
        if (pop) begin                          // the next request becomes the head
            h_open  <= n_open;
            h_hit   <= n_hit;
            h_stale <= n_stale || !n_v;
            n_stale <= 1'b1;
        end
        if (acc) begin
            if (!h_v || (pop && !n_v)) h_stale <= 1'b1;
            else n_stale <= 1'b1;
        end
        n_la <= (nb != hb);                     // used only while !n_stale
        if (rst) begin
            h_stale <= 1'b1;
            n_stale <= 1'b1;
        end
    end

    // ------------------------------------------------------------------ main sequential logic
    integer i;
    always @(posedge clk) begin
        // default: NOP, all DQ released, no masking
        sdr_ras_n <= 1'b1;
        sdr_cas_n <= 1'b1;
        sdr_we_n  <= 1'b1;
        sdr_dqm   <= 4'b0000;
        sdr_dq_oe <= 32'h0;

        if (!wz) wcnt <= wcnt - 16'd1;
        wz <= (wcnt == 16'd1) || wz;

        // initialization sequence
        case (st)
            S_WAIT: if (wz) begin
                sdr_cs_n  <= 1'b0;
                sdr_ras_n <= 1'b0; sdr_cas_n <= 1'b1; sdr_we_n <= 1'b0;   // PRECHARGE ALL
                sdr_a[10] <= 1'b1;
                wcnt <= L_RP16; wz <= (L_RP16 == 16'd0);
                st <= S_REF1;
            end
            S_REF1: if (wz) begin
                sdr_ras_n <= 1'b0; sdr_cas_n <= 1'b0; sdr_we_n <= 1'b1;   // AUTO REFRESH
                wcnt <= L_RFC16; wz <= (L_RFC16 == 16'd0);
                st <= S_REF2;
            end
            S_REF2: if (wz) begin
                sdr_ras_n <= 1'b0; sdr_cas_n <= 1'b0; sdr_we_n <= 1'b1;   // AUTO REFRESH
                wcnt <= L_RFC16; wz <= (L_RFC16 == 16'd0);
                st <= S_MRS;
            end
            S_MRS: if (wz) begin
                sdr_ras_n <= 1'b0; sdr_cas_n <= 1'b0; sdr_we_n <= 1'b0;   // MODE REGISTER SET
                sdr_ba <= 2'b00;
                sdr_a  <= MODE;
                wcnt <= L_MRD16; wz <= (L_MRD16 == 16'd0);
                st <= S_RUN;
            end
            default: ;
        endcase
        if (st == S_RUN && wz) init_done <= 1'b1;

        // refresh timer
        if (!init_done) begin
            ref_t    <= L_REFI;
            ref_z    <= 1'b0;
            ref_pend <= 1'b0;
        end else begin
            ref_t    <= ref_z ? L_REFI : ref_t - 16'd1;
            ref_z    <= (ref_t == 16'd1);
            ref_pend <= (ref_pend && !is_ref) || ref_z;
        end

        // normal commands (RAS CAS WE)
        if (is_act) begin                                   // ACTIVE 011
            sdr_ras_n <= 1'b0;
            sdr_ba <= db;
            sdr_a  <= dr;
            bk_open[db] <= 1'b1;
            bk_row[db]  <= dr;
        end
        if (is_pre) begin                                   // PRECHARGE 010
            sdr_ras_n <= 1'b0; sdr_we_n <= 1'b0;
            sdr_ba <= db;
            sdr_a[10] <= 1'b0;
            bk_open[db] <= 1'b0;
        end
        if (is_prea) begin                                  // PRECHARGE ALL 010, A10 = 1
            sdr_ras_n <= 1'b0; sdr_we_n <= 1'b0;
            sdr_a[10] <= 1'b1;
            bk_open <= 4'b0000;
        end
        if (is_ref) begin                                   // AUTO REFRESH 001
            sdr_ras_n <= 1'b0; sdr_cas_n <= 1'b0;
        end
        if (pop) begin                                      // READ 101 / WRITE 100
            sdr_cas_n <= 1'b0;
            sdr_we_n  <= !is_wr;
            sdr_ba <= hb;
            sdr_a  <= {3'b000, h_addr[6:0], 1'b0};          // A10 = 0: no auto precharge
        end

        // write data: beat 0 with the WRITE command, beat 1 on the next cycle
        wb2 <= 1'b0;
        if (is_wr) begin
            sdr_dq_o  <= h_wd[31:0];
            sdr_dqm   <= ~h_wm[3:0];
            sdr_dq_oe <= 32'hffffffff;
            wb2       <= 1'b1;
            wb2_d     <= h_wd[63:32];
            wb2_dqm   <= ~h_wm[7:4];
        end else if (wb2) begin
            sdr_dq_o  <= wb2_d;
            sdr_dqm   <= wb2_dqm;
            sdr_dq_oe <= 32'hffffffff;
        end

        // read data return
        rdsh     <= {rdsh[10:0], is_rd};
        dq_in_r  <= sdr_dq_i;
        rd_valid <= rdsh[rx0] | rdsh[rx0 + 4'd1];
        rd_last  <= rdsh[rx0 + 4'd1];
        rd_data  <= dq_in_r;

        if (rst) begin
            st        <= S_WAIT;
            wcnt      <= L_INIT;
            wz        <= 1'b0;
            init_done <= 1'b0;
            sdr_cke   <= 1'b1;
            sdr_cs_n  <= 1'b1;
            sdr_ras_n <= 1'b1;
            sdr_cas_n <= 1'b1;
            sdr_we_n  <= 1'b1;
            sdr_dq_oe <= 32'h0;
            bk_open   <= 4'b0000;
            wb2       <= 1'b0;
            rdsh      <= 12'd0;
            rd_valid  <= 1'b0;
            rd_last   <= 1'b0;
            for (i = 0; i < 4; i = i + 1) bk_row[i] <= 11'd0;
        end
    end
endmodule

`default_nettype wire

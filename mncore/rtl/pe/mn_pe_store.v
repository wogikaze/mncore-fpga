// mn_pe_store: BSRAM storage of the GRF0, GRF1, LM0 and LM1 of one PE, or of the NPE PEs of a
// time-multiplexed MAB (WP14, WP30).
//
// Four independent channels, each with the memory bus of contract section 6:
//   req_valid, req_ready, req_we, req_addr[22:0] (long words), req_wdata[63:0],
//   req_wmask[7:0], rsp_valid, rsp_rdata[63:0]; read responses come back in request order.
// Channel index: 0 GRF0, 1 GRF1, 2 LM0, 3 LM1 (vectors are packed, channel k at [k*W +: W]).
// mn_pe_lsu only talks to this interface, so a virtual-PE store (WP34) can replace this
// module with an adapter to SDRAM / a shared BSRAM without touching the sequencer.
//
// This implementation: one mn_ram_1r1w per channel, 64 bits wide, two 32-bit write lanes
// (WP07 recipe; no byte enables). req_ready is always 1.
// IREG = 1 registers the requests before the BSRAM (read latency 2); it takes the
// sequencer's write-data logic off the BSRAM input path. IREG = 0: read latency 1.
// Write granularity is the 32-bit word: wmask[7:4] selects bits [63:32], wmask[3:0] bits
// [31:0], and the caller only sends 4'h0 or 4'hf per word (half-word masks are done by
// read-modify-write in mn_pe_lsu). Address bits above the depth are ignored here; mn_pe_lsu
// checks the range before it sends a request (E_RANGE).
//
// NPE (WP30): the memories of NPE PEs (1 or 4) are stacked in the same BSRAM; the PE number
// `pe` is the upper part of the BSRAM address ({pe, long word}). `pe` is taken with each
// request (registered with it when IREG = 1), so it only has to be valid with req_valid.
// With NPE = 1 `pe` is not used.
//
// Cost (64 bit wide): 2 BSRAM per channel up to 512 long words, so 8 for LM_AW = 9 and
// NPE = 1; NPE = 4 with LM_AW = GRF_AW = 8 (1024 long words per channel) takes 16.
module mn_pe_store #(
    parameter LM_AW  = 9,  // LM0/LM1 depth = 2**LM_AW long words (per PE)
    parameter GRF_AW = 8,  // GRF0/GRF1 depth = 2**GRF_AW long words (per PE)
    parameter IREG   = 1,  // request register before the BSRAM
    parameter NPE    = 1   // PEs stacked in the memories (1 or 4)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [1:0]   pe,           // NPE > 1: PE of the requests
    input  wire [3:0]   req_valid,
    output wire [3:0]   req_ready,
    input  wire [3:0]   req_we,
    input  wire [91:0]  req_addr,
    input  wire [255:0] req_wdata,
    input  wire [31:0]  req_wmask,
    output wire [3:0]   rsp_valid,
    output wire [255:0] rsp_rdata
);
    localparam PB = (NPE > 1) ? 2 : 0;   // PE address bits

    wire [3:0]   v, we;
    wire [91:0]  ad;
    wire [255:0] wd;
    wire [31:0]  wm;
    wire [1:0]   pq;
    generate
        if (IREG != 0) begin : g_ireg
            reg [3:0]   v_q;
            reg [3:0]   we_q;
            reg [91:0]  ad_q;
            reg [255:0] wd_q;
            reg [31:0]  wm_q;
            reg [1:0]   pe_q;
            always @(posedge clk) begin
                if (rst) v_q <= 4'd0;
                else     v_q <= req_valid;
                we_q <= req_we;
                ad_q <= req_addr;
                wd_q <= req_wdata;
                wm_q <= req_wmask;
                pe_q <= pe;
            end
            assign v = v_q; assign we = we_q; assign ad = ad_q; assign wd = wd_q; assign wm = wm_q;
            assign pq = pe_q;
        end else begin : g_direct
            assign v = req_valid; assign we = req_we; assign ad = req_addr; assign wd = req_wdata; assign wm = req_wmask;
            assign pq = pe;
        end
    endgenerate

    reg [3:0] rv;
    always @(posedge clk) begin
        if (rst) rv <= 4'd0;
        else     rv <= v & ~we;
    end
    assign rsp_valid = rv;
    assign req_ready = 4'hf;

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_ch
            localparam AW = (k < 2) ? GRF_AW : LM_AW;
            wire [22:0] a  = ad[23*k +: 23];
            wire [7:0]  m  = wm[8*k +: 8];
            wire        wv = v[k] & we[k];
            wire [AW+PB-1:0] ra;
            if (NPE > 1) begin : g_pa
                assign ra = {pq, a[AW-1:0]};
            end else begin : g_sa
                assign ra = a[AW-1:0];
            end
            mn_ram_1r1w #(.W(64), .AW(AW + PB), .NWE(2), .OREG(0)) u_ram (
                .clk(clk),
                .we({wv & (|m[7:4]), wv & (|m[3:0])}),
                .waddr(ra),
                .wdata(wd[64*k +: 64]),
                .re(v[k] & ~we[k]),
                .raddr(ra),
                .rdata(rsp_rdata[64*k +: 64])
            );
            /* verilator lint_off UNUSEDSIGNAL */
            // Address bits above the depth: range checked by mn_pe_lsu before the request.
            wire unused_hi = ^a[22:AW];
            /* verilator lint_on UNUSEDSIGNAL */
        end
    endgenerate

    /* verilator lint_off UNUSEDSIGNAL */
    // NPE = 1: the PE number is not used
    wire unused_pe = ^pq;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

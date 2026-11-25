// mn_vpe_store: the store of the virtual PEs (WP34): the four store channels of mn_pe_lsu (each the
// memory bus of contract 06 section 6: 0 GRF0, 1 GRF1, 2 LM0, 3 LM1) on one bus to the SDRAM, where
// the LM0 / LM1 / GRF0 / GRF1 of every PE are (rtl/vpe/README.md, "the VPE region").
//
// It stands in for mn_pe_store in mn_mab_mem (VPE = 1); mn_pe_lsu does not see the difference except
// for the latency (it does not depend on it, WP35).
//
// The PE of a request is `pe` = {MAB, PE in the MAB} (6 bits), sampled with the request.
// SDRAM long word address (the bases are aligned, so the fields are ORed in):
//   GRF0 / GRF1 (channel g = 0 / 1): GRF_BASE | {pe, g, a[7:0]}     (2**15 long words)
//   LM0 / LM1   (channel 2 + l):     LM_BASE  | {pe, l, a[10:0]}    (2**18 long words)
// mn_pe_lsu range checks every access before it sends it (E_RANGE), so the address fields fit.
//
// Requests: a grant register g picks the channel whose request goes to the bus; req_ready[k] is 1 only
// for k = g (and the bus ready; a read also needs room in the response queue), so req_ready does not
// depend on req_valid (mn_pe_lsu's host port asks for req_ready before it raises req_valid). g stays on
// a channel while it requests and moves to the lowest requesting channel otherwise, so a stream on one
// channel (READ: up to 8 reads of one memory) goes at one request per clock.
// wmask is sent in 32-bit lanes ({4{|m[7:4]}, 4{|m[3:0]}}), the write granularity of mn_pe_store. The write
// data is channel 0's: mn_pe_lsu sends the same write data on the four channels (WP35).
// Responses: the bus answers reads in order; a FIFO of the channels of the reads in flight sends each
// response to its channel (rsp_valid[ch], rsp_rdata the same 64 bits on every channel).
`default_nettype none
module mn_vpe_store #(
    parameter [19:0] LM_BASE  = 20'hC0000,   // aligned to 2**18
    parameter [19:0] GRF_BASE = 20'hA0000    // aligned to 2**15
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [5:0]   pe,
    // ---- the four channels (mn_pe_lsu st_*)
    input  wire [3:0]   req_valid,
    output wire [3:0]   req_ready,
    input  wire [3:0]   req_we,
    input  wire [91:0]  req_addr,
    input  wire [255:0] req_wdata,
    input  wire [31:0]  req_wmask,
    output wire [3:0]   rsp_valid,
    output wire [255:0] rsp_rdata,
    // ---- the bus to the SDRAM (contract 06 section 6)
    output wire         b_req_valid,
    input  wire         b_req_ready,
    output wire         b_req_we,
    output wire [22:0]  b_req_addr,
    output wire [63:0]  b_req_wdata,
    output wire [7:0]   b_req_wmask,
    input  wire         b_rsp_valid,
    input  wire [63:0]  b_rsp_rdata
);
    localparam QA = 4;                     // response queue: 2**QA reads in flight
    reg  [1:0]    g;                       // granted channel
    reg  [QA:0]   q_wp, q_rp;              // response queue pointers (one extra bit: full / empty)
    wire [QA:0]   q_n    = q_wp - q_rp;
    wire          room   = (q_n != (1 << QA));
    wire          g_we   = req_we[g];
    wire          g_ok   = g_we | room;
    wire [10:0]   g_a    = req_addr[23*g +: 11];
    wire [7:0]    g_m    = req_wmask[8*g +: 8];

    assign b_req_valid = req_valid[g] & g_ok;
    assign b_req_we    = g_we;
    assign b_req_addr  = {3'd0, g[1] ? (LM_BASE | {2'd0, pe, g[0], g_a[10:0]})
                                     : (GRF_BASE | {5'd0, pe, g[0], g_a[7:0]})};
    assign b_req_wdata = req_wdata[63:0];   // mn_pe_lsu sends the same write data on all four (WP35)
    assign b_req_wmask = {{4{|g_m[7:4]}}, {4{|g_m[3:0]}}};

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_rdy
            assign req_ready[k] = (g == k) & b_req_ready & (req_we[k] | room);
        end
    endgenerate

    // the lowest requesting channel
    wire [1:0] low = req_valid[0] ? 2'd0 : req_valid[1] ? 2'd1 : req_valid[2] ? 2'd2 : 2'd3;
    wire       r_go = b_req_valid & b_req_ready & ~g_we;

    // channels of the reads in flight
    wire [1:0] q_ch;
    mn_ram_lut #(.W(2), .AW(QA), .NR(1)) u_q (
        .clk(clk), .we(r_go), .waddr(q_wp[QA-1:0]), .wdata(g), .raddr(q_rp[QA-1:0]), .rdata(q_ch));

    always @(posedge clk) begin
        if (rst) begin
            g    <= 2'd0;
            q_wp <= {(QA+1){1'b0}};
            q_rp <= {(QA+1){1'b0}};
        end else begin
            if (!req_valid[g] && (req_valid != 4'd0)) g <= low;
            if (r_go) q_wp <= q_wp + 1'b1;
            if (b_rsp_valid) q_rp <= q_rp + 1'b1;
        end
    end

    assign rsp_valid = b_rsp_valid ? (4'd1 << q_ch) : 4'd0;
    assign rsp_rdata = {4{b_rsp_rdata}};

    /* verilator lint_off UNUSEDSIGNAL */
    // address bits above the fields: range checked by mn_pe_lsu; the write mask's byte detail: 32-bit lanes;
    // the write data of channels 1..3: the same as channel 0's
    wire unused = ^{req_addr, req_wmask, req_wdata[255:64]};
    /* verilator lint_on UNUSEDSIGNAL */

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && b_rsp_valid && (q_n == {(QA+1){1'b0}}))
            $display("mn_vpe_store: ERROR a read response without a read in flight");
    end
`endif
endmodule
`default_nettype wire

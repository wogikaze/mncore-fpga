// mn_vpe_arb: two masters on one memory bus (contract 06 section 6), round robin (WP34: the MV unit and
// the virtual PEs share the SDRAM bus of mn_core).
//
// A master's req_ready does not depend on its own req_valid (only on the other master's request), so
// a master may wait for req_ready before it raises req_valid. When both request, the one that was not
// served last goes first. The slave answers reads in order; a FIFO of the masters of the reads in flight
// (2**QA) sends each answer back to its master. A read waits while that FIFO is full.
`default_nettype none
module mn_vpe_arb #(
    parameter QA = 5
) (
    input  wire         clk,
    input  wire         rst,
    // ---- master 0
    input  wire         m0_req_valid,
    output wire         m0_req_ready,
    input  wire         m0_req_we,
    input  wire [22:0]  m0_req_addr,
    input  wire [63:0]  m0_req_wdata,
    input  wire [7:0]   m0_req_wmask,
    output wire         m0_rsp_valid,
    // ---- master 1
    input  wire         m1_req_valid,
    output wire         m1_req_ready,
    input  wire         m1_req_we,
    input  wire [22:0]  m1_req_addr,
    input  wire [63:0]  m1_req_wdata,
    input  wire [7:0]   m1_req_wmask,
    output wire         m1_rsp_valid,
    // ---- slave (rsp_rdata goes to both masters)
    output wire         s_req_valid,
    input  wire         s_req_ready,
    output wire         s_req_we,
    output wire [22:0]  s_req_addr,
    output wire [63:0]  s_req_wdata,
    output wire [7:0]   s_req_wmask,
    input  wire         s_rsp_valid
);
    reg  [QA:0] q_wp, q_rp;
    wire [QA:0] q_n  = q_wp - q_rp;
    wire        room = (q_n != (1 << QA));
    reg         pri;                               // 1: master 1 goes first
    wire        ok0  = m0_req_valid & (m0_req_we | room);
    wire        ok1  = m1_req_valid & (m1_req_we | room);
    wire        sel1 = ok1 & (pri | ~ok0);

    assign m0_req_ready = s_req_ready & (m0_req_we | room) & ~(pri & ok1);
    assign m1_req_ready = s_req_ready & (m1_req_we | room) & ~(~pri & ok0);
    assign s_req_valid  = ok0 | ok1;
    assign s_req_we     = sel1 ? m1_req_we : m0_req_we;
    assign s_req_addr   = sel1 ? m1_req_addr : m0_req_addr;
    assign s_req_wdata  = sel1 ? m1_req_wdata : m0_req_wdata;
    assign s_req_wmask  = sel1 ? m1_req_wmask : m0_req_wmask;

    wire go  = s_req_valid & s_req_ready;
    wire rgo = go & ~s_req_we;
    wire q_m;    // the master of the oldest read in flight
    mn_ram_lut #(.W(1), .AW(QA), .NR(1)) u_q (
        .clk(clk), .we(rgo), .waddr(q_wp[QA-1:0]), .wdata(sel1), .raddr(q_rp[QA-1:0]), .rdata(q_m));
    assign m0_rsp_valid = s_rsp_valid & ~q_m;
    assign m1_rsp_valid = s_rsp_valid & q_m;

    always @(posedge clk) begin
        if (rst) begin
            q_wp <= {(QA+1){1'b0}};
            q_rp <= {(QA+1){1'b0}};
            pri  <= 1'b0;
        end else begin
            if (rgo) q_wp <= q_wp + 1'b1;
            if (s_rsp_valid) q_rp <= q_rp + 1'b1;
            if (go) pri <= ~sel1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && s_rsp_valid && (q_n == {(QA+1){1'b0}}))
            $display("mn_vpe_arb: ERROR a read response without a read in flight");
    end
`endif
endmodule
`default_nettype wire

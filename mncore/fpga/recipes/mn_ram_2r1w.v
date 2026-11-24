// mn_ram_2r1w: 2 read ports + 1 write port RAM, single clock (WP07 recipe).
//
// Two copies of mn_ram_1r1w that share the write port. Both copies always hold the same
// data, so each read port sees the same memory. Costs exactly twice the blocks of one
// mn_ram_1r1w (measured: mncore/07-device-budget.md).
//
// When the two reads are never needed in the same clock as a write, mn_ram_tdp is cheaper
// for deep memories (a true-dual-port block gives 2 accesses per clock at up to x18).
//
// Timing and collision rules: see mn_ram_1r1w (applies to each read port).
module mn_ram_2r1w #(
    parameter W    = 64,
    parameter AW   = 8,
    parameter NWE  = 1,
    parameter OREG = 0
) (
    input  wire           clk,
    input  wire [NWE-1:0] we,
    input  wire [AW-1:0]  waddr,
    input  wire [W-1:0]   wdata,
    input  wire           re0,
    input  wire [AW-1:0]  raddr0,
    output wire [W-1:0]   rdata0,
    input  wire           re1,
    input  wire [AW-1:0]  raddr1,
    output wire [W-1:0]   rdata1
);
    mn_ram_1r1w #(.W(W), .AW(AW), .NWE(NWE), .OREG(OREG)) u_copy0 (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re0), .raddr(raddr0), .rdata(rdata0)
    );
    mn_ram_1r1w #(.W(W), .AW(AW), .NWE(NWE), .OREG(OREG)) u_copy1 (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re1), .raddr(raddr1), .rdata(rdata1)
    );
endmodule

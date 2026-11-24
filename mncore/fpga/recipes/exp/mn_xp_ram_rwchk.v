// WP07 experiment only (not a recipe): the "plain" 1R1W RAM coding WITHOUT the no_rw_check
// attribute. yosys must then keep the read-old-data behaviour on a same-address read+write,
// which the GW2A semi-dual-port BSRAM does not guarantee, so it adds bypass logic in LUTs.
// Used to measure that cost against mn_ram_1r1w.
module mn_xp_ram_rwchk #(
    parameter W  = 64,
    parameter AW = 8
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [W-1:0]  wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output reg  [W-1:0]  rdata
);
    reg [W-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule

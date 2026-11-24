// Simple dual-port RAM: one synchronous write port, one synchronous read port (registered output).
// Written so that yosys infers Gowin BSRAM (or LUT RAM for small sizes).
// Read-during-write to the same address is undefined; callers must avoid it.  no_rw_check tells yosys
// so, which removes the collision-bypass registers and multiplexers it would otherwise add per instance.
module brd_ram_1r1w #(
    parameter W  = 8,
    parameter AW = 11
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [W-1:0]  wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output reg  [W-1:0]  rdata
);
    (* no_rw_check *)
    reg [W-1:0] mem [0:(1<<AW)-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        if (re) rdata <= mem[raddr];
    end
endmodule

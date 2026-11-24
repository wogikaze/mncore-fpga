// mn_ram_lut: small RAM in LUT memory (Gowin SSRAM, RAM16SDP4), WP07 recipe.
//
// Synchronous write, asynchronous (combinational) read, NR read ports.
// One RAM16SDP4 holds 16 x 4 bits; each read port is a separate copy, so a W x 16 memory
// costs NR * W / 4 RAM16SDP4 (the device has 648 of them). Deeper than 16 adds LUT muxes.
// Use it for tiny register files such as the T register (8 long words) or FIFOs.
//
// Read-during-write: an asynchronous read of the address being written returns the old
// data until the clock edge, then the new data (no undefined case).
//
// ram_style = "distributed" keeps the memory in SSRAM even when the caller registers rdata;
// without it yosys may fold that register into a BSRAM read port (seen for 64 x 64).
// nextpnr counts 8 LUT4 sites per RAM16SDP4 (measured), so 64 bits of SSRAM cost 8 LUTs.
module mn_ram_lut #(
    parameter W  = 64,
    parameter AW = 3,   // depth = 2**AW
    parameter NR = 1    // number of read ports
) (
    input  wire             clk,
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire [W-1:0]     wdata,
    input  wire [NR*AW-1:0] raddr,  // port r uses raddr[r*AW +: AW]
    output wire [NR*W-1:0]  rdata   // port r drives rdata[r*W +: W]
);
    genvar r;
    generate
        for (r = 0; r < NR; r = r + 1) begin : g_port
            (* ram_style = "distributed" *)
            reg [W-1:0] mem [0:(1<<AW)-1];
            always @(posedge clk) begin
                if (we) mem[waddr] <= wdata;
            end
            assign rdata[r*W +: W] = mem[raddr[r*AW +: AW]];
        end
    endgenerate
endmodule

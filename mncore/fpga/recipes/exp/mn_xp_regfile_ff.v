// WP07 experiment only (not a recipe): a register file in flip-flops with NR asynchronous
// read ports, to compare with mn_ram_lut for the T register (8 long words).
module mn_xp_regfile_ff #(
    parameter W  = 64,
    parameter AW = 3,
    parameter NR = 1
) (
    input  wire             clk,
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire [W-1:0]     wdata,
    input  wire [NR*AW-1:0] raddr,
    output wire [NR*W-1:0]  rdata
);
    (* ram_style = "logic" *)
    reg [W-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end
    genvar r;
    generate
        for (r = 0; r < NR; r = r + 1) begin : g_port
            assign rdata[r*W +: W] = mem[raddr[r*AW +: AW]];
        end
    endgenerate
endmodule

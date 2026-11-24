// mn_ram_1r1w_be: 1 write port + 1 read port RAM with per-byte write enables (WP07 recipe).
//
// One memory with byte-lane enables. yosys maps the enables onto the low address bits of
// SDPX9B (AD[3:0] in x36 mode, AD[1:0] in x18 mode), so 64 bit x 512 still fits in 2 blocks.
//
// CAUTION: the byte-enable function is not described in the current Gowin manuals
// (UG285 1.4E has no byte-enable port; DS102 removed section "3.4.4 Byte-enable" in 2.5.2E).
// The mapping comes from yosys/apicula and has NOT been checked on the board.
// Prefer mn_ram_1r1w with 32-bit lanes unless byte granularity is really needed.
//
// Timing and read/write collision rules are the same as mn_ram_1r1w (OREG = 0).
module mn_ram_1r1w_be #(
    parameter W  = 64,  // data width, multiple of 8
    parameter AW = 8    // address width, depth = 2**AW
) (
    input  wire             clk,
    input  wire [W/8-1:0]   be,     // byte write enables (bit k writes wdata[8k+7:8k])
    input  wire [AW-1:0]    waddr,
    input  wire [W-1:0]     wdata,
    input  wire             re,
    input  wire [AW-1:0]    raddr,
    output reg  [W-1:0]     rdata
);
    (* no_rw_check *)
    reg [W-1:0] mem [0:(1<<AW)-1];

    integer k;
    always @(posedge clk) begin
        for (k = 0; k < W/8; k = k + 1)
            if (be[k]) mem[waddr][k*8 +: 8] <= wdata[k*8 +: 8];
    end
    always @(posedge clk) begin
        if (re) rdata <= mem[raddr];
    end
endmodule

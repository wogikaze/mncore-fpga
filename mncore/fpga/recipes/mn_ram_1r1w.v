// mn_ram_1r1w: 1 write port + 1 read port RAM, single clock (WP07 recipe).
//
// Infers Gowin semi-dual-port BSRAM (SDPX9B / SDPB) through yosys memory_libmap.
// Measured cost and Fmax: mncore/07-device-budget.md.
//
// Write lanes: the word is split into NWE lanes of W/NWE bits. Each lane is a separate
// inferred memory with its own write enable, so this recipe does NOT depend on the BSRAM
// byte-enable feature (undocumented in current Gowin manuals; see mn_ram_1r1w_be.v).
// Use lanes of 32 bits (x36 BSRAM column, 512 deep) or 16 bits (x18, 1024 deep) so that
// splitting costs no extra blocks.
//
// Timing:
//   - write: mem[waddr] <= wdata at the clock edge where we[lane] = 1.
//   - read : rdata = mem[raddr] sampled at an edge with re = 1, valid after 1 + OREG edges.
//            rdata holds its value while re = 0.
//   - read and write of the SAME address in the same cycle: the returned data is undefined
//     on the hardware (DS226 2.5.2, "not allowed"). The memory is marked no_rw_check so yosys
//     does not add bypass logic (about 1.5 LUT per data bit). The caller must avoid the
//     collision or forward the write data itself. The simulation model returns the old data.
module mn_ram_1r1w #(
    parameter W    = 64,  // data width
    parameter AW   = 8,   // address width, depth = 2**AW
    parameter NWE  = 1,   // number of write lanes, W % NWE == 0
    parameter OREG = 0    // 1: extra output register in the fabric (read latency 2)
) (
    input  wire           clk,
    input  wire [NWE-1:0] we,
    input  wire [AW-1:0]  waddr,
    input  wire [W-1:0]   wdata,
    input  wire           re,
    input  wire [AW-1:0]  raddr,
    output wire [W-1:0]   rdata
);
    localparam LW = W / NWE;

    wire [W-1:0] q;

    genvar l;
    generate
        for (l = 0; l < NWE; l = l + 1) begin : g_lane
            (* no_rw_check *)
            reg [LW-1:0] mem [0:(1<<AW)-1];
            reg [LW-1:0] rd;
            always @(posedge clk) begin
                if (we[l]) mem[waddr] <= wdata[l*LW +: LW];
            end
            always @(posedge clk) begin
                if (re) rd <= mem[raddr];
            end
            assign q[l*LW +: LW] = rd;
        end
    endgenerate

    generate
        if (OREG != 0) begin : g_oreg
            reg [W-1:0] qr;
            reg         re_d;
            always @(posedge clk) begin
                re_d <= re;
                if (re_d) qr <= q;
            end
            assign rdata = qr;
        end else begin : g_noreg
            assign rdata = q;
        end
    endgenerate
endmodule

// BSRAM test memory with the internal memory bus of contract §6 (64-bit long words, byte mask).
// Always ready; a read returns rsp_valid one cycle after the request (responses in request order).
// BYTE_EN=1: eight byte-wide RAMs so that req_wmask works (bit i enables bits [8i+7:8i]).
// BYTE_EN=0: one 64-bit RAM; req_wmask is ignored (the decoder in front must reject partial masks).
// Address bits above AW are ignored here; range checking is done by the decoder in front.
module brd_test_mem #(
    parameter AW      = 13,      // depth = 2**AW long words (13 -> 64 KiB)
    parameter BYTE_EN = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [22:0] req_addr,    // only [AW-1:0] is used
    input  wire [7:0]  req_wmask,   // unused when BYTE_EN=0
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [63:0] req_wdata,
    output reg         rsp_valid,
    output wire [63:0] rsp_rdata
);
    assign req_ready = 1'b1;
    wire rd = req_valid && !req_we;
    wire wr = req_valid && req_we;

    generate
        if (BYTE_EN != 0) begin : g_bytes
            genvar i;
            for (i = 0; i < 8; i = i + 1) begin : g_lane
                brd_ram_1r1w #(.W(8), .AW(AW)) u_ram (
                    .clk   (clk),
                    .we    (wr && req_wmask[i]),
                    .waddr (req_addr[AW-1:0]),
                    .wdata (req_wdata[8*i +: 8]),
                    .re    (rd),
                    .raddr (req_addr[AW-1:0]),
                    .rdata (rsp_rdata[8*i +: 8])
                );
            end
        end else begin : g_word
            brd_ram_1r1w #(.W(64), .AW(AW)) u_ram (
                .clk   (clk),
                .we    (wr),
                .waddr (req_addr[AW-1:0]),
                .wdata (req_wdata),
                .re    (rd),
                .raddr (req_addr[AW-1:0]),
                .rdata (rsp_rdata)
            );
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) rsp_valid <= 1'b0;
        else     rsp_valid <= rd;
    end
endmodule

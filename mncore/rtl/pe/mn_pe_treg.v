// mn_pe_treg: the T register of one PE (WP14).
//
// T holds 2 long words for each of the 4 cycles (SDM 3.6.1.12): cycle c always reads and
// writes entry c, 128 bits. Bus layout of an entry (as everywhere in rtl/pe):
//   [127:96] word 0 (MSB), [95:64] word 1, [63:32] word 2, [31:0] word 3.
// Storage is LUT RAM (WP07 recipe mn_ram_lut, SSRAM), asynchronous read, one read port:
//   hi = MSB long word of each entry, 16-bit write lanes (long-word masks select half words,
//        SDM 3.6.2: "MSB 側 1 長語を 4 半語とみなして"),
//   lo = LSB long word, 32-bit write lanes.
// Lanes in LUT RAM cost nothing extra (one RAM16SDP4 is 4 bits wide). The write data is one
// long word; the writer fills hi and lo in separate clocks (or the same one, same data).
//
// tind: word 1 [11:0] of every entry, kept in flip-flops for T-indirect addressing of LM0
// ($lmt...), so the address generator can use all 4 cycles at once without read ports.
//
// No reset: like the RAM contents, T is cleared through the host port (WR_MEM).
module mn_pe_treg (
    input  wire         clk,
    input  wire [1:0]   waddr,   // cycle
    input  wire [3:0]   we_hi,   // 16-bit lanes of the MSB long word, bit 3 = [63:48] of wdata
    input  wire [1:0]   we_lo,   // 32-bit lanes of the LSB long word, bit 1 = [63:32] of wdata
    input  wire [63:0]  wdata,
    input  wire [1:0]   raddr,   // cycle
    output wire [127:0] rdata,   // {MSB long word, LSB long word}
    output wire [47:0]  tind     // entry c word 1 [11:0] at [12*c +: 12]
);
    genvar l;
    generate
        for (l = 0; l < 4; l = l + 1) begin : g_hi
            mn_ram_lut #(.W(16), .AW(2), .NR(1)) u_ram (
                .clk(clk), .we(we_hi[l]), .waddr(waddr), .wdata(wdata[16*l +: 16]),
                .raddr(raddr), .rdata(rdata[64 + 16*l +: 16])
            );
        end
        for (l = 0; l < 2; l = l + 1) begin : g_lo
            mn_ram_lut #(.W(32), .AW(2), .NR(1)) u_ram (
                .clk(clk), .we(we_lo[l]), .waddr(waddr), .wdata(wdata[32*l +: 32]),
                .raddr(raddr), .rdata(rdata[32*l +: 32])
            );
        end
    endgenerate

    reg [11:0] tind_r [0:3];
    always @(posedge clk) begin
        if (we_hi[0]) tind_r[waddr] <= wdata[11:0];
    end
    assign tind = {tind_r[3], tind_r[2], tind_r[1], tind_r[0]};
endmodule

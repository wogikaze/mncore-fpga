// mn_pe_treg: the T register of one PE (WP14), or of NPE PEs (WP35).
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
// NPE (1, 2 or 4): the T of NPE PEs; pe selects the PE of the write, of the read and of tind
// (the RAMs are {pe, cycle}, at most 16 deep, so NPE <= 4 takes no more RAM16SDP4; tind is
// 4 x NPE registers). With NPE = 1, pe is not used.
//
// No reset: like the RAM contents, T is cleared through the host port (WR_MEM).
module mn_pe_treg #(
    parameter NPE = 1
) (
    input  wire         clk,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [1:0]   pe,      // NPE > 1: PE (only its low log2(NPE) bits are used)
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [1:0]   waddr,   // cycle
    input  wire [3:0]   we_hi,   // 16-bit lanes of the MSB long word, bit 3 = [63:48] of wdata
    input  wire [1:0]   we_lo,   // 32-bit lanes of the LSB long word, bit 1 = [63:32] of wdata
    input  wire [63:0]  wdata,
    input  wire [1:0]   raddr,   // cycle
    output wire [127:0] rdata,   // {MSB long word, LSB long word}
    output wire [47:0]  tind     // entry c word 1 [11:0] at [12*c +: 12]
);
    localparam integer PB = (NPE > 2) ? 2 : (NPE > 1) ? 1 : 0;   // PE address bits
    wire [PB+1:0] wa, ra;   // {pe, cycle}
    localparam [1:0] PMASK = (PB == 2) ? 2'd3 : (PB == 1) ? 2'd1 : 2'd0;
    wire [1:0]    pm = pe & PMASK;   // the PE, 0 when NPE = 1
    generate
        if (PB > 0) begin : g_pa
            assign wa = {pe[PB-1:0], waddr};
            assign ra = {pe[PB-1:0], raddr};
        end else begin : g_pa1
            assign wa = waddr;
            assign ra = raddr;
        end
    endgenerate

    genvar l;
    generate
        for (l = 0; l < 4; l = l + 1) begin : g_hi
            mn_ram_lut #(.W(16), .AW(PB + 2), .NR(1)) u_ram (
                .clk(clk), .we(we_hi[l]), .waddr(wa), .wdata(wdata[16*l +: 16]),
                .raddr(ra), .rdata(rdata[64 + 16*l +: 16])
            );
        end
        for (l = 0; l < 2; l = l + 1) begin : g_lo
            mn_ram_lut #(.W(32), .AW(PB + 2), .NR(1)) u_ram (
                .clk(clk), .we(we_lo[l]), .waddr(wa), .wdata(wdata[32*l +: 32]),
                .raddr(ra), .rdata(rdata[32*l +: 32])
            );
        end
    endgenerate

    // flip-flops (not LUT RAM: all 4 cycles are read at once), {PE, cycle} at [12 * (4 PE + c)]
    reg [12*4*NPE-1:0] tind_r;
    integer e;
    always @(posedge clk) begin
        for (e = 0; e < 4 * NPE; e = e + 1)
            if (we_hi[0] && ({pm, waddr} == e[3:0])) tind_r[12*e +: 12] <= wdata[11:0];
    end
    assign tind = tind_r[48*pm +: 48];
endmodule

// mn_mv_tags: the MV completion flags of the 256 tags (WP33).
//
// For every tag t (mvid, 8 bits; tag 0 is "no tag" and never counted) the number of MV
// instructions with tag t that completed and were not yet waited for, saturated at 2:
//   - done (1-clock pulse) with done_tag = t != 0: cnt[t] <- min(cnt[t] + 1, 2)
//   - take (1-clock pulse): cnt[wt_tag] <- 0 (a wait consumed the completion)
//   - wt_cnt = cnt[wt_tag] (combinational; valid while done = 0)
// The official emulator lets a wait pass when its tag's flag is set once and clears it; it blocks
// for ever when the flag is not set and aborts ("PE waits for double asserted DT done flag") when
// two MVs with the tag completed since the last wait (WP33 probes, mncore/rtl/mv/README.md).
// After reset the 256 entries are cleared (256 clocks, clearing = 1).
// The counts are in LUT RAM (mn_ram_lut: 256 x 2 bits, 16 RAM16SDP4 cells and a 16:1 mux).
`default_nettype none
module mn_mv_tags (
    input  wire       clk,
    input  wire       rst,
    output wire       clearing,
    input  wire       done,
    input  wire [7:0] done_tag,
    input  wire [7:0] wt_tag,
    output wire [1:0] wt_cnt,
    input  wire       take
);
    reg  [8:0] clr_a;            // clr_a[8] = 1: the clear is over
    assign clearing = ~clr_a[8];
    wire [7:0] ra = done ? done_tag : wt_tag;
    wire [1:0] rd;
    wire       inc = done & (done_tag != 8'd0);
    wire       we  = clearing | inc | take;
    wire [7:0] wa  = clearing ? clr_a[7:0] : ra;
    wire [1:0] wd  = clearing ? 2'd0 : inc ? ((rd == 2'd0) ? 2'd1 : 2'd2) : 2'd0;
    mn_ram_lut #(.W(2), .AW(8), .NR(1)) u_cnt (
        .clk(clk), .we(we), .waddr(wa), .wdata(wd), .raddr(ra), .rdata(rd));
    assign wt_cnt = rd;

    always @(posedge clk) begin
        if (rst)           clr_a <= 9'd0;
        else if (clearing) clr_a <= clr_a + 9'd1;
    end
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && !clearing && done && take)
            $display("mn_mv_tags: ERROR done and take in the same clock");
    end
`endif
endmodule
`default_nettype wire

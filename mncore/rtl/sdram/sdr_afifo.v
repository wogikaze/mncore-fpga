// sdr_afifo: asynchronous first-word-fall-through FIFO (2**AW entries, AW >= 2).
// Gray-coded pointers with two-flop synchronizers (Cummings style).
// rdata is valid while !rempty; re pops it. Both resets must be asserted together.
`default_nettype none

module sdr_afifo #(
    parameter integer W  = 8,
    parameter integer AW = 3
) (
    input  wire         wclk,
    input  wire         wrst,
    input  wire         we,
    input  wire [W-1:0] wdata,
    output wire         wfull,

    input  wire         rclk,
    input  wire         rrst,
    input  wire         re,
    output wire [W-1:0] rdata,
    output wire         rempty
);
    reg [W-1:0] mem [0:(1 << AW) - 1];

    reg [AW:0] wbin, wgray, rbin, rgray;
    reg [AW:0] w_rg1, w_rg2;               // read pointer (gray) in the write domain
    reg [AW:0] r_wg1, r_wg2;               // write pointer (gray) in the read domain

    wire [AW:0] wbin_n  = wbin + 1'b1;
    wire [AW:0] wgray_n = wbin_n ^ (wbin_n >> 1);
    wire [AW:0] rbin_n  = rbin + 1'b1;
    wire [AW:0] rgray_n = rbin_n ^ (rbin_n >> 1);

    assign wfull  = (wgray == {~w_rg2[AW:AW-1], w_rg2[AW-2:0]});
    assign rempty = (rgray == r_wg2);
    assign rdata  = mem[rbin[AW-1:0]];

    always @(posedge wclk) begin
        if (we && !wfull) mem[wbin[AW-1:0]] <= wdata;
    end

    always @(posedge wclk) begin
        if (wrst) begin
            wbin  <= {(AW + 1){1'b0}};
            wgray <= {(AW + 1){1'b0}};
            w_rg1 <= {(AW + 1){1'b0}};
            w_rg2 <= {(AW + 1){1'b0}};
        end else begin
            w_rg1 <= rgray;
            w_rg2 <= w_rg1;
            if (we && !wfull) begin
                wbin  <= wbin_n;
                wgray <= wgray_n;
            end
        end
    end

    always @(posedge rclk) begin
        if (rrst) begin
            rbin  <= {(AW + 1){1'b0}};
            rgray <= {(AW + 1){1'b0}};
            r_wg1 <= {(AW + 1){1'b0}};
            r_wg2 <= {(AW + 1){1'b0}};
        end else begin
            r_wg1 <= wgray;
            r_wg2 <= r_wg1;
            if (re && !rempty) begin
                rbin  <= rbin_n;
                rgray <= rgray_n;
            end
        end
    end
endmodule

`default_nettype wire

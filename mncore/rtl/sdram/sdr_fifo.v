// sdr_fifo: synchronous first-word-fall-through FIFO (2**AW entries).
// rdata is valid while !empty; re pops it. Writes to a full FIFO and reads from an empty one are ignored.
`default_nettype none

module sdr_fifo #(
    parameter integer W  = 8,
    parameter integer AW = 3
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         we,
    input  wire [W-1:0] wdata,
    output wire         full,
    input  wire         re,
    output wire [W-1:0] rdata,
    output wire         empty
);
    reg [W-1:0] mem [0:(1 << AW) - 1];
    reg [AW:0]  wp, rp;

    assign empty = (wp == rp);
    assign full  = (wp[AW] != rp[AW]) && (wp[AW-1:0] == rp[AW-1:0]);
    assign rdata = mem[rp[AW-1:0]];

    always @(posedge clk) begin
        if (we && !full) mem[wp[AW-1:0]] <= wdata;
    end

    always @(posedge clk) begin
        if (rst) begin
            wp <= {(AW + 1){1'b0}};
            rp <= {(AW + 1){1'b0}};
        end else begin
            if (we && !full) wp <= wp + 1'b1;
            if (re && !empty) rp <= rp + 1'b1;
        end
    end
endmodule

`default_nettype wire

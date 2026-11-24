// sdr_tmr: down-counter for one SDRAM timing constraint, with a registered "ok" flag.
// load at the edge of cycle t with val = gap - 1  ->  ok is 1 again from cycle t + gap on.
`default_nettype none

module sdr_tmr #(
    parameter integer W = 5
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         load,
    input  wire [W-1:0] val,
    output reg          ok
);
    localparam [W-1:0] ONE = 1;
    reg [W-1:0] c;
    always @(posedge clk) begin
        if (rst) begin
            c  <= {W{1'b0}};
            ok <= 1'b1;
        end else if (load) begin
            c  <= val;
            ok <= (val == {W{1'b0}});
        end else if (!ok) begin
            c  <= c - ONE;
            ok <= (c == ONE);
        end
    end
endmodule

`default_nettype wire

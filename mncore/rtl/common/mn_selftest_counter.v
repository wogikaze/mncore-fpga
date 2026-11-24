// Sample unit for the simrun.py harness (WP00).
module mn_selftest_counter #(
    parameter W = 8
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         en,
    output reg  [W-1:0] q
);
    always @(posedge clk) begin
        if (rst) q <= {W{1'b0}};
        else if (en) q <= q + 1'b1;
    end
endmodule

// WP07 experiment only (not a recipe): N18 independent 18 x 18 and N36 independent 36 x 36
// unsigned multipliers with fabric registers, to find how many fit the device
// (capacity check of the "48 multipliers" figure, and of MULT36X36 = 4 multipliers).
module mn_xp_mul_array #(
    parameter N18 = 48,
    parameter N36 = 0
) (
    input  wire                     clk,
    input  wire [N18*36+N36*72-1:0] ab,   // operands, packed
    output wire [N18*36+N36*72-1:0] p
);
    genvar i;
    generate
        for (i = 0; i < N18; i = i + 1) begin : g18
            reg [17:0] a, b;
            reg [35:0] q;
            always @(posedge clk) begin
                a <= ab[i*36 +: 18];
                b <= ab[i*36 + 18 +: 18];
                q <= a * b;
            end
            assign p[i*36 +: 36] = q;
        end
        for (i = 0; i < N36; i = i + 1) begin : g36
            reg [35:0] a, b;
            reg [71:0] q;
            always @(posedge clk) begin
                a <= ab[N18*36 + i*72 +: 36];
                b <= ab[N18*36 + i*72 + 36 +: 36];
                q <= a * b;
            end
            assign p[N18*36 + i*72 +: 72] = q;
        end
    endgenerate
endmodule

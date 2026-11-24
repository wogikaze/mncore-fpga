// mn_fp_f2h: single to half conversion of the `r` operand option (WP12).
//
// Behaviour of the official emulator (mncore/status/WP-03.md, r_round):
//   h = sign | clamp(E - 96 + carry, 0, 63) << 9 | RNE(mantissa 23 -> 9 bits)
// where E is the single exponent field and carry the carry out of the mantissa rounding.
// Zero and infinity keep their sign and rounded mantissa (no normalization), values below
// the half range get exponent 0 (zero) and values above it exponent 63 (infinity).
// As a value (exponent 0 = zero, 63 = infinity) this is the ordinary rounding of SDM 4.1,
// which is what the MAU uses for `hv* ... r` operands (SDM 3.6.9.24).
// Combinational. The exponent for both values of the carry is computed beside the mantissa
// increment, so only one short carry chain is on the path.
module mn_fp_f2h (
    input  wire [31:0] x,
    output wire [15:0] h
);
    wire [7:0]  e   = x[30:23];
    wire [8:0]  k   = x[22:14];
    wire [13:0] rem = x[13:0];
    wire        up  = (rem > 14'h2000) | ((rem == 14'h2000) & k[0]);
    wire [9:0]  k1  = {1'b0, k} + {9'd0, up};
    // clamp(E - 96 + c, 0, 63) for c = 0 and c = 1
    wire [5:0]  eh0 = (e <= 8'd96) ? 6'd0 : (e >= 8'd159) ? 6'd63 : e[5:0] - 6'd32;
    wire [5:0]  eh1 = (e <= 8'd95) ? 6'd0 : (e >= 8'd158) ? 6'd63 : e[5:0] - 6'd31;
    assign h = {x[31], k1[9] ? eh1 : eh0, k1[8:0]};
endmodule

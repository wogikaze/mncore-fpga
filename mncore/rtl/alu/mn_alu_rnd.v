// mn_alu_rnd: ALU input precision reduction, the `r` operand option (SDM 3.6.12.19).
//
// The 2-long-word input is read as four single-precision words; each is reduced to
// MN-Core half precision (1 sign, 6 exponent, 9 mantissa bits, bias 31) and the four
// halves are packed into the MSB long word. The LSB long word becomes 0.
//
// The conversion follows the official emulator, not IEEE rounding (contract §1, §5;
// mncore/status/WP-03.md, disputed reason `r_round`):
//   h = sign | clamp(E - 96 + c, 0, 63) << 9 | (RNE(mantissa 23 -> 9 bits) & 0x1ff)
// where E is the single-precision exponent field and c the carry out of the mantissa
// rounding. Nothing is flushed: -0 stays 0x8000, an underflow keeps its rounded mantissa
// with exponent 0, an infinity or overflow keeps its mantissa with exponent 63.
//
// Combinational. Shared by the integer ALU (WP11) and the FP ALU (WP13).
module mn_alu_rnd (
    input  wire [127:0] d,
    output wire [127:0] q
);
    // E + c is compared with 96 and 159 through the exponent bits, without a carry chain:
    //   E < 96  <=> E[7:5] < 3        E >= 160 <=> E[7] & (E[6] | E[5])
    //   E + c < 96  <=> E < 96 and not (E = 95 and c);   E + c > 159 <=> E >= 160 or (E = 159 and c)
    //   (E + c - 96) mod 64 = (E[5:0] + c) with bit 5 inverted
    function [15:0] f2h;
        input [31:0] s;
        reg       up, c, under, over;
        reg [8:0] m;
        reg [5:0] e6;
        begin
            // round to nearest even on bit 14 (keep 22..14, guard 13, sticky 12..0)
            up    = s[13] & ((|s[12:0]) | s[14]);
            m     = s[22:14] + {8'd0, up};
            c     = up & (&s[22:14]);
            e6    = s[28:23] + {5'd0, c};
            under = ~s[30] & ~(s[29] & s[28]) & ~(c & (s[30:23] == 8'd95));
            over  = (s[30] & (s[29] | s[28])) | (c & (s[30:23] == 8'd159));
            f2h   = {s[31], under ? 6'd0 : over ? 6'd63 : {~e6[5], e6[4:0]}, m};
        end
    endfunction

    assign q = {f2h(d[127:96]), f2h(d[95:64]), f2h(d[63:32]), f2h(d[31:0]), 64'd0};
endmodule

// mn_mv_red: one long word of an MV reduction on the reduced topology (WP33). Combinational.
//
// With one L2B (N_L2B = 1, contract section 3) every MV reduction (mvr, mvr2, mvr4) gets the
// value x of L2BM n0c0 (or 0 when n0c0 is not among its inputs) and zeros from the L2BMs that do
// not exist, so each lane is the reduction of x with zeros (the same rule as mn_l2bm's RRN = 2 with
// a zero input, viz/core rrn.rs with one value):
//   fadd  the lane, 0 when its exponent field is 0, infinity (mantissa 0) when it is all ones
//   max   the lane when its sign is 0, else +0        min  the lane when its sign is 1, else +0
//   iadd, bor  the lane                               band, and  0
//   or    1 in the lane's LSB when the lane is not 0
// Lanes: fmt 0 one of 64 bits (d / l), 1 two of 32 (f / i), 2 four of 16 (h / s), MSB first.
// op: 0 fadd, 1 max, 2 min, 3 iadd, 4 band, 5 and, 6 bor, 7 or (opcode 0000 0001 0010 1000 1001
// 1010 1100 1101; mn_l1bm_rrn's numbering).
`default_nettype none
module mn_mv_red (
    input  wire [2:0]  op,
    input  wire [1:0]  fmt,
    input  wire [63:0] x,
    output reg  [63:0] y
);
    integer    q;
    reg [3:0]  s, ez, ef, nz;      // per 16-bit chunk q: sign, exponent 0 / all ones, non-zero of its lane
    reg [15:0] ch, inf;
    reg        lo;                 // the chunk holds the LSB of its lane
    always @* begin
        y = x;
        for (q = 0; q < 4; q = q + 1) begin
            case (fmt)
                2'd0: begin
                    s[q] = x[63]; ez[q] = (x[62:52] == 11'd0); ef[q] = &x[62:52]; nz[q] = |x;
                end
                2'd1: begin
                    s[q]  = x[63 - 32 * (q / 2)];
                    ez[q] = (x[62 - 32 * (q / 2) -: 8] == 8'd0);
                    ef[q] = &x[62 - 32 * (q / 2) -: 8];
                    nz[q] = |x[63 - 32 * (q / 2) -: 32];
                end
                default: begin
                    s[q]  = x[63 - 16 * q];
                    ez[q] = (x[62 - 16 * q -: 6] == 6'd0);
                    ef[q] = &x[62 - 16 * q -: 6];
                    nz[q] = |x[63 - 16 * q -: 16];
                end
            endcase
        end
        for (q = 0; q < 4; q = q + 1) begin
            ch  = x[63 - 16 * q -: 16];
            inf = (fmt == 2'd2) ? {s[q], 6'h3f, 9'd0} :
                  (fmt == 2'd1) ? (((q % 2) == 0) ? {s[q], 8'hff, 7'd0} : 16'd0) :
                                  ((q == 0) ? {s[q], 11'h7ff, 4'd0} : 16'd0);
            lo  = (fmt == 2'd2) | ((fmt == 2'd1) & ((q % 2) == 1)) | ((fmt == 2'd0) & (q == 3));
            case (op)
                3'd0:       y[63 - 16 * q -: 16] = ez[q] ? 16'd0 : ef[q] ? inf : ch;   // fadd
                3'd1:       y[63 - 16 * q -: 16] = s[q] ? 16'd0 : ch;                  // max
                3'd2:       y[63 - 16 * q -: 16] = s[q] ? ch : 16'd0;                  // min
                3'd4, 3'd5: y[63 - 16 * q -: 16] = 16'd0;                              // band, and
                3'd7:       y[63 - 16 * q -: 16] = {15'd0, lo & nz[q]};                // or
                default:    y[63 - 16 * q -: 16] = ch;                                 // iadd, bor
            endcase
        end
    end
endmodule
`default_nettype wire

// mn_alu_rot_stage: one stage of the lane rotator of mn_alu_int (WP11).
//
// Rotates right by 2^J every lane whose segment select c[k] is 1. The 64-bit long word is
// 4 segments of 16 bits (segment 3 = bits 63..48); a lane is 1, 2 or 4 segments
// (m16 / m32 / neither = 16-, 32-, 64-bit lanes). c[k] must be equal for the segments of a lane.
//
// keep_hierarchy: with the default synth_gowin flow (abc9 with LUTs up to 8 inputs built from
// MUX2_LUT5..8), a flat 6-stage rotator is merged into wide LUTs and costs about twice the LUTs
// of the staged one (WP11 report). Keeping each stage a separate module keeps the stages apart.
//
// Combinational.
(* keep_hierarchy *)
module mn_alu_rot_stage #(
    parameter J = 0
) (
    input  wire        m16,
    input  wire        m32,
    input  wire [3:0]  c,
    input  wire [63:0] d,
    output wire [63:0] q
);
    localparam integer D = 1 << J;
    wire [63:0] r64 = {d[D-1:0], d[63:D]};
    wire [63:0] r32, r16;
    genvar k;
    generate
        if (D < 32) begin : g_r32
            assign r32 = {d[32+D-1:32], d[63:32+D], d[D-1:0], d[31:D]};
        end else begin : g_r32n
            assign r32 = r64;
        end
        if (D < 16) begin : g_r16
            for (k = 0; k < 4; k = k + 1) begin : g_s
                assign r16[16*k +: 16] = {d[16*k+D-1:16*k], d[16*k+15:16*k+D]};
            end
        end else begin : g_r16n
            assign r16 = r64;
        end
    endgenerate
    wire [63:0] src = m16 ? r16 : m32 ? r32 : r64;
    wire [63:0] sel = {{16{c[3]}}, {16{c[2]}}, {16{c[1]}}, {16{c[0]}}};
    assign q = (sel & src) | (~sel & d);
endmodule

// mn_fp_alu_harness: lint / synthesis top of the fpalu unit (WP13). Not used in the core.
// Instantiates mn_fp_alu and mn_fp_alu_bfn side by side with their ports exposed.
module mn_fp_alu_harness (
    input  wire         clk,
    input  wire         rst,
    input  wire [1:0]   pe_aluc_dmode,
    input  wire [4:0]   pe_aluc_aluop,
    input  wire         pe_aluc_is_unsigned,
    input  wire         pe_aluc_rounda,
    input  wire         pe_aluc_roundb,
    input  wire [3:0]   pe_aluc_isela,
    input  wire [2:0]   pe_aluc_iselb,
    // mn_fp_alu
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [127:0] x,
    input  wire [127:0] y,
    output wire         cls_bf,
    output wire         out_valid,
    input  wire         out_ready,
    output wire [127:0] z,
    output wire [3:0]   flags,
    output wire         out_err,
    // mn_fp_alu_bfn
    input  wire         b_in_valid,
    output wire         b_in_ready,
    input  wire [511:0] bx,
    output wire         b_out_valid,
    input  wire         b_out_ready,
    output wire [511:0] bz,
    output wire [15:0]  bflags,
    output wire         b_out_err
);
    mn_fp_alu u_alu (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .pe_aluc_dmode(pe_aluc_dmode), .pe_aluc_aluop(pe_aluc_aluop),
        .pe_aluc_is_unsigned(pe_aluc_is_unsigned), .pe_aluc_rounda(pe_aluc_rounda),
        .pe_aluc_roundb(pe_aluc_roundb), .pe_aluc_isela(pe_aluc_isela),
        .pe_aluc_iselb(pe_aluc_iselb), .x(x), .y(y), .cls_bf(cls_bf),
        .out_valid(out_valid), .out_ready(out_ready), .z(z), .flags(flags), .out_err(out_err));
    mn_fp_alu_bfn u_bfn (
        .clk(clk), .rst(rst), .in_valid(b_in_valid), .in_ready(b_in_ready),
        .pe_aluc_dmode(pe_aluc_dmode), .pe_aluc_aluop(pe_aluc_aluop),
        .pe_aluc_rounda(pe_aluc_rounda), .pe_aluc_iselb(pe_aluc_iselb), .x(bx),
        .out_valid(b_out_valid), .out_ready(b_out_ready), .z(bz), .flags(bflags),
        .out_err(b_out_err));
endmodule

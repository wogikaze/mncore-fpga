// mn_pe_rduse: which PE memories a j word reads as an operand (WP14 helper).
//
// rd_use = {LM1, LM0, GRF1, GRF0}. mn_pe_lsu reads (and range checks) only these memories,
// because assemble3 leaves arbitrary values in the address fields of unused memories.
// The T register needs no entry (it is not range checked and is read without a request).
//
// Rules (spec/isa/j_flat.yaml, Scrapbox 機械語 "ALU入力セレクタ" / "MAU入力セレクタ",
// viz/core vsm.rs ALU_OPS for the number of ALU inputs):
//   - ll = 00 (nop) or 10: nothing.
//   - ALU: unused when aluop = 00000, dmode = 11 and isela = 1000 (the assembler's filler).
//     imm (11111) has no input. Input A is isela; input B (iselb) only for 2-input ops:
//     add sub and or xor imax imin lsl lsr bsl bsr packbit relu* lrelud lreluo ilrelud
//     fmax fmin. (iselb of 11110 / 11101 holds an argument, not a selector.)
//     Selector values 0..4 = $lr $ls $t $lm $ln (ALU A 4 bits, B 3 bits).
//   - MAU: used when enfma = 1 (A always, B unless passa, C unless zeroc) and for the
//     matrix write (mw = 1, source taken from isela; not yet confirmed against the
//     emulator). Selector values 0..4 = $lr $ls $t $lm $ln.
//   - L1BM: l1bm.isel 0..4 = $lr $ls $t $lm $ln is a PE -> L1BM read; 111 = none.
// This is a reference for WP20; the core may compute rd_use itself from its decoder.
module mn_pe_rduse (
    input  wire [425:0] jw,
    output wire [3:0]   rd_use   // {LM1, LM0, GRF1, GRF0}
);
    wire [1:0] ll       = jw[425-0 -: 2];
    wire       enfma    = jw[425-118];
    wire       mw       = jw[425-121];
    wire       passa    = jw[425-128];
    wire       zeroc    = jw[425-129];
    wire [2:0] mau_a    = jw[425-136 -: 3];
    wire [2:0] mau_b    = jw[425-139 -: 3];
    wire [2:0] mau_c    = jw[425-142 -: 3];
    wire [1:0] alu_dm   = jw[425-145 -: 2];
    wire [4:0] aluop    = jw[425-147 -: 5];
    wire [3:0] alu_a    = jw[425-155 -: 4];
    wire [2:0] alu_b    = jw[425-159 -: 3];
    wire [2:0] l1_isel  = jw[425-195 -: 3];

    wire act    = (ll == 2'b01) | (ll == 2'b11);
    wire alu_on = act & ~((aluop == 5'b00000) & (alu_dm == 2'b11) & (alu_a == 4'b1000));
    reg  two_in;
    always @* begin
        case (aluop)
            5'b00000, 5'b00001, 5'b00101, 5'b00110, 5'b00111, 5'b01000, 5'b01001,
            5'b01011, 5'b01100, 5'b01101, 5'b01110, 5'b10011, 5'b10100, 5'b10101,
            5'b10110, 5'b10111, 5'b11000, 5'b11001, 5'b11010, 5'b11011, 5'b11100:
                two_in = 1'b1;
            default: two_in = 1'b0;
        endcase
    end

    // one-hot over {LM1, LM0, T, GRF1, GRF0} for selector values 0..4
    function [4:0] sel5(input [3:0] s);
        sel5 = (s == 4'd0) ? 5'b00001 : (s == 4'd1) ? 5'b00010 : (s == 4'd2) ? 5'b00100 :
               (s == 4'd3) ? 5'b01000 : (s == 4'd4) ? 5'b10000 : 5'b00000;
    endfunction

    wire [4:0] u_alu_a = (alu_on & (aluop != 5'b11111)) ? sel5(alu_a) : 5'd0;
    wire [4:0] u_alu_b = (alu_on & two_in) ? sel5({1'b0, alu_b}) : 5'd0;
    wire [4:0] u_mau_a = (act & (enfma | mw)) ? sel5({1'b0, mau_a}) : 5'd0;
    wire [4:0] u_mau_b = (act & enfma & ~passa) ? sel5({1'b0, mau_b}) : 5'd0;
    wire [4:0] u_mau_c = (act & enfma & ~zeroc) ? sel5({1'b0, mau_c}) : 5'd0;
    wire [4:0] u_l1    = act ? sel5({1'b0, l1_isel}) : 5'd0;
    wire [4:0] u       = u_alu_a | u_alu_b | u_mau_a | u_mau_b | u_mau_c | u_l1;
    assign rd_use = {u[4], u[3], u[1], u[0]};

    /* verilator lint_off UNUSEDSIGNAL */
    // Only the selector fields are needed; u[2] is the T register (no request needed).
    wire unused = ^{jw, u[2]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

// mn_alu_cls: classifies an ALUC field by the ALU block that executes it (WP11).
//
// Exactly one output is 1.
//   cls_int  : mn_alu_int (WP11). add sub inc dec not and or xor max min (integer) passa
//              lsl lsr bsl bsr lnot packbit zero imm. passa and packbit share their machine
//              code between integer and float precisions (dpassa = lpassa, Scrapbox
//              "ALU opcode観測一覧"), so they belong here for every precision.
//   cls_fp   : mn_alu_fp (WP13). rsqrt relu* lrelud lreluo ilrelud fmax fmin floor ftoi bfn
//              bfe (aluop 10000, 10100..11100, 11101 other than zero, 11110).
//   cls_xpe  : msl / msr (aluop 10001 / 10010), which move data between the PEs of a MAB (WP30).
//   cls_none : the word does not use the ALU (dmode = 11, aluop = 00000; assemble3 writes
//              isela = 1000 with it, which is not checked).
//   cls_bad  : a combination the ALU cannot execute. The caller reports it (E_UNSUPPORTED).
//              - rounda / roundb with dmode != 10. assemble3 accepts it, the emulator stops
//                ("ialuc.rounda can be used only with half-word", mncore/status/WP-03.md).
//              - dmode = 11 (pseudo-single) with any aluop other than 00000 (none) and
//                11110 (gbfn).
//
// zero shares aluop 11101 with hbfe/n. assemble3 writes zero as dmode = 10, is_unsigned = 1,
// isela = 0101, iselb = 000, and hbfe/n as is_unsigned = 0 with isela = the source operand
// (Scrapbox "多重化されるALU命令"). zero is recognised by is_unsigned = 1 and isela = 0101.
// For imm (aluop 11111) dmode, rounda, roundb, isela and iselb hold immediate bits and are
// ignored.
//
// Combinational.
module mn_alu_cls (
    input  wire [1:0] dmode,
    input  wire [4:0] aluop,
    input  wire       is_unsigned,
    input  wire       rounda,
    input  wire       roundb,
    input  wire [3:0] isela,
    output reg        cls_int,
    output reg        cls_fp,
    output reg        cls_xpe,
    output reg        cls_none,
    output reg        cls_bad
);
    wire op_imm   = (aluop == 5'b11111);
    wire op_zero  = (aluop == 5'b11101) && is_unsigned && (isela == 4'b0101);
    wire op_xpe   = (aluop == 5'b10001) || (aluop == 5'b10010);
    wire op_int   = (aluop[4] == 1'b0) || (aluop == 5'b10011);
    wire pseudo   = (dmode == 2'b11);
    wire rnd_bad  = (rounda || roundb) && (dmode != 2'b10);

    always @* begin
        cls_int  = 1'b0;
        cls_fp   = 1'b0;
        cls_xpe  = 1'b0;
        cls_none = 1'b0;
        cls_bad  = 1'b0;
        if (op_imm)
            cls_int = 1'b1;
        else if (rnd_bad)
            cls_bad = 1'b1;
        else if (op_xpe)
            cls_xpe = 1'b1;
        else if (op_zero)
            cls_int = 1'b1;
        else if (pseudo) begin
            if (aluop == 5'b00000)
                cls_none = 1'b1;
            else if (aluop == 5'b11110)
                cls_fp = 1'b1;
            else
                cls_bad = 1'b1;
        end else if (op_int)
            cls_int = 1'b1;
        else
            cls_fp = 1'b1;
    end
endmodule

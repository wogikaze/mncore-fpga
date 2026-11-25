// mn_vpe_ctx: the context engine of the virtual PEs (WP34): moves the per-PE context of the 4 PEs of
// one (virtual) MAB between the SDRAM and the working copy in the datapath (mn_mab's host port: T, OMR
// and BAR in mn_pe_lsu, the forwarding registers $aluf / $mauf in mn_pe_core).
//
// go (when idle) with save = 0 loads, save = 1 saves the items that cx selects for PE {vm, p},
// p = 0..3; fin pulses when done (a load: every item is written into the working copy; a save: every
// SDRAM write is accepted). The items of a PE, in order (rtl/vpe/README.md, the context slots):
//   item  0,  1   BAR $mb, $nb   host space 0x11 addr 0, 1     slot 8, 9          load cx[4] save cx[5]
//   item  2       OMR entry e    0x10 addr e (load imr_e, save omr_e)   slot 16+e  load cx[2] save cx[3]
//   items 3..10   T 2c+k         0x05 addr 0..7                slot 0..7          load cx[0] save cx[1]
//   items 11..18  $aluf 2c+k     0x12 addr 0..7                slot 32..39        load cx[6] save cx[7]
//   items 19..26  $mauf 2c+k     0x13 addr 0..7 (MAU = 1)      slot 40..47        load cx[8] save cx[9]
// SDRAM long word of a slot: CTX_BASE | {vm, p, slot} (CTX_BASE aligned to 2**12).
//
// Load: the SDRAM reads go out as fast as the bus takes them; each response is written into the working
//   copy in the same clock (a second iterator walks the same items). The host port takes a T / OMR / BAR /
//   $aluf / $mauf write in every clock while the datapath is idle (mn_pe_lsu, mn_pe_core): the engine
//   relies on that (the bus has no back-pressure on responses; a simulation check reports a miss).
// Save: the host port reads go out one at a time (the answer comes in the next clock); each answer goes to
//   the bus as a write, or into a one-entry hold when the bus is not ready; the next read goes out in the
//   answer's clock when the answer leaves at once (mn_pe_core's ports take it; mn_pe_lsu's a clock later).
`default_nettype none
module mn_vpe_ctx #(
    parameter [19:0] CTX_BASE = 20'hA8000,
    parameter MAU = 1
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         go,
    input  wire         save,
    input  wire [9:0]   cx,
    input  wire [3:0]   imr_e,
    input  wire [3:0]   omr_e,
    input  wire [3:0]   vm,
    output wire         idle,
    output reg          fin,
    // ---- mn_mab's host port (the working copy)
    output wire         hp_req_valid,
    input  wire         hp_req_ready,
    output wire         hp_req_we,
    output wire [1:0]   hp_pe,
    output wire [7:0]   hp_req_space,
    output wire [22:0]  hp_req_addr,
    output wire [63:0]  hp_req_wdata,
    output wire [7:0]   hp_req_wmask,
    input  wire         hp_req_err,
    input  wire         hp_rsp_valid,
    input  wire [63:0]  hp_rsp_rdata,
    // ---- the bus to the SDRAM
    output wire         b_req_valid,
    input  wire         b_req_ready,
    output wire         b_req_we,
    output wire [22:0]  b_req_addr,
    output wire [63:0]  b_req_wdata,
    output wire [7:0]   b_req_wmask,
    input  wire         b_rsp_valid,
    input  wire [63:0]  b_rsp_rdata
);
    localparam NI = 27;   // items per PE

    // ------------------------------------------------------------------ items
    reg         run, sv;
    reg  [3:0]  oe;        // the OMR entry of the operation
    reg  [26:0] en;        // the items of a PE that the operation moves
    // the groups of the operation: BAR, OMR, T, $aluf, $mauf
    wire [4:0]  grp_l = {(MAU != 0) & cx[8], cx[6], cx[0], cx[2], cx[4]};
    wire [4:0]  grp_s = {(MAU != 0) & cx[9], cx[7], cx[1], cx[3], cx[5]};
    function [26:0] items(input [4:0] gr);
        items = {{8{gr[4]}}, {8{gr[3]}}, {8{gr[2]}}, gr[1], {2{gr[0]}}};
    endfunction
    // the first enabled item at or after k (found, index)
    function [5:0] first_from(input [26:0] e, input [4:0] k);
        integer i;
        begin
            first_from = 6'd0;
            for (i = NI - 1; i >= 0; i = i - 1)
                if (e[i] && (i >= k)) first_from = {1'b1, i[4:0]};
        end
    endfunction
    function [7:0] i_space(input [4:0] k);
        i_space = (k < 5'd2) ? 8'h11 : (k == 5'd2) ? 8'h10 : (k < 5'd11) ? 8'h05 : (k < 5'd19) ? 8'h12 : 8'h13;
    endfunction
    function [3:0] i_addr(input [4:0] k, input [3:0] e);
        i_addr = (k < 5'd2) ? {3'd0, k[0]} : (k == 5'd2) ? e : (k < 5'd11) ? k[3:0] - 4'd3 :
                 (k < 5'd19) ? k[3:0] - 4'd11 : k[3:0] - 4'd3;   // 19..26: (k - 19) mod 16 = k - 3
    endfunction
    function [5:0] i_slot(input [4:0] k, input [3:0] e);
        i_slot = (k < 5'd2) ? {5'd4, k[0]} : (k == 5'd2) ? {2'b01, e} : (k < 5'd11) ? {2'b00, k[3:0] - 4'd3} :
                 (k < 5'd19) ? {3'b100, k[2:0] - 3'd3} : {3'b101, k[2:0] - 3'd3};
    endfunction

    // two iterators over (PE, item): a = the requests (SDRAM reads of a load, host reads of a save),
    // b = the completions (host writes of a load, SDRAM writes of a save)
    reg  [1:0]  ap, bp;
    reg  [4:0]  ak, bk;
    reg         a_end, b_end;
    wire [5:0]  a_nx = first_from(en, ak + 5'd1);
    wire [5:0]  b_nx = first_from(en, bk + 5'd1);
    /* verilator lint_off UNUSEDSIGNAL */
    // the first item of a PE (its found bit: an operation without items ends before it advances)
    wire [5:0]  e0   = first_from(en, 5'd0);
    /* verilator lint_on UNUSEDSIGNAL */
    // the next state {end, PE, item} of an iterator: the next item of the PE, the first item of the
    // next PE, or the end after PE 3
    function [7:0] adv(input e, input [1:0] p, input [4:0] k, input [5:0] nx, input [4:0] k0);
        begin
            if (nx[5])          adv = {e, p, nx[4:0]};
            else if (p == 2'd3) adv = {1'b1, p, k};
            else                adv = {e, p + 2'd1, k0};
        end
    endfunction
    // the first item of an operation that starts now
    wire [26:0] en_go = items(save ? grp_s : grp_l);
    wire [5:0]  f_go  = first_from(en_go, 5'd0);

    // ------------------------------------------------------------------ load
    wire        la_go = run & ~sv & ~a_end & b_req_ready;          // SDRAM read
    wire        lb_go = run & ~sv & ~b_end & b_rsp_valid;          // its answer into the working copy

    // ------------------------------------------------------------------ save
    reg         inf;        // a host read is in flight (answer in the next clock)
    reg         hold_v;
    reg  [63:0] hold_d;
    wire        s_wv    = run & sv & ~b_end & (hold_v | (inf & hp_rsp_valid));   // an SDRAM write
    wire [63:0] s_wd    = hold_v ? hold_d : hp_rsp_rdata;
    wire        s_wgo   = s_wv & b_req_ready;
    // the next host read: nothing held after this clock, the read in flight answered and gone
    wire        s_free  = ~hold_v & (~inf | (hp_rsp_valid & b_req_ready));
    wire        sa_go   = run & sv & ~a_end & s_free & hp_req_ready;

    // ------------------------------------------------------------------ ports
    wire [4:0]  hk = sv ? ak : bk;          // the item on the host port
    wire [1:0]  hpp = sv ? ap : bp;
    assign hp_req_valid = run & (sv ? (~a_end & s_free) : lb_go);
    assign hp_req_we    = ~sv;
    assign hp_pe        = hpp;
    assign hp_req_space = i_space(hk);
    assign hp_req_addr  = {19'd0, i_addr(hk, oe)};
    assign hp_req_wdata = b_rsp_rdata;
    assign hp_req_wmask = 8'hff;

    wire [4:0]  bkk = sv ? bk : ak;         // the item on the bus
    wire [1:0]  bpp = sv ? bp : ap;
    assign b_req_valid  = sv ? s_wv : (run & ~a_end);
    assign b_req_we     = sv;
    assign b_req_addr   = {3'd0, CTX_BASE | {8'd0, vm, bpp, i_slot(bkk, oe)}};
    assign b_req_wdata  = s_wd;
    assign b_req_wmask  = 8'hff;
    assign idle = ~run;

    always @(posedge clk) begin
        if (rst) begin
            run    <= 1'b0;
            sv     <= 1'b0;
            fin    <= 1'b0;
            inf    <= 1'b0;
            hold_v <= 1'b0;
            a_end  <= 1'b1;
            b_end  <= 1'b1;
            ap <= 2'd0; ak <= 5'd0; bp <= 2'd0; bk <= 5'd0;
            oe <= 4'd0;
            en <= 27'd0;
        end else begin
            fin <= 1'b0;
            if (!run) begin
                if (go) begin
                    run    <= 1'b1;
                    sv     <= save;
                    oe     <= save ? omr_e : imr_e;
                    en     <= en_go;
                    inf    <= 1'b0;
                    hold_v <= 1'b0;
                    ap     <= 2'd0;
                    bp     <= 2'd0;
                    ak     <= f_go[4:0];
                    bk     <= f_go[4:0];
                    a_end  <= ~f_go[5];
                    b_end  <= ~f_go[5];
                end
            end else begin
                // the request iterator
                if (la_go || sa_go) {a_end, ap, ak} <= adv(a_end, ap, ak, a_nx, e0[4:0]);
                // the completion iterator
                if (lb_go || s_wgo) {b_end, bp, bk} <= adv(b_end, bp, bk, b_nx, e0[4:0]);
                // save: the host read in flight and the hold
                if (sv) begin
                    if (sa_go) inf <= 1'b1;
                    else if (hp_rsp_valid) inf <= 1'b0;
                    if (inf && hp_rsp_valid && !hold_v && !b_req_ready) begin
                        hold_v <= 1'b1;
                        hold_d <= hp_rsp_rdata;
                    end else if (hold_v && b_req_ready) begin
                        hold_v <= 1'b0;
                    end
                end
                if (b_end && !(lb_go || s_wgo)) begin
                    run <= 1'b0;
                    fin <= 1'b1;
                end
            end
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // the host port's errors: the items are always inside its spaces
    wire unused = hp_req_err;
    /* verilator lint_on UNUSEDSIGNAL */

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && run && !sv && lb_go && !hp_req_ready)
            $display("mn_vpe_ctx: ERROR the working copy did not take a loaded item (space %h)", hp_req_space);
        if (!rst && run && hp_req_valid && hp_req_ready && hp_req_err)
            $display("mn_vpe_ctx: ERROR the host port rejected space %h addr %h", hp_req_space, hp_req_addr);
        if (!rst && run && b_rsp_valid && (sv || b_end))
            $display("mn_vpe_ctx: ERROR an SDRAM answer that no load asked for");
    end
`endif
endmodule
`default_nettype wire

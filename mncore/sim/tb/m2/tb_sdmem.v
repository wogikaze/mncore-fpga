// tb_sdmem: a behavioural memory on the contract 06 section 6 bus, standing for sdr_bus64 + the
// SDRAM in the M2 testbenches (WP37): 2**AW long words, the same addresses as sdr_bus64 (long word
// addresses of the 8 MiB SDRAM; err_addr when bits 22..AW of an accepted address are not 0).
//
// - req_ready is random (RAND = 1: about one clock in four is not ready) or always 1.
// - a read is answered LAT .. LAT + 3 clocks after its accept (random with RAND), in order.
// - wmask: a 32-bit half is written when any of its 4 bits is set (sdr_bus64 writes 32-bit lanes;
//   mn_mv always writes whole long words).
// - clear: a task that writes 0 to the whole memory (the testbench calls it at a core reset, like
//   the board's SDCLR clear of the DRAM / PDM after RESET).
`timescale 1ns/1ps
module tb_sdmem #(
    parameter AW   = 20,
    parameter LAT  = 2,
    parameter RAND = 1,
    parameter SEED = 1
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         req_valid,
    output wire         req_ready,
    input  wire         req_we,
    input  wire [22:0]  req_addr,
    input  wire [63:0]  req_wdata,
    input  wire [7:0]   req_wmask,
    output reg          rsp_valid,
    output reg  [63:0]  rsp_rdata,
    output reg          err_addr
);
    reg [63:0] mem [0:(1 << AW) - 1];
    integer seed = SEED;
    integer i;

    task clear;
        begin
            for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 64'd0;
        end
    endtask
    initial clear;

    reg rdy;
    always @(posedge clk) rdy <= (RAND != 0) ? (($random(seed) & 3) != 0) : 1'b1;
    assign req_ready = rdy & ~rst;

    // pending reads: (due clock, data), in order
    localparam QN = 64;
    reg [63:0] q_data [0:QN-1];
    integer    q_due  [0:QN-1];
    integer    q_head = 0, q_tail = 0, now = 0, last_due = 0, due;
    wire       go = req_valid & req_ready;
    wire [AW-1:0] a = req_addr[AW-1:0];
    always @(posedge clk) begin
        now <= now + 1;
        rsp_valid <= 1'b0;
        if (rst) begin
            q_head <= 0;
            q_tail <= 0;
            err_addr <= 1'b0;
        end else begin
            if (go) begin
                if (req_addr[22:AW] != 0) err_addr <= 1'b1;
                if (req_we) begin
                    if (|req_wmask[7:4]) mem[a][63:32] <= req_wdata[63:32];
                    if (|req_wmask[3:0]) mem[a][31:0]  <= req_wdata[31:0];
                end else begin
                    due = now + LAT + ((RAND != 0) ? ($random(seed) & 3) : 0);
                    if (due < last_due) due = last_due;
                    last_due = due;
                    q_data[q_tail % QN] <= mem[a];
                    q_due[q_tail % QN]  <= due;
                    q_tail <= q_tail + 1;
                end
            end
            if (q_head != q_tail && q_due[q_head % QN] <= now) begin
                rsp_valid <= 1'b1;
                rsp_rdata <= q_data[q_head % QN];
                q_head    <= q_head + 1;
            end
        end
    end
endmodule

// UART transmitter, 8N1, LSB first, with a transmit FIFO.
//
// div_q8 = clocks per bit in unsigned Q8 (see brd_uart_rx).  Bit boundaries are placed on the nearest
// following clock of the ideal fractional time, so the average bit period is exactly div_q8 / 256 clocks.
// Bytes are sent back to back (the next start bit follows the stop bit without an idle gap).
// idle: FIFO empty and the shifter is not sending (safe point to change div_q8).
module brd_uart_tx #(
    parameter DIVW    = 24,
    parameter FIFO_AW = 4
) (
    input  wire            clk,
    input  wire            rst,
    input  wire [DIVW-1:0] div_q8,
    input  wire            s_valid,
    output wire            s_ready,
    input  wire [7:0]      s_data,
    output reg             txd,
    output wire            idle,
    output reg             byte_pulse
);
    localparam [DIVW:0] Q1 = 256;

    wire       f_valid;
    wire [7:0] f_data;
    wire       f_empty;

    reg          busy;
    reg [DIVW:0] r;          // Q8 time remaining in the current bit
    reg [3:0]    bitn;       // 0 = start bit on the line, 1..8 = data, 9 = stop
    reg [7:0]    sh;

    wire [DIVW:0] div_e    = {1'b0, div_q8};
    // r - 1 clock and r - 1 clock + one bit (shared), r <= 1 clock as logic (WP35)
    wire [DIVW:0] r_m1     = r - Q1;
    wire [DIVW:0] r_nx     = r_m1 + div_e;
    wire          boundary = busy && (r[DIVW:9] == {(DIVW-8){1'b0}}) && (~r[8] || (r[7:0] == 8'd0));
    wire          last     = boundary && (bitn == 4'd9);
    wire          f_ready  = !busy || last;
    wire          load     = f_valid && f_ready;

    assign idle = !busy && f_empty;

    brd_fifo #(.W(8), .AW(FIFO_AW)) u_fifo (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (s_valid),
        .in_ready  (s_ready),
        .in_data   (s_data),
        .out_valid (f_valid),
        .out_ready (f_ready),
        .out_data  (f_data),
        .empty     (f_empty)
    );

    always @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            r          <= {(DIVW+1){1'b0}};
            bitn       <= 4'd0;
            sh         <= 8'd0;
            txd        <= 1'b1;
            byte_pulse <= 1'b0;
        end else begin
            byte_pulse <= 1'b0;
            if (load) begin
                // start bit; when chaining, keep the fractional remainder of the previous stop bit
                busy       <= 1'b1;
                r          <= busy ? r_nx : div_e;
                bitn       <= 4'd0;
                sh         <= f_data;
                txd        <= 1'b0;
                byte_pulse <= 1'b1;
            end else if (last) begin
                busy <= 1'b0;
                txd  <= 1'b1;
            end else if (boundary) begin
                r    <= r_nx;
                bitn <= bitn + 1'b1;
                if (bitn == 4'd8) begin
                    txd <= 1'b1;                    // stop bit
                end else begin
                    txd <= sh[0];
                    sh  <= {1'b0, sh[7:1]};
                end
            end else if (busy) begin
                r <= r_m1;
            end
        end
    end
endmodule

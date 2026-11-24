// sdr_test_uart_tx: minimal 8N1 UART transmitter for the SDRAM test design (WP04 owns the real UART).
`default_nettype none

module sdr_test_uart_tx #(
    parameter integer CLKDIV = 938         // clock cycles per bit
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       go,
    input  wire [7:0] data,
    /* verilator lint_off PROCASSINIT */  // power-up values are intended: the line idles high
    output reg        busy = 1'b0,        // from configuration on, even before clk runs
    output reg        tx = 1'b1           // (a low line would look like a break to the bridge)
    /* verilator lint_on PROCASSINIT */
);
    localparam integer DIV1I = CLKDIV - 1;
    localparam [15:0]  DIV1  = DIV1I[15:0];
    reg [8:0]  sh;
    reg [3:0]  bits;
    reg [15:0] c;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            tx   <= 1'b1;
        end else if (!busy) begin
            if (go) begin
                sh   <= {1'b1, data};
                tx   <= 1'b0;                  // start bit
                bits <= 4'd9;
                c    <= DIV1;
                busy <= 1'b1;
            end
        end else if (c != 16'd0) begin
            c <= c - 16'd1;
        end else begin
            c <= DIV1;
            if (bits == 4'd0) begin
                busy <= 1'b0;                  // end of the stop bit
            end else begin
                tx   <= sh[0];
                sh   <= {1'b1, sh[8:1]};
                bits <= bits - 4'd1;
            end
        end
    end
endmodule

`default_nettype wire

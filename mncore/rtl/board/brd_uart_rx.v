// UART receiver, 8N1, LSB first, with a receive FIFO.
//
// Bit timing is fractional: div_q8 = clocks per bit in unsigned Q8 (e.g. 27 MHz / 2 Mbaud = 13.5 -> 3456).
// div_q8 is a run-time input so the host can change the baud rate; the reset value is chosen by the parent
// (brd_host_if derives it from its CLK_HZ / BAUD parameters).  div_q8 must be >= 4.0 clocks (1024).
//
// The line goes through a 2-FF synchronizer and a 3-tap majority filter (constant latency, so it does not
// affect timing).  Each bit is sampled once at its centre, measured from the detected start edge.
// A byte whose stop bit reads 0 is dropped and reported on err_frame; the receiver then waits for the line
// to return high.  A byte arriving while the FIFO is full is dropped and reported on err_overrun.
//
// meas: clocks from the start-edge detection to the last 0->1 transition of the last good byte.
//   For the byte 0x55 that transition is the start of the stop bit, so meas / 9 is the sender's bit period.
module brd_uart_rx #(
    parameter DIVW    = 24,
    parameter FIFO_AW = 4
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            rxd,
    input  wire [DIVW-1:0] div_q8,
    output wire            m_valid,
    input  wire            m_ready,
    output wire [7:0]      m_data,
    output reg             err_frame,
    output reg             err_overrun,
    output reg             byte_pulse,
    output reg  [15:0]     meas
);
    localparam [DIVW:0] Q1 = 256;            // one clock in Q8
    localparam [1:0] S_IDLE = 2'd0, S_BITS = 2'd1, S_WAITHI = 2'd2;

    // ---- synchronizer and majority filter ----
    reg [1:0] sync;
    reg [2:0] hist;
    reg       rxf;
    reg       rxf_d;
    always @(posedge clk) begin
        if (rst) begin
            sync  <= 2'b11;
            hist  <= 3'b111;
            rxf   <= 1'b1;
            rxf_d <= 1'b1;
        end else begin
            sync  <= {sync[0], rxd};
            hist  <= {hist[1:0], sync[1]};
            rxf   <= (hist[0] & hist[1]) | (hist[1] & hist[2]) | (hist[0] & hist[2]);
            rxf_d <= rxf;
        end
    end

    // ---- bit engine ----
    wire [DIVW:0] div_e  = {1'b0, div_q8};
    wire [DIVW:0] half_e = {2'b00, div_q8[DIVW-1:1]};

    reg [1:0]    st;
    reg [DIVW:0] r;          // Q8 time remaining until the next sample (sample when r <= 1 clock)
    reg [3:0]    bitn;       // 0 = start, 1..8 = data, 9 = stop
    reg [7:0]    sh;
    reg [15:0]   tcnt;
    reg [15:0]   last_rise;
    reg          push;
    reg [7:0]    push_data;

    always @(posedge clk) begin
        if (rst) begin
            st         <= S_IDLE;
            r          <= {(DIVW+1){1'b0}};
            bitn       <= 4'd0;
            sh         <= 8'd0;
            tcnt       <= 16'd0;
            last_rise  <= 16'd0;
            meas       <= 16'd0;
            push       <= 1'b0;
            push_data  <= 8'd0;
            err_frame  <= 1'b0;
            byte_pulse <= 1'b0;
        end else begin
            push       <= 1'b0;
            err_frame  <= 1'b0;
            byte_pulse <= 1'b0;
            if (tcnt != 16'hffff) tcnt <= tcnt + 1'b1;
            if (rxf && !rxf_d) last_rise <= tcnt;
            case (st)
                S_IDLE: begin
                    if (!rxf) begin
                        // First sample at half a bit, minus one clock for the average detection lateness.
                        st        <= S_BITS;
                        r         <= half_e - Q1;
                        bitn      <= 4'd0;
                        tcnt      <= 16'd1;
                        last_rise <= 16'd0;
                    end
                end
                S_BITS: begin
                    if (r <= Q1) begin
                        r    <= r + div_e - Q1;
                        bitn <= bitn + 1'b1;
                        if (bitn == 4'd0) begin
                            if (rxf) st <= S_IDLE;               // glitch, not a start bit
                        end else if (bitn == 4'd9) begin
                            if (rxf) begin
                                push       <= 1'b1;
                                push_data  <= sh;
                                byte_pulse <= 1'b1;
                                meas       <= last_rise;
                                st         <= S_IDLE;
                            end else begin
                                err_frame <= 1'b1;
                                st        <= S_WAITHI;
                            end
                        end else begin
                            sh <= {rxf, sh[7:1]};
                        end
                    end else begin
                        r <= r - Q1;
                    end
                end
                S_WAITHI: begin
                    if (rxf) st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ---- FIFO ----
    wire f_in_ready;
    /* verilator lint_off UNUSEDSIGNAL */
    wire f_empty;   // not needed on the receive side (m_valid already says whether data is available)
    /* verilator lint_on UNUSEDSIGNAL */
    always @(posedge clk) begin
        if (rst) err_overrun <= 1'b0;
        else     err_overrun <= push && !f_in_ready;
    end

    brd_fifo #(.W(8), .AW(FIFO_AW)) u_fifo (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (push),
        .in_ready  (f_in_ready),
        .in_data   (push_data),
        .out_valid (m_valid),
        .out_ready (m_ready),
        .out_data  (m_data),
        .empty     (f_empty)
    );
endmodule

// Synchronous first-word-fall-through FIFO built on brd_ram_1r1w.
// Capacity is 2**AW entries in the RAM plus one in the output register.
// in_*  : valid/ready push side.   out_* : valid/ready pop side (out_data valid while out_valid).
module brd_fifo #(
    parameter W  = 8,
    parameter AW = 4
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [W-1:0] in_data,
    output reg          out_valid,
    input  wire         out_ready,
    output wire [W-1:0] out_data,
    output wire         empty        // nothing stored (RAM and output register both empty)
);
    reg  [AW:0] wptr;
    reg  [AW:0] rptr;
    wire        ram_empty = (wptr == rptr);
    wire        ram_full  = (wptr[AW-1:0] == rptr[AW-1:0]) && (wptr[AW] != rptr[AW]);
    wire        do_write  = in_valid && !ram_full;
    // Prefetch into the RAM's output register whenever the output stage is free or being popped.
    wire        do_read   = !ram_empty && (!out_valid || out_ready);

    assign in_ready = !ram_full;
    assign empty    = ram_empty && !out_valid;

    brd_ram_1r1w #(.W(W), .AW(AW)) u_ram (
        .clk   (clk),
        .we    (do_write),
        .waddr (wptr[AW-1:0]),
        .wdata (in_data),
        .re    (do_read),
        .raddr (rptr[AW-1:0]),
        .rdata (out_data)
    );

    always @(posedge clk) begin
        if (rst) begin
            wptr      <= {(AW+1){1'b0}};
            rptr      <= {(AW+1){1'b0}};
            out_valid <= 1'b0;
        end else begin
            if (do_write) wptr <= wptr + 1'b1;
            if (do_read) begin
                rptr      <= rptr + 1'b1;
                out_valid <= 1'b1;
            end else if (out_ready) begin
                out_valid <= 1'b0;
            end
        end
    end
endmodule

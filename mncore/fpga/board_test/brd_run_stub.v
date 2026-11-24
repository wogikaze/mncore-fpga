// Stand-in for mn_core in the board test: exercises RUN / STATUS without a real core.
// After run_start it "executes" one entry every TICK clocks: pc and steps advance until run_count entries
// are done (reason OK).  Running past the instruction memory (pc >= IMEM_DEPTH) stops with E_RANGE and
// info = pc, which is how the real core reports an out-of-range fetch.
module brd_run_stub #(
    parameter [15:0] IMEM_DEPTH = 16'd64,
    parameter        TICK       = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        run_start,
    input  wire [15:0] run_pc,
    input  wire [31:0] run_count,
    output reg         busy,
    output reg  [7:0]  reason,
    output reg  [31:0] info,
    output reg  [15:0] pc,
    output reg  [31:0] steps
);
    localparam [7:0]  R_OK     = 8'd0;
    localparam [7:0]  R_ERANGE = 8'd1;
    localparam [31:0] TICK_U32 = TICK;

    reg [31:0] remain;
    reg [31:0] tcnt;

    always @(posedge clk) begin
        if (rst) begin
            busy   <= 1'b0;
            reason <= R_OK;
            info   <= 32'd0;
            pc     <= 16'd0;
            steps  <= 32'd0;
            remain <= 32'd0;
            tcnt   <= 32'd0;
        end else if (run_start) begin
            busy   <= (run_count != 32'd0);
            reason <= R_OK;
            info   <= 32'd0;
            pc     <= run_pc;
            steps  <= 32'd0;
            remain <= run_count;
            tcnt   <= 32'd0;
        end else if (busy) begin
            if (pc >= IMEM_DEPTH) begin
                busy   <= 1'b0;
                reason <= R_ERANGE;
                info   <= {16'd0, pc};
            end else if (tcnt + 32'd1 >= TICK_U32) begin
                tcnt   <= 32'd0;
                pc     <= pc + 1'b1;
                steps  <= steps + 1'b1;
                remain <= remain - 1'b1;
                if (remain == 32'd1) busy <= 1'b0;
            end else begin
                tcnt <= tcnt + 1'b1;
            end
        end
    end
endmodule

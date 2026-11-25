// mvt_l1mem: the L1BM of L1B 0 for the MV test core (WP33): a plain memory of 2**AW long words
// with the port the L2BM unit reaches (mn_l2bm's L1BM master port, as mn_l1bm's port B: the
// response one clock after the accept) and the host port (space 0x06, loc n0c0b0), which is
// served when the L2BM unit does not use the memory. There is no L1BM instruction unit: the test
// core runs no L1BM instruction (mvt_core.v, mncore/rtl/mv/README.md).
`default_nettype none
module mvt_l1mem #(
    parameter AW = 10
) (
    input  wire        clk,
    input  wire        rst,
    // mn_l2bm L1BM master port (lb_req_l1b is 0: one L1B)
    input  wire        lb_req_valid,
    output wire        lb_req_ready,
    input  wire        lb_req_we,
    input  wire [22:0] lb_req_addr,
    input  wire [63:0] lb_req_wdata,
    output wire        lb_req_err,
    output reg         lb_rsp_valid,
    output wire [63:0] lb_rsp_rdata,
    // host
    input  wire        hw_valid,
    output wire        hw_ready,
    output wire        hw_err,
    input  wire [15:0] hw_loc,
    input  wire [22:0] hw_addr,
    input  wire [63:0] hw_data,
    input  wire [7:0]  hw_mask,
    input  wire        hr_valid,
    output wire        hr_ready,
    output wire        hr_err,
    input  wire [15:0] hr_loc,
    input  wire [22:0] hr_addr,
    output reg         hr_rsp_valid,
    output wire [63:0] hr_rsp_data
);
    wire lb_ok = (lb_req_addr >> AW) == 23'd0;
    wire hw_ok = (hw_loc == 16'd0) && ((hw_addr >> AW) == 23'd0);
    wire hr_ok = (hr_loc == 16'd0) && ((hr_addr >> AW) == 23'd0);
    assign lb_req_ready = 1'b1;
    assign lb_req_err   = ~lb_ok;
    wire h_free = ~lb_req_valid;
    assign hw_ready = h_free;
    assign hw_err   = ~hw_ok;
    assign hr_ready = h_free & ~hw_valid;
    assign hr_err   = ~hr_ok;

    wire lb_go = lb_req_valid & lb_ok;
    wire hw_go = h_free & hw_valid & hw_ok;
    wire hr_go = h_free & ~hw_valid & hr_valid & hr_ok;
    wire [1:0]    we    = lb_go ? {2{lb_req_we}} :
                          hw_go ? {&hw_mask[7:4], &hw_mask[3:0]} : 2'b00;
    wire [AW-1:0] wa    = lb_go ? lb_req_addr[AW-1:0] : hw_addr[AW-1:0];
    wire [63:0]   wd    = lb_go ? lb_req_wdata : hw_data;
    wire          re    = (lb_go & ~lb_req_we) | hr_go;
    wire [AW-1:0] ra    = lb_go ? lb_req_addr[AW-1:0] : hr_addr[AW-1:0];
    wire [63:0]   q;
    mn_ram_1r1w #(.W(64), .AW(AW), .NWE(2), .OREG(0)) u_mem (
        .clk(clk), .we(we), .waddr(wa), .wdata(wd), .re(re), .raddr(ra), .rdata(q));
    assign lb_rsp_rdata = q;
    assign hr_rsp_data  = q;
    always @(posedge clk) begin
        if (rst) begin
            lb_rsp_valid <= 1'b0;
            hr_rsp_valid <= 1'b0;
        end else begin
            // a request beyond the memory (lb_req_err) gets no response (mn_l2bm does not wait)
            lb_rsp_valid <= lb_go & ~lb_req_we;
            hr_rsp_valid <= hr_go;
        end
    end
endmodule
`default_nettype wire

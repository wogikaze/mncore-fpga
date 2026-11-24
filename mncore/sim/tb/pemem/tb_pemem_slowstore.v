// tb_pemem_slowstore: behavioural store for mn_pe_lsu with random back-pressure and random,
// in-order read latency (2..5 clocks). Same ports as mn_pe_store. Testbench only.
// Also checks that every write mask is whole 32-bit words (nibbles 0 or f).
module tb_pemem_slowstore #(
    parameter SEED = 1
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [3:0]   req_valid,
    output wire [3:0]   req_ready,
    input  wire [3:0]   req_we,
    input  wire [91:0]  req_addr,
    input  wire [255:0] req_wdata,
    input  wire [31:0]  req_wmask,
    output reg  [3:0]   rsp_valid,
    output reg  [255:0] rsp_rdata,
    output integer      nerr
);
    reg [63:0] mem [0:4*4096-1];
    reg [63:0] fd  [0:63];
    integer    ft  [0:63];
    integer    head [0:3];
    integer    cnt  [0:3];
    integer    now, seed, k, a, slot;
    reg [3:0]  rdy;
    reg [7:0]  wm;

    initial begin
        seed = SEED; now = 0; nerr = 0;
        for (k = 0; k < 4; k = k + 1) begin head[k] = 0; cnt[k] = 0; end
        rdy = 4'h0;
    end
    assign req_ready = rdy & {cnt[3] < 15, cnt[2] < 15, cnt[1] < 15, cnt[0] < 15};

    always @(posedge clk) begin
        now = now + 1;
        if (rst) begin
            for (k = 0; k < 4; k = k + 1) begin head[k] = 0; cnt[k] = 0; end
            rsp_valid <= 4'h0;
            rdy <= 4'h0;
        end else begin
            for (k = 0; k < 4; k = k + 1) begin
                // response of the oldest read, when its time has come
                if (cnt[k] > 0 && ft[k*16 + head[k]] <= now) begin
                    rsp_valid[k] <= 1'b1;
                    rsp_rdata[64*k +: 64] <= fd[k*16 + head[k]];
                    head[k] = (head[k] + 1) % 16;
                    cnt[k]  = cnt[k] - 1;
                end else begin
                    rsp_valid[k] <= 1'b0;
                end
                // request
                if (req_valid[k] && req_ready[k]) begin
                    a = k*4096 + req_addr[23*k +: 12];
                    if (req_we[k]) begin
                        wm = req_wmask[8*k +: 8];
                        if ((wm[7:4] != 4'h0 && wm[7:4] != 4'hf) || (wm[3:0] != 4'h0 && wm[3:0] != 4'hf)) begin
                            $display("slowstore: partial word mask %h on channel %0d", wm, k);
                            nerr = nerr + 1;
                        end
                        if (wm[7]) mem[a][63:32] = req_wdata[64*k + 32 +: 32];
                        if (wm[3]) mem[a][31:0]  = req_wdata[64*k +: 32];
                    end else begin
                        slot = k*16 + (head[k] + cnt[k]) % 16;
                        fd[slot] = mem[a];
                        ft[slot] = now + 1 + ($random(seed) & 3);
                        cnt[k] = cnt[k] + 1;
                    end
                end
                rdy[k] <= (($random(seed) & 3) != 0);
            end
        end
    end
endmodule

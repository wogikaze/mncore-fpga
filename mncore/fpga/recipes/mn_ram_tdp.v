// mn_ram_tdp: true dual-port RAM, 2 read/write ports, single clock (WP07 recipe).
//
// Infers Gowin dual-port BSRAM (DPX9B / DPB). A dual-port block is at most 18 bits wide
// (1K x 18), so a 64-bit word needs 4 blocks even when shallow; from 1024 words up it costs
// the same as mn_ram_1r1w and half of mn_ram_2r1w.
//
// Each port does either a write or a read in one clock ("normal" write mode: rdata keeps
// its old value during a write). GW2A dual-port BSRAM has no read-before-write mode
// (UG285 3, note), so reading and writing on the same port in one clock is not offered.
// Two ports touching the same address in one clock with at least one write: undefined on
// the hardware (DS226 2.5.2). The caller must avoid it.
//
// Read latency: 1 clock.
module mn_ram_tdp #(
    parameter W  = 64,
    parameter AW = 8
) (
    input  wire          clk,
    // port A
    input  wire          en_a,    // access enable
    input  wire          we_a,    // 1: write, 0: read (when en_a = 1)
    input  wire [AW-1:0] addr_a,
    input  wire [W-1:0]  wdata_a,
    output reg  [W-1:0]  rdata_a,
    // port B
    input  wire          en_b,
    input  wire          we_b,
    input  wire [AW-1:0] addr_b,
    input  wire [W-1:0]  wdata_b,
    output reg  [W-1:0]  rdata_b
);
    (* no_rw_check *)
    reg [W-1:0] mem [0:(1<<AW)-1];

    /* verilator lint_off MULTIDRIVEN */
    // A true dual-port memory is written from two processes by definition.
    always @(posedge clk) begin
        if (en_a) begin
            if (we_a) mem[addr_a] <= wdata_a;
            else      rdata_a     <= mem[addr_a];
        end
    end
    always @(posedge clk) begin
        if (en_b) begin
            if (we_b) mem[addr_b] <= wdata_b;
            else      rdata_b     <= mem[addr_b];
        end
    end
    /* verilator lint_on MULTIDRIVEN */
endmodule

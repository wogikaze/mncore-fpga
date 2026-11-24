// tb_sdr_model: behavioral 2M x 32 SDR SDRAM (4 banks x 2048 rows x 256 columns), the part embedded
// in the GW2AR-18. Simulation only (iverilog -g2012).
//
// Checks (each violation increments `errors` and prints the first few messages):
//   - command legality: ACT to an open bank, READ/WRITE to a closed bank, auto precharge (unused),
//     burst interruption (column commands closer than BL = 2), REF/MRS with open banks,
//     commands before the power-up wait, ACT before MODE REGISTER SET
//   - timing: tRCD, tRP, tRC, tRAS, tRRD, tWR, tRFC, tMRD, refresh interval
//   - setup / hold of command, address, DQM and write data at the SDRAM pins
//   - write data with X/Z in an unmasked byte (also catches bus contention)
// Read data is driven T_AC after the clock edge before the edge it belongs to and becomes X T_OH
// after that edge, so capturing it at the wrong moment yields X.
// A gap of more than GAP_NS without any command is taken as a controller re-initialization.
`timescale 1ns/1ps

module tb_sdr_model #(
    parameter real T_AC3 = 5.4,       // access time from clock, CL3 (-6 grade)
    parameter real T_AC2 = 6.0,       // CL2
    parameter real T_OH  = 2.5,
    parameter real T_LZ  = 1.0,
    parameter real T_HZ  = 5.4,
    parameter real T_IS  = 1.5,
    parameter real T_IH  = 0.8,
    parameter real T_RCD = 18.0,
    parameter real T_RP  = 18.0,
    parameter real T_RC  = 60.0,
    parameter real T_RAS = 42.0,
    parameter real T_RRD = 12.0,
    parameter real T_WR  = 12.0,
    parameter real T_RFC = 60.0,
    parameter real T_REFI_MAX = 15625.0,
    parameter real T_INIT = 100000.0,
    parameter real GAP_NS = 50000.0,
    parameter integer MAXMSG = 10,
    parameter integer JUNK = 0,       // 1: drive pseudo-random junk instead of X outside the data window
    parameter NAME = "sdr"
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [10:0] a,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:(1 << 21) - 1];

    integer errors = 0;
    integer n_act = 0, n_rd = 0, n_wr = 0, n_pre = 0, n_ref = 0, n_mrs = 0, n_reinit = 0;

    reg [31:0] dq_drv = 32'bx;
    reg        dq_en  = 1'b0;
    assign dq = dq_en ? dq_drv : 32'bz;

    reg [3:0]  open = 4'b0;
    reg [10:0] row [0:3];
    realtime   t_act [0:3];
    realtime   t_pre [0:3];
    realtime   t_wlast [0:3];
    integer    e_rd [0:3];
    realtime   t_act_any = -1.0e9, t_ref = -1.0e9, t_last_cmd = -1.0e9;
    realtime   t_edge = -1.0e9, t_ctl_chg = -1.0e9, t_dq_chg = -1.0e9, t_wedge = -1.0e9;
    integer    ec = 0, e_col = -100, e_mrs = -100;
    reg        mode_set = 1'b0;
    integer    cl = 3;
    real       t_ac = 5.4;

    // read launch queue: entry j is launched at the (j+1)-th next edge
    reg        lq_v [0:7];
    reg [31:0] lq_d [0:7];
    reg        driving = 1'b0;

    // pending second write beat
    reg        wr_pend = 1'b0;
    reg [20:0] wr_addr;

    integer i;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            t_act[i] = -1.0e9; t_pre[i] = -1.0e9; t_wlast[i] = -1.0e9; e_rd[i] = -100;
            row[i] = 11'd0;
        end
        for (i = 0; i < 8; i = i + 1) begin
            lq_v[i] = 1'b0; lq_d[i] = 32'd0;
        end
    end

    integer maxmsg = MAXMSG, nmsg = 0;   // the testbench may change these at run time
    task automatic err(input [8*48-1:0] what);
        begin
            errors = errors + 1;
            if (nmsg < maxmsg) begin
                nmsg = nmsg + 1;
                $display("[%s] %0t ns: SDRAM model error: %0s", NAME, $realtime, what);
            end
        end
    endtask

    integer junk_seed = 7;
    function automatic [31:0] junk(input integer dummy);
        junk = (JUNK != 0) ? $random(junk_seed) : 32'bx;
    endfunction

    // setup / hold of control and address
    reg [21:0] ctl_prev = 22'd0;
    always @(cs_n or ras_n or cas_n or we_n or ba or a or dqm or cke) begin
        if ($realtime > 0 && $realtime - t_edge < T_IH) begin
            err("hold violation (cmd/addr/dqm)");
            if (nmsg < maxmsg)
                $display("[%s]   {cke cs ras cas we ba a dqm} %b -> %b, %.3f ns after the clock edge",
                         NAME, ctl_prev, {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm}, $realtime - t_edge);
        end
        t_ctl_chg = $realtime;
        ctl_prev = {cke, cs_n, ras_n, cas_n, we_n, ba, a, dqm};
    end

    // hold of write data (only while the model is not driving)
    always @(dq) begin
        if (!dq_en && $realtime - t_wedge < T_IH) err("hold violation (write data)");
        t_dq_chg = $realtime;
    end

    task automatic write_beat(input [20:0] ad);
        integer b;
        reg [31:0] v;
        begin
            if ($realtime - t_dq_chg < T_IS) err("setup violation (write data)");
            v = mem[ad];
            for (b = 0; b < 4; b = b + 1) begin
                if (!dqm[b]) begin
                    if (^dq[8*b +: 8] === 1'bx) err("X/Z in unmasked write data");
                    v[8*b +: 8] = dq[8*b +: 8];
                end
            end
            mem[ad] = v;
            t_wedge = $realtime;
        end
    endtask

    reg [2:0] cmd;
    integer   bk;
    realtime  now;
    reg       launch_v;
    reg [31:0] launch_d;

    always @(posedge clk) begin
        now = $realtime;
        ec  = ec + 1;
        if (now - t_ctl_chg < T_IS) err("setup violation (cmd/addr/dqm)");
        t_edge = now;

        // second write beat
        if (wr_pend) begin
            write_beat(wr_addr);
            t_wlast[wr_addr[20:19]] = now;
            wr_pend = 1'b0;
        end

        // read data launch
        launch_v = lq_v[0];
        launch_d = lq_d[0];
        for (i = 0; i < 7; i = i + 1) begin
            lq_v[i] = lq_v[i + 1];
            lq_d[i] = lq_d[i + 1];
        end
        lq_v[7] = 1'b0;
        if (launch_v) begin
            if (!driving) dq_en <= #(T_LZ) 1'b1;
            dq_drv <= #(T_OH) junk(0);
            dq_drv <= #(t_ac) launch_d;
            driving = 1'b1;
        end else if (driving) begin
            dq_drv <= #(T_OH) junk(0);
            dq_en  <= #(T_HZ) 1'b0;
            driving = 1'b0;
        end

        cmd = {ras_n, cas_n, we_n};
        if (cke && !cs_n && cmd != 3'b111) begin
            if (now < T_INIT) err("command before the power-up wait");
            if (now - t_last_cmd > GAP_NS && mode_set) begin
                // controller re-initialization: forget the mode register and the refresh history
                mode_set = 1'b0;
                n_reinit = n_reinit + 1;
                t_ref = -1.0e9;
            end
            t_last_cmd = now;
            if (mode_set && cmd != 3'b001 && t_ref > 0 && now - t_ref > T_REFI_MAX)
                err("refresh interval exceeded");
            bk = ba;
            case (cmd)
                3'b011: begin  // ACTIVE
                    n_act = n_act + 1;
                    if (!mode_set) err("ACT before MRS");
                    if (ec - e_mrs < 2) err("tMRD");
                    if (open[bk]) err("ACT to an open bank");
                    if (now - t_pre[bk] < T_RP) err("tRP (ACT)");
                    if (now - t_act[bk] < T_RC) err("tRC");
                    if (now - t_act_any < T_RRD) err("tRRD");
                    if (now - t_ref < T_RFC) err("tRFC (ACT)");
                    open[bk] = 1'b1;
                    row[bk] = a;
                    t_act[bk] = now;
                    t_act_any = now;
                end
                3'b101, 3'b100: begin  // READ / WRITE
                    if (!open[bk]) err("READ/WRITE to a closed bank");
                    if (now - t_act[bk] < T_RCD) err("tRCD");
                    if (a[10]) err("auto precharge (not expected)");
                    if (ec - e_col < 2) err("burst interrupted");
                    e_col = ec;
                    if (cmd == 3'b101) begin
                        n_rd = n_rd + 1;
                        e_rd[bk] = ec;
                        lq_v[cl - 2] = 1'b1;
                        lq_d[cl - 2] = mem[{ba, row[bk], a[7:0]}];
                        lq_v[cl - 1] = 1'b1;
                        lq_d[cl - 1] = mem[{ba, row[bk], a[7:1], ~a[0]}];
                    end else begin
                        n_wr = n_wr + 1;
                        write_beat({ba, row[bk], a[7:0]});
                        wr_pend = 1'b1;
                        wr_addr = {ba, row[bk], a[7:1], ~a[0]};
                        t_wlast[bk] = now;
                    end
                end
                3'b010: begin  // PRECHARGE (A10: all banks)
                    n_pre = n_pre + 1;
                    for (i = 0; i < 4; i = i + 1) begin
                        if (a[10] || i == bk) begin
                            if (open[i]) begin
                                if (now - t_act[i] < T_RAS) err("tRAS");
                                if (now - t_wlast[i] < T_WR) err("tWR");
                                if (ec - e_rd[i] < 2) err("PRE during read burst");
                            end
                            open[i] = 1'b0;
                            t_pre[i] = now;
                        end
                    end
                end
                3'b001: begin  // AUTO REFRESH
                    n_ref = n_ref + 1;
                    if (open != 4'b0) err("REF with an open bank");
                    for (i = 0; i < 4; i = i + 1) begin
                        if (now - t_pre[i] < T_RP) err("tRP (REF)");
                        if (now - t_act[i] < T_RC) err("tRC (REF)");
                    end
                    if (now - t_ref < T_RFC) err("tRFC (REF)");
                    if (mode_set && t_ref > 0 && now - t_ref > T_REFI_MAX) err("refresh interval exceeded");
                    t_ref = now;
                end
                3'b000: begin  // MODE REGISTER SET
                    n_mrs = n_mrs + 1;
                    if (open != 4'b0) err("MRS with an open bank");
                    if (a[2:0] != 3'b001) err("burst length is not 2");
                    if (a[3]) err("interleaved burst");
                    if (a[9]) err("single-location write mode");
                    if (a[6:4] != 3'd2 && a[6:4] != 3'd3) err("CAS latency not 2 or 3");
                    cl = a[6:4];
                    t_ac = (cl == 2) ? T_AC2 : T_AC3;
                    mode_set = 1'b1;
                    e_mrs = ec;
                end
                default: err("unsupported command");
            endcase
        end
    end
endmodule

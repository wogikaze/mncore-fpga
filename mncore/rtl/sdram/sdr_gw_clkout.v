// sdr_gw_clkout: forward a clock to an output pin through an ODDR (Gowin IOLOGIC), so the pin
// clock has the same output path as the registered command / data pins.
// Without SYNTHESIS (simulation, lint) the clock is passed through.
`default_nettype none

module sdr_gw_clkout (
    input  wire clk,
    output wire q
);
`ifdef SYNTHESIS
    ODDR u_oddr (.D0(1'b1), .D1(1'b0), .TX(1'b0), .CLK(clk), .Q0(q), .Q1());
`else
    assign q = clk;
`endif
endmodule

`default_nettype wire

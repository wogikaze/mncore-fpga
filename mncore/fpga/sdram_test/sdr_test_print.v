// sdr_test_print: prints one line from a fixed template. Each '#' in the template is replaced by the
// next hex digit of `fields` (taken from the MSB end). `busy` stays high until the line is sent.
// Characters go out only while host_ok is 1: the BL616 USB-UART bridge stops relaying FPGA -> PC for
// good when the FPGA sends while no host reads the port (measured), so the host polls and the
// test waits for it.
//   kind 0:  SDRAM f=<freq> cl=<cl> aw=<aw>
//   kind 1:  S p=<phase> k=<rdx> e=<errors>                        (one sweep point)
//   kind 2:  C p=<phase> k=<rdx> n=<window> eye=<64 bit pass map>  (chosen setting)
//   kind 3:  R i=<iter> p= k= e=<errors> m=<mask errors> sw= sr= rr= rw=<cycles> fa=<addr> fd=<data>
`default_nettype none

module sdr_test_print #(
    parameter integer CLKDIV = 938
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [1:0]   kind,
    input  wire [287:0] fields,
    input  wire         host_ok,           // transmit only while the host is reading (BL616 bridge)
    output wire         busy,
    output wire         tx
);
    localparam integer TL = 120;           // template length in characters (left-padded with NUL)
    localparam integer TL1I = TL - 1;
    localparam [6:0]   TL1  = TL1I[6:0];
    localparam [8*TL-1:0] T0 = "\015\012SDRAM f=######## cl=# aw=##\015\012";
    localparam [8*TL-1:0] T1 = "S p=# k=# e=######\015\012";
    localparam [8*TL-1:0] T2 = "C p=# k=# n=## eye=################\015\012";
    localparam [8*TL-1:0] T3 = "R i=#### p=# k=# e=###### m=###### sw=######## sr=######## rr=######## rw=######## fa=##### fd=################\015\012";

    reg         act;
    reg [6:0]   idx;
    reg [1:0]   kd;
    reg [287:0] f;
    reg         tx_go;
    reg [7:0]   tx_byte;
    wire        tx_busy;

    reg [8*TL-1:0] tmpl;
    always @* begin
        case (kd)
            2'd0:    tmpl = T0;
            2'd1:    tmpl = T1;
            2'd2:    tmpl = T2;
            default: tmpl = T3;
        endcase
    end
    wire [7:0] ch = tmpl[idx * 8 +: 8];
    wire [3:0] nib = f[287:284];
    wire [7:0] hex = (nib < 4'd10) ? (8'h30 + {4'd0, nib}) : (8'h57 + {4'd0, nib});

    always @(posedge clk) begin
        tx_go <= 1'b0;
        if (rst) begin
            act <= 1'b0;
        end else if (!act) begin
            if (start) begin
                act <= 1'b1;
                idx <= TL1;
                kd  <= kind;
                f   <= fields;
            end
        end else if (!tx_go && !tx_busy && host_ok) begin
            if (ch != 8'd0) begin
                tx_go   <= 1'b1;
                tx_byte <= (ch == "#") ? hex : ch;
                if (ch == "#") f <= {f[283:0], 4'd0};
            end
            if (idx == 7'd0) act <= 1'b0;
            else idx <= idx - 7'd1;
        end
    end

    assign busy = act || tx_go || tx_busy;

    sdr_test_uart_tx #(.CLKDIV(CLKDIV)) u_tx (
        .clk(clk), .rst(rst), .go(tx_go), .data(tx_byte), .busy(tx_busy), .tx(tx)
    );
endmodule

`default_nettype wire

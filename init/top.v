module top(input clk, input btn_rev, input btn_alt, output [5:0] led);
  reg [23:0] cnt = 0;
  reg [5:0]  pat = 6'b000001;
  reg        dir = 1'b0;   // 0: 左へ, 1: 右へ（逆順）
  reg        alt = 1'b0;   // 1: 101010/010101 交互モード

  // ボタン: 約10msごとにサンプリング（簡易チャタリング除去）+ 立ち上がり検出
  reg [18:0] dbc = 0;
  reg        rev_q = 0, alt_q = 0;
  wire       tick = (dbc == 19'd0);
  wire       rev_p = tick & btn_rev & ~rev_q;
  wire       alt_p = tick & btn_alt & ~alt_q;

  always @(posedge clk) begin
    dbc <= dbc + 1'b1;
    if (tick) begin
      rev_q <= btn_rev;
      alt_q <= btn_alt;
    end

    if (rev_p) begin            // 87: 回転モードに戻し、向きを反転
      alt <= 1'b0;
      dir <= ~dir;
      pat <= 6'b000001;
    end else if (alt_p) begin   // 88: 交互点灯モード
      alt <= 1'b1;
      pat <= 6'b101010;
      cnt <= 0;
    end else if (cnt == 24'd13_499_999) begin   // 27MHz で 0.5秒
      cnt <= 0;
      if (alt)       pat <= ~pat;                          // 101010 <-> 010101
      else if (dir)  pat <= {pat[0], pat[5:1]};            // 右へ
      else           pat <= {pat[4:0], pat[5]};            // 左へ1つずらす
    end else
      cnt <= cnt + 1'b1;
  end

  // PWMで明るさ調整: 27MHz / 256 ≈ 105kHz。DUTY/256 が点灯割合
  localparam [7:0] DUTY = 8'd32;       // 32/256 ≈ 12.5%
  reg [7:0] pwm = 0;
  always @(posedge clk) pwm <= pwm + 1'b1;
  wire on = (pwm < DUTY);

  assign led = ~(pat & {6{on}});       // 負論理なので反転
endmodule

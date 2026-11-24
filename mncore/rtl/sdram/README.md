# rtl/sdram: GW2AR-18 内蔵 SDRAM のコントローラ（WP05）

Tang Nano 20K の GW2AR-18 には 64 Mbit の SDR SDRAM が載っている。32bit 幅、4 バンク × 2048 行 × 256 列で 8 MiB。
このディレクトリは、これを契約 §6 の 64bit メモリバスで使えるようにする。

## モジュール

| ファイル | モジュール | 役割 |
| --- | --- | --- |
| `sdr_bus64.v` | `sdr_bus64` | 契約 §6 のバス（`req_*` / `rsp_*`、64bit 長語）。要求キュー、32bit 2 ビートの結合、クロックの乗り換え（`ASYNC=1`）。中で `sdr_ctrl` を使う |
| `sdr_ctrl.v` | `sdr_ctrl` | SDRAM 側（32bit）。初期化、オープンページのスケジューラ、リフレッシュ、読み出しの取り込み。1 コマンドで 2 列（バースト長 2）を転送する |
| `sdr_tmr.v` | `sdr_tmr` | タイミング制約 1 つ分のダウンカウンタ。「満たした」フラグをレジスタで出す |
| `sdr_fifo.v` | `sdr_fifo` | 同期 FIFO（先頭語が見える型、LUT RAM） |
| `sdr_afifo.v` | `sdr_afifo` | 非同期 FIFO（グレイコードのポインタ、2 段の同期化） |
| `sdr_gw_pll.v` | `sdr_gw_pll` | Gowin `rPLL` のラッパ。コントローラのクロックと、位相をずらした SDRAM 端子用クロック（位相は固定または動的）。シミュレーション用の動作モデル付き |
| `sdr_gw_clkout.v` | `sdr_gw_clkout` | `ODDR` を通してクロックを端子に出す。他の端子と同じ出力経路になる |

## バス（契約 §6）

```
req_valid, req_ready, req_we, req_addr[22:0]（長語単位）, req_wdata[63:0], req_wmask[7:0]
rsp_valid, rsp_rdata[63:0]       読み出し 1 回につき応答 1 回。要求の順に返す。背圧はない
```

- `req_addr[19:0]` で 2^20 個の長語の 1 つを選ぶ。`req_addr[22:20] != 0` の要求は `req_addr[19:0]` に対して実行し、`err_addr`（保持型）を立てる。
- `req_wmask[i] = 1` でバイト i を書く。`req_wdata[31:0]` が偶数列、`[63:32]` が奇数列に入る。
- 長語の配置: `req_addr = {row[10:0], bank[1:0], colpair[6:0]}`。連続アクセスは 128 長語（1 KiB）ごとに次のバンクへ移る。
- `init_done` はリセット解除の約 200 µs 後に立つ。それ以前の要求はキューに積まれる。
- `ASYNC=0`: 全体が `clk` で動く。`ASYNC=1`: バス側が `clk`/`rst`、コントローラが `sclk`/`srst`（2 つのリセットは同時に入れる）。応答 FIFO があふれないよう、未応答の読み出しを `2**RAW` 個までに制限する。

## スケジューリングとタイミングの定数

- オープンページ方式。列コマンド（READ/WRITE）は要求の順に出す。同じアドレスへの読み書きの順序は要求どおりになる。先頭の要求が待っている間に、次の要求が別バンクなら、その ACTIVATE/PRECHARGE を先に出す。
- 先頭・次の要求の「行が開いているか」「行が一致するか」はレジスタに持つ。キューに新しく入った要求だけ 1 サイクル待つ。
- リフレッシュ: `T_REFI_NS = 7800` ごとに全バンクのプリチャージと自動リフレッシュ（64 ms に 8192 回。部品が要求する 4096 回の 2 倍）。
- 既定のタイミング（ns）: tRP 20、tRCD 20、tRC 66（tRAS + tRP で保証）、tRAS 45、tRRD 15、tWR 15（最低 2 クロック）、tRFC 66、tMRD 3 クロック、READ→WRITE は CL+4 クロック。
  166 MHz 品（-6 グレード）の SDR SDRAM に対して余裕を持たせた値。GW2AR 内のダイの型番は Gowin が公開していない（データシート DS226 には 64 Mbit、32bit、166 MHz とだけある）。
- CAS レイテンシ: 100 MHz までは `CL=2`、それより上は `CL=3`。

## クロックとボードでの調整

```
27 MHz ── rPLL ─ CLKOUT  ─────────────────────── コントローラ（DQ の取り込みを含む全レジスタ）
               └ CLKOUTP（位相 p × 22.5°） ── ODDR ── O_sdram_clk
```

ボードに依存する設定が 2 つある。

- `p`: SDRAM クロックの PLL 位相（`PSDA`、0〜15）。
- `cfg_rdx`: READ から 1 ビート目を取り込むまでの追加サイクル数。1 ビート目は、READ を端子に出したクロックから `CL + cfg_rdx` サイクル後に、DQ を受けるレジスタから取る。

`mncore/fpga/sdram_test` が、動的位相の PLL で (p, cfg_rdx) の通る範囲を実機で測って表示する。結果（2026-11-24、IOB へのレジスタ詰め込みなし）:

| クロック | PLL（IDIV, FBDIV, ODIV） | CL | 通った範囲 | 推奨値 | 8 MiB 全域試験 |
| --- | --- | --- | --- | --- | --- |
| 54 MHz | 0, 1, 16 | 2 | rdx=0: p=3〜5、rdx=1: p=8〜14 | p=11, rdx=1 | 100 回連続で誤り 0 |
| **99 MHz** | 2, 10, 8 | 2 | rdx=1: p=5〜12 | **p=8, rdx=1** | 100 回連続で誤り 0（固定位相でも 30 回） |
| 108 MHz | 0, 3, 8 | 3 | rdx=1: p=6〜10 | p=8, rdx=1 | 100 回連続で誤り 0（固定位相でも 30 回） |

推奨は 99 MHz / CL2（窓が最も広く、ランダム読み出しも速い）。帯域の実測値は `mncore/status/WP-05.md`。

`sdr_gw_pll` は `DYN_PHASE=0` でも rPLL を動的位相モードで使い、`PSDA` の値を端子に固定する。
静的な `PSDA_SEL` の符号化では、同じ値 8 でも位相が違い、SDRAM が誤った（実測）。`PSDA` の値は上の表の p と同じ意味になる。

## 上位で使うとき

下のポート名は nextpnr-himbaechel（apicula）が SDRAM のダイに自動で割り当てる。`.cst` には書かなくてよい。

```verilog
output O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n,
output [3:0] O_sdram_dqm, output [10:0] O_sdram_addr, output [1:0] O_sdram_ba,
inout  [31:0] IO_sdram_dq

sdr_gw_pll #(.IDIV_SEL(2), .FBDIV_SEL(10), .ODIV_SEL(8), .PSDA(8)) u_pll (.clkin(clk27), .psda(4'd0),
    .clkout(sclk), .clkoutp(pclk), .lock(lock));                  // 99 MHz
sdr_gw_clkout u_ck (.clk(pclk), .q(O_sdram_clk));
sdr_bus64 #(.FREQ_HZ(99000000), .CL(2)) u_sdr (.clk(sclk), .rst(rst), .sclk(sclk), .srst(rst),
    .cfg_rdx(2'd1), ... .sdr_dq_o(dq_o), .sdr_dq_oe(dq_oe), .sdr_dq_i(IO_sdram_dq));
assign IO_sdram_dq[i] = dq_oe[i] ? dq_o[i] : 1'bz;                // ビットごと（generate）
```

nextpnr の IOB へのレジスタ詰め込み（`--vopt ireg_in_iob` / `oreg_in_iob` / `ioreg_in_iob`）について:
`oreg_in_iob` で UART の出力レジスタが IOB に入ると、実機で出力が化けた。`ireg_in_iob` だけでも、`uart_rx` の入力レジスタが IOB に入った版は UART が応答しなかった（2026-11-24、OSS CAD Suite 2026-11-23）。
どちらも使わない（`build.py --iob none` が既定）。上の表は詰め込みなしで測った。
なお `IO_sdram_dq` の入力・出力レジスタはファブリックにあるので、配置が変わると最適な位相も少し動きうる。大きく変えたら `sdram_test` で窓を測り直す。

## 出典とライセンス

このコントローラはこのリポジトリのために新しく書いたもの（MIT、リポジトリ直下の `LICENSE`）。外部のコードは取り込んでいない。参考にした資料は次のとおり。

- nand2mario, *sdram-tang-nano-20k*（<https://github.com/nand2mario/sdram-tang-nano-20k>、Apache-2.0）:
  内蔵 SDRAM の構成（2K 行 × 256 列 × 4 バンク × 32bit）、`O_sdram_*` / `IO_sdram_dq` という特別なポート名、SDRAM クロックの位相をずらす考え方。
  コントローラ本体（バイト単位、自動プリチャージ、1 アクセスずつ）は使っていない。
- apicula（<https://github.com/YosysHQ/apicula>、MIT）: `chipdb_builder.py` に、nextpnr が名前で割り当てる GW2AR-18C の SDRAM 端子の一覧がある。
  `gowin_pack.py` で rPLL の位相（`PSDA_SEL`、`DYN_DA_EN`）と IOB レジスタの対応を確認した。
- Gowin DS226（GW2AR シリーズのデータシート）: 64 Mbit SDR SDRAM、166 MHz。

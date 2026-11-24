# 06. 共通契約（並列作業のための取り決め）

すべての WP（作業パッケージ）は、この文書と、リポジトリ直下の `CLAUDE.md` に従う。
**変更できるのは統括（lead）だけ。** 変更が必要な WP は、報告書の「契約変更の要望」欄に書く。

## 1. 正解の優先順位

1. **公式エミュレータ `gpfn3_package_main`**（judge 同梱の v20240826）。これが最終的な正解。
2. `third_party/mncore/viz/core` の Rust Sim。ユニット単位のベクタと縮小トポロジの正解はここから作る。
   - WP02 の全件比較（959 本）では両方が通った 809 本のうち 801 本が一致した。
   - **例外: MV の n128 転送（`mvb/n128 $d0 $lc0`、`mvrffadd/n128 $lc0 $d0` など）。** viz/core の commit `2b9e595` 以降で公式と食い違う（WP06 で修正予定）。修正されるまで、これを含むプログラムは公式だけを正解とする。
   - PDM は比較から外す。公式の `d get $p` は PDM ではなく DRAM の内容を出すため。
3. SDM（`third_party/mncore/docs/mncore_llm`）、Scrapbox [mncore/機械語](https://scrapbox.io/mncore/機械語)。
   - Scrapbox には観測にもとづくフィールドの意味が書いてある。

1 と 2 が食い違ったら作業を止め、報告書に書く。勝手にどちらかに合わせない。

## 2. 入力形式

- FPGA が受け取る機械語は **flat 形式で、パック前のもの**とする。
  `assemble3 --instruction-mode flat --disable-packer` の出力で、`j`（426bit）、`m`（82bit）、`d`（デバッグ）の行からなる。
  auto_stride（`i` 292bit）と q 形式は対象外。
- 基準のアセンブラは WSL の `~/wgkz/mncore/judge/judge-py/mncore2_emuenv/assemble3`（2024 年配布版）。
  SDK 0.9 版とは L1BM の欄（187..194）が異なる（Scrapbox 参照）。
- **フィールドの定義は `mncore/spec/isa/j_flat.yaml` と `m.yaml`（WP01 で確定）。**
  - `assemble3 --print-csv` の値の列を順に連結すると `j`/`m` 語と一致する。
  - ただし **CSV ヘッダの列名は auto_stride の並びなので、flat の列名には使えない**。列名は j_flat.yaml の `csv_col` で引く。
- assemble3 の出力に出る `r` 行（.vsm のデータ行をそのまま出したもの）は、ホスト側ツールが `WR_MEM` に変換する。FPGA は解釈しない。
- submodule の .vsm は `core.autocrlf=true` だと CRLF でチェックアウトされ、assemble3 が失敗する。assemble3 に渡す前に CR を除く。

### ビット番号

- 文字列の左端を pos 0 とする（Scrapbox と同じ）。
- Verilog では `input [425:0] jw` とし、**`jw[425-pos]` が pos に対応する**（MSB-first）。MV 語は `[81:0]`。
- フィールド名は j_flat.yaml の `name`（CSV 名の `.` と `/` を `_` に置き換えたもの）。例: `pe.aluc.aluop` → `pe_aluc_aluop`。
  - flat の L1BM 187..190 / 191..194 は 2 欄に分かれ、`l1bm_mabadr` と `l1bm_opcode` とする。
- cycle1〜3 のアドレス欄には `_c1` / `_c2` / `_c3` を付ける（`spec/isa/` が正）。
- 先頭 2bit（ll）: `01` 通常、`11` noforward（書くがフォワーディングを更新しない）、`00` nop、`10` は停止 → FPGA は `E_DECODE`。
- 予約欄 `rsv_162` / `rsv_164` が 0 以外なら `E_UNSUPPORTED <field>`。
- imm の語では LM0 欄は即値なので、`pe_lm0_write` を LM0 書き込みとして解釈しない。

## 3. 縮小トポロジ

| パラメータ | 既定（初期） | 意味 |
| --- | --- | --- |
| `N_L2B` | 1 | L2B の数 |
| `N_L1B` | 1 | L2B あたりの L1B の数 |
| `N_MAB` | 1（P3 から 16） | L1B あたりの MAB の数 |
| `N_PE` | 4 で固定 | MAB あたりの PE の数（初期の RTL は PE 0 だけを持つ「1 PE モード」） |
| `LM_DEPTH` | 256 長語（1 PE モードでは 512 可。BSRAM の費用は同じ） | LM0/LM1 の容量。実機は 2048 |
| `GRF_DEPTH` | 256 長語 | GRF0/GRF1 の容量（実機と同じ） |
| `L1BM_DEPTH` / `L2BM_DEPTH` | 1024 / 2048 長語 | 実機は 8192 / 32768（WP07 の予算により L2BM を 4096 → 2048 に変更） |

- 実装する PE は、チップ上の座標 `n0 c0 b0 m0 p0` から順に割り当てる。
  `$peid` / `$l1bid` / `$l2bid` / `$mabid` / `$subpeid` は**実チップでの値**を返す。
- 縮小した容量の外にアクセスしたら、**トラップ**（ステータスコード `E_RANGE` と語番号）を出して停止する。黙って折り返してはいけない。
- 縮小構成での正解は次の 2 つ。
  - (b) 4096 PE で実行し、実装した PE の範囲だけを比較する（初期）
  - (a) Rust Sim の縮小トポロジ版で実行する（WP06 の後）

## 4. 正規化ダンプ（`.ndmp`）

比較は常にこの形式で行う。

```
# ndmp v1
LM0 n0c0b0m0p0 0x0000 0123456789abcdef
GRF1 n0c0b0m0p3 0x00ff 3ff0000000000000
L1BM n0c0b0 0x0010 0000000000000000
```

- 1 行に 1 長語。列は「空間名 位置 長語アドレス 値（16 桁 hex、小文字）」。
- アドレスは 4 桁。PDM と DRAM だけ 8 桁。
- 追加の空間: `LM0W LM1W GRF0W GRF1W`（単語アクセス）、`OMR`（アドレスはエントリ × 4 + サイクル）。
- T のアドレスは「2 × サイクル + k」。L1BM の `$llb` は長語 a と a + 4 の組として出す。
- 同じ場所への d get が複数回あるときは後勝ち。
- ヘッダ行の後にメタデータ行（`#` 始まり）を置いてよい。細目の正は `mncore/tools/golden/` の実装と `mncore/status/WP-02.md`。
- 空間名は `LM0 LM1 GRF0 GRF1 T L1BM L2BM PDM DRAM` と、必要なら追加する名前。位置の表記は SDM 3.4.3 の d get に合わせる。
- 行を辞書順に並べる。比較ツールは `mncore/tools/golden/ndiff.py`（WP02）。
- 変換器（WP02 が作る）:
  - `norm_gpfn3.py`: 公式の dmp → ndmp
  - Rust Sim → ndmp
  - FPGA や RTL シミュレーションのダンプ → ndmp

## 5. ユニットテスト用ベクタの形式（`.vec`）

```
# vec v1 unit=alu op=iadd dmode=01 cols: a b c flags_in | y flags_out
0000000100000002 0000000300000004 0000000000000000 0 | 0000000400000006 0
```

- 空白区切りの hex。`|` の左が入力、右が期待値。1 行目の `#` に列の定義を書く。
- 生成するのは WP03（`mncore/vecgen`、Rust）。置き場所は `mncore/sim/vectors/<unit>/*.vec`。生成物なので git 管理しない。
- 小さな固定サンプルだけは `mncore/sim/vectors_fixed/` に置いてコミットする。

## 6. RTL の規約

- **Verilog-2005** と `generate` を使う。テストベンチだけ `iverilog -g2012` の範囲で SystemVerilog を使ってよい。
- 1 ファイルに 1 モジュールを書き、ファイル名とモジュール名を同じにする。接頭辞は `mn_`。
  - ボード周りは `brd_`、SDRAM は `sdr_`。
- クロックは `clk`、リセットは同期式で正論理の `rst`。コア部分は単一クロックにする。クロックをまたぐのは `rtl/board` と `rtl/sdram` の中だけ。
- 合格条件（各 WP は提出前に 3 つとも通す）:
  1. `iverilog -g2012 -Wall`（テストベンチを含む）
  2. `verilator_bin --lint-only -Wall`。抑止する警告は、ファイル内の `/* verilator lint_off */` で理由を添えて書く。
  3. `yosys -p "synth_gowin -family gw2a"` がエラーなく終わる。資源の使用量を報告書に書く。
- テストベンチは自己検査にする。最後の行に `PASS` か `FAIL <理由>` を出し、`$finish` で終える。
- 実行方法: `python mncore/tools/simrun.py <unit>`（WP00 が雛形を作る）。
  `mncore/sim/tb/<unit>/files.txt` に RTL とテストベンチの一覧を書く。

### 内部のメモリバス（SDRAM と BSRAM ストアで共通）

```
req_valid, req_ready, req_we, req_addr[22:0] (長語単位), req_wdata[63:0], req_wmask[7:0]
rsp_valid, rsp_rdata[63:0]   // 読み出しの応答はリクエストの順に返す
```

### 資源予算（WP07 で確定。根拠は `mncore/07-device-budget.md`）

| 区分 | BSRAM ブロック数（全 46） | 備考 |
| --- | --- | --- |
| 命令メモリ | 12 | 426bit × 256〜512 語。大きなプログラムは SDRAM から先読みする |
| PE 1 個分の状態（LM0/LM1/GRF0/GRF1） | 8 | 64bit 幅、32bit レーンの 1R1W × 4 面。T（64bit × 8）は SSRAM。1 MAB を BSRAM に置くなら 16 |
| L1BM / L2BM | 4 + 8 | 1024 / 2048 長語 |
| ボード | 0〜2 | |
| 予備 | 残り | 1 PE で計 34/46、1 MAB で 42/46 |

- 乗算器 48 個（18×18 換算）のうち FPU に最大 24 個。FMA 1 個は 9 個が目安。

### RAM と DSP の書き方

- RAM と乗算は `mncore/fpga/recipes/` のレシピ（`mn_ram_1r1w`、`mn_ram_1r1w_be`、`mn_ram_2r1w`、`mn_ram_tdp`、`mn_ram_lut`、`mn_mul_pipe`）を使う。各 unit の `files.txt` からそのパスを参照してよい。
- BSRAM には `no_rw_check` を付ける（レシピが付けている）。
- **バイトイネーブルの挙動に依存しない。** 部分書き込みは 32bit レーンに分けた RAM で行う。
- 各メモリはサイクルあたり読み出しアドレス 1 本で足りる（2R1W は不要）。書き込みの単位は 32bit 語。
- **DSP の前後には必ずレジスタを置く。** nextpnr は DSP を通る経路の遅延を計算しないため。DSP の上限は 275 MHz とみなす。

## 7. ホストとの通信（UART）

- BL616 経由の USB-UART。初期は 1 Mbps、8N1。運用は 2 Mbps を推奨（上限 3 Mbaud。BL616 は実際 3.076M で動くので `SET_BAUD` で合わせる）。
- ピンは `uart_tx` = 69（FPGA → BL616）、`uart_rx` = 70。
- **確定仕様は `mncore/rtl/board/PROTOCOL.md`（版 1）。** コマンド番号、空間 ID、エラー応答はそちらが正。
- 空間 ID: 0 IMEM、1 LM0、2 LM1、3 GRF0、4 GRF1、5 T、6 L1BM、7 L2BM、8 PDM、9 DRAM、15 TEST。
- 位置の符号化: `loc = n<<10 | c<<9 | b<<6 | m<<2 | p`。
- 命令メモリのエントリ: 448bit。`[447:446]` が種類（01 = j、10 = m）、`[425:0]` が jw（m は下位 82bit）。
- BL616 の制約: 読み出しは約 70 KiB/s が上限。未受信の応答を 6300 バイト以下に保つ。PC から Ctrl-X / Ctrl-C を単独で送らない（BL616 のシェルに入り、`mnhost.py bridge reboot` が要る）。
- フレーム: `0xA5 | cmd u8 | len u16le | payload | crc8`
- コマンド:
  - `PING`、`INFO`（0x02）、`SET_BAUD`（0x09）
  - `WR_IMEM(addr, words)`
  - `WR_MEM(space, loc, addr, data)`
  - `RD_MEM(space, loc, addr, n)`
  - `RUN(start, count)`
  - `STATUS`（停止理由: `OK` / `E_RANGE` / `E_UNSUPPORTED <field>` / `E_DECODE`。`E_DECODE` は ll=10 など）
  - `RESET`
- 詳細は WP04 が `mncore/rtl/board/PROTOCOL.md` に書く。
- `d set` / `d get` はホスト側ツールが `WR_MEM` / `RD_MEM` と `RUN` の分割に変換する。FPGA は `d` 行を解釈しない。

## 8. リポジトリとディレクトリの担当

```
nano20k/                    （git リポジトリ。公開予定）
  CLAUDE.md                 lead
  third_party/mncore/       submodule（wogikaze/mncore）。WP06 だけがブランチで変更する
  mncore/*.md               lead
  mncore/wp/                lead（各 WP の指示書）
  mncore/status/WP-xx.md    各 WP（報告書。自分のファイルだけ）
  mncore/spec/isa/          WP01
  mncore/tools/mnisa/       WP01（Python: decode / encode / CSV 取り込み）
  mncore/tools/golden/      WP02
  mncore/tools/host/        WP04
  mncore/tools/simrun.py    WP00 → 以後は lead
  mncore/vecgen/            WP03（Rust crate）
  mncore/rtl/<area>/        その area を担当する WP（下表）
  mncore/sim/tb/<unit>/     その unit を担当する WP
  mncore/fpga/<design>/     WP04 / WP21 / WP40
```

| rtl/area | 担当 |
| --- | --- |
| board | WP04 |
| sdram | WP05 |
| dec | WP10 |
| alu | WP11 |
| fpu | WP12、WP13 |
| pe | WP14 → WP20 |
| core | WP20 |
| mab | WP30 |
| l1bm | WP31 |
| l2bm | WP32 |
| mv | WP33 |
| vpe | WP34 |
| top | WP21 / WP40 |

## 9. 作業ルール（subagent 向け）

- 各 WP は git worktree で作業し、担当の外のファイルは変更しない。
  他 WP のモジュールが必要なら、**スタブを自分の tb 配下に置く**。
- 公式バイナリ（`assemble3`、`gpfn3_package_main`）とその配布物をコミットしたり再配布したりしない。
  WSL から呼び出すだけにする（`wsl -d Ubuntu -- bash -lc '...'`）。
- **実機（Tang Nano 20K）を使う WP は排他にする。**
  - `C:\wgkz\nano20k\mncore\.board.lock`（メインのチェックアウト側の絶対パス）に、WP 番号と開始時刻を書いてから使う。終わったら消す。
  - ロックが 2 時間以上前のものなら、古いロックとして扱ってよい。
  - ロックがあるときや、`openFPGALoader --detect` で見つからないときは、実機テストを「保留」として報告する。失敗扱いにはしない。
- 作業の最後に、報告書 `mncore/status/WP-xx.md` を次の章立てで書く。
  - 成果物
  - 実行したテストと結果（コマンドと出力の要約）
  - 未解決の点
  - 契約変更の要望
  - 次の WP への申し送り
- テストが通らないまま「完了」と書かない。部分的に終わった場合は、その範囲をはっきり書く。

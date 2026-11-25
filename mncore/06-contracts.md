# 06. 共通契約（並列作業のための取り決め）

すべての WP（作業パッケージ）は、この文書と、リポジトリ直下の `CLAUDE.md` に従う。
**変更できるのは統括（lead）だけ。** 変更が必要な WP は、報告書の「契約変更の要望」欄に書く。

## 1. 正解の優先順位

1. **公式エミュレータ `gpfn3_package_main`**（judge 同梱の v20240826）。これが最終的な正解。
2. `third_party/mncore/viz/core` の Rust Sim。ユニット単位のベクタと縮小トポロジの正解はここから作る。
   - WP02 の全件比較（959 本）では両方が通った 809 本のうち 801 本が一致した。
   - MV の n128 転送の食い違い（viz/core `2b9e595` で混入）は WP06 が `topo-param` ブランチの `5f0ceb1` で修正した。submodule はこのコミットを指す。これ以降は 146 件すべてで公式と一致する（lead が該当 12 本を再確認）。
   - 間接参照（`$di`）を使う `mvb` / `mvd` / `mvr` は公式との一致が未確認。
   - PE の記憶で Rust Sim と公式が食い違う点が 3 つある（WP14）。RTL は公式に合わせる。Sim の修正は後で行う。
     - T に長語マスクがかかり、そのサイクルの 4 フラグがすべて 0 のとき、公式は何も書かない。
     - `$mb` / `$lmb` にマスクがかかったとき、公式は 12bit が入っている半語のフラグだけで書くかを決める（`$mb` は f[2]、`$lmb` は f[0]）。
     - 同じステップで `$omr` に書いて `$imr` として使うと、公式は書く前の値を使う。
   - L1BM まわりの Rust Sim と公式の食い違い（WP31）: `fmaxr` / `fminr` の丸め、`fmax $..e` で拡張した値の特殊値、転送のない語のあいだの `$lbi` の保持、折り返しの読み出しだけの語による `$lbi` の上書き。SDM 3.6.8.20 の擬似コードはずらしの符号が逆。
   - L2BM まわりの Rust Sim と公式の食い違い（WP32）:
     - 連続する `l2bmdars` では、公式は最初の語の DAR アドレスと L2B を保つ。Rust は毎回設定し直す。
     - 語の中の L1BM への書き込みの順序は、公式ではサイクルごとに PE 側、L2BM 側の順。Rust は .vsm に書いた順。
   - `$lbf` の暗黙の更新: 公式は L1BM の欄がない語でも `$lbf` を更新するが、RTL は合わせない。assemble3 はその後の `$lbf` の読み出しを拒否するため、アセンブルしたプログラムでは結果に差が出ない（lead の判断）。
   - `$mreadf` は、公式では nop / noforward 以外の全ステップで更新される（WP20）。Rust Sim は ?mread のないステップで 0 にする。
   - ユニット単位の演算では食い違いが 4 種ある（§5、WP03）。
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
- ll=00 の語でも wd（wait）は有効（WP20 が公式で確認）。発行していないタグを待つと、後の語は実行されない。
- 予約欄 `rsv_162` / `rsv_164` が 0 以外なら `E_UNSUPPORTED <field>`。`<field>` は yaml の欄番号（デコーダの `err_field`）で符号化する。
- m 語の欄の Verilog 上の名前には `mv_` を付ける（`priority` が SystemVerilog の予約語のため）。
- デコーダは `mncore/tools/gen_dec.py` が yaml から生成する（`mncore/rtl/dec/`）。手で編集しない。
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
  - **実際に行うアクセスだけを検査する。** assemble3 は使わないアドレス欄にも値を置くので、欄の値だけで判定しない。
  - 語番号は 0 始まりの命令語番号。STATUS の info では命令メモリのエントリ番号になる。アドレスは折り返しの後で比べる。
  - マスクで止まる書き込みの検査は、`mn_pe_core` が検査用に imr=0 の語を LSU に渡す今の方式でよい（WP20）。LSU の内部を変えるときはこの前提を保つ。
  - 書き込みマスクで止まる書き込みも検査する。検査するのは存在するユニットだけ。
  - PE メモリの E_RANGE は実行前に検査するので、E_UNSUPPORTED より先に報告する。
- 存在しないユニットの扱い:
  - そこへの転送は捨てる。
  - そこから受け取る結合・縮約の入力は値ゼロとする。ただし `l2bmr` の集合の外は単位元とする。
  - L1BM の結合では、存在しない MAB の位置には 0 を書く。
  - 4 PE（時分割）では、どれかの PE が範囲外なら、どの PE も書く前に E_RANGE で止まる。
  - DAR はグループごとに持ち、縮小しない（1024 × 32bit）。N_L2B = 1 では `@.1` は 0 を読む。
  - L2BM の M2 の構成は `N_L1B=1`、`RRN=2`、`DAR=0`（BSRAM 8）。DAR を入れると +3（MV の間接参照に要る。WP33 で判断）。
  - L1BM の E_RANGE の対象は、欄のある語の読み出し（存在する PE の分）と、me=1 の書き込み。
  - グループは L2B を 1 つ以上持つものだけが存在する。容量には `PDM_DEPTH` / `DRAM_DEPTH` もある。
  - 定義の正は `third_party/mncore/viz/core/docs/topology.md`。
- 縮小構成での正解は次の 2 つ。
  - (b) 4096 PE で実行し、実装した PE の範囲だけを比較する。
  - (a) Rust Sim の縮小トポロジ版で実行する: `sim_run --topology <spec> [--compare-full]`。
    - (a) が全構成の切り出しと一致するのは、データの移動が、縮小構成に完全に含まれるユニットの中で閉じる命令列に限る。

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
- 小さな固定サンプルだけは `mncore/sim/vectors_fixed/` に置いてコミットする（各ファイルから 50 行。全行を公式と照合済み）。
- ヘッダの拡張（機械語の欄、`sdm`、`disputed`、`edge`）と行ごとの制御列は `mncore/vecgen/FORMAT.md` が正。
- **RTL が合わせる相手は公式エミュレータ。** WP03 で見つかった Sim と公式の食い違い 4 種（`r_round`、`ext_mul`、`fvr_flags`、`round_twice`）は公式の挙動を実装する。
  - 食い違う行は `cargo run --release -- all --official-expect` で公式の出力を期待値にする。ヘッダには `disputed=` と `expect=official` が残る。
  - ベクタの作り方: 生成 → `--official-expect` → `--check-official --sample all` → `fixed`（`FORMAT.md`）。
  - `vectors_fixed` は置き換え済みで、全行が公式と一致する。ユニットテストで disputed の行を除外しない。
  - `round_twice` の正しい規則は WP12 が確定した（`mncore/rtl/fpu/SPEC.md` の WP12 節）。
    - 積を捨てる: `Uc - Ep` が T 以上なら積を 0 とする。T は d で 55、f と h で 26。
    - h の加数は `2^(Ep-28)` の格子に揃える。
    - 出力丸めのない形でも Sim と違いが出る。seed 1 以外のベクタでは、印のないファイルで食い違いが出うる。
  - 公式で照合済みの固定サンプルは、`vectors_fixed/` のほかに、各 unit の tb 配下に置いてよい（例: `mncore/sim/tb/fpu_fp/probe/`）。
  - Sim 側の修正は後で行う（viz/core のブランチ）。

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

- SDRAM（`mncore/rtl/sdram/`、WP05）: 容量は 2^20 長語。バスは下位 20bit で実行し、超えたアドレスでは `err_addr` を立てる。
  - 上位側（コア、WP34）は、要求を出す前に範囲を検査して E_RANGE で止める。`err_addr` は最後の安全策で、立ったら E_RANGE として扱う。
  - 推奨設定は 99 MHz / CL2（`IDIV_SEL=2, FBDIV_SEL=10, ODIV_SEL=8`）、`PSDA=8`、`cfg_rdx=1`。
  - 配置が大きく変わったら `mncore/fpga/sdram_test` の掃引で位相の窓を確かめ直す。
- 合成は `synth_gowin -nowidelut` を標準とする。既定の設定ではマルチプレクサの多い論理で LUT が 14〜27% 増え、Fmax も上がらないため（WP11）。各 WP の資源報告は両方の値を書いてよい。
- `(* keep_hierarchy *)` は、段がまとめられて Fmax が落ちる箇所に、理由をコメントで添えて付けてよい。
- 整数 ALU（`mn_alu_int`、WP11）の振り分け出力 `cls_bad` は、PE コア（WP20）が `E_UNSUPPORTED` に変換する。
  - 対象は、`r` を dmode ≠ 10 に付けた語と、dmode = 11 の不正な ALU の語など。
  - デコーダ（WP10）はここを判定しない。
- nextpnr の `--vopt *reg_in_iob`（IOB へのレジスタ詰め込み）は使わない。UART が壊れたため（WP05）。

### 資源予算（WP07 で確定。根拠は `mncore/07-device-budget.md`）

| 区分 | BSRAM ブロック数（全 46） | 備考 |
| --- | --- | --- |
| 命令メモリ | 12 | 426bit × 256〜512 語。大きなプログラムは SDRAM から先読みする |
| PE 1 個分の状態（LM0/LM1/GRF0/GRF1） | 8 | 64bit 幅、32bit レーンの 1R1W × 4 面。T（64bit × 8）は SSRAM。1 MAB を BSRAM に置くなら 16 |
| L1BM / L2BM | 4 + 8 | 1024 / 2048 長語 |
| ボード | 0〜2 | |
| 予備 | 残り | 1 PE で計 34/46、1 MAB で 42/46 |

- LUT の実測（WP04〜14）。全体は 20,736。
  - デコーダ約 190、整数 ALU 約 1,900〜2,100、PE の記憶 約 5,500（RAM16SDP4 の分を含む。Fmax 約 62 MHz）。
  - FMA / MAU ベクトル 約 3,800（DSP 8）、FP ALU 約 2,500、ブロックフロート化 約 2,700。
  - ボード（host_if）約 1,900〜3,000、SDRAM 約 1,000。
  - **実機の実測（WP21、27 MHz）**: 1 PE 構成（FPALU=3）で LUT4 15,582（75%）、DFF 62%、BSRAM 23/46、DSP 8、Fmax 48 MHz。
  - **WP35 の後**: 1 PE の全部入り（FPALU=1、MAU=1）は LUT4 71%、44〜47 MHz で、実機で 259/260 が一致。
  - nextpnr の LUT4 は、桁上げ鎖 1 本ごとに約 1.8 サイト多く数える。定数との比較や短い計数器は論理式で書く。
  - 動作は当面 27 MHz なので、Fmax を上げるためだけの桁上げ選択などは入れない。
  - **LUT4 は 75% を上限とする。** これを超えると nextpnr が配置できない（77% と 83% で失敗）。
  - RAM16SDP4 は CFU を 1 つ使う（LUT 8 個と DFF 6 個の場所）。浅いメモリは深さ 16 にまとめる。
  - **実測（WP20）**: 全部入りのコアだけで LUT 換算 80% になり、配置できない。`FPALU=0` ならコアだけで LUT4 66%、55.8 MHz。削減案 A〜H は `mncore/status/WP-20.md` にある。
  - **単純に足すと LUT が全体の約 100% になる。** WP20 / WP21 は面積の削減を前提にする（共有化、`RND` の省略、加数の位置合わせ窓の縮小、host_if の縮小など）。
- ALU 系ユニットの共通インタフェースは `mn_alu_int` の形（valid/ready、デコード済みの `pe_aluc_*` 欄）。レイテンシは命令によって変わってよい。
- `mn_pe_lsu` / `mn_pe_treg` の `NPE` > 1 では、既存の入力 `subpe` が PE ごとの状態（T、マスクレジスタ、`$mb` / `$nb`）の番号を兼ねる（WP35）。`mn_fp_alu` はこれに `pe_aluc_iselb` を加え、`imm32` を除いたもの。
- MAB をまたぐ ALU 命令（bfn / bfe、msl / msr）は、PE p の値を `x[128*p +: 128]` に並べて受け渡す。
  - msl / msr の結果は {隣の PE の x の MSB 側の長語, 0}、フラグは 0 で、`$aluf` に入る（公式で確認）。
- 1 MAB（4 PE 時分割、WP30）の実測（27 MHz）:
  - 構成 A（FPALU=0、MAU=1）: LUT4 75%、BSRAM 33/46、48 MHz。
  - 構成 B（FPALU=3、BFN=1）: LUT4 71%、49 MHz。
  - 全部入りは yosys の換算で 105% になり、載らない。
  - L1BM と L2BM を足すと、BSRAM は 45/46 の見込み。
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
- 空間 ID: 0 IMEM、1 LM0、2 LM1、3 GRF0、4 GRF1、5 T、6 L1BM、7 L2BM、8 PDM、9 DRAM、15 TEST、0x10 OMR、0x11 BAR（`$mb` / `$nb`）。
- PE が入力として読むメモリの判定（rd_use）は WP20 の担当。WP14 の `mn_pe_rduse.v` を出発点にし、MAU / L1BM / mwrite の規則を確かめる。
- 位置の符号化: `loc = n<<10 | c<<9 | b<<6 | m<<2 | p`。
- 命令メモリのエントリ: 448bit。`[447:446]` が種類（01 = j、10 = m）、`[425:0]` が jw（m は下位 82bit）。
- BL616 の制約: 読み出しは約 70 KiB/s が上限。未受信の応答を 6300 バイト以下に保つ。PC から Ctrl-X / Ctrl-C を単独で送らない（BL616 のシェルに入り、`mnhost.py bridge reboot` が要る）。
- **FPGA から一方的に送り続けない。** PC が読んでいないのに送り続けると中継が止まる（WP05）。送るのは要求への応答か、PC が定期的に信号を送っている間だけにする。
- `uart_tx` の初期値（リセット中を含む）は 1。
- `bridge reboot` をすると FPGA は Flash の内容で読み直され、SRAM に書いたデザインは消える。再起動の後は書き込み直す。
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
- RESET で PE の状態を 0 にする（ホスト側での初期化は要らない）。
- STATUS の info の符号化（WP20）:
  - E_UNSUPPORTED は欄番号。bit7 が 1 なら m 語の欄。
  - E_DECODE は 0、0x100|種類、0x200。
  - E_RANGE は命令メモリのエントリ番号。
  - 細目の正は `PROTOCOL.md`。
- 命令メモリは 7 レーンを順に書く。
- デザイン ID: 0x02 は `mn_top_1pe`、0x03 は `mn_top_mab`（1 MAB）。
  - INFO のフラグ: bit 3..2 = FPALU、bit 4 = MAU、bit 5 = BFN。設計固有の空間（OMR、BAR）を INFO に載せる方法は未定。今の `mnhost` は「PE の空間があれば OMR もある」とみなす。
- `mnhost.py run` は ndmp を WP02（§4）と同じ単位で出す。単語アクセスは `LM0W` などの行になる。WP04 の「単語アクセスを長語 1 行で出す」は廃止。
- 実機での回帰は `python mncore/fpga/top_1pe/hwrun.py --all --fpalu <n>` で行う。
- 単語の `d get` には dtype が必須。
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

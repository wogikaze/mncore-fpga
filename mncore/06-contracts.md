# 06. 共通契約（並列作業のための取り決め）

すべての WP（作業パッケージ）は、この文書と、リポジトリ直下の `CLAUDE.md` に従う。
**変更できるのは統括（lead）だけ。** 変更が必要な WP は、報告書の「契約変更の要望」欄に書く。

## 1. 正解の優先順位

1. **公式エミュレータ `gpfn3_package_main`**（judge 同梱の v20240826）。これが最終的な正解。
2. `third_party/mncore/viz/core` の Rust Sim。公式と全問題で一致を確認済み。ユニット単位のベクタと縮小トポロジの正解はここから作る。
3. SDM（`third_party/mncore/docs/mncore_llm`）、Scrapbox [mncore/機械語](https://scrapbox.io/mncore/機械語)。
   - Scrapbox には観測にもとづくフィールドの意味が書いてある。

1 と 2 が食い違ったら作業を止め、報告書に書く。勝手にどちらかに合わせない。

## 2. 入力形式

- FPGA が受け取る機械語は **flat 形式で、パック前のもの**とする。
  `assemble3 --instruction-mode flat --disable-packer` の出力で、`j`（426bit）、`m`（82bit）、`d`（デバッグ）の行からなる。
  auto_stride（`i` 292bit）と q 形式は対象外。
- 基準のアセンブラは WSL の `~/wgkz/mncore/judge/judge-py/mncore2_emuenv/assemble3`（2024 年配布版）。
  SDK 0.9 版とは L1BM の欄（187..194）が異なる（Scrapbox 参照）。
- **フィールドの出所は `assemble3 --print-csv`。** CSV の列を順に連結すると `j`/`m` 語とビット単位で一致する（確認済み）。

### ビット番号

- 文字列の左端を pos 0 とする（Scrapbox と同じ）。
- Verilog では `input [425:0] jw` とし、**`jw[425-pos]` が pos に対応する**（MSB-first）。MV 語は `[81:0]`。
- フィールド名は CSV の名前の `.` と `/` を `_` に置き換えたもの。例: `pe.aluc.aluop` → `pe_aluc_aluop`、`l1bm.mabadr/opcode` → `l1bm_mabadr_opcode`。
- cycle1〜3 のアドレス欄には `_c1` / `_c2` / `_c3` を付ける。名前は WP01 が `spec/isa/` で確定する。

## 3. 縮小トポロジ

| パラメータ | 既定（初期） | 意味 |
| --- | --- | --- |
| `N_L2B` | 1 | L2B の数 |
| `N_L1B` | 1 | L2B あたりの L1B の数 |
| `N_MAB` | 1（P3 から 16） | L1B あたりの MAB の数 |
| `N_PE` | 4 で固定 | MAB あたりの PE の数（初期の RTL は PE 0 だけを持つ「1 PE モード」） |
| `LM_DEPTH` | 256 長語 | LM0/LM1 の容量。実機は 2048 |
| `GRF_DEPTH` | 256 長語 | GRF0/GRF1 の容量（実機と同じ） |
| `L1BM_DEPTH` / `L2BM_DEPTH` | 1024 / 4096 長語 | 実機は 8192 / 32768 |

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
L1BM n0c0 0x0010 0000000000000000
```

- 1 行に 1 長語。列は「空間名 位置 長語アドレス 値（16 桁 hex、小文字）」。
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

### 資源予算（暫定。WP07 が確定させる）

| 区分 | BSRAM ブロック数（全 46） | 備考 |
| --- | --- | --- |
| 命令メモリ | 8 | 512 語 × 448bit 程度。大きなプログラムは SDRAM から先読みする |
| PE 1 個分の状態（LM0/LM1/GRF0/GRF1/T） | 10 | 1 PE モード。4 PE 以上は WP34（仮想 PE）で SDRAM に置く |
| L1BM / L2BM のキャッシュ | 12 | |
| ボード（UART FIFO など）と予備 | 16 | |

乗算器 48 個のうち FPU に最大 24 個を割り当てる。

## 7. ホストとの通信（UART）

- BL616 経由の USB-UART。初期は 1 Mbps、8N1。WP04 が上限を測る。
- フレーム: `0xA5 | cmd u8 | len u16le | payload | crc8`
- コマンド:
  - `PING`
  - `WR_IMEM(addr, words)`
  - `WR_MEM(space, loc, addr, data)`
  - `RD_MEM(space, loc, addr, n)`
  - `RUN(start, count)`
  - `STATUS`（停止理由: `OK` / `E_RANGE` / `E_UNSUPPORTED <field>` / `E_DECODE`）
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

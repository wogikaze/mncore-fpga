# 01. 対象の分析: MN-Core 2 と Tang Nano 20K

出典:
- wogikaze/mncore `docs/mncore_llm`（SDM 全文）、`research/architecture.md`、`docs/gpu-instruction-coverage.md`
- 公式エミュレータ配布物 `judge/judge-py/mncore2_emuenv`（WSL の `~/wgkz/mncore/judge`）

## MN-Core 2 の要点（SDM 1章より）

### 階層

| 階層 | 個数 | 付属メモリ |
| --- | --- | --- |
| チップ（トップレベル） | 1 | 4 グループ × (PDM 4 MiB + DRAM 4 GiB) |
| L2B | 8（2 個で 1 グループ） | L2BM 32Ki 長語 = 256 KiB |
| L1B | 64（L2B あたり 8） | L1BM 8Ki 長語 = 64 KiB |
| MAB | 1024（L1B あたり 16） | MAU（行列演算ユニット）1 つ |
| PE | 4096（MAB あたり 4） | LM0/LM1 各 2Ki 長語（16 KiB）、GRF0/GRF1 各 256 長語（2 KiB）、T 8 長語 |

- 1 長語は 64bit。PE 側では 32bit の単語と 128bit（2 長語）のアクセスもある。
- 演算の精度は半精度 (16)、単精度 (32)、倍精度 (64) の 3 種類。長語 1 つに対して SIMD で処理する（半精度なら 4 並列）。
- 浮動小数点は**独自形式**。
  - 半精度は符号 1・指数 6・仮数 9。
  - **非正規化数と NaN がない**（正規化数、±0、±∞ のみ）。
  - 仮数部はけち表現。block float では仮数部にけち表現を使わない。
- キャッシュはなく、分岐もない。命令ストリームは 1 本だけで、**VLIW と SIMD** の組み合わせになっている。

### 機械語の形式

`assemble3` が出力する `.asm` で確認した。

| 種類 | 行頭 | 幅 | 内容 |
| --- | --- | --- | --- |
| PE 命令語 | `j` | **426 bit** | 1 ステップ（PE 側では 4 サイクル）。ALU / MAU-calc / mwrite / mread / L1BM / L2BM / wait / noforward の各グループを同時に発行する |
| MV 命令語 | `m` | **82 bit** | 上位記憶（PDM・DRAM・L2BM）の間の転送。発行すると非同期に実行され、`wait` で待ち合わせる |
| デバッグ | `d` / `r` | — | `d get` / `d set` など。エミュレータ専用（初期データの投入と結果のダンプに使える） |

- 1 つのオペランドが **4 サイクル分のアドレス**を持ち、それぞれ命令語の別々のフィールドに入っている（[04](04-encoding-probe.md) で確認）。
- 同時発行の制約（同じグループからは 1 式まで、など）は `research/architecture.md` §2 にまとまっている。
- 1 ステップの中では、全命令式の入力を読んでから書き込む（CPU 側 `Sim` の意味論）。

### 命令の量（`docs/gpu-instruction-coverage.md` より）

| 分類 | 量 |
| --- | --- |
| ALU | 32 opcode × 精度 (d/f/g/h/l/i/s) × unsigned × 入力修飾 `r`/`e` × zero-flush × 最大 8 出力 |
| MAU | ベクトル fma/mul/add/passa（D/F/G/H）、行列 MAU と mwrite/mread、block float |
| L1BM | 1/2 長語、M4 系、全 RRN（縮約）、`l1bmd` の分配と結合 |
| L2BM | Bcast/Bcast2/Distrib/Gather/FromL1b/Reduce/Reduce2/Imcast、DAR |
| MV | 25 基本モード（mvp/mvb/mvd/mvr 系）と DRAM 間接参照 |
| オペランド | 直接参照、フォワーディング（`aluf`/`mauf`/`mreadf`/`lbf`）、固定値 6 種、T 間接、`$mb`/`$nb`、マスク |

### 既存の基準モデル（`viz/core`、Rust）

主なファイルの行数は次のとおり。

| ファイル | 行数 |
| --- | ---: |
| `machine.rs` | 約 2,970 |
| `vsm.rs`（パーサ） | 約 980 |
| `blocks.rs` | 約 580 |
| `mv.rs` | 約 560 |
| `float.rs` | 約 470 |
| `hazard.rs` | 約 380 |

- 主要部分は合わせて **約 7〜8 千行**。FPGA で実装する意味論の量の目安になる。
- 公式エミュレータとの一致は、全 73 問と challenge の解で確認済み（`check-conformance.sh`）。
- 速さは公式エミュレータ（4096 PE）で **121 命令語/s**、Rust 版で 691〜1286 語/s（MNIST の学習 1 step で計測）。

## Tang Nano 20K（GW2AR-LV18QN88C8/I7）

数値はデータシートの記憶にもとづく。**P0 で公式の資料と照合すること。**

| 資源 | 量 |
| --- | --- |
| LUT4 | 20,736 |
| FF | 15,552 |
| BSRAM | 46 × 18 Kbit ≈ 828 Kbit ≈ **103 KiB** |
| SSRAM（分散 RAM） | 約 41 Kbit |
| 乗算器 | 18×18 を 48 個 |
| 内蔵 SDRAM | 64 Mbit = **8 MiB**（SDR、32bit 幅） |
| クロック | 27 MHz 発振器 + PLL |
| ホスト I/F | BL616 による USB-JTAG と USB-UART、microSD スロット |

- 手元のツールチェーン（`docs/tools.md`）: OSS CAD Suite（yosys、nextpnr-himbaechel、gowin_pack、openFPGALoader）
- iverilog、verilator_bin、gtkwave、sby が使えることを確認した。
- WSL の Ubuntu では `assemble3` と `gpfn3_package_main` が動く。

## 規模の差

| 項目 | MN-Core 2 | Tang Nano 20K | 比 |
| --- | --- | --- | --- |
| PE 内メモリ（LM/GRF/T） | 36 KiB × 4096 ≈ **144 MiB** | BSRAM 103 KiB / SDRAM 8 MiB | 約 1/18（SDRAM を全部使っても） |
| L1BM + L2BM | 4 MiB + 2 MiB | 同上 | — |
| PDM / DRAM | 16 MiB / 16 GiB | 同上 | — |
| 並列演算器 | 4096 PE + 1024 MAU | 乗算器 48 個 | — |

ここから次の結論になる。

- 全 4096 PE の状態は **SDRAM にも入らない**。microSD をスワップ先にする案は、1 語ごとに全 PE をなめる必要があるので非現実的。
- 縮小トポロジでの目安は次のとおり。
  - **1 MAB（4 PE）**: LM を縮めれば BSRAM だけで済む。LM をフルサイズにすると 4 × 36 KiB = 144 KiB で BSRAM を超える。
  - **1 L1B（64 PE）**: PE 状態 2.25 MiB + L1BM 64 KiB + L2BM 256 KiB。SDRAM に入る。
  - **2 L1B（128 PE）**: 約 4.8 MiB。SDRAM に入るが余裕は少ない。
- 速度の目安: 64 個の仮想 PE を 1 本のデータパスで順に処理すると、1 語あたり約 6 KB の SDRAM アクセスになる。
  SDRAM の実効帯域を約 200 MB/s とすると**数万語/s** で、公式エミュレータ（121 語/s）よりは十分速い。
- 命令語 426bit は 32bit × 14 ワードで読み込める。MNIST の学習 1 step（3,558 語）は約 190 KB なので、UART 1 Mbps なら約 2 秒で転送できる。

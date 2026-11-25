# fpga/multi: ビットストリームの組（WP38）

1 本のビットストリームには全ユニットが載らない（WP37: MAU を含む M2 は LUT 換算 96 %）。`mncore/tools/host/mnrun.py` は、プログラムを区間に分け、区間ごとにこの組のメンバーを FPGA の SRAM に書き、状態を引き継ぎながら実機で最後まで実行する。

## メンバー（`set.json`）

どのメンバーも `mn_top_multi.v` で、パラメータだけが違う。`build.py --member <name>` で作り、`build/<name>/top_multi.fs` を `mnrun.py` が使う。

| パラメータ | 意味 |
| --- | --- |
| `UNITS` | 2: L1BM + L2BM + MV（`mn_core` M2 = 1、WP37 の M2a と同じコア）。1: L1BM だけ（M2 = 1 で、`stub/mn_l2bm.v`・`stub/mn_mv.v` を本物の代わりに使う。`files_l1.txt`）。0: ユニットなし（M2 = 0、WP30 の 1 MAB） |
| `SDRAM` | 1: SDRAM の制御器と PDM / DRAM の空間を持つ。0: 持たない（面積。UNITS < 2 だけ）。構成の後に SDRAM を self refresh に入れ、次のメンバーまで PDM / DRAM の内容を保たせる |
| `FPALU` / `MAU` / `BFN` / `MAT` / `REPLICA` / `L1_RRN` | `mn_core` と同じ |

INFO はデザイン ID 0x05（提案）。フラグは 0x03 / 0x04 と同じ（bit 3..2 FPALU、bit 4 MAU、bit 5 BFN、bit 6 MAT、bit 7 REPLICA）。L1BM / L2BM / PDM / DRAM の空間の深さ（0 はない）で `UNITS` と `SDRAM` が分かる。`L1_RRN` は INFO に出ないので `set.json` に書く。

## `mn_top_m2`（WP37）との違い

1. **PDM / DRAM を消すのは RESET コマンドだけ**（`mn_core` の `SDCLR` = 0、消去は上位で行う）。構成（電源投入、ボタン S1）では消さない。プログラムの途中で別のメンバーを書いても、PDM / DRAM の内容は SDRAM に残る。
2. **ユニットのないメンバーも PDM / DRAM のホスト空間（0x08 / 0x09）を持つ**（`SDRAM` = 1）。コアに MV がないので、上位が `mn_mv` のホストの口と同じ検査と番地で SDRAM に橋渡しする。リフレッシュも続く。
3. `SDRAM` = 0 のメンバーは PDM / DRAM の空間を持たない。`mnrun.py` は、その区間の PDM / DRAM の d set / r / d get を、次の SDRAM のあるメンバーまで順番どおりに保留する（そのメンバーの語は PDM / DRAM に触れないので、順序は保たれる）。

## 作り方

```
python mncore/fpga/multi/build.py --member M2a          # yosys -> nextpnr -> gowin_pack
python mncore/fpga/multi/build.py --all
python mncore/fpga/multi/build.py --param UNITS=1 --param MAU=1 --tag try --no-pnr   # 面積の試算
```

資源と、どの組み合わせが載るかは `mncore/status/WP-38.md`。

## SDRAM の保持

構成の間（数秒）は SDRAM がリフレッシュされず、少しのビットが化ける（WP38 の実測: 1 回の読み込みで 12.6 Mbit のうち 3 ビット）。`mnrun.py` は PDM / DRAM の行を MV の語の直前まで保留し、0 だけのはずのときは RESET し直すので、M2 の回帰の本は切り替えをまたいで PDM / DRAM を保つ必要がない。測り方は `sdram_norefresh.py`（リフレッシュなしで置く）と `mnrun.py sdram-hold`（メンバーを経由する）。

## 試験

- `python mncore/tools/simrun.py multi` / `multi_n` / `multi_l1` / `multi_l1n` / `multi_m2`（`mncore/sim/tb/multi/`）: UART 越しに各メンバーの構成を動かす。PDM / DRAM の空間、ボタンで内容が残ること、RESET で消えること、SDRAM のない構成の self refresh、スタブ、hello_world の後半を前半の PE の状態から実行して縮小 Rust と一致すること。
- `python mncore/sim/tb/multi/lint_cfg.py`: verilator lint の 11 構成。
- `python mncore/tools/host/test_mnrun.py`: 計画と実行器（偽のボード）。

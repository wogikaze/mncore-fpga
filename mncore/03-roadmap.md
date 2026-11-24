# 03. ロードマップと作業量の見積もり

> この文書は、人手で順に進める場合の初版である。subagent で並列に進める計画は [05-schedule.md](05-schedule.md) にある。
> エンコード解析（P1）は、Scrapbox の記録と `--print-csv` があるので大幅に小さくなった。

見積もりは「集中して作業した日数」で示す。週 10〜15 時間の趣味ペースなら、おおむね 1 日 ≒ 0.5 週になる。
幅は FPGA の慣れと、詰まり具合で変わる。

| フェーズ | 内容 | 完了条件 | 見積もり |
| --- | --- | --- | --- |
| **P0 環境整備** | Rust Sim（`viz/core`）をビルドする。<br>`assemble3` と `gpfn3` を呼ぶスクリプトを用意する。<br>iverilog/Verilator のテストベンチの雛形を作る。<br>UART のエコーとローダを実機で確認する。<br>Tang Nano 20K の資源を公式資料で確認する | `.vsm` から (1) 公式の dmp、(2) Rust の dmp、(3) RTL シミュレーションの dmp を 1 コマンドで並べて比較できる | 2〜4 日 |
| **P1 エンコード解析** | `assemble3` を使った差分プローブを自動化する。<br>オペランドの種類×アドレスのビット、opcode、精度、修飾子、グループごとの有効ビットを網羅する。<br>MV 語（82bit）も同様に調べる。<br>Python で decode（426bit → 構造体 → VSM 文字列）を書く | 959 本の `.vsm` をアセンブル → デコード → 再アセンブルしたとき、全語がビット単位で一致する。フィールド表 `fields.yaml` ができている | 1〜3 週 |
| **P2 最小 HW** | ローダ、命令メモリ、シーケンサを作る。<br>PE 1 個、LM0/LM1/GRF を縮小して BSRAM に置く。<br>整数 ALU の一部（passa / inc / add / 論理演算 / シフト / imm）と、固定値オペランド（`$peid` など）を実装する。<br>`d get` 相当のダンプを UART で返す | `hello_world` と Welcome 問題の公式 `.asm` が実機で動き、dmp が一致する | 1〜2 週 |
| **P3 PE の整数部分を完成** | 全 32 opcode、精度 d/f/h/l/i/s、unsigned、`r`/`e`、zero-flush、複数出力を実装する。<br>T レジスタと T 間接、`$mb`/`$nb`、マスク、`aluf` のフォワーディング、nop/wait/noforward も入れる。<br>1 MAB（4 PE）に広げる | `gpu_alu_conformance` 相当の 142 設定が一致し、整数だけを使う challenge 解が通る | 3〜5 週 |
| **P4 浮動小数点** | MN-Core 形式（けち表現、非正規化数と NaN なし）の加算・乗算・FMA を実装する。<br>ベクトル MAU（D/F/G/H）、変換（ftoi、itof、ffloor など）、丸めモード、`mauf` も入れる | `float.rs` と照合したランダムベクタ数万件と、`gpu_mau_conformance` のベクトル部分が一致する | 3〜6 週 |
| **P5 階層とメモリ** | L1BM（`l1bmd` の分配と結合、RRN 縮約、`lbf`）と L2BM（Bcast/Gather/Reduce など）を実装する。<br>Rust Sim を縮小トポロジに対応させる。<br>SDRAM コントローラを入れ、仮想 PE（64 PE）に移行する | `gpu_l1_conformance` と L2BM 系が縮小トポロジで一致する | 4〜8 週 |
| **P6 MV、行列、残り** | PDM/DRAM（SDRAM 内）と MV の 25 モード、DAR を実装する。<br>行列 MAU、mwrite/mread、block float も入れる | `gpu_mem_conformance` と matrix の一致。`difftest_prog` の全問題のうち、縮小トポロジで意味のあるものが通る | 4〜8 週 |
| **P7 実プログラム** | FizzBuzz の解答と MNIST の推論（縮小版）を動かす。<br>デモとして LED や UART に出力する。速度を改善する | 公式 `.asm` の FizzBuzz が、縮小トポロジでの期待値どおりに出力される | 2〜4 週 |

### 累計の目安

| 到達点 | フェーズ | 集中作業日数 | 趣味ペース |
| --- | --- | --- | --- |
| 公式の機械語で最初のデモ | P0〜P2 | 約 15〜25 日 | 1〜1.5 か月 |
| 整数系の問題が動く（4 PE） | 〜P3 | 約 30〜50 日 | 2〜3 か月 |
| FP を含む PE ローカルの問題 | 〜P4 | 約 50〜80 日 | 4〜5 か月 |
| ISA をほぼ全部（縮小トポロジ） | 〜P6 | 約 90〜150 日 | 6〜12 か月 |

## 検証の方法

```
.vsm ──assemble3──▶ .asm ──┬──▶ gpfn3_package_main ──▶ ref.dmp   (4096 PE、公式)
                           ├──▶ viz/core Sim        ──▶ rust.dmp  (縮小トポロジ対応後は縮小版も)
                           ├──▶ iverilog/Verilator  ──▶ rtl.dmp   (同じ RTL を回す)
                           └──▶ UART → Tang Nano 20K ──▶ fpga.dmp
                                         diff (対象 PE だけ / 縮小トポロジ)
```

- テストの素材は wogikaze/mncore にすでにあるものを使う。
  - `viz/core/src/bin/gpu_*_conformance.rs`（VSM を生成する部分を流用する）
  - `problems/` の 73 問、`solutions/`
  - `proofs_lean/evidence/*`
- RTL の単体テスト: FP ユニットと ALU は、Rust の関数から生成したベクタで iverilog の自己検査テストベンチを回す。
- 回帰テスト: 1 コマンドで「全 `.vsm` × RTL シミュレーション」を回す。実機は代表ケースだけ。

## リポジトリ構成（案）

```
nano20k/
  mncore/
    README.md 01..04-*.md      ← この調査
    tools/                     ← probe、エンコード解析、dmp 比較（Python/bash）
    spec/fields.yaml           ← P1 の成果物
    rtl/                       ← Verilog（decoder, seq, pe, fpu, l1bm, l2bm, mv, uart, sdram）
    sim/                       ← テストベンチ、ベクタ
    fpga/                      ← cst、build.bat（init/ を雛形に）
```

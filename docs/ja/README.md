# mncore-fpga（日本語版）

**MN-Core 2** の機械語を **Sipeed Tang Nano 20K**（Gowin GW2AR-LV18）で実行する。入力は、公式アセンブラ `assemble3` が出力する flat 形式の機械語（PE 命令語 `j` 426bit、MV 命令語 `m` 82bit）。FPGA は MN-Core 2 の縮小トポロジを実装し、結果を公式エミュレータ `gpfn3_package_main` と比べる。

English: [README.md](../../README.md)

これは非公式のプロジェクトである。公式のアセンブラとエミュレータは同梱していない（[必要なもの](#必要なもの)を参照）。

## 何ができて、何ができないか

- ホストの PC が、`assemble3 --instruction-mode flat --disable-packer` の出力を UART で送る。FPGA は命令語を命令メモリに置いて実行する。
  - `d set` / `d get` / `r` 行は、ホスト側でメモリの読み書きに変換する。
- **チップ全体は載らない。** MN-Core 2 は 4096 PE あり、PE 内のメモリだけで約 144 MiB ある（[`mncore/01-target-analysis.md`](../../mncore/01-target-analysis.md)）。FPGA には次の縮小トポロジを実装した（チップの値は同じファイル、FPGA の値は [WP-37](../../mncore/status/WP-37.md) と [WP-33](../../mncore/status/WP-33.md) による）。

  | | MN-Core 2 | この FPGA（M2） |
  | --- | --- | --- |
  | グループ / L2B / L1B / MAB / PE | 4 / 8 / 64 / 1024 / 4096 | 1 / 1 / 1 / 1 / 4（4 PE は 1 組のデータパスを時分割で使う） |
  | PE あたりの LM0 / LM1 | 2048 長語 | 256 長語 |
  | PE あたりの GRF0 / GRF1、T | 256 長語、8 | 同じ |
  | L1BM / L2BM | 8192 / 32768 長語 | 1024 / 2048 長語 |
  | PDM / DRAM（パッケージ内の SDRAM） | グループあたり 4 MiB / 4 GiB | 1 MiB / 4 MiB、グループ 0 だけ |

  - 実装した PE は `n0c0b0m0p0`〜`p3`。`$peid` などの ID のオペランドは、チップ上の座標の値を返す。
  - 縮小した容量の外にアクセスしたら、`E_RANGE` で止まる。黙って折り返すことはしない。
- **存在しないユニットの扱い**（ほかの 15 MAB、7 L1B など）は、ビットストリームを作るときに次の 2 つから選ぶ。
  - **ゼロ規則**（既定）: 存在しないユニットへの転送は捨て、そこから受け取る縮約・結合の入力は 0 とする。正解は、同じ縮小トポロジで実行した Rust Sim。
  - **複製規則**（`REPLICA=1`）: 存在しない MAB / L1B を、実装したユニットの複製とみなす。全ユニットが同じデータを持つ SPMD 的なプログラムでは、4096 PE の公式の結果と一致する。
  - データの移動が実装したユニットの中で閉じるプログラムは、どちらの規則でも公式と一致する。
- **全ユニットは 1 本のビットストリームに載らない**（LUT4 の実用上の上限は 75 %。[WP-21](../../mncore/status/WP-21.md)）。そこで**機能別のビットストリーム**を作る。たとえば、ベクトル MAU を持つものと、L1BM + L2BM + MV を持つもの。
  - 両方を使うプログラムは途中で分け、ホストが PE の状態を次のビットストリームに引き継いで実行する。
  - 今は手動の切り替えである（`hello_hw.py`）。
- **対象外のもの**:
  - auto_stride（`i` 語）とパック済みの形式。
  - 倍精度の行列 MAU（`dmfma` / `dmmul`）は実装していない。
  - 半精度の拡張表現の行列積の丸めは近似である（[divergences.md](../divergences.md)）。

設計の詳細は [architecture.md](architecture.md)（日本語）、ISA のまとめは [isa-notes.md](../isa-notes.md)（英語）、公式エミュレータと Rust Sim の食い違いは [divergences.md](../divergences.md)（英語）にある。

## 現状

マイルストーン **M2**（2026-11-25）の時点の状態。

**数字は英語版の [Results](../../README.md#results) の 1 か所にまとめている**（各行に出典の報告書を付けた）。ここでは要点だけを書く。

- **M1**: 1 PE の構成を実機で動かした。最後まで実行した本は、比べた範囲（PE の全状態）で公式エミュレータと一致した。
  - 一致しない本は、ビットストリームに入っていない演算器の命令で `E_UNSUPPORTED` になり、RTL シミュレーションと同じ語で止まる。
  - 値が食い違った本はない。
- **4 PE（1 MAB の時分割）と行列ユニット**: 機能別のビットストリームで実機で動かした。どれも全本が RTL シミュレーションと同じ結果で、値の食い違いは 0。
- **M2**（1 MAB + L1BM + L2BM + MV、PDM / DRAM は SDRAM）: 実機で回帰の全本が RTL シミュレーションと同じ結果で、値の食い違いは 0。
  - 比べた本は、公式エミュレータ（データの移動が閉じる本）か、縮小トポロジの Rust Sim（ゼロ規則）と一致した。
- **hello_world**: 公式の問題はベクトル MAU と L1BM / L2BM / MV の両方を使う。そのため 2 本のビットストリームに分け、ホストが状態を引き継いで実機で実行した。
  - 複製規則では、DRAM に "Hello, world!" が出て、比べた全長語が公式と一致した。
  - ゼロ規則では、縮小トポロジの Rust Sim と全長語が一致した（公式は 16 MAB と 8 L1B の同じ値を足すので、値が違う）。
  - MAU を使わない版は、M2 のビットストリーム 1 本で "Hello, world!" を出せる。
- **制約**:
  - LM が 256 長語なので、FizzBuzz の解答を含む一部の本は `E_RANGE` で止まる。
  - MAU を含む M2 は面積が足りず、1 本に載らない。
  - M2 では SDRAM を 54 MHz で動かしている。
- **作業中**（この文書を書いた時点）: 仮想 PE（LM 2048 長語、最大 64 PE、WP34）と、ビットストリームの自動切り替え（WP38）。

「一致」は、比べた長語がすべて同じという意味である。比べるのは、実装した PE の最終状態（プローブ）、M2 ではさらに L1BM / L2BM / DRAM、そしてプログラム自身の `d get` の出力。公式エミュレータは常に 4096 PE で実行し、実装したユニットの分を切り出して比べる。PDM は比べない（公式の `d get $p` は DRAM を出すため）。

## 必要なもの

- **ボード**: Sipeed Tang Nano 20K（GW2AR-LV18QN88C8/I7、family GW2A-18C）を USB でつなぐ。UART はボード上の BL616（FTDI 互換、VID:PID 0403:6010）を通る。
- **FPGA ツール**: [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)（yosys、nextpnr-himbaechel、gowin_pack、openFPGALoader、iverilog、verilator）。Windows 11 で 2026-11-23 版を使って開発した。
- **Python**: 3.13 で開発した。パッケージは [`mncore/requirements.txt`](../../mncore/requirements.txt)（`pyyaml`、`pyserial`）。
- **Rust**（`cargo`）: Rust Sim をリンクする正解の出力器（`mncore/golden_rs`、`mncore/sim/regress/topo_rs`）と、ベクタの生成器（`mncore/vecgen`）に使う。
- **公式ツール**: `assemble3` と `gpfn3_package_main`（2024 年配布版、judge v20240826）。
  - **このリポジトリには含まれない。** MN-Core Challenge の配布物から入手する。
  - スクリプトは WSL（Ubuntu）の中で呼び出し、`~/wgkz/mncore/judge/judge-py/mncore2_emuenv` にあるものとして扱う。golden のツールでは、`MNCORE_EMU_DIR_WSL` と `MNCORE_WSL_DISTRO` で場所を変えられる。
  - 正解の結果と `.asm` の入力を作るのに使う。ビットストリームの作成と書き込みには要らない。
- **submodule**: `third_party/mncore`（[wogikaze/mncore](https://github.com/wogikaze/mncore)、ブランチ `topo-param`）。Rust Sim（`viz/core`）、SDM の本文（`docs/mncore_llm`）、プログラムのコーパスがある。

## 試し方

リポジトリの直下で実行する。スクリプトは Python で、makefile はない。

```sh
git submodule update --init third_party/mncore
python -m pip install -r mncore/requirements.txt
```

**シミュレーションだけ**（ボードも公式ツールも要らない。期待値はコミット済みの台本に入っている）:

```sh
python mncore/tools/simrun.py core   # 1 PE、直接試験 27 本
python mncore/tools/simrun.py mab    # 1 MAB（4 PE）
python mncore/tools/simrun.py m2     # M2 のコア（L1BM、L2BM、MV、SDRAM の振る舞いモデル）
```

**ビットストリームを作って書き込む。** `--program` は FPGA の SRAM にだけ書く（電源を切ると消える。Flash には書かない）。配置配線は、開発中は 1 回 20〜60 分ほどかかった。

```sh
python mncore/fpga/top_m2/build.py --tag M2a --program                      # M2a、ゼロ規則
python mncore/fpga/top_m2/build.py --tag M2aR --param REPLICA=1 --program   # M2a-R、複製規則
python mncore/fpga/top_mab/build.py --tag A                                  # MAU を持つ 1 MAB（ビットストリーム A）
python mncore/tools/host/mnhost.py info                                      # デザイン ID、トポロジ、載っているユニット
```

出力は `mncore/fpga/<design>/build/<tag>/<design>.fs`。作ってあるビットストリームは `python mncore/fpga/top_m2/build.py --fs <file.fs>` で書き込める。

**プログラムを実機で動かす。** 先に正解を作るので、WSL の公式ツールが要る。

```sh
# M2 の本: 公式エミュレータ、縮小トポロジの Rust Sim、RTL シミュレーション
python mncore/sim/regress/run.py --m2
# 任意: ボードと同じユニットの RTL シミュレーション（M2a）。「RTL と同じか」の比較に使う
python mncore/sim/regress/run.py --m2 --define TB_FPALU=0 --define TB_MAU=0 --define TB_BFN=0
# 同じ本を実機で
python mncore/fpga/top_m2/hwrun.py --all --no-lock-check

# M1（1 PE のビットストリーム、mncore/fpga/top_1pe）
python mncore/sim/regress/run.py
python mncore/fpga/top_1pe/hwrun.py --all --fpalu 3 --no-lock-check

# hello_world を 2 本のビットストリームで（PE の状態はホストが引き継ぐ）
python mncore/fpga/top_m2/hello_hw.py --mau-fs mncore/fpga/top_mab/build/A/top_mab.fs \
    --m2-fs mncore/fpga/top_m2/build/M2aR/top_m2.fs --no-lock-check
```

`mnhost.py run X.asm -o X.ndmp` は、1 本の `.asm`（`mncore/tools/golden/run_official.py` が作るエミュレータへの入力全体）を実行して、正規化したダンプを書く。2 つのダンプは `mncore/tools/golden/ndiff.py` で比べる。

注意:

- 実機を使うスクリプトは、開発中に使っていたボードのロックファイル（`C:\wgkz\nano20k\mncore\.board.lock`）があるかを確かめる。その環境の外では `--no-lock-check` を付ける。
- COM ポートに Ctrl-X や Ctrl-C を単独で送らない。BL616 が自分のシェルに入り、FPGA からの出力を中継しなくなる。
  - `python mncore/tools/host/mnhost.py bridge reboot` で戻る。
  - この再起動で FPGA は Flash の内容で読み直されるので、ビットストリームを書き込み直す（[WP-04](../../mncore/status/WP-04.md)、[`mncore/rtl/board/PROTOCOL.md`](../../mncore/rtl/board/PROTOCOL.md)）。
- Windows で `core.autocrlf=true` だと、submodule の `.vsm` が CRLF で展開され、`assemble3` が受け付けない。スクリプトは CR を除いてから渡す。

## ディレクトリ

| パス | 内容 |
| --- | --- |
| `mncore/spec/isa/` | `j` 語と `m` 語の欄の定義（`j_flat.yaml`、`m.yaml`）と、未確定の点（`UNKNOWN.md`） |
| `mncore/rtl/` | Verilog-2005 の RTL。`board`（UART、ホストのプロトコル）、`dec`（生成したデコーダ）、`alu`、`fpu`、`pe`、`mab`、`core`、`l1bm`、`l2bm`、`mv`、`sdram`、`top` |
| `mncore/fpga/` | ボードのデザイン（`top_1pe`、`top_mab`、`top_m2`）、試験用のデザイン、RAM / DSP のレシピ、配置配線と実機のログ |
| `mncore/sim/` | テストベンチ（`tb/<unit>/`）、固定のテストベクタ、コーパスの回帰（`regress/`） |
| `mncore/tools/` | `simrun.py`（シミュレーション、lint、合成）、`mnisa`（Python のデコーダ）、`golden`（正解の実行とダンプの比較）、`host/mnhost.py`（ホストツール） |
| `mncore/vecgen/`、`mncore/golden_rs/` | Rust。テストベクタの生成器と正解の出力器（submodule の Rust Sim を使う） |
| `mncore/status/` | 各作業パッケージの報告書。上の数字の出典 |
| `mncore/*.md`、`mncore/wp/` | 計画、工程表、共通契約、作業パッケージの指示書 |
| `docs/` | この文書群（`docs/ja/` は日本語版） |

## ライセンスと謝辞

このリポジトリのコードと文書は MIT ライセンス（[LICENSE](../../LICENSE)）。submodule の `third_party/mncore` は別のリポジトリである。

次のものを土台にしている。

- Preferred Networks: MN-Core 2、そのソフトウェア開発者マニュアル（SDM）、MN-Core Challenge の配布物に含まれる公式のアセンブラとエミュレータ。
  - ここでのすべての結果は、このエミュレータを最終的な正解としている。
  - バイナリは再配布しない。
- [wogikaze/mncore](https://github.com/wogikaze/mncore): Rust の基準シミュレータ（`viz/core`）、SDM の本文（`docs/mncore_llm`）、プログラムのコーパス。
- Scrapbox [mncore/機械語](https://scrapbox.io/mncore/機械語): 機械語の欄の配置の観測。
- [nand2mario/sdram-tang-nano-20k](https://github.com/nand2mario/sdram-tang-nano-20k)（Apache-2.0）: 内蔵 SDRAM の構成、ポート名、クロックの位相の参考にした。コードは取り込んでいない（[`mncore/rtl/sdram/README.md`](../../mncore/rtl/sdram/README.md)）。
- [YosysHQ/apicula](https://github.com/YosysHQ/apicula)（MIT）: GW2AR-18 の SDRAM の端子の一覧と、rPLL / IOB の設定の参考にした。
- YosysHQ の OSS CAD Suite: FPGA の流れ全体に使った。
- [sipeed/TangNano-20K-example](https://github.com/sipeed/TangNano-20K-example): UART のピン割り当て（[`mncore/fpga/board_test/README.md`](../../mncore/fpga/board_test/README.md)）。
- Gowin のデータシートとユーザーガイド（DS226、DS102、UG285、UG286、UG287）と、Sipeed の Tang Nano 20K の wiki: デバイスの資源（[`mncore/07-device-budget.md`](../../mncore/07-device-budget.md)）。

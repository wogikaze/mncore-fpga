# demo: hello_world と FizzBuzz を Tang Nano 20K で動かす（WP41）

MN-Core 2 の公式アセンブラ `assemble3` が出力した機械語（flat 形式の `j` / `m` 語）を、Tang Nano 20K の FPGA で実行し、結果を端末に表示する。どちらのスクリプトも 1 コマンドで、プログラムの用意、ビットストリームの用意（なければビルド）、FPGA への書き込み（SRAM だけ）、実行、表示、公式エミュレータとの照合までを行う。

| スクリプト | 何をするか | 使うビットストリーム |
| --- | --- | --- |
| `hello.py` | 公式の `problems/challenge/21.hello-world` を実行し、DRAM の先頭 13 バイトを文字列として表示する | `fpga/multi` の MAU → M2aR（途中で切り替え） |
| `fizzbuzz.py` | `problems/challenge/23.fizzbuzz-pe`（各 PE の LM0 の数を FizzBuzz に置き換えて LM1 に書く）を実行し、LM1 を FizzBuzz の文字列として表示する | `fpga/multi` の L1MAU（4 PE） |
| `fizzbuzz.py --program int` | 同じ問題を整数 ALU だけで解くこのデモ用の解答（`programs/fizzbuzz_int.vsm`）を 64 PE で実行する | `fpga/top_vpe` の V64（仮想 PE、64 PE） |

### 実機での結果（2026-11-26、ログは `logs/`）

| コマンド | 実機の出力 | 照合 | 時間（全体 / うちボード） |
| --- | --- | --- | --- |
| `hello.py` | DRAM n0 = `48656c6c6f2c2077 6f726c64212afe00` = **"Hello, world!"** | 公式エミュレータと 2/2 長語が一致 | 9.2 s / 7.7 s |
| `hello.py --no-official` | 同上 | 記録した公式の出力と一致 | 7.8 s / 7.7 s |
| `hello.py --rule zero` | `3a655e6c612c1277 61725e64132af362`（":e^la,.war^d."） | 縮小トポロジの Rust Sim（WP37 / WP38）と一致。公式とは違う（規則どおり） | 9.9 s / 8.0 s |
| `fizzbuzz.py` | 1〜32 の FizzBuzz（4 PE） | 公式 16/16 長語、Python 32/32 個 | 8.3 s / 4.1 s |
| `fizzbuzz.py --input testcase` | テストケースの 32 個（4 PE） | 公式 16/16、Python 32/32 | 8.2 s / 4.0 s |
| `fizzbuzz.py --no-official` | 1〜32 | 記録した公式の出力 16/16、Python 32/32 | 5.6 s / 4.1 s |
| `fizzbuzz.py --program int` | **1〜512 の FizzBuzz（64 PE）** | 公式 256/256 長語、Python 512/512 個 | 15.1 s / 11.8 s |
| `fizzbuzz.py --program int --input testcase` | テストケースの 512 個（64 PE） | 公式 256/256、Python 512/512 | 9.8 s / 6.8 s |
| `fizzbuzz.py --program int --no-official` | 1〜512 | 記録した公式の出力 256/256、Python 512/512 | 7.4 s / 6.8 s |

公式エミュレータは 4096 PE で実行し、実機にある PE（4 PE または 64 PE）と DRAM n0 の分だけを比べる。

## 必要なもの

- **Tang Nano 20K**（GW2AR-LV18）を USB でつなぐ。JTAG（`openFPGALoader -b tangnano20k`）と UART（BL616 の USB シリアル。既定は自動検出、`--port COM6` などで指定）を使う。
  - ビットストリームは **SRAM にだけ** 書く（`-f` を付けない）。電源を切るか BL616 を再起動すると Flash のデザインに戻る。
- **OSS CAD Suite**（yosys、nextpnr-himbaechel、gowin_pack、openFPGALoader）。`PATH` にない場合は `%LOCALAPPDATA%\Programs\oss-cad-suite` を探す（`docs/tools.md`）。
- **Python 3.13** と `mncore/requirements.txt`（pyserial、pyyaml）。
- **submodule** `third_party/mncore`（問題の .vsm とテストケース）。
- **公式ツール（任意）**: WSL の Ubuntu の `~/wgkz/mncore/judge/judge-py/mncore2_emuenv/` にある `assemble3` と `gpfn3_package_main`。**正解の表示（照合）とアセンブルにだけ使う。** 場所は環境変数 `MNCORE_EMU_DIR_WSL`、ディストリビューションは `MNCORE_WSL_DISTRO` で変えられる。
  - 公式ツールがなければ（または `--no-official`）、`programs/*.main.asm`（公式アセンブラの出力をコミットしたもの）をテストケースの `d` 行と組み合わせて実行し、`programs/*.official.ndmp`（公式エミュレータの出力を記録したもの）と照合する。公式のバイナリそのものは含まない。

## 手順

きれいな環境から（PowerShell の例）:

```powershell
git clone <このリポジトリ> nano20k
cd nano20k
git submodule update --init third_party/mncore
py -3.13 -m venv .venv
.venv\Scripts\python.exe -m pip install -r mncore\requirements.txt   # uv なら: uv pip install --python .venv\Scripts\python.exe -r mncore\requirements.txt

.venv\Scripts\python.exe mncore\demo\hello.py
.venv\Scripts\python.exe mncore\demo\fizzbuzz.py
.venv\Scripts\python.exe mncore\demo\fizzbuzz.py --program int
```

- **ビットストリームがなければ、スクリプトが自動でビルドする**（足りないものを並列に。ビルドの出力は `demo/build/build_<名前>.log`）。ビルド済みのビットストリームは git に入っていない（`build/` は .gitignore）。先に作っておくなら:

  ```powershell
  .venv\Scripts\python.exe mncore\fpga\multi\build.py --member MAU   --seeds 1,2,3     # hello
  .venv\Scripts\python.exe mncore\fpga\multi\build.py --member M2aR  --seeds 3,2,1,4   # hello（種によっては 27 MHz に届かない。下の「所要時間」）
  .venv\Scripts\python.exe mncore\fpga\multi\build.py --member L1MAU --seeds 1,2,3     # fizzbuzz
  .venv\Scripts\python.exe mncore\fpga\top_vpe\build.py --tag V64   --seeds 1,2,3     # fizzbuzz --program int
  ```

  できるのは `mncore/fpga/multi/build/<名前>/top_multi.fs` と `mncore/fpga/top_vpe/build/V64/top_vpe.fs`。`--dry-run` で、どのビットストリームが要り、あるかどうかだけを表示する。`--no-build` ではビルドせずに止まる。
- 主なオプション（両スクリプト共通）: `--no-official`（公式ツールを使わない）、`--port COM6`、`--log FILE`（表示をファイルにも書く）、`--dry-run`、`--reuse`（FPGA に入っているデザインが最初の区間のものなら書き込みを省く）、`-v`（区間ごとの経過）。
  - `hello.py --rule zero`: 存在しないユニットを 0 とみなす規則（下の「しくみ」）。文字列は "Hello, world!" にならない（公式エミュレータとは縮約の分だけ違う）。M2a のビットストリームが要る。
  - `fizzbuzz.py --input testcase`: 1, 2, 3, ... の代わりに問題のテストケース（乱数）を使う。
- 終わると、最後に書いたデザイン（M2aR、M2a、L1MAU、V64 のどれか）が FPGA に残る。どれも LED 0 だけを暗く点ける（契約 §7 の LED の方針）。
- このリポジトリのボードを複数の作業で共有しているときは、スクリプトが `C:\wgkz\nano20k\mncore\.board.lock` を取り、終わったら消す（契約 §9）。ほかの作業のロック（2 時間以内）があれば止まる。そのディレクトリがない環境ではロックしない。

## 所要時間

**実行（ビットストリームがあるとき）: 1 回 5〜15 秒。**

| 段階 | 時間 | 備考 |
| --- | --- | --- |
| 公式ツール（WSL の assemble3 と gpfn3_package_main、4096 PE） | 1〜3 s | `--no-official` なら 0 |
| ビットストリームの書き込み（openFPGALoader、SRAM） | 1 本 3.3〜3.6 s（PC の負荷で 8 s 以上） | hello は 2 本、fizzbuzz は 1 本。`--reuse` で省ける |
| 状態の引き継ぎ（hello: PE 4 つの GRF / LM / T / マスクを読んで書き戻す） | 0.6 s | |
| 実行と `d set` / `d get` | 0.05〜0.4 s（4 PE）、3.2 s（64 PE） | 64 PE は 256 回の書き込みと 256 回の読み出しが大半。計算そのものは 64 PE で 27 語、数 ms |

**ビットストリームのビルド: 1 本 15〜120 分。** yosys は 1〜1.5 分、残りは nextpnr。今回（5 本を並列に、ほかの作業の配置配線とも並行）は、V64 84 分、M2a 94 分、L1MAU 108 分、MAU 114 分だった。負荷が軽いときは 1 本 15〜25 分（今回の M2aR の種 1 は 14.5 分、種 3 は 21 分）。

- **M2aR は上限ぎりぎり**（LUT4 75 %）。今の RTL では種 1、2、4、5 がコア 26.1〜26.7 MHz で 27 MHz に届かず、**種 3 が 28.15 MHz で通った**。`build.py` は種を順に試すので、届かない種が続くと時間がかかる。demo の自動ビルドは種 3 から試す。
- 種ごとに別の `--tag` で並列に回し、通ったものを `build/M2aR/top_multi.fs` に置いてもよい（`--tag` を付けると `build/<tag>/` にできる）。

## 出力の例

`hello.py -v`（`logs/hello.log`）:

```text
== hello_world on the Tang Nano 20K (2026-11-26 02:54:54) ==
program   third_party/mncore/problems/challenge/21.hello-world/main.vsm with its testcase
          9 words (assemble3 flat, no packer); reference: official emulator gpfn3_package_main (WSL) (1.2 s)
          assemble3 + gpfn3_package_main: 1.0 s
plan      rule replica: words 0-3 on MAU (MAU+MAUF+SDRAM), words 4-8 on M2aR (L1+L1R+L2+MV+SDRAM)
          bitstream MAU    mncore/fpga/multi/build/MAU/top_multi.fs (built 2026-11-26 02:41)
          bitstream M2aR   mncore/fpga/multi/build/M2aR/top_multi.fs (built 2026-11-26 02:54)
#   loaded MAU in 3.30 s
#   segment 0: words 0..3 on MAU
#   loaded M2aR in 3.49 s
#   segment 1: words 4..8 on M2aR
board     words 0-3 on MAU, words 4-8 on M2aR
          7.7 s on the board: 2 bitstream load(s) 6.8 s, state hand-over 0.63 s, RUN / d lines 0.05 s (9 steps, 2 RUNs)

  DRAM n0 [0..1]  48656c6c6f2c2077 6f726c64212afe00
  first 13 bytes as text:  "Hello, world!"

official  DRAM n0 [0..1]  48656c6c6f2c2077 6f726c64212afe00  "Hello, world!"
          the board equals the official emulator (2 of 2 long words)
total     9.2 s
RESULT: PASS ("Hello, world!", as the official emulator)
```

`fizzbuzz.py`（`logs/fizzbuzz_pe_seq.log`）:

```text
== FizzBuzz (23.fizzbuzz-pe) on the Tang Nano 20K (2026-11-26 02:35:20) ==
program   third_party/mncore/problems/challenge/23.fizzbuzz-pe/main.vsm, input: the numbers 1..32768 (8 per PE)
          9 words (assemble3 flat, no packer); reference: official emulator gpfn3_package_main (WSL) (2.6 s)
          assemble3 + gpfn3_package_main: 2.3 s
plan      words 0-8 on L1MAU (L1+MAU+MAUF)
          bitstream L1MAU  mncore/fpga/multi/build/L1MAU/top_multi.fs (built 2026-11-26 02:35)
board     words 0-8 on L1MAU
          4.1 s on the board: 1 bitstream load(s) 3.5 s, state hand-over 0.00 s, RUN / d lines 0.44 s (9 steps, 1 RUNs)

  FizzBuzz 1..32 from the LM1 of the 4 PEs (n0c0b0m0p0..n0c0b0m0p3):
    1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz 16 17 Fizz 19 Buzz Fizz 22 23 Fizz
    Buzz 26 Fizz 28 29 FizzBuzz 31 32

Python    FizzBuzz of the inputs: 32 of 32 numbers as the board
official  official emulator gpfn3_package_main (WSL): the board equals it (16 of 16 long words of LM1)
total     8.3 s
RESULT: PASS (32 numbers on 4 PEs, as the official emulator and Python)
```

`fizzbuzz.py --program int`（`logs/fizzbuzz_int_seq.log`、途中を略す）:

```text
plan      words 0-26 on V64 (mncore/fpga/top_vpe: 16 MABs = 64 PEs in the SDRAM, integer ALU, design 0x06)
board     words 0-26 on V64
          11.8 s on the board: 1 bitstream load(s) 8.3 s, state hand-over 0.00 s, RUN / d lines 3.23 s (27 steps, 1 RUNs)

  FizzBuzz 1..512 from the LM1 of the 64 PEs (n0c0b0m0p0..n0c0b0m15p3):
    1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz 16 17 Fizz 19 Buzz Fizz 22 23 Fizz
    ...
    FizzBuzz 496 497 Fizz 499 Buzz Fizz 502 503 Fizz Buzz 506 Fizz 508 509 FizzBuzz 511 512

Python    FizzBuzz of the inputs: 512 of 512 numbers as the board
official  official emulator gpfn3_package_main (WSL): the board equals it (256 of 256 long words of LM1)
total     15.1 s
RESULT: PASS (512 numbers on 64 PEs, as the official emulator and Python)
```

終了コード: 0 PASS、1 不一致またはエラー（ビルドの失敗、ほかの作業のロックなど）、2 ボードが停止（E_RANGE など）、3 ボードが見つからない（保留）。

## しくみ

### 縮小トポロジ

MN-Core 2 は 4096 PE（4 グループ × 2 L2B × 8 L1B × 16 MAB × 4 PE）を持つが、Tang Nano 20K に載るのはその一部だけである。

- `fpga/multi` のデザインは 1 MAB（4 PE）。`fpga/top_vpe` の V64 は 16 MAB（64 PE）で、PE の状態を SDRAM に置き、1 組のデータパスで MAB を順に実行する（WP34）。
- 載らない PE、MAB、L1B の扱いは 2 通りある（契約 §3）。
  - ゼロ規則: 存在しないユニットの値を 0 とする。
  - 複製規則: 存在しないユニットを、実装したユニットの複製とみなす。

hello_world は 4096 PE の DRAM に L1BM / L2BM の縮約で文字を集める。複製規則なら、公式エミュレータと同じ "Hello, world!" が DRAM に出る。FizzBuzz は PE ごとに閉じた計算なので、どちらの規則でも、実装した PE の LM1 が公式エミュレータの同じ PE と一致する。

### ビットストリームの切り替え（`mncore/tools/host/mnrun.py`、WP38）

1 本のビットストリームには全ユニット（ベクトル MAU、L1BM、L2BM、MV など）が載らない。`mnrun.py` は、語ごとに要るユニットを機械語の欄から求め、プログラムを区間に分ける（`mnplan.py`）。区間ごとに、組（`fpga/multi/set.json`）のメンバーを FPGA の SRAM に書き、PE の状態をホストが引き継ぐ。

- hello_world（9 語）: 語 0〜3 がベクトル MAU（`dvpassar`、`fvadd`）、語 4〜8 が L1BM / L2BM の縮約と DRAM への MV。MAU で前半を実行し、PE 4 つの GRF / LM / T / マスクレジスタを読み出して M2aR に書き戻し、後半を実行する。
- 23.fizzbuzz-pe（9 語）: MAU と L1BM を同じ語で使うので、両方を持つ L1MAU 1 本で実行する。
- デモは `mnrun.py run` と同じ `ProgramRun` を import して使う。`mnrun.py` を直接使うなら: `python mncore/tools/host/mnrun.py --rule replica run mncore/demo/build/hello/official.asm`。

### 整数だけの FizzBuzz（`programs/fizzbuzz_int.vsm`）

V64 は整数 ALU だけを持つ（MAU も L1BM もない。面積のため）。公式の解答は MAU と L1BM を使うので、整数 ALU だけで同じ問題を解く 27 語の解答を書いた。

- 16 ≡ 1 (mod 15) なので、16 進の桁の和は 15 で割った余りを保つ。n ≤ 2^15 では 3 回畳むと 1〜17 になる。
- その値で、表（3 の倍数、5 の倍数、15 の倍数に当たるビットだけ 0 の定数）を右シフトし、最下位ビットが 0 ならマスクレジスタに 1 を書く（`iand` の「出力がすべて 0 なら 1」）。
- LM0 を LM1 に写してから、マスク付きの `imm` で Buzz、Fizz、FizzBuzz の順に上書きする。

公式エミュレータで、1〜32768 と問題のテストケースの両方（各 32,768 個）が Python の FizzBuzz と一致することを確かめた。

## ファイル

| パス | 内容 |
| --- | --- |
| `hello.py`、`fizzbuzz.py` | デモの本体 |
| `demolib.py` | 共通部分（プログラムの用意と公式エミュレータ、ビットストリームの用意、ボードのロック、`mnrun` / `mnhost` での実行、照合） |
| `programs/*.main.asm` | 公式アセンブラ（flat、パッカーなし）の出力。公式ツールがないときに使う。`--update` で作り直す |
| `programs/*.official.ndmp` | 公式エミュレータの出力（テストケースの `d get`。チップの n0c0b0 の範囲と n0 だけ）。公式ツールがないときの照合に使う |
| `programs/fizzbuzz_int.vsm` | 整数 ALU だけの FizzBuzz（このデモで書いた解答） |
| `logs/` | 実機で実行したときの出力 |
| `build/` | 作業用（git 管理外）: 公式エミュレータの入出力（`<名前>/official.asm` など）、ビルドのログ |

# nano20k

目標: Tang Nano 20K（GW2AR-LV18）上で、MN-Core 2 の公式機械語（`assemble3` が出力する flat の `j` 426bit / `m` 82bit）を、縮小トポロジのまま公式エミュレータと同じ結果で実行する。公開プロジェクト。

## まず読むもの

- `mncore/README.md`: 全体のまとめ
- `mncore/05-schedule.md`: 工程表と WP の依存関係
- `mncore/06-contracts.md`: **共通契約**（形式、規約、担当範囲、作業ルール）。WP 作業では必ず従う
- `mncore/wp/WP-xx.md`: 各 WP の指示書

## 環境（Windows 11）

- シェルは PowerShell と Git Bash。make はないので Python スクリプトで代用する。
- Python の venv は `.venv\Scripts\python.exe`（3.13）。
- FPGA ツールは OSS CAD Suite（yosys、nextpnr-himbaechel、gowin_pack、openFPGALoader、iverilog、verilator_bin、gtkwave）。詳細は `docs/tools.md`。
  - ユーザーの PATH には登録済みだが、古いシェルからは見えないことがある。
  - そのときは PowerShell で `$env:PATH = "$env:LOCALAPPDATA\Programs\oss-cad-suite\bin;$env:LOCALAPPDATA\Programs\oss-cad-suite\lib;$env:PATH"` を実行する。
  - `simrun.py` は自動で PATH を補う。
- Python パッケージは uv で入れる: `uv pip install --python .venv\Scripts\python.exe <pkg>`（venv に pip は入っていない）。
- 公式ツール（`assemble3`、`gpfn3_package_main`）は WSL の Ubuntu にある。
  - 場所は `~/wgkz/mncore/judge/judge-py/mncore2_emuenv/`。
  - 呼び出し方は `wsl -d Ubuntu -- bash -lc '...'`。Windows のパスは `/mnt/c/...` になる。
  - **バイナリをコミットしたり再配布したりしない。**
- 参照リポジトリ wogikaze/mncore は `third_party/mncore`（submodule）にある。
  - SDM の全文は `docs/mncore_llm`、Rust の基準シミュレータは `viz/core`。
- 機械語の観測メモは Scrapbox にある。全文は API で取れる: `https://scrapbox.io/api/pages/mncore/%E6%A9%9F%E6%A2%B0%E8%AA%9E/text`
- ボードのビルドの例は `init/build.bat`。デバイス名は `GW2AR-LV18QN88C8/I7`、family は `GW2A-18C`。

## worktree で作業するとき（subagent）

- 最初に `git submodule update --init third_party/mncore` を実行する。worktree には submodule が展開されていない。
- venv は worktree にはない。メインのチェックアウトにあるものを絶対パスで使う: `C:\wgkz\nano20k\.venv\Scripts\python.exe`
- 成果は自分のブランチにコミットする。main へのマージは lead が行う。

## 実機

- Tang Nano 20K は USB 接続済み。JTAG は `openFPGALoader -b tangnano20k`、UART は **COM6**（BL616 の FTDI 互換インタフェース）。
- 実機を使うときは、**メインのチェックアウトにある絶対パス** `C:\wgkz\nano20k\mncore\.board.lock` で排他する（契約 §9）。worktree 内のパスではない。

## 注意

- 公式エミュレータを最終的な正解とする。Rust Sim と食い違ったら、どちらかに合わせず報告する。

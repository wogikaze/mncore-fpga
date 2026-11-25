# Wave 5: 仮想 PE、全プログラムの実機実行、統合、デモ、公開

M2（WP37、2026-11-25）の結果を受けて、lead が範囲と順序を決め直した。

## 状況

- 1 本のビットストリームには全機能が載らない。M2a（L1BM、L2BM、MV、整数 ALU）は LUT4 72%。MAU 入りは 95.6% の見込み。
- LM の深さ 256 長語のため、26 本が E_RANGE になる（FizzBuzz の解答を含む）。
- 公式の hello_world（MAU を使う）は、ビットストリーム 2 本を手で切り替え、PE の状態をホストが引き継いで実行した（`fpga/top_m2/hello_hw.py`）。

## WP の一覧

| WP | 範囲 | 担当 | 依存 | 状態 |
| --- | --- | --- | --- | --- |
| WP34 | 仮想 PE: PE の状態（LM0/LM1/GRF0/GRF1）を SDRAM に置き、BSRAM をキャッシュにする。LM を実チップと同じ 2048 長語にする。1 L1B の 16 MAB（64 PE）まで広げる | `rtl/vpe/`、`rtl/core/`、`rtl/pe/`、`rtl/mab/`、`fpga/top_vpe/` | M2 | 指示書 `WP-34.md` |
| WP38 | 自動切り替えの実行器: 命令語ごとに必要なユニットを調べ、それを含むビットストリームに切り替えながら、PE / L1BM / L2BM / DRAM の状態を引き継いで最後まで実機で実行する | `tools/host/`（新しいファイル）、`fpga/multi/`（新規） | M2 | 指示書 `WP-38.md` |
| WP42a | 公開文書の下書き: README（英語と日本語）、`spec/isa` の解説、アーキテクチャの説明、結果の表 | `README.md`、`docs/`（新規）、`mncore/README.md` | M2 | 指示書 `WP-42.md` |
| WP40 | 統合と適合試験: 全構成の合格率表と、未対応の命令の一覧 | lead、`sim/regress/` | WP34、WP38 | |
| WP41 | デモ: FizzBuzz（`problems/challenge/20.fizzbuzz`）を実機で動かして UART に出力する。MNIST は可能なら | `mncore/demo/` | WP34 または WP38 | |
| WP42b | 公開の仕上げ: 最終結果の反映、Scrapbox への還元案 | lead | WP40、WP41 | |

- Wave 5a（並行）: WP34、WP38、WP42a。WP34 と WP38 は実機をロックで排他して使う。
- Wave 5b: WP40、WP41、WP42b。

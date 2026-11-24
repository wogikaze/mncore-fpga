# WP40〜42 統合、デモ、公開（Wave 5）

| WP | 範囲 | 担当 | 受入の要点 |
| --- | --- | --- | --- |
| WP40 | 統合と適合試験 | lead、`fpga/top_l1b/`、`sim/regress/` | 縮小トポロジでの全回帰。正解は WP06 の Rust 縮小版。合格率表と、未対応の命令の一覧を出す |
| WP41 | デモ | `mncore/demo/` | FizzBuzz の解答（`problems/challenge/20.fizzbuzz`）を縮小構成用に動かし、UART に出力する。MNIST 推論（縮小版）は可能なら |
| WP42 | 公開と文書 | lead | README（英語と日本語）、`spec/isa` の解説、Scrapbox「機械語」への還元（追記はユーザーが判断）、ライセンスの表記 |

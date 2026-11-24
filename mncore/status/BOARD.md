# 進捗ボード（lead が更新）

| WP | 内容 | Wave | 状態 | 備考 |
| --- | --- | --- | --- | --- |
| WP00 | キックオフ | 0 | 完了 2026-11-24 | git init、submodule、雛形、simrun selftest PASS（sim、lint、synth） |
| WP01 | ISA スキーマと Python デコーダ | 1 | 完了 2026-11-24 | 110 + 12 欄を確定。22,835 語の往復で不一致 0。unittest 31 件（lead が再実行して OK） |
| WP02 | ゴールデン基盤 | 1 | 実行中 | |
| WP03 | ベクタ生成 | 1 | 実行中 | |
| WP04 | UART、ホスト | 1 | 実行中 | 実機 |
| WP05 | SDRAM | 1 | 実行中 | 実機 |
| WP06 | Rust Sim の縮小トポロジ対応 | 1 | 実行中 | wogikaze/mncore の topo-param ブランチ |
| WP07 | 資源とレシピ | 1 | 完了 2026-11-24 | `07-device-budget.md`。レシピ 6 本。`recipes.py check` は lead が再実行して PASS。§6 の予算を改訂 |
| WP10 | RTL デコーダ | 2 | 未着手 | |
| WP11 | 整数 ALU | 2 | 未着手 | |
| WP12 | FP の FMA | 2 | 未着手 | |
| WP13 | FP 系の ALU 命令 | 2 | 未着手 | |
| WP14 | PE の記憶 | 2 | 未着手 | |
| WP20 | PE コアの統合 | 3 | 未着手 | |
| WP21 | 1 PE を実機で動かす | 3 | 未着手 | |
| WP30〜34 | 階層 | 4 | 未着手 | |
| WP40〜42 | 統合、公開 | 5 | 未着手 | |

# 進捗ボード（lead が更新）

| WP | 内容 | Wave | 状態 | 備考 |
| --- | --- | --- | --- | --- |
| WP00 | キックオフ | 0 | 完了 2026-11-24 | git init、submodule、雛形、simrun selftest PASS（sim、lint、synth） |
| WP01 | ISA スキーマと Python デコーダ | 1 | 完了 2026-11-24 | 110 + 12 欄を確定。22,835 語の往復で不一致 0。unittest 31 件（lead が再実行して OK） |
| WP02 | ゴールデン基盤 | 1 | 完了 2026-11-24 | 959 本を全件比較。一致 801、不一致 8（MV n128 の Rust 退行 6、PDM の d get 2）。test_golden 21 件は lead が再実行して OK |
| WP03 | ベクタ生成 | 1 | 完了 2026-11-24 | 5 unit、584,743 行。公式との食い違い 4 種、34,685 行（disputed）。--official-expect で 34,685 行を公式の出力に置き換え、全 584,743 行が公式と一致。cargo test は lead が再実行して OK |
| WP04 | UART、ホスト | 1 | 完了 2026-11-24 | 実機 22 項目 PASS、最大 3 Mbaud。BL616 で読み出し約 70 KiB/s が上限。test_mnhost と sim は lead が再実行して OK。ndmp の細部は WP02 に合わせる作業が残る |
| WP05 | SDRAM | 1 | 実行中 | 実機 |
| WP06 | Rust Sim の縮小トポロジ対応 | 1 | 実行中 | wogikaze/mncore の topo-param ブランチ |
| WP07 | 資源とレシピ | 1 | 完了 2026-11-24 | `07-device-budget.md`。レシピ 6 本。`recipes.py check` は lead が再実行して PASS。§6 の予算を改訂 |
| WP10 | RTL デコーダ | 2 | 完了 2026-11-24 | yaml から生成。j 8,926 語と m 1,220 語で不一致 0。LUT 約 190。sim、lint、synth は lead が再実行して PASS |
| WP11 | 整数 ALU | 2 | 実行中 | |
| WP12 | FP の FMA | 2 | 実行中 | |
| WP13 | FP 系の ALU 命令 | 2 | 実行中 | |
| WP14 | PE の記憶 | 2 | 実行中 | |
| WP20 | PE コアの統合 | 3 | 未着手 | |
| WP21 | 1 PE を実機で動かす | 3 | 未着手 | |
| WP30〜34 | 階層 | 4 | 未着手 | |
| WP40〜42 | 統合、公開 | 5 | 未着手 | |

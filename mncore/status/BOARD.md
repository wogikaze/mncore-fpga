# 進捗ボード（lead が更新）

| WP | 内容 | Wave | 状態 | 備考 |
| --- | --- | --- | --- | --- |
| WP00 | キックオフ | 0 | 完了 2026-11-24 | git init、submodule、雛形、simrun selftest PASS（sim、lint、synth） |
| WP01 | ISA スキーマと Python デコーダ | 1 | 完了 2026-11-24 | 110 + 12 欄を確定。22,835 語の往復で不一致 0。unittest 31 件（lead が再実行して OK） |
| WP02 | ゴールデン基盤 | 1 | 完了 2026-11-24 | 959 本を全件比較。一致 801、不一致 8（MV n128 の Rust 退行 6、PDM の d get 2）。test_golden 21 件は lead が再実行して OK |
| WP03 | ベクタ生成 | 1 | 完了 2026-11-24 | 5 unit、584,743 行。公式との食い違い 4 種、34,685 行（disputed）。--official-expect で 34,685 行を公式の出力に置き換え、全 584,743 行が公式と一致。cargo test は lead が再実行して OK |
| WP04 | UART、ホスト | 1 | 完了 2026-11-24 | 実機 22 項目 PASS、最大 3 Mbaud。BL616 で読み出し約 70 KiB/s が上限。test_mnhost と sim は lead が再実行して OK。ndmp の細部は WP02 に合わせる作業が残る |
| WP05 | SDRAM | 1 | 完了 2026-11-24 | 実機で 8 MiB 全域 × 100 回の照合で誤り 0（54/99/108 MHz）。推奨 99 MHz CL2、連続 387 MB/s、ランダム 167 MB/s。sim と lint は lead が再実行して PASS |
| WP06 | Rust Sim の縮小トポロジ対応 | 1 | 完了 2026-11-24 | topo-param `5f0ceb1`（push 済み）。縮小 10 構成で不一致 0。MV n128 の退行を修正し、conformance は 146 件すべて一致。lead が sweep で 12 本を再確認 |
| WP07 | 資源とレシピ | 1 | 完了 2026-11-24 | `07-device-budget.md`。レシピ 6 本。`recipes.py check` は lead が再実行して PASS。§6 の予算を改訂 |
| WP10 | RTL デコーダ | 2 | 完了 2026-11-24 | yaml から生成。j 8,926 語と m 1,220 語で不一致 0。LUT 約 190。sim、lint、synth は lead が再実行して PASS |
| WP11 | 整数 ALU | 2 | 完了 2026-11-24 | 144,645 行 × 2 構成で一致（disputed 29,126 行を含む）。LUT 2,142（-nowidelut で 1,871）、124 MHz。sim と lint は lead が再実行して PASS |
| WP12 | FP の FMA | 2 | 完了 2026-11-25 | fp 62,340 行、mau 52,480 行、境界 39,669 行が公式と一致。FMA は DSP 8、LUT 約 2,700。round_twice の規則を確定。sim と lint は lead が再実行して PASS |
| WP13 | FP 系の ALU 命令 | 2 | 完了 2026-11-25 | 151,856 行で一致。fp_alu の LUT 約 2,500、bfn 約 2,700、約 105 MHz。sim と lint は lead が再実行して PASS |
| WP14 | PE の記憶 | 2 | 完了 2026-11-25 | 公式エミュレータを期待値にした 86 本で 29,568 長語が一致。BSRAM 8、LUT 約 5,500、62 MHz。Rust Sim との食い違い 3 件。sim と lint は lead が再実行して PASS |
| WP20 | PE コアの統合 | 3 | 完了 2026-11-25 | pe1 の 260 本のうち 259 本が公式と一致（残り 1 本は bfn のため比較対象外）。直接試験 14,494 か所、変異 21 種。全部入りは LUT 80% で配置できず、FPALU=0 なら 66%。lead が sim、lint、回帰の一部を再実行して PASS |
| WP21 | 1 PE を実機で動かす | 3 | **完了 2026-11-25（M1）** | 実機で pe1 の 260 本のうち 256 本が公式と一致し、値の食い違いは 0（FPALU=3、27 MHz、LUT4 75%）。残り 4 本は E_UNSUPPORTED（floor、fmax、bfn）。lead も実機で 4 本を再実行して一致 |
| WP30 | MAB（4 PE の時分割） | 4a | 完了 2026-11-25 | 4 PE の 260 本すべてが公式と一致（bfn を含む）。1 PE は 259 で退行なし。実機は機能別の 2 本で、値の食い違い 0。BSRAM 33/46。mab と core は lead が再実行して PASS |
| WP31 | L1BM ユニット | 4a | 完了 2026-11-25 | 公式を期待値にした 96 本、rrn 186,396 行で一致。N_MAB=1、RRN=2 で LUT 約 1,500、BSRAM 4。sim と lint は lead が再実行して PASS |
| WP35 | 面積の削減 | 4a | 完了 2026-11-25 | LUT 換算 −2,479。1 PE の全部入りが LUT4 71% で配置でき、実機で 259/260 一致。lsu に NPE を追加。pemem、mab、top_1pe は lead が再実行して PASS |
| WP32 | L2BM | 4b | 実行中 | |
| WP33 | MV | 4b | 未着手 | |
| WP36 | 行列 | 4b | 実行中 | |
| WP37 | M2 の統合（hello_world を実機で） | 4c | 未着手 | |
| WP34 | 仮想 PE（64 PE） | 5 | 未着手 | |
| WP40〜42 | 統合、公開 | 5 | 未着手 | |

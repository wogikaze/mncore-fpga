# MN-Core 2 の機械語を Tang Nano 20K で動かす

**目標（2026-11-24 確定）**: 公式アセンブラ `assemble3` が出力した flat 形式の機械語（`j` 426bit / `m` 82bit）を、そのまま FPGA に流し込む。
縮小トポロジ上で、公式エミュレータと同じ結果を得る。成果は公開する。

| ファイル | 内容 |
| --- | --- |
| [01-target-analysis.md](01-target-analysis.md) | MN-Core 2 と Tang Nano 20K の比較、規模の差 |
| [02-approach.md](02-approach.md) | 実装方式の比較と推奨構成 |
| [03-roadmap.md](03-roadmap.md) | 人手で進める場合のフェーズ分けと見積もり（初版） |
| [04-encoding-probe.md](04-encoding-probe.md) | 命令語のエンコードについてわかっていること |
| **[05-schedule.md](05-schedule.md)** | **subagent で並列に進める工程表**（Wave、依存グラフ、クリティカルパス） |
| **[06-contracts.md](06-contracts.md)** | **共通契約**（入力形式、ビット番号、ダンプ形式、RTL 規約、担当範囲、作業ルール） |
| [wp/](wp/) | WP ごとの指示書と、起動の手順（[LAUNCH.md](wp/LAUNCH.md)） |
| [tools/probe_bits.sh](tools/probe_bits.sh) | 差分プローブ（WSL で実行） |

リポジトリ直下の [`CLAUDE.md`](../CLAUDE.md) に、subagent も読む環境情報と規約の入口がある。

## 現状の要約

2026-11-25 に **M2** に到達した。数字は [リポジトリ直下の README.md の Results](../README.md#results) の 1 か所にまとめている（各行に出典の報告書を付けた）。設計は [docs/ja/architecture.md](../docs/ja/architecture.md) にある。

1. **縮小トポロジで動いている。** チップ全体は載らない（PE 内メモリだけで約 144 MiB）。
   - M1（WP21）: 1 PE を実機で動かした。
   - M2（WP37）: 1 グループ・1 L2B・1 L1B・1 MAB（4 PE を時分割）に、L1BM、L2BM、MV を入れた。PDM / DRAM は SDRAM に置く。実機の回帰では、全本が RTL シミュレーションと同じ結果で、値の食い違いは 0。
   - 存在しないユニットの扱いは、ゼロ規則（既定。正解は縮小トポロジの Rust Sim）と複製規則（`REPLICA=1`。正解は公式の切り出し）の 2 本立て（契約 §3）。
2. **公式の hello_world を実機で実行した。** ベクトル MAU と L1BM / L2BM / MV が 1 本に載らないので、機能別のビットストリーム 2 本に分け、PE の状態をホストが引き継いだ（`fpga/top_m2/hello_hw.py`）。
   - 複製規則では、DRAM に "Hello, world!" が出て、比べた全長語が公式と一致した。
   - ゼロ規則では、比べた全長語が縮小トポロジの Rust Sim と一致した。
3. **機械語の意味は、残りわずかを除いて確定した。**
   - 欄の定義は `spec/isa/`、まとめは [docs/isa-notes.md](../docs/isa-notes.md) にある。
   - 公式エミュレータと Rust Sim の食い違いは [docs/divergences.md](../docs/divergences.md) にまとめた（契約 §1 と同じ内容）。
4. **残っている制約**:
   - LM が 256 長語なので、FizzBuzz の解答を含む一部の本は `E_RANGE` で止まる。
   - MAU を含む M2 は面積が足りない（LUT4 の実用上の上限は 75 %。WP21、WP37）。
   - ビットストリームの切り替えは手作業である。
5. **Wave 5 で進めていること**（[wp/WP-4x.md](wp/WP-4x.md)）:
   - 仮想 PE（WP34。LM 2048 長語、64 PE）
   - 自動切り替えの実行器（WP38）
   - 公開文書（WP42a）
   - その後に、統合と適合試験（WP40）、FizzBuzz のデモ（WP41）、公開の仕上げ（WP42b）。

## 着手前にユーザーが決めること

- [ ] 公開リポジトリの名前とライセンス（例: `wogikaze/mncore-fpga`、MIT または Apache-2.0）
- [ ] nano20k を `git init` し、`third_party/mncore` を submodule にしてよいか
- [ ] WP06 で wogikaze/mncore にブランチ（`topo-param`）を作ってよいか
- [ ] Wave 1 の間、ボードを USB でつないだままにできるか

これらが決まったら、lead が WP00（キックオフ）を行い、Wave 1（WP01〜07）を同時に起動する。

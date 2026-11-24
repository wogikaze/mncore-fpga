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

1. **チップ全体は載らない。** PE 内メモリだけで約 144 MiB ある。縮小トポロジで作る。
   - 最初は 1 PE。次に 1 MAB。最後に仮想 PE で 1 L1B（64 PE）まで広げる。
2. **エンコードのリスクはほぼ解消した。**
   - Scrapbox の [mncore/機械語](https://scrapbox.io/mncore/機械語) に、ALUC、MAUC、MV、L1BM/L2BM、即値、アドレスの配置が観測済みでまとまっている。
   - `assemble3 --print-csv` の出力を順に連結すると、`j` 語とビット単位で一致することを確認した。
   - つまりフィールドの区切りはアセンブラ自身が教えてくれる。残っているのは意味が未確定の欄の確認だけ。
3. **正解の基盤がある。** 公式エミュレータ（WSL）と Rust Sim（`viz/core`、公式と全問題で一致）がある。
   ユニット単位の期待値は、Rust の実装から生成する。
4. **作業の進め方**: 7 並列の Wave 1 から始め、6 Wave で進める。
   - 実時間の目安は **4〜6 週**（[05](05-schedule.md)）。
   - 律速になるのは FP のビット一致、統合、実機デバッグ（ボードは 1 台）。

## 着手前にユーザーが決めること

- [ ] 公開リポジトリの名前とライセンス（例: `wogikaze/mncore-fpga`、MIT または Apache-2.0）
- [ ] nano20k を `git init` し、`third_party/mncore` を submodule にしてよいか
- [ ] WP06 で wogikaze/mncore にブランチ（`topo-param`）を作ってよいか
- [ ] Wave 1 の間、ボードを USB でつないだままにできるか

これらが決まったら、lead が WP00（キックオフ）を行い、Wave 1（WP01〜07）を同時に起動する。

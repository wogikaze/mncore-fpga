# WP30〜34 階層とメモリ（Wave 4）

Wave 4 は M1 の後に始める。下の範囲は確定しているが、**詳細な指示書は M1 の後で lead が WP ごとに分けて書く**。
それまでに得た知見（資源の実測、PE コアの構造）を反映するため。

| WP | 範囲 | 担当 | 依存 | 受入の要点 |
| --- | --- | --- | --- | --- |
| WP30 | MAB: 4 PE（時分割）、行列レジスタ、mwrite/mread、行列 MAU（mfma/mmul）、block float、msl/msr | `rtl/mab/` | WP21 | `gpu_mau_conformance` の行列部分と、相当するコーパスの一致 |
| WP31 | L1BM: l1bmp/l1bmm/l1bmm4/l1bmd（分配と結合）、RRN 縮約、`lbf`、`$lbi` | `rtl/l1bm/` | WP21（WP30 と並行） | `gpu_l1_conformance` 相当が、縮小トポロジ（1 L1B）で一致 |
| WP32 | L2BM: Bcast/Bcast2/Distrib/Gather/FromL1b/Reduce/Reduce2/Imcast、DAR/DARBUF | `rtl/l2bm/` | WP31 | L2BM 系のコーパスが縮小トポロジで一致 |
| WP33 | MV: 25 モード、PDM/DRAM（SDRAM 上に配置）、mvid/wait、priority、DRAM 間接参照 | `rtl/mv/` | WP32、WP05 | `gpu_mem_conformance` の MV 相当が一致 |
| WP34 | 仮想 PE: PE の状態を SDRAM に置き、BSRAM をワーキングセットにする。64 PE まで拡張 | `rtl/vpe/` | WP21、WP05 | 1 L1B（64 PE）構成で WP20 の回帰が全件一致し、速度を報告する |

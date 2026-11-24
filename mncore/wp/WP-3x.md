# WP30〜37 階層とメモリ（Wave 4）

M1（WP21、2026-11-25）の結果を受けて、lead が範囲と順序を決め直した。

## 前提と方針

- 1 PE 構成でも、LUT4 は上限 75% に達している（契約 §6）。PE を実体で増やす余地はない。
  - **4 PE（1 MAB）は時分割で実行する。** 物理的なデータパスは 1 組だけ持ち、PE 0〜3 の状態を BSRAM に積む。
  - LM0/LM1/GRF0/GRF1 を 4 PE 分積むと 16 ブロック（WP07）。命令メモリ 12 + PE 16 + L1BM 4 + L2BM 8 = 40/46。
- **機能別のビットストリームを認める。** 全ユニットが同時に載らない場合は、パラメータでユニットを選んだ複数のビットストリームを作る。
  - ホスト側は、プログラムが使うユニット（WP10 の `grp`）から、それを含むビットストリームを選ぶ。
  - INFO で、載っているユニットを報告する。
- 面積の削減は WP35 が並行して進める。
- **M2 の目標:** 公式の hello_world を、1 L2B・1 L1B・1 MAB（4 PE）の縮小トポロジで、実機で公式と一致させる。
  - 正解は、公式エミュレータで 4096 PE を実行した結果を、実装した範囲で切り出したもの（契約 §3 (b)）。
  - 縮小トポロジの Rust Sim（契約 §3 (a)）は補助として使う。

## WP の一覧と順序

| WP | 範囲 | 担当 | 依存 | 状態 |
| --- | --- | --- | --- | --- |
| WP30 | MAB: 4 PE の時分割、msl/msr、bfn/bfe（4 PE の入力がそろう） | `rtl/mab/`、`rtl/core/`、`rtl/pe/mn_pe_core.v`、`rtl/pe/mn_pe_mem.v`、`rtl/pe/mn_pe_store.v` | WP21 | 指示書 `WP-30.md` |
| WP31 | L1BM: l1bmp/l1bmm/l1bmm4/l1bmd、RRN 縮約、`lbf`、`$lbi`。単体のユニットとして作る | `rtl/l1bm/` | WP21 | 指示書 `WP-31.md` |
| WP35 | 面積の削減: host_if、LSU、FPU、ALU | `rtl/board/`、`rtl/pe/mn_pe_lsu.v`、`rtl/fpu/`、`rtl/alu/` | WP21 | 指示書 `WP-35.md` |
| WP32 | L2BM: Bcast/Bcast2/Distrib/Gather/FromL1b/Reduce/Reduce2/Imcast、DAR/DARBUF | `rtl/l2bm/` | WP31 | 指示書は WP31 の後 |
| WP33 | MV: PDM/DRAM を SDRAM に置く、mvid/wait、priority、間接参照 | `rtl/mv/` | WP32、WP05 | 指示書は WP32 の後 |
| WP36 | 行列: 行列レジスタ、mwrite/mread、mfma/mmul | `rtl/mab/` の行列部分 | WP30 | 指示書は WP30 の後 |
| WP37 | M2 の統合: WP30〜33 を `mn_core` に入れ、hello_world を実機で一致させる | `rtl/top/`、`fpga/top_mab/` | WP30〜33、WP35 | |
| WP34 | 仮想 PE: PE の状態を SDRAM に置き、64 PE（1 L1B）へ広げる | `rtl/vpe/` | WP37 | Wave 5 に回す |

- Wave 4a（今すぐ並行）: WP30、WP31、WP35。
- Wave 4b: WP32 → WP33、WP36。
- Wave 4c: WP37（M2）。

## 共通の注意

- WP31〜33 は、PE コアとの境界のポートを自分の `README.md` に定義し、単体のテストベンチで正しさを示す。`mn_core` への組み込みは WP37 が行う。
- 時分割と実体の 4 PE のどちらでも同じ結果になるよう、PE の番号はポートや状態のアドレスで明示的に渡す。

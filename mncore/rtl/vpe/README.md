# rtl/vpe: 仮想 PE（WP34）

1 組の時分割 MAB データパス（`mn_mab`、WP30）で、1 L1B の 16 MAB（64 PE）までを順に実行する。
PE の状態はすべて SDRAM に置き、LM は実チップと同じ 2048 長語まで使える。

`mn_core #(.N_PE(4), .VPE(1), .N_MAB(16), .LM_AW(11))` で使う（`N_MAB` は 1〜16、`LM_AW` は 8〜11）。
`VPE = 0` の構成（M1、1 MAB、M2）は従来のまま。

## モジュール

| ファイル | モジュール | 役割 |
| --- | --- | --- |
| `mn_vpe.v` | `mn_vpe` | 仮想 MAB の順序制御。1 語を MAB 0〜N_MAB-1 の順に実行し、その前後で文脈を入れ替える。ホストの PE 空間を SDRAM に直接つなぐ（ホストエンジン）。SDRAM のバスを 1 本にまとめる |
| `mn_vpe_ctx.v` | `mn_vpe_ctx` | 文脈エンジン。MAB の 4 PE の T / `$omr` / `$mb`・`$nb` / `$aluf` / `$mauf` を、SDRAM とデータパスの作業用の写し（`mn_pe_lsu` NPE = 4、`mn_pe_core`）のあいだで読み書きする |
| `mn_vpe_store.v` | `mn_vpe_store` | `mn_pe_lsu` のストアの 4 チャネル（GRF0 / GRF1 / LM0 / LM1）を SDRAM のバス 1 本に載せる（`mn_pe_store` の代わり。`mn_mab_mem` の `VPE = 1`） |
| `mn_vpe_arb.v` | `mn_vpe_arb` | 2 つの主（MV ユニットと仮想 PE）が SDRAM のバスを分け合う調停（ラウンドロビン、読み出しの応答を主に返す FIFO） |

変更した既存の部品（`rtl/mab`、`rtl/pe`、`rtl/core`、`rtl/l1bm`）:

- `mn_mab_mem`: `VPE = 1` で `mn_pe_store` の代わりに `mn_vpe_store`。PE 番号は {仮想 MAB `vm`, MAB 内の PE}。
- `mn_pe_core`: 入力 `vm`（`$peid` / `$mabid` は MAB `POS_M + vm` のもの）、出力 `cx_use`（語が使う文脈）と `xchk`（データのために検査だけのパスが要る語）。`VPE = 1` でフォワーディングレジスタにホストの口（空間 0x12 `$aluf`、0x13 `$mauf`）。`LBS = 1` で `$lbf` の読み出しを 1 クロック待つ。
- `mn_mab`: 入力 `chk_only`（検査だけのパスだけを行う）と `nochk`（データのためでなければ検査だけのパスを省く）。
- `mn_core`: パラメータ `VPE`、`N_MAB`、`VPE_CXALL`、`GRF_BASE` / `CTX_BASE` / `LM_BASE`。`mn_vpe` を置き、L1BM ユニットを N_MAB の MAB にし（`cur_mab`）、SDRAM のバスを MV と分ける。リセット後の消去（`SDCLR`）は VPE 領域も 0 にする。
- `mn_l1bm`（WP31）: パラメータ `BS`。16 MAB の 256 項目のソースバッファ、`$lbf`、`$lbi` を BSRAM に置く（LUT RAM では RAM16SDP4 が 1,536 個要り、デバイスの 648 個を超える）。`mn_core` は `N_MAB > 1` のとき `BS = 1` にする。

## SDRAM の配置（VPE 領域、長語アドレス）

| 範囲 | 大きさ | 内容 | アドレスの組み立て |
| --- | --- | --- | --- |
| 0x00000〜0x7FFFF | 2^19 | DRAM（WP33） | |
| 0x80000〜0x9FFFF | 2^17 | PDM（WP33） | |
| 0xA0000〜0xA7FFF | 2^15 | GRF0 / GRF1 | `GRF_BASE \| {pe[5:0], g, a[7:0]}` |
| 0xA8000〜0xA8FFF | 2^12 | 文脈（PE ごとに 64 長語） | `CTX_BASE \| {pe[5:0], slot[5:0]}` |
| 0xA9000〜0xBFFFF | | 空き | |
| 0xC0000〜0xFFFFF | 2^18 | LM0 / LM1 | `LM_BASE \| {pe[5:0], l, a[10:0]}` |

`pe` = {MAB m（0〜15）, PE p（0〜3）}。3 つの基点はそれぞれの大きさにそろえてあるので、欄は OR で入る。

文脈のスロット（PE ごと）:

| slot | 内容 | 形式（ホストの口の読み出しと同じ） |
| --- | --- | --- |
| 0〜7 | T（2c + k: サイクル c の MSB 側 k = 0、LSB 側 k = 1） | 長語 |
| 8、9 | `$mb`、`$nb` | 下位 12bit |
| 16 + e | `$omr<e>`（e = 1〜15） | 下位 16bit（ニブル c がサイクル c のフラグ） |
| 32〜39 | `$aluf`（2c + k） | 長語 |
| 40〜47 | `$mauf`（2c + k、MAU = 1） | 長語 |

## 1 語の実行（`mn_vpe`）

```
for m = 0 .. N_MAB-1:
    文脈の読み込み（MAB m の 4 PE）   mn_vpe_ctx load（語が読むものだけ: cx_use）
    MAB m の 4 PE で語を実行           mn_mab（vm = m）: GRF / LM は mn_vpe_store 経由で SDRAM
    文脈の書き戻し                     mn_vpe_ctx save（語が書いたものだけ）
```

- `cx_use`（`mn_pe_core`）: T を読む（オペランド `$t`、T 間接の LM0、T への書き込み: 書かないレーンを残すため）、T を書く、`$omr<imr>` を読む、`$omr<omr>` を書く（4 ニブルとも書かれる）、`$mb` / `$nb` を読む（LM0 / LM1 のアクセス）・書く、`$aluf` / `$mauf` を読む・書く（4 サイクルとも書かれる）。書き戻すのは「読み込んだもの」か「全部を書いたもの」だけ。`VPE_CXALL = 1` は T / BAR / `$aluf` / `$mauf` を毎回すべて動かす（選択の誤りを見つけるための比較用）。
- `$lbf`、`$lbi`、L1BM は L1BM ユニットが 16 MAB 分を持つ。行列レジスタ（MAT）は N_MAB = 1 のときだけ（16 MAB では E_UNSUPPORTED）。
- L1BM / L2BM ユニットの start（`ugo`）は MAB 0 のもの、commit は最後の MAB の後（`mn_core` の手順は WP37 のまま）。
- 停止: E_UNSUPPORTED は語の性質なので MAB 0 で見つかる（何も書く前）。MAB 1 以降は `nochk` で検査だけのパスを省く（msl / msr / bfn / bfe と行列 MAU のデータ集めは残す）。LM_AW = 11 では LM / GRF の範囲外は起こらない。LM_AW < 11 かつ N_MAB > 1 で LM を使う語は、先に全 MAB で検査だけのパス（`chk_only`）を行い、どの PE が範囲外でも 64 PE のどれも書く前に E_RANGE で止まる（契約 §3）。
- ホストの PE 空間（RUN の外）: 空間 1〜5、0x10、0x11、0x12、0x13 は SDRAM に直接読み書きする。マスクと範囲は `mn_pe_lsu` のホストの口と同じ（LM / GRF は 32bit レーン、T の MSB 側は 16bit レーン、OMR はバイト、エントリ 0 は ffff を読み書き込みは無視、BAR は 12bit）。
- リセット: `SDCLR = 1` で DRAM、PDM、VPE 領域を 0 にする（公式の初期状態）。`CLEAR`（PE のホストの口からの消去）は VPE では使わない。

## 速さ（RTL シミュレーション、27 MHz のコアのクロック）

`mncore/status/WP-34.md` の「速度」の節。

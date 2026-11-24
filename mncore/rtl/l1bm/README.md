# rtl/l1bm: L1BM ユニット（WP31）

1 つの L1B の L1BM（`L1BM_DEPTH` = 2^AW 長語）、PE ⇔ L1BM の転送（l1bmp / l1bmm / l1bmm@ / l1bmm4 / l1bmm4@ / l1bmd / l1bmr / l1bmr4）、
RRN の縮約、折り返しレジスタ `$lbi`、フォワーディングレジスタ `$lbf` を持つ単体のユニット。
`mn_core` への組み込みは WP37、L2BM 側（`l1bm_gwrite` / `l1bm_gadr` と L2BM 命令）は WP32 が行う。

## モジュール

| ファイル | モジュール | 役割 |
| --- | --- | --- |
| `mn_l1bm.v` | `mn_l1bm` | ユニット本体。L1BM（BSRAM 4 個）、ソースバッファ、`$lbi`、`$lbf`、転送の順序制御、範囲検査 |
| `mn_l1bm_rrn.v` | `mn_l1bm_rrn` | RRN の 1 レーン分の縮約（逐次）。L1BM の 16x1（2 段）・4x4 と、L2BM の 8 入力・2 入力（WP32 が使える） |

## パラメータ

| 名前 | 既定 | 意味 |
| --- | --- | --- |
| `N_MAB` | 1 | L1B の MAB 数（1〜16、契約 §3）。MAB 0〜N_MAB-1 が存在する |
| `AW` | 10 | L1BM の深さ 2^AW 長語（契約 `L1BM_DEPTH` = 1024。実チップは 13） |
| `RRN` | 1 | 1: 縮約に `mn_l1bm_rrn` を使う（任意の N_MAB）。2: N_MAB = 1 専用の小さな縮約（各レーンが MAB 0 の値と 0 の縮約になることを使う）。0: 縮約を持たない（l1bmr / l1bmr4 は E_UNSUPPORTED） |
| `CLEAR` | 1 | 1: リセット後に L1BM と `$lbi` を 0 にする（2^AW クロック、その間 `idle` = 0） |

## 境界のポート（PE コア ⇔ mn_l1bm）

PE の番号は (m, p) で明示する（m = MAB 0〜15、p = MAB 内の PE 0〜3）。時分割の PE コア（WP30）でも、実体の PE でも同じに使える。
データのバスの並びは `mn_pe_lsu` と同じ 128bit（`[127:96]` が語 0 = MSB、`[63:0]` が LSB 側の長語）。

### 語の欄（`mn_dec_j` の出力をそのままつなぐ。start から done まで変えない）

`ll`、`l1bm_bmode`、`l1bm_lwrite`、`l1bm_rmode`、`l1bm_me`、`l1bm_ladr`、`l1bm_dmode`、`l1bm_ext`、`l1bm_round_out`、
`l1bm_mabadr`、`l1bm_opcode`、`l1bm_isel`、`l1bm_wl`。

### 欄から決まる出力（組み合わせ回路）

| 信号 | 意味 |
| --- | --- |
| `use_src` | PE → L1BM の転送がある。コアは全 PE・全サイクルの `l1bm_isel` のオペランドを `src_*` で渡す |
| `lbf_upd` | この語は `$lbf` を更新する。コアは全 PE・全サイクルの結果を取り、`lbf_w*` で書く |
| `chk_trap`, `chk_addr` | E_RANGE（L1BM のアクセスが 2^AW 以上）。`chk_addr` は ladr が範囲外なら ladr、そうでなければ語のアクセスの最大アドレス（参考の値。停止理由の info は語番号） |
| `chk_unsup`, `chk_field` | E_UNSUPPORTED と欄番号（`MN_J_<field>_IDX`） |

### 1 語の手順

```
start ─┐ (idle のとき)
       ├─ src_we × (N_MAB×4 PE × 4 サイクル)       use_src のとき。順序は自由
       ├─ res_req → res_valid × 必要な (m, p, c)    isel=10 の書き込み先、または lbf_upd のとき。順序は自由
       ├─ lbf_we × (m, p, c)                        lbf_upd のとき（ゼロフラッシュ後の値）
commit ┘ → (L1BM と $lbi の書き込み) → done（1 クロックのパルス）
```

- 対象の語: `ll` = 01 / 11 で、L1BM の欄が既定値でない語、または isel = 10 の書き込み先を持つ語。そうでない語では start も commit も要らない。
  デコーダの `grp[MN_J_GRP_L1BM]`（`gwrite` / `gadr` も含む、少し広い条件）で選んでも害はない（何も書かない語は commit ですぐ done になる）。
- **L1BM と `$lbi` は commit の後にだけ書く。** その語の読み出し（L1BM → PE、`$lbi` の折り返し、ポート B の読み出し）はすべて書き込みの前の状態を見る（SDM 3.6.3.9 と同じ順序）。
  コアは PE の読み出しの段で `src` を渡し、書き込みの段で `res` を取ればよい。
- `chk_trap` / `chk_unsup` の語は実行しない（コアが停止理由を出す。start / commit をしても何も書かない）。範囲の検査は start の前に欄だけで決まる（契約 §3: 実際に行うアクセスだけ。存在する PE の L1BM → PE の読み出しと、me = 1 の PE → L1BM の書き込み）。
- 時間: `res` は L1BM から 2 クロック（2 長語は 3）、`$lbi` から 1 クロック。commit は書く長語 1 つにつき 1 クロック（l1bmd の結合は 256 長語）、縮約は 1 レーンにつき数十クロック。

### PE → L1BM のソース

| 信号 | 意味 |
| --- | --- |
| `src_we`, `src_mab[3:0]`, `src_pe[1:0]`, `src_cycle[1:0]`, `src_data[127:0]` | PE (m, p) のサイクル c の `l1bm_isel` のオペランド（`$lr $ls $t $lm $ln $mauf $aluf`。長語の読み出しなら LSB 側の長語は 0）。m ≥ N_MAB は無視 |

### L1BM → PE の値

| 信号 | 意味 |
| --- | --- |
| `res_req`, `res_ready`, `res_mab`, `res_pe`, `res_cycle` | 要求（`res_ready` のとき受け付ける。応答までは次を出さない） |
| `res_valid`, `res_data[127:0]` | 1 クロックのパルス。`res_data` は次の要求まで保持。ゼロフラッシュとマスクの前の値。1 長語の転送では LSB 側の長語は 0（`$lbi` からは LSB 面の値） |

isel = 10 の書き込み先（GRF0 / GRF1 / LM0 / LM1 / T）に書くのはコアの役目（マスク、ゼロフラッシュ `zero_sel` = 10 を含む）。

### `$lbf`

| 信号 | 意味 |
| --- | --- |
| `lbf_rmab`, `lbf_rpe`, `lbf_rcycle` → `lbf_rdata[127:0]` | 読み出し（組み合わせ回路）。コアのオペランド収集（`isela` = 13）用 |
| `lbf_we`, `lbf_wmab`, `lbf_wpe`, `lbf_wcycle`, `lbf_wdata[127:0]` | 書き込み。値はゼロフラッシュ後の結果（`mn_pe_core` の `aluf_wd` と同じ作り方）。`lbf_upd` でない語では無視 |

`$lbf` はリセットで消さない（L1BM → PE の前の読み出しは、エミュレータでエラー、アセンブラが拒否する）。

### ポート B（L2BM 側・ホスト）

契約 §6 のメモリバス（長語単位）。ホストの WR_MEM / RD_MEM（空間 6 = L1BM）と、WP32 の L2BM 側の転送に使う。

| 信号 | 意味 |
| --- | --- |
| `b_req_valid`, `b_req_ready`, `b_req_we`, `b_req_addr[22:0]`, `b_req_wdata[63:0]`, `b_req_wmask[7:0]` | 要求。`wmask` は 32bit 単位（4bit がすべて 1 の半分だけ書く） |
| `b_req_err` | 受け付けと同時に 1: アドレスが 2^AW 以上。要求は捨てる |
| `b_rsp_valid`, `b_rsp_rdata[63:0]` | 読み出しの応答（受け付けの 1 クロック後、順番どおり） |

- PE 側が同じクロックにメモリのポート（読み出しまたは書き込み）を使うときは `b_req_ready` = 0。
- 同じ語の中で、L2BM 側の読み出し（L1BM → L2BM、内部マルチキャスト）は commit より前に、L2BM 側の書き込み（L2BM → L1BM）は commit の後に行うこと（WP37）。

## mn_l1bm_rrn（L2BM の縮約にも使える）

| 信号 | 意味 |
| --- | --- |
| `start`（`busy` = 0 のとき）、`op[2:0]` | 0 fadd、1 max、2 min、3 iadd、4 band、5 and、6 bor、7 or |
| `fmt[1:0]` | レーン幅: 0 64bit（d / l）、1 32bit（f / i）、2 16bit（h / s） |
| `out_half` | fadd（fmt = 1）の最終結果を半精度に丸める（L1BM の hfadd） |
| `two_stage`、`zgrp[3:0]` | 16 入力を 4 × 4 の 2 段で（L1BM の 16x1）。`zgrp[g]` = 1 の組は入力がすべて 0 として飛ばす |
| `nin_m1[3:0]` | 1 段のときの入力数 − 1（L1BM の 4x4 は 3、l2bmr は 7、l2bmr2 は 1） |
| `in_idx[3:0]` → `in_val[63:0]` | 入力の要求と、その値（同じクロックに返す。下位のビットにレーンの値、上位は 0） |
| `done`、`res[63:0]` | 1 クロックのパルスと結果（下位のビット） |

- 演算は viz/core の `rrn.rs` と同じで、rrn ベクタ（WP03、全件公式一致）の全 186,396 行と一致する（l2bmr / l2bmr2 のファイルを含む）。
- L2BM の hfadd は半精度のまま（`fmt` = 2、`out_half` = 0）。L1BM の hfadd は呼び出し側が単精度に拡張して `fmt` = 1、`out_half` = 1。
- 1 レーンに 1 段あたり（入力数 + 2）クロックほど。fadd は桁合わせ（1 クロックに 8 ビットまで）と正規化が加わる。最大は 207 クロック（rrn ベクタ）。

## 意味（公式エミュレータで確かめたもの）

正は公式エミュレータ。`mncore/sim/tb/l1bm/l1model.py` が機械語の欄で書いたモデルで、プローブ（`l1prog.py` で手で欄を変えた語を含む）で公式と照合した。

- **lwrite = 0**: L1BM → PE の値は L1BM から読む（`me` = 0 でも読む）。並びは bmode と wl で決まる。
  - 00 l1bmp: 全 PE に `L1BM[ladr + c]`（wl: と `ladr + c + 4`）
  - 01 l1bmm: PE p に `L1BM[ladr + 4c + p]`（wl: `ladr + 8c + p` と `+ 4`）
  - 10 l1bmm4: PE (m, p) に `L1BM[ladr + 16c + 4(m >> 2) + p]`（wl: `ladr + 32c + 8(m >> 2) + p` と `+ 4`）
  - 11 l1bmd: PE (m, p) に `L1BM[(ladr & ~63) + 64c + ((L + 4m + p) mod 64)]`、L = `ladr[5:2]` × 4（MAB のずらし。`ladr[1:0]` は使わない）
  - アドレスの揃え（アラインメント）は要らない（揃っていない ladr もそのまま足す）。
- **lwrite = 1**: L1BM → PE の値は `$lbi`（折り返し）から。並びは最後に `$lbi` を書いた転送の bmode・wl・L で決まり、**この語の bmode などは使わない**（`l1bmm $lbi ...` の語は bmode = 00, me = 0, isel = 111）。
  さらにこの語は PE → L1BM の転送をする（isel = 111 なら値はすべて 0）。`$lbi` は noforward でなければ書き、L1BM は me = 1 のときだけ書く。bmode = 00 は 01（16x1）と同じ。
  - 01（l1bmm@M / l1bmr）: `L1BM[ladr + 4c + p]` ← PE (M, p)（wl: `+8c`、LSB 側は `+4`）
  - 10（l1bmm4@i / l1bmr4）: `L1BM[ladr + 16c + 4k + p]` ← PE (4k + i, p)（wl: `ladr + 32c + 8k + p` と `+4`）
  - 11（l1bmd）: `L1BM[(ladr & ~63) + 64c + ((4m + p - L) mod 64)]` ← PE (m, p)
  - `$lbi` の位置（MSB 面 0〜63、LSB 面 64〜127）: 16x1 は p、4x4 は 4k + p（wl: 8k + p）、l1bmd は 4m + p（ずらさない）。書かない位置は前の値のまま。
- **`$lbf`**: L1BM の欄のどれかが既定値でない語（noforward を除く）が、その語の L1BM → PE の値（ゼロフラッシュ後）で更新する（`lbf_upd`）。
  - 公式エミュレータは、L1BM の欄がすべて既定値の語（ALU だけの語など）でも、暗黙の `l1bmp $lb0` の読み出しで `$lbf` を更新する（手で欄を変えた語のプローブで確認）。
    アセンブラはそのような語の後の `$lbf` の読み出しを拒否する（`ialu_op->a()` の検査）ので、アセンブルしたプログラムでは違いが出ない。RTL はこの更新をしない（全語で 16 回の結果の取り出しが要るため）。
  - Rust Sim（viz/core）は、L1BM → PE の転送のない語で `$lbf` を保つ（RTL と同じ）。公式とは上の点で異なる。
- **縮約**（rmode = 1、bmode 01 / 10。00 は 01 と同じ）: `mn_l1bm_rrn`（1 レーンずつ）。演算は opcode、精度は (dmode, ext, round_out):

  | 機械語（dmode, ext, round_out） | 命令 | 入力 → 出力（PE ごと） |
  | --- | --- | --- |
  | 整数 (0, 0, 0) / (1, 0, 0) / (1, 1, 0) | l / i / s | 64 / 32 / 16bit レーン |
  | 浮動小数点 (0, 0, 0) | d | 64bit レーン |
  | 浮動小数点 (1, 0, 0) | f | 32bit レーン |
  | fadd (1, 1, 0) / max・min (1, 1, 0) | `ffadd $..e` / `fmax $..e` | MSB 側の半精度 4 個を単精度 4 個に拡張 → 単精度 4 個（2 長語） |
  | fadd (1, 0, 1) / max・min (1, 0, 1) | `ffaddr` / `fmaxr` | 単精度 4 個（2 長語）→ 半精度 4 個（1 長語） |
  | fadd (1, 1, 1) | `hfadd`（= `ffaddr $..e`） | 拡張し、単精度で縮約し、半精度に丸める |
  | max・min (1, 1, 1) | `hmax` / `hmin` | 16bit レーン（拡張も丸めもしない） |

  - 拡張: 符号と仮数 9bit をそのまま残し、指数 0 → 0、63 → 255、それ以外は + 96（max / min は無限大の仮数も見る）。
  - 丸め: fadd は縮約の中で丸める（最近接偶数、あふれは無限大、下は 0）。max / min は結果を ALU の `r` と同じ規則で丸める（指数は 0〜63 に飽和、仮数は残す。WP03 の r_round）。
  - 丸めた結果は PE p の 4 個が 1 長語に並ぶ（SDM の並べ替えは打ち消し合う）。
  - **L1BM と `$lbi` への並びは wl で決まる。** 拡張した結果（2 長語）を wl = 0 で書くと 1 長語目だけ、丸めた結果（1 長語）を wl = 1 で書くと 2 長語目は 0。
  - d に e / r を付けた語と、整数に e を付けた d の語はエミュレータが異常終了する。E_UNSUPPORTED にする。
- **存在しない MAB**（m ≥ N_MAB）: PE → L1BM の転送には 0 を送る（契約 §3）。L1BM → PE の値は受け取らない。N_MAB = 1 では `$lbi` の位置 0〜3 だけを持つ（ほかは常に 0）。

## E_UNSUPPORTED にする語（`chk_unsup`）

| 条件 | 欄 | 理由 |
| --- | --- | --- |
| rmode = 1 で、lwrite = 0、bmode = 11、または `RRN` = 0 | `l1bm_rmode` | アセンブラが作らない（bmode = 11 の縮約はエミュレータの並びが不明） |
| 縮約の opcode が表にない | `l1bm_opcode` | デコーダの `unsup_vec` と同じ |
| dmode = 0 で ext = 1 | `l1bm_ext` | エミュレータが異常終了する |
| dmode = 0 で round_out = 1、または整数の演算で round_out = 1 | `l1bm_round_out` | 同上（整数は未確認） |

- `chk_trap` と `chk_unsup` が両方 1 の語は、PE メモリと同じく E_RANGE を先に報告するのがよい（契約 §3）。

## 資源（`synth_gowin -nowidelut`、N_MAB = 1、AW = 10、平坦化）

| `RRN` | LUT | ALU | FF | SSRAM（RAM16SDP4） | BSRAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1（`mn_l1bm_rrn`、任意の N_MAB） | 2,328 | 757 | 601 | 112 | 4 |
| 2（N_MAB = 1 専用の小さな縮約） | 1,485 | 273 | 306 | 96 | 4 |
| 0（縮約なし） | 759 | 208 | 238 | 96 | 4 |

SSRAM 96 個は、ソースバッファ（16 × 128bit）、`$lbf`（16 × 128bit）、`$lbi`（2 面 × 16 × 64bit）。1 個が LUT 8 個分の場所を使う。

## テスト

`python mncore/tools/simrun.py l1bm [--lint] [--synth]`（`mncore/sim/tb/l1bm/`）。試験は公式エミュレータの結果を期待値にしたもの（`gen_tests.py` が作る `fixed/*.tst`）と、rrn ベクタ。詳細は `mncore/status/WP-31.md`。

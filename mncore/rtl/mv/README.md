# rtl/mv: MV ユニット（WP33）

m 語（82bit、MV 命令）を実行する単体のユニット。L2BM（WP32 の `mn_l2bm` のポート B）、PDM と DRAM（SDRAM、WP05 の `sdr_bus64`）の間でデータを動かし、
MV のタグ（`wait` 用）を持ち、ホストの空間 L2BM / PDM / DRAM を受け持つ。`mn_core` への組み込みは WP37。

## モジュール

| ファイル | モジュール | 役割 |
| --- | --- | --- |
| `mn_mv.v` | `mn_mv` | 本体。m 語の解読、検査の走査（E_RANGE / E_UNSUPPORTED）、16 長語のチャンク単位の転送（チャンクのバッファ 16 × 64bit、LUT RAM）、DRAM 間接参照、タグ、ホストの口 |
| `mn_mv_red.v` | `mn_mv_red` | 縮約 1 長語（N_L2B = 1 では値 x と 0 の縮約になる。下の「縮約」） |
| `mn_mv_tags.v` | `mn_mv_tags` | 256 タグの完了数（0 / 1 / 2 以上。LUT RAM 256 × 2bit、リセット後 256 クロックで消去） |

試験用のコア `mvt_core`（命令メモリ、順序制御、`mn_mv`、`mn_l2bm`、L1BM のメモリ）と実機の試験デザインは `mncore/fpga/mv_test/`。
`mvt_core` の順序制御は、下の「コア側の手順」をそのまま実装した見本でもある。

## パラメータ

| 名前 | 既定 | 意味 |
| --- | --- | --- |
| `L2AW` | 11 | L2BM の深さ 2^L2AW 長語（`mn_l2bm` の `AW`。契約 `L2BM_DEPTH`） |
| `PDM_AW` | 17 | PDM の深さ 2^PDM_AW 長語（提案 `PDM_DEPTH` = 131072 長語 = 1 MiB） |
| `DRAM_AW` | 19 | DRAM の深さ 2^DRAM_AW 長語（提案 `DRAM_DEPTH` = 524288 長語 = 4 MiB） |
| `PDM_BASE` | 20'h80000 | SDRAM（`sdr_bus64` の長語アドレス）での PDM の先頭。2^PDM_AW の倍数 |
| `DRAM_BASE` | 20'h00000 | SDRAM での DRAM の先頭。2^DRAM_AW の倍数 |

トポロジは N_L2B = 1 に固定（グループ 0 と L2B n0c0 だけが存在する。契約 §3）。

### SDRAM の配置（提案、2^20 長語 = 8 MiB）

| 長語アドレス | 大きさ | 内容 |
| --- | --- | --- |
| 0x00000〜0x7FFFF | 4 MiB | DRAM（グループ 0）。`DRAM_DEPTH` = 2^19 |
| 0x80000〜0x9FFFF | 1 MiB | PDM（グループ 0）。`PDM_DEPTH` = 2^17 |
| 0xA0000〜0xFFFFF | 3 MiB | 空き（WP34 の仮想 PE の状態、命令の先読みなど） |

コーパス（`third_party/mncore` の全 .vsm）で MV / `r` / `d get` が触る最大の番地は、DRAM 208,064 長語（`viz/core/benchmarks/mnist_train_step.vsm`、ほかは 32,768 以下）、PDM 32,768 長語。
上の深さはすべてを含み、空きを 3 MiB 残す。

## 境界のポート

### 発行（コア → `mn_mv`）

| 信号 | 意味 |
| --- | --- |
| `start`, `mw[81:0]` | `ready` のときに 1 クロック。`mw` はこのクロックだけ読む（命令メモリの `[81:0]` をそのまま） |
| `ready` | 受け付けられる（= `busy` = 0） |
| `acc`, `acc_st[1:0]`, `acc_field[3:0]` | 検査の結果（1 クロックのパルス）。0 OK（転送は裏で続く）、1 E_RANGE、2 E_UNSUPPORTED（`acc_field` = `MN_M_<欄>_IDX`）。OK 以外の語は何もしない |
| `busy` | 検査中または転送中（リセット後のタグの消去中も） |

- 検査は語の全アクセスを転送と同じ順で走査して行う（間接参照では DAR も読む）。E_RANGE なら、どの書き込みも行わない（契約 §3）。
  `acc` までの時間は、直接参照でチャンク数 × 2 クロック、間接参照で × 3 クロック程度。
- `valid` = 0 の m 語（mvnop）はコアが読み飛ばしてよい（`start` しても OK を返して何もしない）。
- **`mn_dec_m` の `mv_unsup_vec` / `mv_err_kind` は使わない。** mmode 111、tmode 110 / 111 を E_UNSUPPORTED にするが、公式は何もしない（タグは数える）。
  dmode 11 も縮約でなければ公式は無視する。判定は `acc_st` / `acc_field` に従うこと。

### wait（コア → `mn_mv`）

| 信号 | 意味 |
| --- | --- |
| `wt_tag[7:0]` | j 語の `wd`（`MN_J_WD`） |
| `wt_cnt[1:0]` | タグ `wt_tag` の MV で、完了して、まだ wait していない数（0 / 1 / 2 = 2 以上）。`busy` = 0 のときに有効 |
| `wt_take` | 1 クロックのパルスで、そのタグの数を 0 にする（`busy` = 0 で、`wt_cnt` = 1 のとき） |

### L2BM（`mn_mv` → `mn_l2bm` のポート B）と DAR

`cb_req_*` / `cb_rsp_*` は `mn_l2bm` のポート B（契約 §6 のバス、応答は受け付けの 1 クロック後）にそのままつなぐ。
`mn_mv` が転送とホストの空間 7 を調停するので、ポート B の主は `mn_mv` だけになる。
`dar_re` / `dar_raddr` → `dar_rdata` は `mn_l2bm` の DAR の読み出しポート（`DAR` = 0 の `mn_l2bm` では 0 が返り、間接参照は DAR = 0 として動く）。

### SDRAM（`mn_mv` → `sdr_bus64`）

`sd_req_*` / `sd_rsp_*` は `sdr_bus64` の要求・応答にそのままつなぐ（コアのクロックで。`ASYNC` = 1 なら SDRAM 側は別クロック）。
`sd_err_addr` は `sdr_bus64` の `err_addr`。`err_sdr` は保持型の写し（`mn_mv` は範囲を検査済みのアドレスしか出さないので立たない。立ったら E_RANGE 扱い、契約 §6）。

### ホスト（brd_host_if の mw / mr ポート）

`hw_*` / `hr_*` は `brd_host_if` のメモリポートと同じ形。空間 0x07 L2BM（loc 0 = n0c0、2^L2AW 長語）、0x08 PDM、0x09 DRAM（loc 0 = n0）を受け持ち、
ほかの空間、位置、深さ以上のアドレスは `*_err`。`busy` = 0 のときだけ受け付ける（コアの停止中だけホストに渡す）。読み出しは同時に 1 つ（`brd_host_if` と同じ）。

## コア側の手順（WP37。`mncore/fpga/mv_test/mvt_core.v` が見本）

1. **m 語**（エントリの種類 10）: `valid` = 0 なら次へ。そうでなければ `ready` を待って `start`、`acc` を待つ。
   `acc_st` = 0 なら次のエントリへ進む（転送は裏で続く）。1 は E_RANGE（info = エントリ番号）、2 は E_UNSUPPORTED（info = 0x80 | `acc_field`）で止まる。
   m 語では `mn_l2bm.skip` を出さない（`l2bmdars` の連続の規則、WP32）。
2. **wait**（j 語の `wd` ≠ 0。ll = 00 の語も）: `busy` = 0 を待ち、`wt_cnt` を見る。
   - 1: `wt_take` を出して、その語を実行する。
   - 0: そのタグの MV は発行されていない（または消費済み）。公式はここで止まったまま終わる（後の語は実行されず、d get はこの時点の状態を出す）。→ 停止理由 **WAIT**（提案、値 4、info = タグ）。
   - 2: 公式は異常終了する（`PE waits for double asserted DT done flag`）。→ E_UNSUPPORTED、info = `MN_J_WD_IDX`（91）。
3. **L2BM 命令のある j 語**（`mn_l2bm.act`、`l2bmdars` / `l2bmdarw` も）: `busy` = 0 を待ってから `mn_l2bm` を start する。
   公式は MV を発行の時点で完了させるので、MV の後の L2BM 命令は MV の結果を見て、MV の前の L2BM 命令の結果は MV が見る（`o_mv_l2` 試験）。
4. **それ以外の j 語**（PE、L1BM）: MV と共有する状態がないので、MV の転送中に実行してよい。
5. **RUN の終わり**（停止も含む）: `busy` = 0 を待ってから `core_busy` を下ろす（ホストが PDM / DRAM / L2BM を読むため）。PROTOCOL.md の「発行したものがすべて完了してから止まる」。
6. リセット（RESET）でタグを消す（256 クロック）。SDRAM の中身は残る（公式は PDM / DRAM を 0 で始めるので、ホストが書く）。

## 意味（公式エミュレータで確かめたもの）

正は公式エミュレータ。`mncore/sim/tb/mv/mvmodel.py` が機械語の欄で書いたモデル（全チップと縮小トポロジ）で、
`mncore/sim/tb/mv/probe.py` のプローブ（アセンブラが作らない組み合わせは、アセンブル後に欄を手で変えた語）で全チップの全ユニットにデータを置いて照合した。

### 欄

| 欄 | 意味 |
| --- | --- |
| `valid` | 0: mvnop（何もしない。タグも数えない） |
| `mmode` / `tmode` | 向きと形（下の表）。mmode 111 と tmode 110 / 111 は何もしない（MV は完了し、タグは数える）。表で「異常」の組は公式が異常終了する → E_UNSUPPORTED `tmode` |
| `destid` / `srcid` | グループ × 2 + L2B 番号。PDM / DRAM では bit 0 を見ない。並列（tmode 001）ではグループの部分を見ず、L2B 番号だけを見る。縮約では {`destid[0]`, `srcid`} が演算、`destid[2:1]` が PDM のグループ |
| `dmode` | 縮約の精度（00 d/l、01 f/i、10 h/s）。縮約で 11 は異常終了。縮約でなければ見ない |
| `mvid` | タグ（0 はタグなし） |
| `indirect` | DRAM 間接参照 |
| `adra` | DRAM の長語アドレス ÷ 16（DRAM のある形）、PDM ⇔ L2BM の PDM 側、PDM → PDM の転送元。間接参照では `nd << 10 \| M`（`nd` は bit 14..10 の 5bit、bit 15 以上は見ない。アセンブラは nd ≤ 31） |
| `adrb` | L2BM のアドレス ÷ 16（**bit 1..0 は使わない**: 64 長語単位）、または PDM ⇔ DRAM の PDM 側、PDM → PDM の転送先（PDM は 16 長語単位でよい） |
| `nw` | 16 長語のチャンク数。0 は異常終了。b2 / b4 / b の形と DRAM → PDM の mvd は nw が 4 の倍数でないと異常終了。ほかはチャンク単位で動く |
| `priority` | 結果に影響しない（使わない） |

アドレスはチップの大きさで折り返す: L2BM 2^15、PDM 2^19、**DRAM 2^29** 長語（公式の DRAM はグループあたり 2^29 長語。MV の番地はそこで折り返し、`d get` / `r` 行は範囲外で異常終了する）。その後で縮小した容量と比べる（契約 §3）。

### 形（mmode × tmode）

| mmode \ tmode | 000 単独 | 001 並列 | 010 b2 | 011 b4 | 100 b | 101 d |
| --- | --- | --- | --- | --- | --- | --- |
| 000 PDM → DRAM | `mvp $p@g $d@g` | 各グループ（*） | 異常 | 異常 | 異常 | `mvd $p@g $d` |
| 001 PDM → L2BM | `mvp $p@g $lc@g.l` | `mvp $p $lc@.l` | グループ g の PDM → g の L2BM 2 つ（*） | 異常 | `mvb $p@g $lc` | `mvd $p@g $lc` |
| 010 DRAM → L2BM | `mvp $d@g $lc@g.l` | `mvp $d $lc@.l` | `mvb2 $d $lc` | `mvb4 $d $lc` | `mvb $d $lc` | 異常 |
| 011 PDM → PDM | `mvp $p@g $p@g` | 各グループ（*） | 異常 | 異常 | 異常 | 異常 |
| 100 DRAM → PDM | `mvp $d@g $p@g` | 各グループ（*） | 異常 | 異常 | 異常 | `mvd $d $p@g` |
| 101 L2BM → PDM | `mvp $lc@g.l $p@g` | `mvp $lc@.l $p` | `mvr2 $lc@g $p@g` | 異常 | `mvr $lc $p@g` | `mvd $lc $p@g` |
| 110 L2BM → DRAM | `mvp $lc@g.l $d@g` | `mvp $lc@.l $d` | `mvr2 $lc $d` | `mvr4 $lc $d` | `mvr $lc $d` | 異常 |

（*）はアセンブラが作らない組。公式は表のとおりに動くので、RTL も実装した。各形の転送の対応は `mvmodel.plan()`、SDM 3.5.8 と同じ（下の DRAM の歩き方を除く）。

### DRAM の歩き方と間接参照

- 各グループの DRAM はチャンク（16 長語）i ごとに歩く: 直接参照で `adra × 16 + 16 i`（WP06 の修正 `5f0ceb1` と同じ）。mvb4 / mvr4 は L2B c の分がチャンク 2i + c。
- 間接参照のチャンク i: `16 × (DAR[(M + i / N) mod 1024] + i mod N)`（N = nd）。
  **nd = 0（省略）は N 無限大: `16 × (DAR[M] + i)`**（エントリ M を使い続け、オフセットが増える）。SDM 3.5.6 の本文の「DAR[M + i]」とも Rust Sim（`DAR[(M + i) mod 1024]`、オフセット 0）とも違う（WP33 の報告「未解決の点」）。
- DAR はグループごと。N_L2B = 1 では DAR 0 だけがあり、グループ 1〜3 の DRAM は存在しないので読まない（0）・書かない。

### 縮小トポロジ（N_L2B = 1）

存在するのはグループ 0（PDM 0、DRAM 0、DAR 0）と L2BM n0c0。存在しないユニットへの転送は捨て、その転送元は読まない（範囲も検査しない）。存在しないユニットからの読み出しは 0。

### 縮約

縮約の入力は 2 個（mvr2）、4 個（mvr4）、8 個（mvr）の L2BM。N_L2B = 1 では n0c0 の値 x（n0c0 が入力に含まれないときは 0）と 0 の縮約になる（`mn_mv_red`）:
fadd は x（指数部 0 は +0、全 1 は仮数 0 の無限大）、max は符号 0 なら x で 1 なら +0、min はその逆、iadd / bor は x、band / and は 0、or は 0 でないレーンの LSB が 1。
`mn_l2bm` の `RRN` = 2 の 1 入力の縮約と同じ規則で、全演算・全精度を公式と照合した（`red_*` 試験。特殊値を含むデータ）。

### 順序

- 公式は MV を発行の時点で完了させる。前後の j 語・m 語との順序は命令の並びどおり（ハザード検査に通る並びで）。
- MV の中では、すべての読み出しが書き込みの前（PDM → PDM で範囲が重なっても転送元の元の値が写る）。RTL は転送先が転送元より上なら後ろから写す。

### タグと wait

- 完了した MV のタグごとに「完了したが wait していない数」がある。wait はそれが 1 なら消費して通る。0 なら止まったままになり（後の語は実行されない）、2 以上なら公式は異常終了する。
- 同じタグを wait の後に再び使うのは正しい（`w_reuse`）。2 回目の wait は 1 回目で消費されているので止まる（`w_twice`）。発行の前の wait も止まる（`w_before`）。
- 何もしない形（mmode 111 など）でもタグは数える。`valid` = 0 は数えない。

## E_RANGE / E_UNSUPPORTED

- E_RANGE: 存在するユニットへの実際のアクセスで、折り返した後のアドレスが L2BM 2^L2AW、PDM 2^PDM_AW、DRAM 2^DRAM_AW 以上。検査の走査で見つけ、何も書かない。
- E_UNSUPPORTED（公式が異常終了する語）: 形の表の「異常」（`tmode`）、縮約の演算が表にない（`srcid`）、縮約で dmode 11（`dmode`）、nw = 0 または 4 の倍数でない（`nw`）。

## 時間

`python mncore/sim/tb/mv/timing.py`（試験のコアで 1 語だけの RUN。取り出し、検査、転送、完了まで。コアのクロック数）。
転送は 16 長語のチャンクごとに「転送元を 16 長語読んでバッファに置く → 転送先に 16 長語書く」を繰り返す（読みと書きは重ねない）。

| m 語 | a: コア 27 MHz、SDRAM 108 MHz | b: 54 MHz 単一クロック |
| --- | ---: | ---: |
| `mvp/n64 $d0@0 $lc0@0.0`（DRAM → L2BM、64 長語） | 183 | 262 |
| `mvp/n64 $lc0@0.0 $p0@0`（L2BM → PDM、64） | 156 | 158 |
| `mvp/n64 $p0@0 $d1024@0`（PDM → DRAM、64） | 183 | 335 |
| `mvp/n2048 $d0@0 $lc0@0.0`（DRAM → L2BM、2048） | 5,551 | 7,953 |
| `mvp/n2048 $lc0@0.0 $d4096@0`（L2BM → DRAM、2048） | 4,744 | 4,848 |
| `mvp/n1024 $d32768@0 $p0@0`（DRAM → PDM、1024） | 2,833 | 5,442 |
| `mvrdfadd/n64 $lc0 $d512`（縮約。N_L2B = 1 では DRAM 0 のチャンク 1 つ） | 45 | 47 |
| `mvb/n128 $d64 $lc256`（チャンクの 3/4 は 0 を書く） | 214 | 252 |
| `mvd/n64 $lc64 $p0@0`（L2BM 64 → PDM 512。7/8 は 0 を書く） | 716 | 1,131 |
| `mvp/n64 $p0@0 $lc512@0.1`（転送先が存在しない: 何もしない） | 24 | 24 |

27 MHz で 64 長語の転送は約 7 µs。SDRAM の読み出しは 1 長語ずつの要求を続けて出し、応答を順に受ける（`sdr_bus64` の先読みは 2 本まで）。

## 資源

`synth_gowin -family gw2a -nowidelut`、既定のパラメータ（`python mncore/sim/tb/mv/synth_stat.py [--flat] [--top mvt_core]`）。

| 対象 | LUT | ALU | FF | SSRAM | BSRAM | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mn_mv`（平坦化） | 1,074 | 206 | 226 | 32 | 0 | 0 |
| うち `mn_mv_red` / `mn_mv_tags`（階層） | 155 / 33 | 0 / 9 | 0 / 9 | 0 / 16 | 0 | 0 |
| `mvt_core`（`mn_mv` + `mn_l2bm` RRN = 2・DAR = 1 + L1BM + 命令メモリ、階層） | 2,682 | 502 | 840 | 32 | 27 | 0 |

LUT 換算（LUT + ALU + 8 × SSRAM）は `mn_mv` で 1,536（20,736 の 7.4%）。SSRAM はチャンクのバッファ 16 とタグ 16。BSRAM は使わない。

## テスト

`python mncore/tools/simrun.py mv [--lint] [--synth]`（`mncore/sim/tb/mv/`）。試験は公式エミュレータの結果を期待値にしたもの（`gen_tests.py` が作る `fixed/mv.tst`）。
実機: `python mncore/fpga/mv_test/build.py --program`、`python mncore/fpga/mv_test/hwrun.py`。詳細は `mncore/status/WP-33.md`。

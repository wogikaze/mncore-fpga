# rtl/l2bm: L2BM ユニット（WP32）

1 つの L2B の L2BM（`L2BM_DEPTH` = 2^AW 長語）、L2BM 命令（L2BM ⇔ L1BM の転送、L1BM 間の内部マルチキャスト）、
グループの DAR と DAR バッファ（`l2bmdars` / `l2bmdarw`）を持つ単体のユニット。
L1BM の中身へは、WP31 の `mn_l1bm` のポート B を通してアクセスする。`mn_core` への組み込みは WP37、MV 側（L2BM のポート B と DAR の読み出し）は WP33 が使う。

## モジュール

| ファイル | モジュール | 役割 |
| --- | --- | --- |
| `mn_l2bm.v` | `mn_l2bm` | ユニット本体。L2BM（BSRAM 8 個）、DAR（1024 × 32bit、BSRAM 2 個）と DAR バッファ（512 × 32bit、BSRAM 1 個）、転送の順序制御、縮約、範囲検査、L1BM へのマスタポート、ポート B、DAR の読み出しポート |

縮約には WP31 の `mn_l1bm_rrn`（`rtl/l1bm/mn_l1bm_rrn.v`）をそのまま使う（`RRN` = 1）。

## パラメータ

| 名前 | 既定 | 意味 |
| --- | --- | --- |
| `N_L1B` | 1 | L2B の L1B 数（1〜8、契約 §3）。L1B 0〜N_L1B-1 が存在する |
| `AW` | 11 | L2BM の深さ 2^AW 長語（契約 `L2BM_DEPTH` = 2048。実チップは 15） |
| `L1AW` | 10 | 範囲検査に使う L1BM の深さ 2^L1AW（契約 `L1BM_DEPTH` = 1024。`mn_l1bm` の `AW` と同じ値にする） |
| `RRN` | 1 | 1: 縮約に `mn_l1bm_rrn` を使う（任意の N_L1B）。2: N_L1B = 1 専用の小さな縮約（各レーンが L1B 0 の値と、0 または単位元の縮約になることを使い、1 長語を 1 クロックで作る）。0: bor だけ（`l2bm@n` は使える。ほかの縮約は E_UNSUPPORTED） |
| `DAR` | 1 | 1: DAR と DAR バッファを持つ（BSRAM 3 個）。0: 持たない（`l2bmdars` / `l2bmdarw` は E_UNSUPPORTED） |
| `CLEAR` | 1 | 1: リセット後に L2BM、DAR、DAR バッファを 0 にする（max(2^AW, 1024) クロック、その間 `idle` = 0） |
| `REPLICA` | 0 | 1: 複製規則（WP37、`mncore/wp/WP-3x.md` の M2 の判断）。存在しない L1B b を L1B b mod N_L1B の複製とみなして読む（下の「存在しない L1B」）。N_L1B は 2 のべき |

M2（1 L2B・1 L1B、hello_world は `l2bmrhfadd` を使う）では `N_L1B` = 1、`RRN` = 2 が安い。MV の間接参照を使わないなら `DAR` = 0 で BSRAM が 3 個減る。

## 境界のポート（PE コア ⇔ mn_l2bm ⇔ mn_l1bm）

### 語の欄（`mn_dec_j` の出力をそのままつなぐ。start から done まで変えない）

- L2BM の欄: `ll`、`l1bm_gwrite`、`l1bm_gadr`、`l2bm_lwrite`、`l2bm_bdmode`、`l2bm_ladr`、`l2bm_l1adr`、`l2bm_immode`、`l2bm_dmode`、`l2bm_opcode`、`l2bm_darsend`、`l2bm_darwrite`。
- 同じ語の L1BM の欄（L1BM への書き込みの順序に使う）: `l1bm_bmode`、`l1bm_lwrite`、`l1bm_me`、`l1bm_ladr`、`l1bm_wl`。

### 欄から決まる出力（組み合わせ回路）

| 信号 | 意味 |
| --- | --- |
| `act` | L2BM 命令がある語（`ll` = 01 / 11 で `gwrite` / `lwrite` / `darsend` / `darwrite` のどれか）。デコーダの `grp[MN_J_GRP_L2BM]` と同じ。start から done までの手順が要る |
| `chk_trap` | E_RANGE（L2BM の 2^AW 以上、L1BM の 2^L1AW 以上へのアクセス。実際に行うアクセスだけ。下の「範囲の検査」） |
| `chk_unsup`, `chk_field` | E_UNSUPPORTED と欄番号（`MN_J_<field>_IDX`。下の表） |

### 1 語の手順（`mn_l1bm` と合わせて）

```
start（両ユニット、idle のとき。L2BM 側は act の語だけ）
   ├─ mn_l1bm: src_we × (全 PE・全サイクル)、res_req → res_valid × (必要な PE・サイクル)
   └─ mn_l2bm: 前半（L1BM の読み出し、L2BM への書き込み、DAR）を自分で進める
mn_l2bm の pre_done = 1 を待つ
mn_l1bm.commit → mn_l1bm.done
mn_l2bm.commit → 後半（L1BM への書き込み）→ mn_l2bm.done（1 クロックのパルス）
act でない j 語（ll = 00 の語も）を 1 つ実行するごとに mn_l2bm.skip を 1 クロック 1 にする（m 語では出さない）
```

- 前半は L1BM → L2BM（縮約、`l2bm@`、結合）の L1BM の読み出しと L2BM への書き込み、`l2bmdars` / `l2bmdarw`。後半は L2BM → L1BM と `l2bmi` の L1BM への書き込み。
  前半は `mn_l1bm` の commit より前、後半は後になる。これで公式エミュレータの語の中の順序（下の「語の中の順序」）と一致する。
- L1BM の欄がない語でも、`mn_l2bm` は commit を待つ（pre_done の後すぐに commit してよい）。commit が start と同時かそれより後の前半のうちに来たら覚えておく。
- `skip` は `l2bmdars` の規則（連続する `l2bmdars` の語。下の「DAR と DAR バッファ」）のためにある。`mn_l2bm` を start した語の後は出さない。
- `chk_trap` / `chk_unsup` の語は実行しない（コアが停止理由を出す）。`mn_l1bm` の `chk_*` と合わせて、E_RANGE を E_UNSUPPORTED より先に報告する。
- 時間（N_L1B = 1、start から done まで。テストベンチの `+l2time` で測った値）:

  | 命令 | クロック |
  | --- | ---: |
  | `l2bmb` / `l2bmb2`（64 長語を書く） | 200 |
  | `l2bmd`（分配、32 長語を書く） | 104 |
  | `l2bmd`（結合、32 長語を読んで 256 長語を書く） | 584 |
  | `l2bm@0`、`l2bmr`（64 長語）: `RRN` = 2 / 1 | 456 / 1,100〜7,900（`l2bmrhfadd` は 7,716） |
  | `l2bmr2`（256 長語）: `RRN` = 2 / 1 | 1,672 / 3,200〜12,600 |
  | `l2bmi`（L1B 0 に 0 を 64 長語） | 136 |
  | `l2bmdars`（256 長語 → DAR バッファ 512 エントリ） | 1,040 |
  | `l2bmdarw` だけ、何もしない語 | 16、12 |

### L1BM マスタポート（`mn_l1bm` のポート B へ）

| 信号 | 意味 |
| --- | --- |
| `lb_req_valid`, `lb_req_ready`, `lb_req_l1b[2:0]`, `lb_req_we`, `lb_req_addr[22:0]`, `lb_req_wdata[63:0]`, `lb_req_wmask[7:0]` | 契約 §6 のバスに L1B 番号を足したもの。L1B `lb_req_l1b` の `mn_l1bm` のポート B につなぐ（N_L1B = 1 では常に 0）。`wmask` は常に ff |
| `lb_req_err` | 受け付けと同時に 1（`mn_l1bm` の `b_req_err`）。読み出しの値は 0 とする（範囲検査があるので起きない） |
| `lb_rsp_valid`, `lb_rsp_rdata` | 読み出しの応答（`mn_l1bm` は受け付けの 1 クロック後） |

- 要求は 1 つずつ出す（読み出しは応答を待ってから次）。応答は要求を受け付けた L1B から返す（WP37 が L1B ごとに振り分ける）。
- ホストの空間 6（L1BM）もポート B を使う。WP37 が調停する（コアの停止中だけホストに渡せばよい）。

### ポート B（L2BM。MV 側・ホスト）

| 信号 | 意味 |
| --- | --- |
| `b_req_valid`, `b_req_ready`, `b_req_we`, `b_req_addr[22:0]`, `b_req_wdata[63:0]`, `b_req_wmask[7:0]` | 契約 §6 のメモリバス（長語単位）。`wmask` は 32bit 単位（4bit がすべて 1 の半分だけ書く） |
| `b_req_err` | 受け付けと同時に 1: アドレスが 2^AW 以上。要求は捨てる |
| `b_rsp_valid`, `b_rsp_rdata[63:0]` | 読み出しの応答（受け付けの 1 クロック後、順番どおり） |

- ユニットが同じクロックにメモリのポート（読み出しまたは書き込み）を使うときは `b_req_ready` = 0。リセット後の消去の間は書き込みを待たせる。
- MV（WP33）とホストの空間 7（L2BM）が使う。調停は WP33 / WP37。
- SDM 3.6.1.1 では、L2BM は MV 側と L2BM 命令側で別のポート（それぞれ 1R/1W）を持つ。FPGA では 1R1W の BSRAM を分け合う。

### DAR の読み出しポート（MV の間接参照、WP33）

| 信号 | 意味 |
| --- | --- |
| `dar_re`, `dar_raddr[9:0]` → `dar_rdata[31:0]` | `dar_re` = 1 のクロックの `DAR[dar_raddr]` が次のクロックから出る（`dar_re` = 0 の間は保持） |

- DAR はグループに 1 つで、L2B 0 の `mn_l2bm` に置く（N_L2B = 1 の縮小トポロジ）。DAR の 1 エントリは 32bit で、DRAM の 16 長語単位のアドレス。
- MV の間接参照のアドレス: 16 長語のチャンク i が `16 × (DAR[(M + i / N) mod 1024] + i mod N)`（`nd<N>`、`$di<M>`）。`nd1` で公式エミュレータと一致することを確かめた（`mncore/sim/tb/l2bm/l2prog.py` の DAR の観測器）。
  `nd` を省略した形は確かめていない（viz/core の記録では、公式は DRAM にアクセスしない）。WP33 で確かめること。

## 意味（公式エミュレータで確かめたもの）

正は公式エミュレータ。`mncore/sim/tb/l2bm/l2model.py`（と WP31 のモデルを合わせた `l2pe.py`）が機械語の欄で書いたモデルで、
プローブ（`probe.py`。アセンブラが作らない組み合わせは、アセンブル後に欄を手で変えた語）で公式と照合した。
記号: c = サイクル 0〜3、k = 長語、b = L1B、a = 16 × `ladr`（L2BM）、g16 = 16 × `gadr[9:1]`、g8 = 8 × `gadr`（L1BM）。

### 転送の種類（`gwrite`, `lwrite`, `bdmode`）

| gwrite | lwrite | bdmode | 命令 | 動作 |
| --- | --- | --- | --- | --- |
| 1 | 0 | 01 | `l2bmb` | 集合の各 L1B b: `L1BM_b[g16 + 16c + k] ← L2BM[a + 16c + k]`（k < 16） |
| 1 | 0 | 10 | `l2bmb2` | 集合の各 L1B b: `L1BM_b[g16 + 16c + k] ← L2BM[a + 64c + 16(b >> 1) + k]`（k < 16） |
| 1 | 0 | 00 | `l2bmd`（分配） | 集合の各 L1B b: `L1BM_b[g8 + 8c + k] ← L2BM[a + 64c + 8b + k]`（k < 8） |
| 1 | 0 | 11 | なし | 何もしない（公式はエラーにならず、何も書かない） |
| 0 | 1 | 01 | `l2bmr<op>`、`l2bm@n` | `L2BM[a + 16c + k] ← reduce(b = 0..7: L1BM_b[g16 + 16c + k])`（k < 16） |
| 0 | 1 | 10 | `l2bmr2<op>` | `L2BM[a + 64c + 16g + k] ← reduce(b = 2g, 2g + 1: L1BM_b[g16 + 16c + k])`（g < 4、k < 16） |
| 0 | 1 | 00 | `l2bmd`（結合） | immode = 111 のとき: `L2BM[a + 64c + 8b + k] ← L1BM_b[g8 + 8c + k]`（b < 8、k < 8）。immode ≠ 111 では何もしない |
| 0 | 1 | 11 | — | 公式は異常終了する → E_UNSUPPORTED |
| 1 | 1 | 00 | `l2bmi` | 集合の外の各 L1B d: `L1BM_d[16·ladr + 16c + k] ← L1BM_s[g16 + 16c + k]`、s = (l1adr & ~immode) \| (d & immode)。集合の L1B（読み出し元）は書かない。immode = 111 では結合（上の行）と同じ |
| 1 | 1 | ≠ 00 | — | 公式は異常終了する → E_UNSUPPORTED |

- **集合**（`l2bm_l1adr` / `l2bm_immode`）: L1B b は `(b & ~immode) == (l1adr & ~immode)` のとき集合に入る（SDM 3.6.7.1）。L2BM → L1BM では書き込む L1B、縮約では値を送る L1B（外は単位元）。
  `l2bmr2` にも効く（アセンブラは常に 111 を置く）。結合は immode = 111 のときだけ動く。
- **`l2bm@n` は集合 {n} の bor の縮約**（l1adr = n、immode = 000、opcode = 1100、dmode = 00）。
  opcode と集合を手で変えると、その縮約になる（UNKNOWN.md A 節の「縮約でない転送で 1100」の答え）。結合（bdmode 00）、L2BM → L1BM、`l2bmi` は opcode と dmode を見ない（表にない値でも何もエラーにならない）。
- **`l2bmi` の欄**: 読み出し元のアドレスは `gadr`（× 8）、書き込み先のアドレスは `ladr`（× 16）に入る。書き込み先は 8192 で折り返さない（ladr = 520 で L1BM 0〜1023 には何も書かない）。
- **アドレスの揃え**: 16 長語/サイクルで L1BM を読み書きする形（`l2bmb`、`l2bmb2`、`l2bm@`、`l2bmr`、`l2bmr2`、`l2bmi` の読み出し元）は `gadr[0]` を使わない（16 に切り捨て）。
  8 長語/サイクルの形（`l2bmd` の両方向）は 8 × `gadr` をそのまま使う。L2BM 側（16 × `ladr`）は 64 に揃っていなくてもそのまま足す。
- **縮約**: 精度は `dmode`（00: 64bit レーン d / l、01: 32bit f / i、10: 16bit h / s、11: 公式が異常終了）、演算は `opcode`（表外は公式が異常終了）。
  演算は `mn_l1bm_rrn` の 1 段（l2bmr は 8 入力 `nin_m1` = 7、l2bmr2 は 2 入力 `nin_m1` = 1）で、rrn ベクタ（WP03、公式と全件一致）の l2bmr / l2bmr2 と同じ。
  L2BM の hfadd は半精度のまま（`fmt` = 2、`out_half` = 0）。
- **単位元**（集合の外の L1B が送る値。レーンの幅で）: fadd / iadd / bor / or は 0、max と band は全ビット 1、min は符号以外の全ビット 1、and は 1。全演算で公式と一致（Rust Sim の `rrn::unit_value` とも同じ）。
- **存在しない L1B**（b ≥ N_L1B、契約 §3）: そこへの転送は捨てる（読み出しもしない）。集合の中で存在しない L1B は縮約に 0 を送る。結合は 0 を書く。`l2bmi` の読み出し元が存在しなければ 0 を書く。
  - `REPLICA` = 1（複製規則、WP37）: 存在しない L1B b は L1B b mod N_L1B の複製として読む: 縮約（l2bmr、l2bmr2、l2bm@）の入力、結合のスロット、`l2bmi` の読み出し元は、その L1B の L1BM の値になる。書き込みは今までどおり捨てる。範囲の検査も、読み出しは複製元のアクセスとして行う。
  - `RRN` = 2 の複製規則の縮約は、集合の中の入力 n 個（l2bmr は 2^popcount(immode) 個、l2bmr2 は L1B 2g・2g+1 のうち集合の中のもの）がすべて L1B 0 の値の縮約: fadd は値の指数に log2 n を足す（同じ値の和は正確で、丸めは 1 回。あふれは無限大、指数 0 は 0）、iadd は n 倍、max / min / band / bor は値のまま、and / or は 0 でなければ 1。n = 0 は単位元。
  N_L1B = 1 では、`l2bmi` は L1B 0 が集合の中なら何もせず、外なら 0 を書く（L1BM を読まない）。
- **noforward**（ll = 11）は L2BM 命令に影響しない。ll = 00 の語は何もしない。

### DAR と DAR バッファ

- `l2bmdars $lc<a>@.<l2b> $dar<w>`: `l2bm_l1adr`〜`l2bm_opcode` の 12bit が {w（10bit）, l2b（2bit）}。`l2bm_ladr` は a / 16。
  `DARBUF[128c + 2i] ← L2BM[a + 64c + i] の上位 32bit`、`[128c + 2i + 1] ← 下位 32bit`（i < 64、全 512 エントリ）。DAR の書き込みアドレスを w に、DAR バッファの読み出しアドレスを 0 にする。
  - l2b は bit 0 だけを使う（手で 2 にすると L2B 0、3 にすると L2B 1 を読む）。N_L2B = 1 では L2B 1 は存在しないので 0 を読む。
  - **連続する j 語の `l2bmdars`**: 直前の j 語にも `l2bmdars` があると、DAR バッファは新しい語の a から書き直すが、DAR の書き込みアドレス、DAR バッファの読み出しアドレス、L2B は、連続の最初の語のものを保つ（新しい w、l2b は使わない）。
    m 語（MV）は間に入っても連続を切らない。ll = 00 の語やほかの j 語は切る。（ハードウェアの「発行した最初のサイクル」の扱いと思われる。SDM 3.6.7.10 には書かれていない。）
- `l2bmdarw`: `DAR[w] ← DARBUF[r]` を 4 回（w は 1024、r は 512 で折り返す）。同じ語の `l2bmdars` の後に行う（新しい内容と、設定したアドレスを使う）。ほかの L2BM 命令と同じ語にあってもよい。
- `l2bmdars` の語では `bdmode`、`gadr` は使われない。`gwrite` / `lwrite` との組み合わせは欄を共有するので E_UNSUPPORTED にした。
- 初期値（リセット後）: DAR、DAR バッファ、両アドレスとも 0（最初の `l2bmdarw` は DAR[0..3] に 0 を書く）。
- 確認は MV の間接参照で行った（DAR は `d get` で読めない）。DRAM に目印を置き、`mvp/n<16n>nd1 $di<a>@0 $lc..@0.0` で読んだチャンクから DAR を求める（`l2prog.dar_lines`）。

### 語の中の順序（L1BM の欄と L2BM の欄が同じ語にあるとき）

アセンブラは、同じ語で同じ L1BM アドレスを読み書きする組み合わせも受け付ける。公式エミュレータの順序は次のとおり（プローブ 28 本。`l2pe.py` の `pre_cycle`）。

1. **読み出しはすべて語の前の状態を見る。** L1BM → PE（`mn_l1bm` の res）、L1BM → L2BM（縮約、結合、`l2bm@`）、`l2bmi` の読み出しのどれも、同じ語の書き込みを見ない。
2. **L1BM への書き込みはサイクルごとに、PE → L1BM（`mn_l1bm`）のサイクル c、L2BM → L1BM のサイクル c の順。**
   したがって、同じアドレスに両方が書くとき、L2BM 側の書き込みが勝つのは PE 側が同じかそれより前のサイクルで書いたときだけ。PE 側が後のサイクルで書くアドレスでは PE 側が勝つ。

`mn_l2bm` は、L1BM への書き込みを `mn_l1bm` の commit の後に行い、PE 側がそのアドレスを後のサイクルで書く（`l1bm_lwrite` = 1、`me` = 1、PE 側のブロック `base + c' × blk` に入り、c' > c）ときはその書き込みを捨てる。
PE 側のブロックは `mn_l1bm` と同じ（bmode 00 は 01、l1bmd: base = `ladr & ~63`・blk 64、l1bmm4@: blk 16 / 32、l1bmm@: blk 4 / 8。wl で 2 倍）。

## E_UNSUPPORTED にする語（`chk_unsup`）

| 条件 | 欄 | 理由 |
| --- | --- | --- |
| `lwrite` = 1 で bdmode = 11、または `gwrite` = `lwrite` = 1 で bdmode ≠ 00 | `l2bm_bdmode` | 公式が異常終了する |
| 縮約（`lwrite` = 1、`gwrite` = 0、bdmode 01 / 10）で dmode = 11 | `l2bm_dmode` | 同上 |
| 縮約で opcode が表にない（`RRN` = 0 では bor 以外） | `l2bm_opcode` | 同上 |
| `darsend` = 1 で `gwrite` または `lwrite` = 1 | `l2bm_darsend` | 欄を共有する。アセンブラが作らない |
| `DAR` = 0 で `darsend` / `darwrite` | `l2bm_darsend` / `l2bm_darwrite` | DAR を持たない構成 |
| N_L1B > 1 の `l2bmi` で、同じ語の PE → L1BM の書き込みの範囲が読み出し元の範囲と重なる | `l1bm_gwrite` | `l2bmi` は commit の後に読むため（N_L1B = 1 では起きない） |

- `gwrite` = 1 で bdmode = 11 の語と、immode ≠ 111 の結合は、公式どおり何もしない（E_UNSUPPORTED にしない）。
- **デコーダとの関係**: デコーダ（WP10）の `unsup_vec` は `l2bm_bdmode` = 11 と表外の `l2bm_opcode` を、語の種類に関係なく E_UNSUPPORTED にする。
  しかし `l2bmdars` の語では opcode の欄が DAR のアドレスの下位 2bit と L2B 番号を運ぶ（例 `l2bmdars $lc0@.0 $dar1` は opcode = 0100）。縮約でない転送も opcode / dmode を見ない。
  WP37 は L2BM の欄（80〜90）についてはデコーダの判定を使わず、`mn_l2bm` の `chk_unsup` を使うこと。

## 範囲の検査（`chk_trap`）

契約 §3 のとおり、実際に行うアクセスだけを検査する。

- L2BM → L1BM: 存在する集合の L1B があるときだけ。L2BM の読み出し（`l2bmb2` / `l2bmd` は存在する最大の L1B の分まで）と L1BM の書き込み。
- L1BM → L2BM: L2BM の書き込み（全スロット。存在しない L1B の分は 0 を書く）と、存在する集合の L1B の L1BM の読み出し。
- `l2bmi`: 存在する書き込み先があれば、その範囲（16 × `ladr` + 63。折り返さない）。存在する読み出し元があれば、その範囲。
- `l2bmdars`: L2B 0 を読むときだけ（連続の `l2bmdars` では最初の語の L2B）、a + 255。
- アドレスは折り返す前の値で比べる（AW < 15、L1AW < 13 の縮小構成では、範囲内のアクセスは折り返さないので契約 §3 と同じ）。実チップの大きさ（AW = 15、L1AW = 13）では、末尾を越えるアクセスも E_RANGE になる（公式は折り返す）。

## 資源（`synth_gowin -family gw2a -nowidelut`、AW = 11、平坦化）

`python mncore/sim/tb/l2bm/synth_stat.py --flat --param RRN=2 ...`

| 構成 | LUT | ALU | FF | SSRAM | BSRAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| N_L1B = 1、`RRN` = 1（`mn_l1bm_rrn`） | 2,085 | 728 | 503 | 0 | 11 |
| N_L1B = 1、`RRN` = 2 | 1,051 | 216 | 139 | 0 | 11 |
| N_L1B = 1、`RRN` = 0 | 755 | 216 | 138 | 0 | 11 |
| N_L1B = 1、`RRN` = 2、`DAR` = 0 | 927 | 196 | 120 | 0 | 8 |
| N_L1B = 1、`RRN` = 0、`DAR` = 0 | 637 | 197 | 119 | 0 | 8 |
| N_L1B = 8、`RRN` = 1 | 2,107 | 773 | 439 | 16 | 11 |

BSRAM: L2BM 8、DAR 2、DAR バッファ 1。DSP は使わない。

## テスト

`python mncore/tools/simrun.py l2bm [--lint] [--synth]`（`mncore/sim/tb/l2bm/`）。試験は公式エミュレータの結果を期待値にしたもの（`gen_tests.py` が作る `fixed/l1.tst`・`fixed/l8.tst`）。詳細は `mncore/status/WP-32.md`。

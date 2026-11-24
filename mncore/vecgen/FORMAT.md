# vecgen: ユニットテスト用ベクタ（`.vec`）の形式

`mncore/vecgen` は、RTL のユニット（整数 ALU、FP 系 ALU、MAU のベクトル演算、FP の基本関数、RRN の縮約）を単体で検証するためのベクタを作る。
期待値は Rust Sim（`third_party/mncore/viz/core`）を**ブラックボックスとして実行して**得る。

- 1 命令だけの VSM を Sim の構文解析器で読み、Sim の `exec` で実行する。
- 入力は Sim の PE メモリに置き、結果を Sim の PE メモリから読む。viz/core のロジックはコピーしていない。
- 同じ命令と同じメモリ内容を VSM プログラム（`d set` / 命令 / `d get`）にして、公式のアセンブラとエミュレータでも実行できる（`--check-official`）。

## 使い方

```
cd mncore/vecgen
cargo run --release -- <unit|all> --n <count> --seed <s>      # 生成
cargo run --release -- <unit|all> --check-official [--sample K|all]
cargo run --release -- fixed [--rows 50]                      # vectors_fixed を作り直す
cargo run --release -- list <unit|all>                        # ファイルの一覧
```

| オプション | 既定 | 意味 |
| --- | --- | --- |
| `--n` | 1000 | 1 ファイルあたりのランダム行の数。境界値の行はこれとは別に必ず入る。SDM にない形（後述の `sdm=no`）は `n/4` |
| `--seed` | 1 | 乱数の種。ファイルごとに `seed` とファイル名から独立の系列を作るので、ほかのファイルの追加や削除で値が変わらない |
| `--out` / `--in` | `mncore/sim/vectors` | 出力先と、照合で読むディレクトリ（`<dir>/<unit>/<op>.vec`） |
| `--only TEXT` | なし | ファイル名に TEXT を含むものだけを処理する |
| `--sample K` | 256 | 照合する行数（ファイルごと）。半分は境界値の行から選ぶ。`all` なら全行 |
| `--work DIR` | `vecgen/target/official/<unit>` | 照合で作る VSM、asm、dump、CSV、不一致の一覧（`<op>.mismatch.txt`）の置き場所 |

照合は `scripts/run_official.sh` を WSL の bash で実行する（Windows では `wsl -d Ubuntu -- bash ...` を内部で呼ぶ）。
公式ツールの場所は `MNCORE_EMU_DIR`（既定は `~/wgkz/mncore/judge/judge-py/mncore2_emuenv`）、WSL の配布名は `VECGEN_WSL_DISTRO`（既定 `Ubuntu`）、並列数は `VECGEN_JOBS`（既定 8）で変えられる。

## 共通の形式

```
# vec v1 unit=alu op=iadd prec=i lanebits=32 dmode=01 aluop=00000 is_unsigned=0 inputs=2 sdm=yes seed=1 edge=221 rows=1221 cols: ra rb x_hi x_lo y_hi y_lo | z_hi z_lo flags
0 0 0000000000000000 55df440c14d6b406 0000000000000001 1a3062c7f6653f8f | 0000000000000001 55df440c14d6b406 f
```

- 1 行目はヘッダ。`# vec v1` の後に `key=value` が並び、`cols:` の後に列名がある。`|` の左が入力、右が期待値。
- 2 行目以降が 1 行 1 ベクタ。値はすべて小文字の 16 進で、列ごとに桁数が決まっている（バスの半分は 16 桁、フラグや制御ビットは 1 桁）。
- **先頭の `edge` 行が境界値の行**（組み合わせの作り方は決まっていて、詰め物のビットや一部の仮数だけを種から作る）で、その後がランダム行。`rows` は全行数。
- 2 長語（128bit）のバスは `_hi`（上位 64bit）と `_lo`（下位 64bit）の 2 列に分ける。
  Verilog では `{x_hi, x_lo}` が `[127:0]` で、bit 127 が 1 語目（MSB 側の語）の MSB。SDM 1.3 の並びと同じく、要素は MSB 側から順に詰まっている（倍精度 1 要素、単精度 2 要素、半精度 4 要素が上位の長語に入る）。
- `flags` は、その命令がマスクレジスタ（`$omr`）に書くそのサイクルの 4 ビット。bit 3 が MSB 側の要素に対応する（SDM 3.6.12.1、3.6.9.26）。

### 共通のヘッダ項目

| 項目 | 意味 |
| --- | --- |
| `unit` | ユニット名（ディレクトリ名と同じ） |
| `op` | VSM のオペコード（`fp` では演算の名前） |
| `sdm` | `yes`: SDM に書かれた形。`no`: アセンブラもエミュレータも受理するが、SDM には書かれていない形（`u` を付けられないはずの命令の `u` 付き、単精度の出力丸め `fv*r` など） |
| `seed`、`edge`、`rows` | 乱数の種、境界値の行数、全行数 |
| `disputed` | 公式エミュレータとの照合で不一致がある（後述）。値は理由の短い名前（複数なら `+` でつなぐ） |
| `excluded` | `vectors_fixed` だけ。`disputed` の理由で該当行を除いた |

機械語の欄（`dmode`、`aluop`、`is_unsigned`、`iselb` など）は、`assemble3 --print-csv` の同名の欄の値（2 進）である。
`--check-official` は、各命令をアセンブルした CSV の欄がヘッダおよび行の制御ビットと一致するかも確かめる。
あわせて、flat の `j` 語の中の位置（pos は左端を 0）も確かめている。ALUC は CSV の並びどおり 145..161。
MAUC（116..144）は CSV ヘッダの並びと違い、dmode 116、enfma 118、round_out 120、signa 126、signc 127、passa 128、zeroc 129、mdw/side 130、exta 132、extb 133、extc 134、signb 135、isela 136、iselb 139、iselc 142 である（mmode 119、mw 121、ma 122、readh 131 は検体で常に 0 だったので推定）。

### メモリ配置と命令

すべてのベクタは次の配置で、1 行を 1 つの (PE, サイクル) で評価した結果である。

| オペランド | 置き場所 | 命令中の表記 |
| --- | --- | --- |
| 第 1 入力（ALU の x、MAU の a） | GRF0 | `$llr0v`（2 長語、4 サイクル） |
| 第 2 入力（ALU の y、MAU の b） | GRF1 | `$lls0v` |
| 第 3 入力（MAU の c。`vadd` では 2 番目のオペランド） | LM0 | `$llm0v` |
| 結果 | LM1 とマスクレジスタ 1 | `$lln0v $omr1` |

入力はすべて 2 長語アクセスで読むので、入力列の 128bit は命令が受け取るバスそのものである。
命令が使わないビット（たとえば `fvfma` の LSB 側の長語）にも乱数が入っている。RTL はそれを無視しなければならない。

## unit `alu`（整数 ALU、WP11）

ファイル: `[u]<p><op>.vec`（`p` は `l` / `i` / `s`）。op は add、sub、inc、dec、not、and、or、xor、max、min、passa、lsl、lsr、bsl、bsr、lnot、packbit。
ほかに `zero.vec`、`imm.vec`、`immu.vec`、半語（`s`）の `r` 付き `<op>.r.vec`。

```
cols: ra rb x_hi x_lo y_hi y_lo | z_hi z_lo flags
```

| 列 | 桁 | 意味 |
| --- | --- | --- |
| `ra`、`rb` | 1 | x、y に `r` オプション（単精度 4 語を半精度 4 語に丸めてから入力。SDM 3.6.12.19）を付けたか。ALUC の `rounda` / `roundb` |
| `x_*`、`y_*` | 16 | 入力バス（丸めの前）。1 入力の命令では y は使われない（乱数の詰め物） |
| `z_*` | 16 | 結果の 2 長語 |
| `flags` | 1 | マスクフラグ |

ヘッダ: `prec`、`lanebits`（要素のビット数 64 / 32 / 16）、`dmode`、`aluop`、`is_unsigned`、`inputs`（1 か 2）。
`zero` には `isela=0101`、`iselb=000` も付く（多重化された命令の判別に使う欄）。

- `imm.vec` / `immu.vec` は列が異なる: `cols: imm | z_hi z_lo flags`。`imm` は 32bit の即値ペイロード（`imm ui"0x..."`）。
  即値の命令では ALUC の `dmode`、`rounda`、`roundb`、`isela`、`iselb` に即値のビットが入るので、ヘッダには `aluop` と `is_unsigned` だけを書いた。
- **`u` 付きの形**: SDM で `u` を受け付けるのは add、sub、inc、dec、max、min、lsr（ftoi）だけだが、アセンブラはほかの命令にも `u` を付けて `is_unsigned=1` を出す。これらも `sdm=no` として生成した（エミュレータも受理し、照合ではすべて一致した。結果は `u` なしと同じ）。
- **`r` 付きの形（`.r.vec`）**: 行ごとに `(ra, rb)` が `(1,0)`、`(0,1)`、`(1,1)` のどれか（1 入力の命令は `(1,0)`）。
  アセンブラはどの精度でも `r` を受理するが、**エミュレータは半語（dmode=10、つまり h と s）以外では実行時に止まる**（`ialuc.rounda can be used only with half-word`）。そのため `r` 付きは s（と fpalu の h）だけを作った。

境界値の行（`edge`）:
- 2 入力: 要素の特別な値 21 種（0、1、2、3、-1、-2、符号ありの最大と最小とその隣、w-1、w、w+1、2w-1、2w、2w+1、0x55..、0xaa..、半分の位置のビット、など。w は要素のビット数）の全組み合わせを、要素に詰めたもの。
- シフト（lsl、lsr、bsl、bsr）: さらに 5 種の x に対して、シフト量 0〜2w+2 と、2w の倍数を足した大きなシフト量。
- 1 入力: 特別な値の各々。
- `r` 付き: 丸めの特別な値（半精度の最大値、最大値＋半 ulp（偶数丸めで ∞）、最小の正規化数とその直下、丸めの同点とその前後、範囲外、±0、±∞、指数 0 で仮数が 0 でない値）。2 入力で両方に `r` を付けた行は、それらの全組み合わせ。

## unit `fpalu`（FP 系 ALU、WP13）

ファイル: `[u]<p><op>.vec`（`p` は `d` / `f` / `h`）。op は passa、rsqrt、packbit、relu、relu1、relu2、relu3、lrelud、lreluo、ilrelud、max、min、floor、ftoi。
`relu0` は `relu` と同じ機械語（aluop=10100）なので作っていない。
h の各命令には `r` 付きの `<op>.r.vec` がある（`sdm=yes`）。列は `alu` と同じ。

`floor` と `ftoi` は aluop=11110 を共有し、`iselb`（floor=110、ftoi=111）で区別する。ヘッダの `iselb` はこの意味である。

境界値の行:
- max、min: 浮動小数点数の特別な値 36 種（±0、指数 0 で仮数が 0 でない値、±∞、仮数が 0 でない ∞、最大と最小の正規化数、1、1+ulp、2-ulp、0.5、1.5、2 など）の全組み合わせ、および x と y が 1 ビットだけ違う組。
- relu、relu1〜3: x の上位 4 ビットの 16 通り × y の特別な値。
- lrelud、lreluo、ilrelud: x = ±1、±0 × y の指数部を端から端まで（半精度は全 64 通り、ほかは両端と中央）、仮数 0、1、全 1、乱数、両符号。
- floor、ftoi: 不偏指数 -3 から（仮数長＋2、ftoi は整数の幅＋2）まで、仮数 0、1、全 1、0.5 の位置、乱数、両符号、および特別な値。
- rsqrt: 仮数の上位 4 ビットの 16 通り × 指数 0、1、2、3、bias±2、最大付近、∞ × 両符号。
- packbit、passa: 特別な値。

### ブロックフロート化（`dbfn`、`fbfn`、`gbfn`、`hbfn<n>`、`hbfe<n>`）

`bfn` / `bfe` は MAB の 4 PE をまたぐ（SDM 3.6.12.12、4.4）。1 行が 1 MAB の 1 サイクル分である。

```
cols: ra x0_hi x0_lo x1_hi x1_lo x2_hi x2_lo x3_hi x3_lo | z0_hi z0_lo z1_hi z1_lo z2_hi z2_lo z3_hi z3_lo f0 f1 f2 f3
```

- `xP_*`、`zP_*` は MAB 内の PE P（0〜3）の入力と結果。`fP` は PE P のマスクフラグ（常に 0）。
- ファイル名の `hbfn6` は `hbfn/6`。ヘッダの `bf_n` は仮数長 n、`bf_keep` は残す仮数のビット数、`iselb` は `9-n`（d/f/g は 000）。
- ブロックの組み方は Sim と同じ: d は各 PE の上位長語 4 個で 1 ブロック。f は上位長語の上位の単語 4 個と下位の単語 4 個の 2 ブロック。g は上位長語の単語 8 個で 1 ブロック。h は各 PE の上位長語の半語 16 個と下位長語の半語 16 個の 2 ブロック。d / f / g では下位の長語の結果は 0。
- `.r.vec` は `ra=1`（入力を単精度 4 語として半精度に丸めてから変換。h だけ）。
- 境界値の行は 12 種の作り方 × 16 回: 指数が全部 0、∞ を含む、最大の要素の残す仮数が全 1（共通指数 +1）、共通指数が範囲の上端に届く、指数差 0、1、2…、拡張表現の境界（最大の要素との指数差 5〜7、上位の仮数が全 1 かどうか）、0 の混在、シフトで落ちるビットがちょうど半分（丸めの同点）、全部同じ指数、指数が小さい値だけ、指数が広く散らばる、特別な値。

## unit `mau`（MAU のベクトル演算、WP12 の `mn_mau_vec`）

ファイル: `dvfmau`、`dvfmad`、`dvmulu`、`dvmuld`、`dvadd`、`dvpassa`、`fvfma`、`fvmul`、`fvadd`、`fvpassa`、`hvfma`、`hvmul`、`hvadd`、`hvpassa` と、それぞれの出力丸め付き（末尾 `r`）の 28 個。
`gv*` はアセンブラが受理しない（疑似単精度は行列演算とブロックフロート化だけ）。

```
cols: pe signa signb signc exta extb extc a_hi a_lo b_hi b_lo c_hi c_lo | z_hi z_lo flags
```

| 列 | 意味 |
| --- | --- |
| `pe` | MAB 内の PE の位置（0〜3）。`dvfmau` / `dvmulu` は PE 0、1 だけが乗算し、`dvfmad` / `dvmuld` は PE 2、3 だけが乗算する（ほかの PE では積を 0 として c だけを足す。SDM 3.6.9.10） |
| `signa`〜`signc` | 入力の符号反転（オペランドの前の `-`、SDM 3.6.9.22）。MAUC の同名の欄 |
| `exta`〜`extc` | MAUC の同名の欄。d と f では精度拡張（オペランドの後の `e`。単精度→倍精度、半精度→単精度）。**h の `exta` / `extb` は単精度からの丸め（オペランドの後の `r`、SDM 3.6.9.24）**、h の `extc` は精度拡張（`e`） |
| `a_*`、`b_*`、`c_*` | 入力バス（オプションを適用する前）。命令が読まないオペランドは乱数の詰め物（mul の c、add の b、passa の b と c） |
| `z_*`、`flags` | 結果と、結果の符号ビットを反転したマスクフラグ |

ヘッダ: `prec`、`kind`（fma / mul / add / passa）、`lanes`、`fmt_ab` / `fmt_c` / `fmt_z`（a と b、c、結果の幅）、MAUC の `dmode`、`enfma`、`mmode`、`round_out`、`mdw_side`（CSV の `mdw/side`）、`passa`、`zeroc`、`mul_pes`（乗算する PE の位置）。

- add の 2 番目のオペランドは c の側に入る（`fvadd a c`、b は 1）。passa は b=1、c=0（SDM 3.6.9.1）。
- オプションの組み合わせは、命令が読むオペランドについて全通り（fma は 64、mul と add は 16、passa は 4）。行ごとに異なる。
- 境界値の行: 組み合わせごとに 48 要素ずつ、a、b、c の特別な値（オプション適用前の形式で 12 種。h の `r` は丸めの特別な値）の直積を順に取る（組み合わせをまたいで続くので、全体で直積を一巡する）。PE の位置は 0〜3 を順に回す。
- ランダム行の fma（オプションなし）は 1/3 の確率で c ≈ -(a×b)（打ち消し）。

## unit `fp`（FP の基本関数、WP12 の `mn_fp_fma`）

1 行が 1 要素の `z = round(a × b + c)`（SDM 4.3）。

```
cols: a b c | z            （cvt_f2h だけは cols: a | z）
```

ファイル: `<kind>_<p>[r].vec`。kind は fma、mul、add、passa、p は d / f / h、`r` は出力の精度縮減。

| p | a、b | c | z | 評価に使う命令 |
| --- | --- | --- | --- | --- |
| d | 倍精度 | 倍精度 | 倍精度（`r`: 単精度） | `dvfmau`（PE 0、1）、`dvmulu`、`dvadd`、`dvpassa` |
| f | 単精度 | 単精度 | 単精度（`r`: 半精度） | `fvfma`、`fvmul`、`fvadd`、`fvpassa` |
| h | 半精度 | 単精度 | 単精度（`r`: 半精度） | `hvfma`、`hvmul`、`hvadd`、`hvpassa` |

- 列の桁数は形式の幅に合わせる（倍精度 16 桁、単精度 8 桁、半精度 4 桁）。
- **b と c は実際の演算に入る値**である。mul の c は +0（`0`）、add の b は 1.0、passa の b は 1.0 で c は +0。したがって、どのファイルも `z = fma(a, b, c)` として FMA コアに与えればよい。
- 境界値の行:
  1. 特別な値の直積（fma は 12 種の 3 乗、mul と add は 36 種の 2 乗、passa は 36 種）。
  2. 打ち消し: c ≈ -(a×b)（±3 ulp）。単精度と倍精度では、部分積の省略（SDM 4.3）が効くように a と b の仮数の下位ビットを立てた行も入れた。SDM 4.3 の例 `(2^20+1)^2 - 2^40` も入れた。
  3. 最終の丸めの同点とその前後: 出力形式の格子の上にある積に、半 ulp、半 ulp より少し大きい・小さい c を足す。mul では仮数の短い数どうしの積。passa の出力丸めでは落ちるビットが `10..0` とその前後。
  4. 出力形式の最大値の付近（あふれ）: 最大値に半 ulp を足すと偶数丸めで ∞ になる場合、それより少し小さい場合、大きな数どうしの積。
  5. 出力形式の最小の正規化数の付近（アンダーフロー）: 積や和がその直下、直上、丸めで最小の正規化数に上がる場合。
  6. 加算器の格子への c の位置合わせ（単精度と倍精度）: 積の指数と c の指数の差を K-6〜K+4（K = 残す部分積の桁数 + 仮数長。単精度 41、倍精度 88）で振り、c の下位ビットのスティッキーを確かめる。差が K+2 以上なら c は捨てられる（NUMERICS.md）。
- `cvt_f2h.vec`: ALU の `r` オプションの単精度→半精度の丸め（`hpassa $llr0vr` で評価）。
- `cargo test` は、どの行も `float::vfma`（Sim が使う関数）を直接呼んだ結果と一致することを確かめる。

## unit `rrn`（RRN の縮約、WP31/WP32）

1 行が 1 要素の縮約である。

```
cols: x0 x1 ... x(N-1) | z
```

| ファイル | 命令 | N | 入力の並び |
| --- | --- | --- | --- |
| `l1bmr<op>.vec` | `l1bmr<op> $lr0v $lb0`（PE → L1BM、16×1） | 16 | MAB 0〜15（2 段: 4 MAB ずつ縮約し、その 4 個を縮約） |
| `l1bmr4<op>.vec` | `l1bmr4<op> $lr0v $lb0`（4×4） | 4 | MAB 4g〜4g+3 |
| `l2bmr<op>.vec` | `l2bmr<op> $lb0 $lc0`（L1BM → L2BM、全 L1B） | 8 | L1B 0〜7 |
| `l2bmr2<op>.vec` | `l2bmr2<op> $lb0 $lc0` | 2 | L1B 2g、2g+1 |

- op は dfadd、ffadd、hfadd、dmax、fmax、hmax、dmin、fmin、hmin、liadd、iiadd、siadd、lband、iband、sband、land、iand、sand、lbor、ibor、sbor、lor、ior、sor。
- 値の幅は op の精度による（d / l は 16 桁、f / i は 8 桁、h / s は 4 桁）。ヘッダの `lanebits` も同じ。
- 1 長語に入る要素（d は 1 個、f は 2 個、h は 4 個）は独立に縮約される。行は要素ごとに分けてある。
- `l1bmrhfadd` は Sim では「単精度に拡張して 1 段目を単精度で丸め、2 段目で半精度に丸める」（NUMERICS.md）。
- 精度拡張（`e`）と出力丸め（`r`）の付いた L1BM の縮約、`l2bmr` の L1B 集合の指定（`@`）は作っていない。
- 境界値の行: 特別な値の 2 個を先頭と末尾に置き残りを 0 にした全組み合わせ、指数差・丸めの同点・打ち消し・あふれ・±∞ の混在・±0・全部同じ・符号違い（浮動小数点）、全 1・特別な値・1 ビットずつ（整数）。

## 公式エミュレータとの照合で分かったこと

`--check-official --sample all` で全ファイルの全行を照合した。結果は報告書 `mncore/status/WP-03.md` にある。
Sim と公式エミュレータが食い違った行は、**値を Sim のまま残し**、ヘッダに `disputed=<理由>` を付けた（契約 §1: 勝手にどちらかに合わせない）。
`vectors_fixed` には食い違う行を入れていない（そのファイルのヘッダには `excluded=<理由>` がある）。

| 理由 | 対象 | 内容 |
| --- | --- | --- |
| `r_round` | `alu/*.r.vec`、`fpalu/*.r.vec`、`fp/cvt_f2h.vec` | ALU の `r` オプションの単精度→半精度の丸めが違う。公式は「符号はそのまま、指数 = 単精度の指数 - 96 + 仮数の丸めの繰り上がり を 0〜63 に飽和、仮数 = 23 ビットを 9 ビットに最近接偶数丸め」で、0 への切り捨てや ∞ の仮数の消去をしない（-0 は 0x8000、下にあふれた値は指数 0 で仮数が残る、∞ や上にあふれた値は指数 63 で仮数が残る）。Sim は通常の丸め（下にあふれたら +0、∞ の仮数は 0、-0 は +0）。この式は `cvt_f2h` の照合した全行で公式と一致した |
| `ext_mul` | `mau` の d と f の fma、mul（出力丸め付きを含む）の、`exta` か `extb` が 1 の行 | 精度拡張した a / b を掛けた結果が違う。公式は拡張した値どうしを正確に掛ける（拡張後の仮数の下位ビットは 0 なので、SDM 4.3 の部分積の省略は効かない）。Sim は拡張前の短い仮数のまま `float::vfma`（`mul_exact`）に渡すため、省略の補正を誤った位置にかける（c の位置合わせの基準もずれる）。add と passa では不一致は出なかった |
| `fvr_flags` | `mau/fv*r.vec`（SDM にない単精度の出力丸め）の全行 | マスクフラグが違う。公式は半精度 2 個の結果に bit 3、bit 2 を 1 ビットずつ（bit 1、0 は 0）、Sim は 1 要素に 2 ビットずつ。z は一致する |
| `round_twice` | 出力丸め付きで加数のある形: `mau` の `dvfmaur`、`dvfmadr`、`dvaddr`、`fvfmar`、`fvaddr`、`hvfmar`、`hvaddr`、`fp` の `fma_dr`、`add_dr`、`fma_fr`、`add_fr`、`fma_hr`、`add_hr` | 縮減後の精度でちょうど同点になる値に、ごく小さい加数が付く場合だけ違う（全行の照合で 10 行）。公式は、もとの出力精度の最下位ビットより 2 ビット下（h では単精度の 6 ビット下）までを残して小さい加数を捨ててから、縮減後の精度に丸める（調べた範囲）。Sim は SDM 4.3 どおり 1 回だけ丸める。印はファイル単位 |

`vectors_fixed` からは、`r_round` と `fvr_flags` のファイル（全行）、`ext_mul` の該当行、`fp` の `round_twice` のファイルで「もとの出力精度での結果が縮減後の精度の同点から 1 ulp 以内」の行を除いた。
そのうえで `vectors_fixed` の全行（13,550 行）を公式エミュレータで照合し、すべて一致した。

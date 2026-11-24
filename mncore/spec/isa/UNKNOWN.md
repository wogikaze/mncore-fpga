# 意味が未確定の欄（flat `j` / `m`）

`j_flat.yaml` と `m.yaml` の欄のうち、意味がまだ確定していないもの、または実装で注意が要るものをまとめる。
ビットの位置と幅はすべて確定している（コーパスの全語で CSV と一致）。ここで扱うのは「値が何を意味するか」だけである。

- 基準: judge 同梱の 2024 年配布版 `assemble3`（revision `e0d90436755d1303e5577ea6e17c6611ab88f300`）と、同梱のエミュレータ `gpfn3_package_main`。
- 出現数はコーパス（`third_party/mncore` の `.vsm` のうち flat でアセンブルできた 840 本、j 22,835 語、m 727 語）での値。`verify_corpus.py --report` で再集計できる。
- 根拠の記号: **[C]** コーパスの観測、**[P]** assemble3 のプローブ（`python -m mnisa.probe`）、**[E]** エミュレータ実験（`emu_probe.py`）、**[S]** [Scrapbox 機械語](https://scrapbox.io/mncore/機械語)、**[SDM]** SDM の節。

## A. コーパスで 0 以外が現れるが、意味が確定していない欄

| 欄（pos） | 出現 | 例（その値になる命令） | わかっていること | 未確定の点 |
| --- | --- | --- | --- | --- |
| `pe_mauc_readh`（131） | 1 が 1,289 語 | `gmwrite $aluf $lx0` → 1、`gmwrite $aluf $ly0` → 0、`gmmul $ly $t $nowrite` → 1、`gmmul $lx $aluf $ln0v` → 0、`dmread $lx0 $lr0v` → 1、`gmwrite $lmt48v4 $ly0; gmread $lx0 $nowrite` → 0 | 観測則 [C]（コーパスの命令行を 1 行ずつアセンブルした 620 行で例外なし）: ?mwrite があれば書き込み先が `$lx` のとき 1。なければ ?mmul / ?mfma が `$ly` を使うとき 1。なければ ?mread の読み出し元が `$lx` のとき 1。つまり 1 は「X を書き込み・読み出し側、Y を積の側」とする指定と読める | ハードウェア（エミュレータ）がこの 1bit で何を切り替えるか。規則に反する組み合わせ（`$lx` に書きながら `$lx` で積をとる語など）を手で作ったときの動作。SDM 3.6.10 / 3.6.11 に符号化の記述はない |
| `pe_mauc_mdw_side`（130） | 1 が 41 語 | `dvfmad $lmt0 $lmt0 $mauf $ln16` → 1（`dvfmau` は 0）、`hmwrite $aluf $llx0; hbfn/9 $mreadf $nowrite` → 1、`hmwrite $aluf $lx0` → 0 | 倍精度 MAU 命令の d / u 指定で 1 [S][P]。半精度の 2 長語行列書き込み（`$llx` / `$lly`）でも 1 [C] | 倍精度の d / u が演算のどの半分を指すか（SDM 3.6.9.2 / 3.6.9.10）と、行列書き込みでの「side」の意味 |
| `pe_mauc_ma`（122..125） | 0 以外が 715 語（0100: 611、1000: 64、1100: 37、1110: 3） | `gmwrite $t $lx4` → 0100、`gmwrite $t $ly8` → 1000、`gmwrite $t $lx12` → 1100、`hmwrite $lm[128,128,128,160]r $lx14` → 1110 | 行列レジスタへの書き込み位置（`$lx<n>` の n）[C][P] | 読み出し（?mread `$lx<n>`）の位置がどの欄に入るか。`mw` / `readh` との組み合わせで 1 語に書き込みと読み出しが同居するときの割り当て |
| `l1bm_me`（170） | 1 が 1,443 語 | `l1bmd $ls0 $lb0`、`l1bmp $lb0 $lr32`、`l1bmm $lb0 $ln0v` などすべての L1BM 命令式で 1 | L1BM 命令式を含む語で常に 1 [C][P] | 名前（me）の意味。0 で L1BM 命令式の他の欄が 0 でない語は観測していない |
| `l1bm_ladr`（171..183）と `l1bmd+<n>` | `l1bmd+<n>` を含む語（`problems/challenge/17.transpose-mab` など） | `l1bmd+1 $lr0 $lb0` → 60、`l1bmd+3 $lr0 $lb0` → 52（`l1bmd $lr0 $lb0` は 0） | `+<n>` を付けると L1BM アドレス欄の値が変わる [P] | `+<n>` の意味（SDM 3.6.8.20 / 3.6.8.21 に文法の記述がない）とアドレスの計算式 |
| `l1bm_dmode` / `l1bm_ext` / `l1bm_round_out`（184..186） | dmode=1 が 255 語、ext=1 が 12 語、round_out=1 が 5 語 | `l1bmrffadd` → dmode=1、`l1bmrhfadd` → dmode=1・ext=1・round_out=1、`l1bmrsbor` → dmode=1・ext=1、`l1bmrliadd` → すべて 0 | 縮約の精度を 3bit で表す [P]（d/l: 000、f/i: 100、h: 111、s: 110） | 整数・ビット演算（s 系）で ext=1 になる理由と、ext / round_out を単独で立てたときの動作 |
| `l2bm_opcode`（232..235） | 1100 が 890 語、1000 が 8 語、0010 が 8 語 | `l2bmd $lb0 $lc0` → 1100、`l2bm@0 $lb0 $lc0` → 1100、`l2bmriiadd $lb0 $lc0` → 1000 | 縮約（l2bmr…）では縮約 opcode [P] | 縮約でない転送（l2bmd、l2bm@）で常に 1100（bor）が入る理由。ハードウェアが無視するのか、bor として働くのか |
| `l2bm_ladr`（213..223）と `l2bmdars` | darsend=1 の語 | `l2bmdars $lc1024@.0 $dar0` → ladr=64 | 通常の転送ではソースのアドレス ÷ 16 [P]。l2bmdars でも同じ欄にアドレスが入る | DAR に送る値の単位と、`@.0` の扱い（SDM 3.6.7.10、3.6.1.3） |
| m: `destid` / `srcid`（7..12） | destid 0 以外 103 語、srcid 0 以外 79 語 | `mvp/n64 $lc0@1.1 $d0@3` → srcid=011・destid=110、`mvrfmax/n128 $lc0 $d0` → srcid=001 | 転送先・元の ID は `@n` → n×2、`@n.m` → n×2+m [P]。縮約転送では {destid の bit0, srcid} が縮約 opcode [P] | `@n.m` の n と m の意味（チップ番号と L2B 番号か）。縮約転送で ID を指定したいときの符号化 |
| m: `adra` / `adrb`（24..68） | adra 0 以外 162 語、adrb 0 以外 136 語 | `mvd/n64 $lc64 $p128@0` → adra=8・adrb=4、`mvp/n64 $p64@0 $p128@1` → adra=4・adrb=8 | DRAM を含む転送では adra が DRAM 側、adrb が L2BM / PDM 側。どちらも ÷ 16 [P] | L2BM⇔PDM、PDM→PDM での割り当ての一般則（観測は表の 2 例のみ） |
| m: `indirect`（23）と `adra` | 1 が 12 語 | `mvp/n64nd4 $p0@0 $di32@0` → adra=0x1020、`mvp/n64nd1 $p0@0 $di0@0` → adra=0x400 | DRAM 間接参照で 1 [S][P] | indirect=1 のときの adra の符号化（nd<k> と `$di` のアドレスの詰め方）。SDM 3.5.6 |

## B. コーパスでは常に 0、または予約の欄

| 欄（pos） | 状況 |
| --- | --- |
| `rsv_162`、`rsv_164`（162..165） | assemble3 が 0 以外を出すことはない（コーパス全語、プローブ）[C][P]。エミュレータは 1 を立てても結果を変えない（`lpassa`、`iadd`、`fvadd`、`l1bmp` で確認）[E]。auto_stride には対応する欄がない。Scrapbox では「162..165 の補助欄」と書かれている [S]。**実装は無視してよいが、0 以外なら `E_UNSUPPORTED rsv_162` を出すのが安全** |
| `pe_lm1_maadj`（111） | コーパスでは 0。`lpassa $lr0v $ln0vj1` で 1 になる [P]。意味は LM0 の maadj と同じ（SDM 3.6.1.8） |
| m: `priority`（80..81） | コーパスでは 0。`mvp/n64p2 …` → 10 [P][S] |
| `ll` = 10 | assemble3 は出さない。エミュレータは `inst.ll == undefined` で停止する [E]。**`E_DECODE` 扱い** |

## C. 確定したが、実装で注意が要る点

1. **`ll`（0..1）は語全体の実行形態を決める** [E]（`emu_probe.py ll`）。
   - 01: 通常。11: 書き込みは行うが、フォワーディングレジスタ（`$aluf` など）と `$lbi` を更新しない（noforward）。
   - 00: nop。**ほかの欄に値が入っていても、書き込みも更新もしない**（`ipassa $lr2 $lr16` の ll だけを 00 にすると `$lr16` は書かれない）。
   - assemble3 の `--ll-mode`（cold=01 / hot=11 / mix）が実機で何を切り替えるのかは不明。エミュレータは 11 を noforward として扱う。
2. **`l1bm_mabadr`（187..190）と `l1bm_opcode`（191..194）**: 2024 年版 assemble3 は、MAB 番号でも縮約 opcode でも同じ値を両方の欄に書く（CSV では両方とも `l1bm.mabadr/opcode`）[C][S]。
   エミュレータは 187..190 を MAB 番号、191..194 を縮約 opcode として読む [E]（`emu_probe.py l1bm`: `l1bmm@2` の 191..194 だけを変えても結果は同じ、`l1bmrsbor` の 187..190 だけを変えても同じ）。
   RTL は両欄が等しいと仮定せず、それぞれの欄を読むこと。SDK 0.9 の assemble3 は両欄を分けて書く [S]。
3. **CSV ヘッダの順と flat の j 行の順は違う**。ヘッダ（95 名）は auto_stride の i 語の並び。flat では
   - rfc0 / rfc1: `wadr, wwl, rwl, radr`（ヘッダは `wadr, wadri, wwl, radr, radri, rwl`）
   - MAUC: `…, ma, signa, signc, passa, zeroc, mdw/side, readh, exta, extb, extc, signb, isela, …`（ヘッダは `…, ma, mdw/side, readh, signa, signb, signc, exta, extb, extc, passa, zeroc, …`）
   - 162..165 の予約欄、187..194 の 2 欄、246..425 の cycle1〜3 アドレスは flat だけ。
   名前は auto_stride の名前付き列との値の一致で決めた（`verify_corpus.py --cross-check-auto-stride`）。
4. **`pe_mrc_zero_sel`（15..16）は isel と同じ符号**で、ゼロフラッシュをかける演算器を選ぶ [P]: 00 MAU（`fvadd/0101`）、01 ALU（`lpassa/0101`）、10 L1BM（`l1bmd/0101`、`l1bmp/0101`）、11 行列読み出し（`dmread/0101`）。
5. **`pe_mrc_ifsel`（21）**: `$omr` に書くとき、MAU 命令式が書くなら 1、ALU 命令式なら 0 [C]（コーパスの命令行を 1 行ずつアセンブルして、`$omr` に書く 471 行すべてで一致。例: `fvadd $mauf -$lr8v $omr1` → 1、`ixor $m7 $r4 $omr1` → 0）。
6. **ベースアドレスレジスタの書き込み**: `$mb` / `$nb` への書き込みは、専用の欄でなく `pe_lm0_*` / `pe_lm1_*` の組み合わせ（write=1、maadj=0、madpe=11、wl=00）で表す [P]。
7. **即値（imm / immu）**: ペイロードは ALUC と LM0 の欄を再利用する（`imm_layout`）。cycle1〜3 の LM0 アドレス欄にも下位 12bit が複製される（コーパスの imm 3,898 語すべてで複製が一致）[C][P]。
   これらの語では、ペイロードを運ぶ欄（`pe_aluc_isela` など）の enum は当てはまらない。半精度リテラル `h"…"` は同じ半語を 2 つ並べた値になる [S][P]。
   imm の語では LM0 を使えない。assemble3 は `imm … $lm32` を `immop can't output to LM0` で、同じ語の他の命令式が LM0 を読むものを `field conflict between immediate and lm0` で拒否する [P]。
   したがって **imm の語の `pe_lm0_write` などは LM0 の制御ではない**（例: `imm i"0x12345678" $lr0` で `pe_lm0_write=1`）。
8. **語長欄は未使用でも 0 でない**: `pe_rfc*_wwl` / `rwl`、`pe_lm*_wl` は、そのメモリを使わない語（nop など）でも 01 になることが多い（assemble3 の既定値）。語長やアドレスの欄は、write・isel・入力セレクタと合わせて解釈すること。なお GRF の書き込みアドレス欄（cycle0〜3）は、write=0 の語では常に 0 だった [C]。
9. **assemble3 の出力には `r` 行が混ざる**: `.vsm` に書かれた `r 0 000000000 001 3E80…` の形の行（DRAM の初期データと思われる）を、`d` 行と同様にそのまま出力する（CSV でも同じ）。`asm_io` / `csv_import` は種別 `r` として保持する。
10. **CRLF**: Windows で `third_party/mncore` をチェックアウトすると `.vsm` が CRLF になり、assemble3 は `Trailing letter after location` で失敗する。`assemble_corpus.sh` は CR を除いてから渡す。

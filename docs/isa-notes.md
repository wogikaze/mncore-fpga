# ISA notes: the flat `j` and `m` words

A summary of [`mncore/spec/isa/`](../mncore/spec/isa/) and of what this project confirmed with the official emulator about the meaning of the fields. The authoritative definitions are the YAML files; this page is a guide to them. The last section lists facts that could be added to the Scrapbox page [mncore/機械語](https://scrapbox.io/mncore/機械語) (written in Japanese, like that page).

Notation: **[E]** confirmed by running the official emulator, **[P]** by assembling probes with `assemble3`, **[C]** observed over the whole corpus. Each item names the report in [`mncore/status/`](../mncore/status/).

## 1. Base

- Reference assembler: `assemble3` from the 2024 distribution (judge v20240826), revision `e0d90436755d1303e5577ea6e17c6611ab88f300`, run as `assemble3 --instruction-mode flat --disable-packer`. The SDK 0.9 assembler differs in the L1BM fields 187..194 ([WP-01](../mncore/status/WP-01.md)).
- Output lines: `j` (PE word, 426 bits), `m` (MV word, 82 bits), `d` (debug: `d set` / `d get`) and `r` (data lines of the `.vsm`, passed through; the host turns them into DRAM writes).
- Files:
  - [`j_flat.yaml`](../mncore/spec/isa/j_flat.yaml): 110 fields, with `pos`, `width`, `group`, the CSV column, `enum` and `enum_when`, SDM references, and the immediate layout `imm_layout`.
  - [`m.yaml`](../mncore/spec/isa/m.yaml): 12 fields.
  - [`UNKNOWN.md`](../mncore/spec/isa/UNKNOWN.md): open points and the confirmations added by the lead (Japanese).
  - The Python package `mncore/tools/mnisa` decodes and encodes words with these files, and the RTL decoder is generated from them.
- How the fields were fixed ([WP-01](../mncore/status/WP-01.md)):
  - The values of `assemble3 --print-csv`, concatenated in order, equal the `j` / `m` word bit for bit.
  - **The CSV header (95 names) is the column order of the auto_stride `i` word, not of the flat `j` line (110 columns).** Flat names were assigned by matching values with the named auto_stride columns over 7,843 words accepted in both modes, and checked with probes.
  - Over the corpus (840 programs, 22,835 `j` and 727 `m` words) the round trip has 0 mismatches.
- Bit numbering: position 0 is the leftmost character of the line, and a field value has its MSB at the smallest position. In Verilog, `jw[425-pos]` is position `pos`.

## 2. Field map

`j` word (426 bits):

| Positions | Group | Fields (position) |
| --- | --- | --- |
| 0..1 | `ll` | word control: 01 normal, 11 noforward, 00 nop, 10 invalid |
| 2..21 | `mrc` (masks) | `imr` 2..6, `wl` 7, `target_rf0/rf1/tr/lm0/lm1/mr` 8..13, `zero` 14, `zero_sel` 15..16, `omr` 17..20, `ifsel` 21 |
| 22..24 | `trc` (T) | `write` 22, `isel` 23..24 |
| 25..49 | `rfc0` (GRF0) | `write` 25, `isel` 26..27, `wadr` 28..36, `wwl` 37..38, `rwl` 39..40, `radr` 41..49 |
| 50..74 | `rfc1` (GRF1) | same layout as `rfc0` |
| 75..95 | `lm0` (LM0) | `write` 75, `isel` 76..77, `adr` 78..89, `tregadr` 90, `maadj` 91, `madpe` 92..93, `wl` 94..95 |
| 96..115 | `lm1` (LM1) | `write` 96, `isel` 97..98, `adr` 99..110, `maadj` 111, `madpe` 112..113, `wl` 114..115 |
| 116..144 | `mauc` (MAU, matrix) | `dmode` 116..117, `enfma` 118, `mmode` 119, `round_out` 120, `mw` 121, `ma` 122..125, `signa` 126, `signc` 127, `passa` 128, `zeroc` 129, `mdw_side` 130, `readh` 131, `exta` 132, `extb` 133, `extc` 134, `signb` 135, `isela` 136..138, `iselb` 139..141, `iselc` 142..144 |
| 145..161 | `aluc` (ALU) | `dmode` 145..146, `aluop` 147..151, `is_unsigned` 152, `rounda` 153, `roundb` 154, `isela` 155..158, `iselb` 159..161 |
| 162..165 | `rsv` | `rsv_162`, `rsv_164` (flat only) |
| 166..209 | `l1bm` | `bmode` 166..167, `lwrite` 168, `rmode` 169, `me` 170, `ladr` 171..183, `dmode` 184, `ext` 185, `round_out` 186, `mabadr` 187..190, `opcode` 191..194, `isel` 195..197, `wl` 198, `gwrite` 199, `gadr` 200..209 |
| 210..237 | `l2bm` | `lwrite` 210, `bdmode` 211..212, `ladr` 213..223, `l1adr` 224..226, `immode` 227..229, `dmode` 230..231, `opcode` 232..235, `darsend` 236, `darwrite` 237 |
| 238..245 | `wd` | MV tag to wait for (0 = no wait) |
| 246..305 | cycle 1 addresses | GRF0 write / read, GRF1 write / read (9 bits each), LM0, LM1 (12 bits each) |
| 306..365 | cycle 2 addresses | same |
| 366..425 | cycle 3 addresses | same |

GRF and LM address fields are in 32-bit words (GRF 9 bits = 512 words, LM 12 bits = 4096 words). The cycle-0 addresses sit in the unit groups; cycles 1–3 are flat-only fields named `<field>_c1` .. `_c3`.

`m` word (82 bits): `valid` 0, `mmode` 1..3, `tmode` 4..6, `destid` 7..9, `srcid` 10..12, `dmode` 13..14, `mvid` 15..22 (tag), `indirect` 23, `adra` 24..53, `adrb` 54..68, `nw` 69..79, `priority` 80..81.

## 3. Confirmed meanings

### Word control

- `ll` [E]: 01 normal; 11 noforward (memories are written, but the forwarding registers and `$lbi` are not updated); 00 nop (no write and no update, whatever the other fields hold); 10 makes the emulator stop ([WP-01](../mncore/status/WP-01.md)).
- `wd` is valid in an `ll` = 00 word too. `nop ; wait i01` is emitted as `ll` = 00 with `wd` = 01. Waiting for a tag whose MV was never issued leaves that word and all later words unexecuted; the emulator then ends normally and `d get` shows the state at that point ([WP-20](../mncore/status/WP-20.md), [WP-33](../mncore/status/WP-33.md)).
- `rsv_162` / `rsv_164` [C][P][E]: `assemble3` never sets them; the emulator ignores a 1 there. This project stops with `E_UNSUPPORTED` instead ([WP-01](../mncore/status/WP-01.md)).

### Masks, PE memories, immediates

- `zero_sel` [P] uses the `isel` code to choose the unit whose output is zero-flushed: 00 MAU, 01 ALU, 10 L1BM, 11 matrix read ([WP-01](../mncore/status/WP-01.md)).
- `ifsel` [C]: 1 when a MAU expression writes `$omr`, 0 when an ALU expression does (471 corpus lines) ([WP-01](../mncore/status/WP-01.md)).
- `$mb` / `$nb` have no field of their own [P]. A write is the LM0 / LM1 field combination `write` = 1, `maadj` = 0, `madpe` = 11; `wl` = 00 for `$mb`, 01 for `$lmb` ([WP-01](../mncore/status/WP-01.md), [WP-10](../mncore/status/WP-10.md)).
- Immediates [C][P]: the 32-bit payload reuses ALUC and LM0 fields, and its low 12 bits are copied into the cycle 1–3 LM0 address fields (all 3,898 immediate words in the corpus). In an immediate word the LM0 fields are payload: `assemble3` refuses LM0 as the destination or as another expression's input ([WP-01](../mncore/status/WP-01.md)).
- Word-length fields (`wwl`, `rwl`, LM `wl`) are often 01 even in words that do not use the memory; read them together with `write` and the input selectors ([WP-01](../mncore/status/WP-01.md)).
- Write masks [E] ([WP-14](../mncore/status/WP-14.md)):
  - A long-word mask on a T write whose 4 flags for the cycle are all 0 writes nothing.
  - With a mask, `$mb` / `$lmb` are written according to the flag of the half-word that holds the 12-bit value (`$mb`: f[2], `$lmb`: f[0]).
  - Writing `$omr<n>` and using `/$imr<n>` in the same step uses the value before the step.
- Writing T and using T-indirect addressing in the same step: both the read and the write use T from before the step [E]. `assemble3` refuses a word that writes `$mb` / `$nb` and uses LM in the same step ([WP-20](../mncore/status/WP-20.md)).
- Single-word `d get` needs a dtype (`getf` / `geth`); without one the emulator stops ([WP-20](../mncore/status/WP-20.md)).

### ALU and MAU

- `r` (single → half rounding of an input) [E]: `h = sign | clamp(E − 96 + c, 0, 63) << 9 | (RNE(mantissa 23 → 9 bits) & 0x1ff)`. Nothing is flushed to zero and the mantissa of infinity is kept. `assemble3` accepts `r` with any precision, but the emulator stops unless `dmode` = 10 (h / s) ([WP-03](../mncore/status/WP-03.md)).
- `u` is accepted by `assemble3` on ALU operations where the SDM does not allow it; the result equals the operation without `u`. `u` changes only add / sub / inc / dec flags, `lsr`, and max / min ([WP-03](../mncore/status/WP-03.md)).
- Vector FMA [E] ([WP-12](../mncore/status/WP-12.md)):
  - The product is treated as zero when `Uc − Ep ≥ T` (T = 55 for d, 26 for f and h).
  - For h, the addend is aligned to the grid `2^(Ep − 28)`.
  - Extended (`e`) operands are multiplied exactly.
  - `fv*r` sets one flag bit per half-precision result (bits 3 and 2) ([WP-03](../mncore/status/WP-03.md)).
- `msl` / `msr` [E]: the result is {the neighbour PE's MSB long word, 0} with zero flags, and goes to `$aluf` ([WP-30](../mncore/status/WP-30.md)).
- Matrix fields [E] (166 cases, [WP-36](../mncore/status/WP-36.md)):

  | Field | `mw` = 0 | `mw` = 1 (`?mwrite` in the word) |
  | --- | --- | --- |
  | `readh` 131 | transposed-read plane = readh ? X : Y; matrix-MAU plane = readh ? Y : X | write plane = readh ? X : Y; transposed read and matrix MAU use the other plane |
  | `ma` 122..125 | column of the transposed read | row written |
  | `signa, signc, passa, zeroc` 126..129 | MAU fields | column of the transposed read |
  | `mdw_side` 130 | d matrix MAU: u (0) computes output rows 0–1, d (1) rows 2–3 | h: write two rows per cycle (`$ll`) |

  The h read column and the h two-row write row are rounded down to even. `?mwrite` takes MAU input b (`iselb`, `signb`, `extb`).
- `$mreadf` is updated in every step that is not nop or noforward, with the transposed read that the MAUC fields describe, even without `?mread` ([WP-20](../mncore/status/WP-20.md), [WP-36](../mncore/status/WP-36.md)).
- Matrix MAU numerics [E]: the addend grid is `Ep − K` with K = 86 / 39 / 34 / 26 for d / f / g / h. A product is dropped when `lead(c) − Ep ≥ T` (T = 57 for d, 30 for h). The dot product is exact and rounded once ([WP-36](../mncore/status/WP-36.md)).

### L1BM

- `mabadr` 187..190 and `opcode` 191..194 [C][E]: the 2024 `assemble3` writes the same value into both. The emulator reads the first as the MAB number and the second as the reduction opcode ([WP-01](../mncore/status/WP-01.md)).
- Reduction opcodes [P]: fadd 0000, max 0001, min 0010, iadd 1000, band 1001, and 1010, bor 1100, or 1101 ([WP-01](../mncore/status/WP-01.md)).
- Reduction precision `dmode, ext, round_out` (184..186) [P]: d / l 000, f / i 100, h 111, s 110 ([`UNKNOWN.md`](../mncore/spec/isa/UNKNOWN.md)).
  - `e` also applies to max / min: it keeps the mantissa and only rebases the exponent.
  - `r` is the rounding inside the reduction for fadd, and the ALU `r` rounding for max / min ([WP-31](../mncore/status/WP-31.md)).
- `me` [E] is only the L1BM write enable. A word with `lwrite` = 0 reads L1BM whatever `me` is ([WP-31](../mncore/status/WP-31.md)).
- `lwrite` = 1 [E] always makes a PE → L1BM transfer, and the L1BM → PE value comes from `$lbi` (turnaround).
  - The turnaround read uses the arrangement of the last transfer that wrote `$lbi`, not the reading word's fields.
  - A turnaround-only word (`isel` = 111) also transfers and overwrites `$lbi` (not in noforward words) ([WP-31](../mncore/status/WP-31.md)).
- The PE → L1BM operand with `isel` = 111 is `$lbf` [E]. WP31 had assumed 0, and WP37 corrected it ([WP-37](../mncore/status/WP-37.md)).
- `l1bmd` [P][E]: `assemble3` puts `−4 × shift mod 64` in `ladr[5:0]`, and the emulator uses only `ladr[5:2]`. Distribution reads `(L + 4m + p) mod 64`; gather writes PE (m, p) to `(4m + p − L) mod 64` ([WP-31](../mncore/status/WP-31.md)).
- `$lbf` is updated by every executed word, including words whose L1BM fields hold defaults. `assemble3` rejects reading `$lbf` after such a word ([WP-31](../mncore/status/WP-31.md)).

### L2BM

- `l2bm@n` is a bor reduction over the set {n}. That is why `opcode` holds 1100. Gather, L2BM → L1BM and `l2bmi` ignore `opcode` / `dmode` ([WP-32](../mncore/status/WP-32.md)).
- `l2bmdars`: the 12 bits `l1adr`..`opcode` are {DAR address (10 bits), L2B number (2 bits)}; only bit 0 of the L2B number is used. In consecutive `j` words with `l2bmdars`, the DAR address and L2B of the first word are kept. `m` words do not break the sequence; other `j` words, including `ll` = 00, do ([WP-32](../mncore/status/WP-32.md)).
- Identity elements of reductions: fadd / iadd / bor / or 0, max and band all ones, min all ones except the sign, and 1 ([WP-32](../mncore/status/WP-32.md)).
- Order inside a word: all reads see the state before the word. L1BM is written per cycle, PE → L1BM first and L2BM → L1BM second ([WP-32](../mncore/status/WP-32.md)).
- Encodings of all L2BM forms (`gwrite`, `lwrite`, `bdmode`, set fields): table in [WP-32](../mncore/status/WP-32.md) and [`mncore/rtl/l2bm/README.md`](../mncore/rtl/l2bm/README.md).

### MV

All [E] over the whole chip with distinct values in every unit ([WP-33](../mncore/status/WP-33.md)):

- `adra` is the DRAM address ÷ 16 (forms with DRAM), the PDM side of PDM ⇔ L2BM, and the source of PDM → PDM. `adrb` is the L2BM address ÷ 16, the PDM side of PDM ⇔ DRAM, and the destination of PDM → PDM.
- `destid` / `srcid` = group × 2 + L2B. PDM / DRAM ignore bit 0, parallel forms ignore the group, and broadcast forms ignore both. In reductions, {`destid[0]`, `srcid`} is the operation and `destid[2:1]` the PDM group.
- L2BM addresses are in units of 64 long words (bits 1..0 of `adrb` are ignored); PDM and DRAM in units of 16. Addresses wrap at L2BM 2^15, PDM 2^19, DRAM 2^29 long words.
- Besides the 24 forms of `assemble3`, the emulator runs PDM ⇔ DRAM and PDM → PDM in parallel, and PDM → L2BM with `tmode` = 010. `mmode` = 111 and `tmode` = 110 / 111 do nothing but still count the tag. 14 other combinations abort.
- `nw` counts chunks of 16 long words. 0 aborts; broadcast forms and DRAM → PDM `mvd` need a multiple of 4.
- DRAM indirect: chunk i is at `16 × (DAR[(M + i / N) mod 1024] + i mod N)` with M = `adra[9:0]` and N = `adra[14:10]` (5 bits). **Without `nd` (N = 0), N acts as infinity: `16 × (DAR[M] + i)`.**
- MV completes at issue: a following L2BM instruction sees its result. Inside one MV, every read happens before any write.
- `wait`: one completed, not-yet-waited MV with the tag → consumed; none → the program stays stopped; two or more → abort. `priority` does not change results. `dmode` matters only for reductions.

## 4. Still open

- What `assemble3 --ll-mode` (cold 01 / hot 11 / mix) selects on the real chip. The emulator treats 11 as noforward ([`UNKNOWN.md`](../mncore/spec/isa/UNKNOWN.md)).
- The rounding of h extended-format products in the matrix MAU. It is shifted and rounded, but not round-to-nearest-even in 6–8 % of single-product cases, and depends on the operands ([WP-36](../mncore/status/WP-36.md)).
- The d matrix MAU rules (K = 86, T = 57, u / d rows) are confirmed, but not implemented in the RTL ([WP-36](../mncore/status/WP-36.md)).

## 5. Candidates for the Scrapbox page 機械語

The following facts were confirmed in this project. As of this writing they seem to be missing from [mncore/機械語](https://scrapbox.io/mncore/機械語), or present there without their meaning. The list is written in Japanese to match that page. **Whether to add them is the user's decision**; check each against the current page first.

- **ll（0..1）の意味**: 01 通常、11 noforward（メモリには書くが、フォワーディングレジスタと `$lbi` を更新しない）、00 nop（ほかの欄に値があっても何も書かない）、10 はエミュレータが停止する。ll = 00 の語でも wd（wait）は有効（`nop ; wait i01` は ll = 00、wd = 01）。[WP-01, WP-20]
- **162..165 の 2 欄（flat だけ）**: assemble3 は常に 0 を出す。エミュレータは 1 を立てても結果を変えない（`lpassa`、`iadd`、`fvadd`、`l1bmp` で確認）。[WP-01]
- **CSV ヘッダの順と flat の j 行の順は違う**: `--print-csv` のヘッダ（95 名）は auto_stride の i 語の並び。flat の j 行は 110 列で、rfc0 / rfc1 は `wadr, wwl, rwl, radr`、MAUC は `…, ma, signa, signc, passa, zeroc, mdw/side, readh, exta, extb, extc, signb, isela…` の順。[WP-01, WP-03]
- **187..190 と 191..194**: 2024 年版 assemble3 は同じ値を両方に書くが、エミュレータは 187..190 を MAB 番号、191..194 を縮約 opcode として別々に読む（片方だけ書き換えて確認）。[WP-01]
- **zero_sel（15..16）**: isel と同じ符号。00 MAU、01 ALU、10 L1BM、11 行列読み出し。[WP-01]
- **縮約 opcode の全表**: fadd 0000、max 0001、min 0010、iadd 1000、band 1001、and 1010、bor 1100、or 1101。L1BM 縮約の精度（184..186）は d / l 000、f / i 100、h 111、s 110。[WP-01、UNKNOWN.md]
- **ifsel（21）**: `$omr` に書くのが MAU 命令式なら 1、ALU 命令式なら 0。[WP-01]
- **`$mb` / `$nb` の書き込み**: 専用の欄はなく、LM0 / LM1 の欄の組み合わせ（write = 1、maadj = 0、madpe = 11。`$mb` は wl = 00、`$lmb` は wl = 01）で表す。[WP-01, WP-10]
- **readh / ma / mdw_side の意味**（公式で 166 例）:
  - mw = 0: 転置読み出しの面 = readh ? X : Y、行列 MAU の面 = readh ? Y : X、ma = 転置読み出しの列。
  - mw = 1: 書き込みの面 = readh ? X : Y（読み出しは反対の面）、ma = 書き込みの行、転置読み出しの列は {signa, signc, passa, zeroc}（126..129）。
  - mdw_side: h の 2 行書き込みと、d の行列 MAU の u / d。
  - h の読み出しの列と 2 行書き込みの行は偶数に切り捨てる。
  - [WP-36]
- **`$mreadf`**: nop / noforward 以外の全ステップで、MAUC の欄が表す転置読み出しの値に更新される（?mread のない語でも）。[WP-20, WP-36]
- **l1bm_me（170）**: L1BM への書き込みの許可だけ。lwrite = 0 の語は me = 0 でも L1BM を読む。[WP-31]
- **L1BM の isel = 111**: PE → L1BM のオペランドは `$lbf`。[WP-37]
- **l1bmd のずらし**: assemble3 は `−4 × shift mod 64` を ladr[5:0] に入れ、エミュレータは ladr[5:2] だけを使う。[WP-31]
- **l2bm@n の opcode が 1100 の理由**: `l2bm@n` は集合 {n} の bor の縮約。結合、L2BM → L1BM、`l2bmi` は opcode / dmode を見ない。[WP-32]
- **l2bmdars の符号化**: `l2bm_l1adr`〜`l2bm_opcode` の 12bit が {DAR アドレス 10bit, L2B 番号 2bit}（L2B は bit 0 だけを使う）。連続する j 語の l2bmdars では最初の語の DAR アドレスと L2B を保つ。[WP-32]
- **MV の destid / srcid**: グループ × 2 + L2B。PDM / DRAM では bit 0 を、並列ではグループを、放送では両方を見ない。縮約では {destid[0], srcid} が演算、destid[2:1] が PDM のグループ。[WP-33]
- **MV の adra / adrb の割り当て**:
  - adra: DRAM のアドレス ÷ 16（DRAM のある形）、PDM ⇔ L2BM の PDM 側、PDM → PDM の転送元。
  - adrb: L2BM のアドレス ÷ 16、PDM ⇔ DRAM の PDM 側、PDM → PDM の転送先。
  - L2BM のアドレスは 64 長語単位（adrb の bit 1..0 は使われない）。
  - [WP-33]
- **DRAM 間接参照**:
  - チャンク i のアドレスは `16 × (DAR[(M + i/N) mod 1024] + i mod N)`。M = adra[9:0]、N = adra[14:10]（nd、5bit）。
  - nd を省略すると N は無限大として働き、`16 × (DAR[M] + i)` になる。
  - [WP-33]
- **MV の priority と wait**:
  - priority は結果に影響しない。
  - wait は、完了してまだ wait していない MV が 1 つなら消費して進み、0 なら止まったまま終わり、2 以上なら異常終了する。
  - mmode 111、tmode 110 / 111 は何もしない（タグは数える）。
  - [WP-33]

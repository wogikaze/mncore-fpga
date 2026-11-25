# Divergences: official emulator vs the Rust simulator

This list collects the cases where the Rust reference simulator ([wogikaze/mncore](https://github.com/wogikaze/mncore) `viz/core`) gives a different result from the official emulator `gpfn3_package_main` (judge v20240826). The cases were found while building this FPGA implementation. It is written so that each entry can be filed upstream as it is.

- **Reference**: the official emulator is the final reference. The RTL of this project implements the official behaviour in every case below. The simulator has not been changed, except for entry 1.
- **Simulator versions**: the divergences were observed with `viz/core` at `e011bf9` (master at the time) or `5f0ceb1` (branch `topo-param`, the submodule commit of this repository). Only entry 1 is fixed, and only on `topo-param`.
- **Sources**: each entry cites a report in [`mncore/status/`](../mncore/status/) (Japanese) with the full evidence. Contract §1 ([`mncore/06-contracts.md`](../mncore/06-contracts.md)) keeps the running list.
- **Reproduction**:
  - Paths starting with `problems/`, `docs/`, `research/` or `mncompile/` are in the upstream repository.
  - Paths starting with `mncore/` are in this repository.
  - The scripts that compare with the Rust simulator use `mncore/golden_rs` (`golden_dump`, which links `viz/core`).

## Summary

| # | Area | Trigger | Status | Source |
| --- | --- | --- | --- | --- |
| 1 | MV | `mvb` / `mvd` / `mvr` with 128 or more long words (DRAM walk) | fixed on `topo-param` `5f0ceb1`, not on master | WP-02, WP-06 |
| 2 | MV | DRAM indirect `$di` without `nd` | open | WP-33 |
| 3 | ALU | input rounding `r` (single → half) | open | WP-03 |
| 4 | MAU | product of extended (`e`) operands | open | WP-03 |
| 5 | MAU | flags of `fv*r` | open | WP-03 |
| 6 | MAU | addend alignment and product drop in the vector FMA | open | WP-03, WP-12 |
| 7 | ALU | `r` on a precision other than half-word | open (validation) | WP-03, WP-30 |
| 8 | Parser | `uhbfn/<n>`, `uhbfe/<n>` | open | WP-03 |
| 9 | Parser | hexadecimal float literal `0x3.p+22` | open | WP-02 |
| 10 | PE memory | long-word mask on a T write with all flags 0 | open | WP-14 |
| 11 | PE memory | mask on `$mb` / `$lmb` / `$nb` writes | open | WP-14 |
| 12 | PE memory | `$omr<n>` written and `/$imr<n>` used in the same step | open | WP-14 |
| 13 | Matrix | `$mreadf` update in steps without `?mread` | open | WP-20, WP-36 |
| 14 | L1BM | `fmaxr` / `fminr` reductions | open | WP-31 |
| 15 | L1BM | `fmax` / `fmin` reductions with `e` and special values | open | WP-31 |
| 16 | L1BM | `$lbi` across words without a PE → L1BM transfer | open | WP-02, WP-31 |
| 17 | L1BM | turnaround-only word and `$lbi` | open | WP-31 |
| 18 | L1BM | implicit `$lbf` update | open (not visible in assembled programs) | WP-31 |
| 19 | L2BM | consecutive `l2bmdars` | open | WP-32 |
| 20 | L2BM | order of L1BM writes inside one word | open | WP-32 |
| 21 | Matrix | addend grid of the h matrix MAU | open | WP-36 |
| 22 | Matrix | product drop in the matrix MAU | open | WP-36 |
| 23 | Matrix | h extended-format products | open (official rule not fully known) | WP-36 |
| 24 | Matrix | sign of zero in `?mwrite` with `e` | open | WP-36 |
| 25 | Matrix | h two-row `?mwrite` to an odd row | open | WP-36 |
| 26 | Debug | `d get $p` | difference in the debug interface | WP-02 |

## Entries

### 1. MV: DRAM walk of `mvb` / `mvd` / `mvr` (fixed on `topo-param`)

- **Official**: in every group g, `mvb/n $d0 $lc0` reads the DRAM of group g in order. L2BM `64 i + 16 g + k` ← DRAM of group g `16 i + k`; `mvd` and the reductions `mvr` use the same mapping. `mvb4` / `mvr4` use `32 i + 16 c + k`.
- **Rust (since `2b9e595`)**: the DRAM side walks chunks numbered `4 i + g` across all groups, so the addresses of groups 1–3 shift. Problems that look only at group 0 show it from 128 long words on.
- **Reproduce**: `problems/28.dram-dl-16-16/answer.vsm` (504 long words differ in LM0, L1BM and L2BM) and `problems/46.matmul-tra-pkg-lmdram-16-256-16/answer.vsm` (112 long words in DRAM). The upstream `difftest_prog` reproduces both.
- **Status**: fixed in `viz/core/src/mv.rs` by `5f0ceb1` on `topo-param`, which adds the regression test `mv::tests::group_spread_transfers_walk_each_group_dram_in_order`. All 146 problem checks of `check-conformance.sh` then agree. The same index change in `gpu/mv_kernel.cu` was not run (no CUDA GPU was available). Indirect `mvb` / `mvd` / `mvr` with `nd` were later confirmed against the official emulator ([WP-33](../mncore/status/WP-33.md)).
- **Source**: [WP-02](../mncore/status/WP-02.md), [WP-06](../mncore/status/WP-06.md)

### 2. MV: DRAM indirect without `nd`

- **Official**: chunk i is at `16 × (DAR[(M + i / N) mod 1024] + i mod N)`, with M = `adra[9:0]` and N = `adra[14:10]`. When `nd` is omitted (N = 0), N acts as infinity: `16 × (DAR[M] + i)`. Entry M is used throughout and the offset grows.
- **Rust** (`mv.rs`): `16 × DAR[(M + i) mod 1024]`. It advances the entry and keeps the offset at 0. The text of SDM 3.5.6 ("the address is DAR[M + i]") reads the same way as the simulator.
- **Reproduce**: `python mncore/sim/tb/mv/rust_check.py`. `x_nd0_read` (`mvp/n128 $di8@0 $lc256@0.0`) differs in 112 long words, `x_nd0_write` in 192, `x_nd0_mvb` in 16. With `nd`, direct addressing and overlapping PDM copies agree.
- **Source**: [WP-33](../mncore/status/WP-33.md)

### 3. ALU: input rounding `r`

- **Official**: `h = sign | clamp(E − 96 + c, 0, 63) << 9 | (RNE(mantissa 23 → 9 bits) & 0x1ff)`, where E is the single-precision exponent field and c the carry of the mantissa rounding. There is no flush to zero, the mantissa of infinity is kept, and −0 stays `0x8000`. This formula matches all 1,442 rows of `fp/cvt_f2h`.
- **Rust** (`round_bus` in `machine.rs`): `encode(HALF, decode(SINGLE, x))`. Underflow gives +0, the mantissa of infinity is cleared, and −0 becomes +0.
- **Examples**:

  | Input | Official | Rust |
  | --- | --- | --- |
  | `0x80000000` | `0x8000` | `0x0000` |
  | `0x307fdfff` | `0x01ff` | `0x0000` |
  | `0xffc00001` | `0xff00` | `0xfe00` |

- **Extent**: 28,288 of 584,743 vector rows (ALU `s` with `r`, FP ALU `h` with `r`, `fp/cvt_f2h`).
- **Source**: [WP-03](../mncore/status/WP-03.md)

### 4. MAU: products of extended operands

- **Official**: extended (`e`) a and b are multiplied exactly.
- **Rust** (`compute_vec(_pe)`, `float::vfma`):
  - The extended operand stays decoded at the shorter precision.
  - `mul_exact` applies its partial-product omission to the short mantissa.
  - `align_c` computes the grid from the wrong exponent.
- **Example**: `dvmuld`, a = `bf800001` (single, extended, negated), b = `bff0000000000001` → official `bff0000020000001`, Rust `bff0000020000081`.
- **Suggested fix**: re-decode the extended operand in the operation's format, `decode(f, encode(f, v))`.
- **Extent**: 1,219 rows (d and f fma / mul).
- **Source**: [WP-03](../mncore/status/WP-03.md)

### 5. MAU: flags of `fv*r`

- **Official**: one flag bit per half-precision result (bits 3 and 2; 1 if positive), bits 1 and 0 are 0.
- **Rust** (`mau_flags`): two bits per element. The z result agrees.
- **Extent**: 5,224 rows.
- **Source**: [WP-03](../mncore/status/WP-03.md)

### 6. MAU: addend alignment and product drop in the vector FMA

- **Official**: the adder has two rules that the simulator lacks:
  - The product is treated as zero when `Uc − Ep ≥ T`, with T = 55 for d and 26 for f and h.
  - For h, c is aligned to the grid `2^(Ep − 28)`, as d (88) and f (41) are.
  - The SDM 4.3 statement "round directly to the reduced precision" is what the simulator implements.
- **Visible**: mostly in forms with output rounding (WP03 called it `round_twice`), but also without output rounding at the boundary.
- **Example**: `dvfmau` with a = `a6459c860b63a7b1`, b = `561fffffffffffff`, c = `3fd0000000000000` → official `3fd0000000000000`, Rust `3fcfffffffffffff`.
- **Suggested fix** (`float::vfma`):
  - (1) if a, b and c are finite and `Uc − Ep ≥ T`, use a zero product;
  - (2) apply `align_c(c, Ep − 28)` to `HALF` too;
  - (3) the fix of entry 4.

  The Python model `mncore/sim/tb/fpu_tools/mnfp_ref.py` has this form and agrees with all vector and probe rows.
- **Source**: [WP-03](../mncore/status/WP-03.md), [WP-12](../mncore/status/WP-12.md)

### 7. ALU: `r` on a precision other than half-word

- **Official**: `assemble3` accepts `r` with any precision. The emulator stops at run time: `ialuc.rounda can be used only with half-word`. `msl $lr0vr` is accepted by the assembler and stops the emulator with InvalidArgument.
- **Rust**: executes the word.
- **Source**: [WP-03](../mncore/status/WP-03.md), [WP-30](../mncore/status/WP-30.md)

### 8. Parser: `uhbfn/<n>` and `uhbfe/<n>`

- **Official**: `assemble3` accepts them.
- **Rust**: the VSM parser reads `/<n>` as a mask and fails.
- **Source**: [WP-03](../mncore/status/WP-03.md)

### 9. Parser: hexadecimal float literal

- **Official**: runs `problems/challenge/20.fizzbuzz/lpha100.vsm`.
- **Rust**: `parse_error` on the literal `0x3.p+22` (a TODO in viz/core).
- **Source**: [WP-02](../mncore/status/WP-02.md)

### 10. PE memory: long-word mask on T with all flags 0

- **Official**: when a long-word mask is applied to a T write and the 4 flags of that cycle are all 0, nothing is written (not even the LSB-side long word).
- **Rust**: writes the LSB-side long word (`word_enabled` is always true for i ≥ 2).
- **Reproduce**: tests `mask_t_pat` and `t_mask_zero_cycles` in `mncore/sim/tb/pemem/gen_tests.py`.
- **Source**: [WP-14](../mncore/status/WP-14.md)

### 11. PE memory: mask on `$mb` / `$lmb` / `$nb`

- **Official**: the write is decided by the flag of the half-word that holds the 12-bit value (`$mb`: `[111:96]`, `$lmb`: `[79:64]`; with a long-word mask, f[2] / f[0]).
- **Rust**: writes if any flag is 1.
- **Reproduce**: tests `omr_bar_mask`, `bar_imr_lmb_hi`, `bar_imr_mb` in `mncore/sim/tb/pemem/gen_tests.py`.
- **Source**: [WP-14](../mncore/status/WP-14.md)

### 12. PE memory: `$omr` written and used as `$imr` in the same step

- **Official**: the mask uses the value before the step (SDM 3.6.2: "available from the next step").
- **Rust**: uses the newly written value (order of the write loop).
- **Reproduce**: test `omr_same_step` in `mncore/sim/tb/pemem/gen_tests.py`.
- **Source**: [WP-14](../mncore/status/WP-14.md)

### 13. Matrix: `$mreadf` in steps without `?mread`

- **Official**: every step that is not nop or noforward performs the transposed read that the MAUC fields describe and writes it to `$mreadf`, even without `?mread` (for example, after `dmwrite $lr0v $ly0`, `zero $nowrite; lpassa $mreadf $lls64v` reads `3ff0000000000000`). The zero flush applies to `$mreadf`; write masks do not.
- **Rust** (`machine.rs`): sets `$mreadf` to 0 in steps without `?mread`.
- **Reproduce**: test `mat_mreadf` in `mncore/sim/tb/mat/gen_mat.py` (8 long words differ).
- **Source**: [WP-20](../mncore/status/WP-20.md), [WP-36](../mncore/status/WP-36.md)

### 14. L1BM: `fmaxr` / `fminr`

- **Official**: the single-precision result is rounded to half precision with the ALU `r` rule (entry 3).
- **Rust** (`blocks.rs`): places the low 16 bits of the single-precision result.
- **Reproduce**: tests `r_round` and `r_minmax_*` in `mncore/sim/tb/l1bm/gen_tests.py`.
- **Source**: [WP-31](../mncore/status/WP-31.md)

### 15. L1BM: `fmax` / `fmin` with `e`

- **Official**: the extension keeps the mantissa. A value with exponent 63 stays an infinity with a mantissa and is compared as such.
- **Rust**: normalizes through `float::decode` / `encode` (exponent 0 → +0, the mantissa of infinity is cleared). Results differ when a half-precision input has exponent 0 or 63.
- **Source**: [WP-31](../mncore/status/WP-31.md)

### 16. L1BM: `$lbi` between transfers

- **Official**: `$lbi` keeps its value across words without a PE → L1BM transfer (`assemble3` allows other words, including nop, between the transfer and the turnaround read).
- **Rust**: the turnaround read in a later word is a run-time error.
- **Reproduce**: `research/experiments/resched/matmul-sweep/37/c2.vsm` (runs on the official emulator, `unsupported` on Rust).
- **Source**: [WP-02](../mncore/status/WP-02.md), [WP-31](../mncore/status/WP-31.md)

### 17. L1BM: turnaround-only word

- **Official**: a turnaround-only word (`l1bmm $lbi ...`, `isel` = 111) also performs a PE → L1BM transfer and overwrites `$lbi` (not in noforward words).
- **Rust**: does not overwrite. `assemble3` does not allow two turnaround reads in a row, so assembled programs rarely show it.
- **Reproduce**: test `ta_lbi_only` in `mncore/sim/tb/l1bm/gen_tests.py`.
- **Source**: [WP-31](../mncore/status/WP-31.md)

### 18. L1BM: implicit `$lbf` update

- **Official**: every executed word updates `$lbf`, including words whose L1BM fields hold the defaults (an implicit `l1bmp $lb0` read).
- **Rust**: updates it only in words with an L1BM transfer. The RTL of this project does the same.
- **Visible**: not in assembled programs, because `assemble3` rejects reading `$lbf` after such a word. Listed for completeness.
- **Source**: [WP-31](../mncore/status/WP-31.md), contract §1

### 19. L2BM: consecutive `l2bmdars`

- **Official**: when consecutive `j` words contain `l2bmdars`, only the DAR buffer is rewritten. The DAR write address, the DAR-buffer read address and the L2B stay those of the first word. `m` words do not break the sequence; any other `j` word does, including `ll` = 00. SDM 3.6.7.10 does not describe this.
- **Rust** (`l2_dar` in `blocks.rs`): sets them again in every word.
- **Reproduce**: `x_dars_consec` in `mncore/sim/tb/l2bm/rust_check.py`.
- **Source**: [WP-32](../mncore/status/WP-32.md)

### 20. L2BM: order of L1BM writes inside a word

- **Official**: when the L1BM part and the L2BM part of one word write the same L1BM address, each cycle writes PE → L1BM first, then L2BM → L1BM. The result does not depend on the order of the expressions in the `.vsm` (machine code has no order).
- **Rust** (`machine.rs`): processes the expressions in `.vsm` order, so the one written later always wins.
- **Reproduce**: `x_ww_l2_first`, `x_ww_pe_first`, `x_ww_m4` in `mncore/sim/tb/l2bm/rust_check.py`.
- **Source**: [WP-32](../mncore/status/WP-32.md)

### 21. Matrix MAU: addend grid of h

- **Official**: the addend c is aligned to `Ep − 26` for h (d 86, f 39, g 34).
- **Rust** (`bf_dot`, `low = 2 * m`): `Ep − 16`.
- **Reproduce**: tests `mfma_h` (165 long words differ) and `mfma_h0` (122) in `mncore/sim/tb/mat/gen_mat.py`.
- **Source**: [WP-36](../mncore/status/WP-36.md)

### 22. Matrix MAU: product drop

- **Official**: the dot product is dropped when `lead(c) − Ep ≥ T`, with T = 30 for h and 57 for d.
- **Rust** (`mat_fma`): has no such rule.
- **Reproduce**: test `mfma_hr` (17 long words).
- **Source**: [WP-36](../mncore/status/WP-36.md)

### 23. Matrix MAU: h extended-format products

- **Official**: a product with an extended-format operand (exponent field 0 = common exponent − 6) is shifted right by 6 or 12 bits and rounded before the sum. The rounding is not round-to-nearest-even in 8.0 % (6-bit shift) and 6.4 % (12-bit shift) of single-product cases, and it depends on the operands. The rule is not known; SDM 4.5 also omits it.
- **Rust**: exact.
- **This project**: the RTL approximates the official rule with round-to-nearest-even, so it does not always match the official emulator either. Corpus programs that use the extended format agree because the discarded bits are 0.
- **Source**: [WP-36](../mncore/status/WP-36.md)

### 24. Matrix: `?mwrite` with `e`

- **Official**: the extension keeps the sign of zero and infinity and clears the mantissa (−0 → `0x8000…`).
- **Rust** (`compute_mwrite`): `encode(decode(..))` gives +0.
- **Reproduce**: test `mat_rw_d` (4 long words).
- **Source**: [WP-36](../mncore/status/WP-36.md)

### 25. Matrix: h two-row write to an odd row

- **Official**: the row of an h two-row write (`$ll`, `mdw_side` = 1) is rounded down to even. `assemble3` accepts an odd row, as in `hmwrite $llr40v $llx3`.
- **Rust**: writes from the odd row.
- **Reproduce**: test `mat_rw_mix` (24 long words).
- **Source**: [WP-36](../mncore/status/WP-36.md)

### 26. Debug: `d get $p`

- **Official**: `d get $p` prints the DRAM contents, not PDM. An L2BM → PDM → L2BM round trip works, but `$p` reads 0.
- **Rust** (`golden_dump`, `Sim::dump` key `PIU`): prints the real PDM.
- **Reproduce**: `mncore/tools/golden/testdata/pdm_dget.vsm`.
- **This project**: PDM is left out of every comparison.
- **Source**: [WP-02](../mncore/status/WP-02.md)

## Notes on the SDM

- SDM 3.6.8.20: the pseudo-code `src_mab = (mab + mabdiff) % 16` has the wrong sign. The example in the same section, the Rust simulator (`mab - mabdiff`) and the official emulator agree with each other ([WP-31](../mncore/status/WP-31.md)).
- SDM 3.6.7.10 does not describe consecutive `l2bmdars` (entry 19), and SDM 3.5.6 reads differently from the official behaviour without `nd` (entry 2).
- SDM 4.3 says outputs are rounded directly to the reduced precision; the official adder has the additional rules of entry 6.

## Where this FPGA implementation differs from the official emulator

Not divergences of the simulator, but listed here so that the scope of "matches the official emulator" is clear:

- **Reduced topology**: accesses beyond the reduced capacities stop with `E_RANGE`. Units that do not exist follow the zero or replica rule ([architecture.md §7](architecture.md#7-reduced-topology)). Only programs whose data stays inside the implemented units are compared with the official result directly.
- **Units not in a bitstream**: their instructions stop with `E_UNSUPPORTED`. In M2 this includes DAR (`l2bmdars` / `l2bmdarw`).
- **Not implemented**:
  - the d-precision matrix MAU (`E_UNSUPPORTED`);
  - the implicit `$lbf` update (entry 18);
  - the exact h extended-format matrix rounding (entry 23, approximated).
- **Abort cases**: words that the official emulator aborts on (for example two pending completions on one `wait` tag, invalid MV forms, `nw` = 0) stop with `E_UNSUPPORTED`. A nonzero `rsv_162` / `rsv_164`, which the official emulator ignores, does too.
- **Wait without a completed MV**: the official emulator ends normally with the later words unexecuted. The FPGA stops with reason 4 `WAIT`; the state is the same.
- **`d get $p`**: the host reads the real PDM (entry 26).

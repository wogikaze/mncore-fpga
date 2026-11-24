#!/usr/bin/env python3
"""WP31: directed tests of the L1BM unit, with the official emulator's results as expectations.

    python mncore/sim/tb/l1bm/gen_tests.py [--only NAME,...] [--jobs 16] [--no-model]

Every test is a small program (l1prog.Prog): initial data from splitmix64 (L1BM long words
0..1023 and, for the PEs of MABs < init_mabs of L1B n0c0b0, GRF0 / GRF1 long words 0..31, LM0 /
LM1 0..63 and T), the body, and d get of those regions for all 64 PEs of the L1B. It is
assembled with the official assemble3 (flat, no packer) and run on the official emulator
(WSL, emu_batch.sh; only called, contract section 9); some words are edited by hand after the
assembly (fields the assembler never sets, to pin the emulator's semantics).
The result is a test file for tb_l1bm_env.v (format there): the words and FNV-1a hashes of the
final state (L1BM in blocks of 64 long words, every PE region) taken from the emulator's dump:
    fixed/m1.tst   init_mabs = 1: only MAB 0 has data, for N_MAB = 1 (and 16)
    fixed/m16.tst  init_mabs = 16: the whole L1B, for N_MAB = 16
Tests that end in E_RANGE (the reduced L1BM of 1024 long words; the emulator has 8192) or
E_UNSUPPORTED take the expected stop from the test definition and the expected state from the
emulator run of the words before the stop (the unit must not execute the stopping word).
The files are committed: `python mncore/tools/simrun.py l1bm` needs neither WSL nor the tools.

The reference model (l1model.py, pemodel.py) is run on the same words as a cross-check of the
semantics (--no-model skips it); its result is reported, never used as an expectation. For
init_mabs = 1 tests it also runs with N_MAB = 1 (MABs 1..15 send zeros): a test is valid for the
reduced topology only if that matches the emulator too (gen_tests refuses it otherwise).
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import l1prog as LP  # noqa: E402
from l1prog import Prog  # noqa: E402

FIXED = HERE / "fixed"
BUILD = HERE / "build"
M64 = (1 << 64) - 1
# field indices (mn_jfields.vh MN_J_<field>_IDX)
F_RMODE, F_EXT, F_ROUND, F_OPCODE, F_WL = 70, 74, 75, 77, 79


def fnv(h: int, v: int) -> int:
    return ((h ^ v) * 0x100000001B3) & M64


def hashes(dump: Dict, npe: int):
    """(K lines) of the final state: L1BM blocks and PE regions, from an ndmp dict."""
    out = []
    for blk in range(16):
        h = 0xCBF29CE484222325
        for a in range(64 * blk, 64 * blk + 64):
            h = fnv(h, dump.get(("L1BM", "n0c0b0", 64 * blk + (a - 64 * blk)), 0))
        out.append(f"K L {blk} {h:016x}")
    for i in range(npe):
        loc = f"n0c0b0m{i // 4}p{i % 4}"
        for sp, (space, nlong) in enumerate((("GRF0", 32), ("GRF1", 32), ("LM0", 64), ("LM1", 64), ("T", 8))):
            h = 0xCBF29CE484222325
            for a in range(nlong):
                v = dump.get((space, loc, a), 0)
                h = fnv(h, v >> 32)
                h = fnv(h, v & 0xFFFFFFFF)
            out.append(f"K P {i} {sp} {h:016x}")
    return out


# ------------------------------------------------------------------------------------ tests
def T(name, body, data="bits", edits=None, stop=None, mabs=16, lbz=False, note=""):
    p = Prog(name, body, init_mabs=mabs, data=data, edits=edits or [], note=note, lb_zero=lbz)
    p.stop = stop   # (word index, kind 1 E_RANGE / 2 E_UNSUPPORTED, field)
    return p


def tests_common(m: int) -> List[Prog]:
    """Tests that run in both files (m = init_mabs). Names get the suffix of the file."""
    s = f"_{m}"
    t = [
        # ---------------------------------------------------------------- L1BM -> PE
        T("p_bcast" + s, ["l1bmp $lb3 $lr0v", "l1bmp $llb5 $llr8v", "l1bmp $lb9 $r40v", "l1bmp $lb7 $t"], mabs=m),
        T("p_multi" + s, ["l1bmp $lb7 $lr2v $ls4v $lm8v $ln10v"], mabs=m),
        T("m_bcast" + s, ["l1bmm $lb16 $lr0v", "l1bmm $llb32 $llr8v", "l1bmm $lb4 $t", "nop", "l1bmm $llb64 $llm0v"],
          mabs=m),
        T("m4_bcast" + s, ["l1bmm4 $lb16 $lr0v", "l1bmm4 $llb64 $llr8v", "l1bmm4 $lb256 $t"], mabs=m),
        T("d_dist" + s, ["l1bmd $lb0 $lr0v", "l1bmd+1 $lb64 $ls0v", "l1bmd-3 $lb128 $ls8v", "l1bmd $lb256 $t"], mabs=m),
        T("unaligned" + s, ["l1bmm $lb16 $lr0v", "l1bmm $llb32 $llr8v", "l1bmm4 $lb64 $ls0v"], mabs=m,
          edits=[(0, {"l1bm_ladr": 18}), (1, {"l1bm_ladr": 37}), (2, {"l1bm_ladr": 70})]),
        T("d_shift_low" + s, ["l1bmd $lb64 $lr0v", "l1bmd $lb128 $ls0v"], mabs=m,
          edits=[(0, {"l1bm_ladr": 64 + 62}), (1, {"l1bm_ladr": 128 + 1})]),
        T("read_me0" + s, ["l1bmm $lb16 $lr8v", "l1bmm $lb16 $lr16v"], mabs=m,
          edits=[(0, {"l1bm_me": 0}), (1, {"l1bm_me": 0, "l1bm_bmode": 0, "l1bm_ladr": 0})]),
        T("zflush" + s, ["l1bmm/0101 $lb16 $lr0v", "lpassa $lbf $ls0v", "l1bmm/ll0110 $llb32 $llr16v",
                         "lpassa $lbf $ls8v"], mabs=m),
        # the L1BM and $lbi as the reset leaves them (zero); the unit's reset clears them
        T("lb_clear" + s, ["l1bmm $lb16 $lr0v", "l1bmm4 $llb64 $llr8v", "l1bmm@0 $ls0v $lb1000"],
          mabs=m, lbz=True),
        # ---------------------------------------------------------------- PE -> L1BM
        T("m_write" + s, ["l1bmm@0 $lr0v $lb16", "l1bmm@0 $llr8v $llb64", "l1bmm@0 $t $lb4",
                          "l1bmm@0 $lm6v $llb128", "l1bmm@0 $ln4v $lb200"], mabs=m),
        T("m_write_absent" + s, ["l1bmm@5 $lr4v $lb32", "l1bmm@3 $llr0v $llb64"], mabs=m),
        T("m4_write" + s, ["l1bmm4@0 $lr0v $lb64", "l1bmm4@3 $ls2v $lb16", "l1bmm4@0 $llr0v $llb128",
                           "l1bmm4@2 $lr0v $llb256"], mabs=m),
        T("gather" + s, ["l1bmd $lr0v $lb0", "l1bmd+1 $lr0v $lb256", "l1bmd-5 $ln4v $lb512", "l1bmd $t $lb768"],
          mabs=m),
        T("gather_shift_low" + s, ["l1bmd $lr0v $lb64", "l1bmd $lr0v $lb128"], mabs=m,
          edits=[(0, {"l1bm_ladr": 64 + 62}), (1, {"l1bm_ladr": 128 + 1})]),
        T("write_me" + s, ["l1bmm@0 $lr0v $lb16", "l1bmm@0 $lr0v $lbi", "l1bmm@0 $lr8v $lb64"], mabs=m,
          edits=[(0, {"l1bm_me": 0}), (1, {"l1bm_me": 1, "l1bm_ladr": 32}), (2, {"l1bm_bmode": 0})]),
        # ---------------------------------------------------------------- turnaround
        T("ta_m" + s, ["l1bmm@0 $lr0v $lb0", "l1bmm $lbi $lm0v;l1bmm@0 $lr8v $lb16", "l1bmm $lbi $lm8v"], mabs=m),
        T("ta_d" + s, ["l1bmd+1 $lr0v $lb0", "l1bmd-1 $lr0v $lb256;l1bmd+1 $lbi $ls0v", "l1bmd-1 $lbi $ls8v",
                       "nop", "l1bmd $lb0 $ls16v", "l1bmd $lb256 $ls24v"], mabs=m),
        T("ta_m4" + s, ["l1bmm4@0 $lr0v $lb16", "l1bmm4 $lbi $lm0v", "l1bmm4@0 $llr0v $llb64",
                        "l1bmm4 $llbi $llm16v"], mabs=m),
        T("ta_lsb" + s, ["l1bmm@0 $llr0v $llb0", "l1bmd $lr8v $lbi", "l1bmd $lbi $t"], mabs=m),
        T("ta_lbi_only" + s, ["l1bmm@0 $lr0v $lbi", "l1bmm $lbi $lr8v", "ipassa $r0v $r60v"], mabs=m,
          edits=[(2, {"__copy__": 1, "pe_rfc0_wadr": 40, "pe_rfc0_wadr_c1": 42, "pe_rfc0_wadr_c2": 44,
                      "pe_rfc0_wadr_c3": 46})]),
        T("ta_nofwd" + s, ["l1bmm@0 $lr0v $lb0", "l1bmm@0 $lr4v $lb64;noforward", "l1bmm $lbi $lr8v",
                           "nop", "l1bmm $lbi $lr12v"], mabs=m,
          edits=[(4, {"__copy__": 2, "pe_rfc0_wadr": 24, "pe_rfc0_wadr_c1": 26, "pe_rfc0_wadr_c2": 28,
                      "pe_rfc0_wadr_c3": 30, "ll": 3})]),
        T("ta_reader_fields" + s, ["l1bmm4@0 $lr0v $lb16", "l1bmm4 $lbi $lm0v", "l1bmd+1 $lr0v $lbi",
                                   "l1bmd+1 $lbi $lm16v"], mabs=m,
          edits=[(1, {"l1bm_bmode": 1}), (3, {"l1bm_ladr": 8})]),
        T("ta_start" + s, ["l1bmm@0 $lr0v $lb0", "l1bmm $lbi $lr8v"], mabs=m, edits=[(0, {"ll": 0})]),
        # ---------------------------------------------------------------- $lbf
        T("lbf" + s, ["l1bmm $lb16 $lr0v", "lpassa $lbf $ls0v", "l1bmp $lb40 $nowrite", "lpassa $lbf $ls8v",
                      "l1bmm@0 $lr4v $lbi", "lpassa $lbf $ls16v"], mabs=m),
        # (l1bmm@0: the broadcast of the first word also fills MAB 1, which does not exist in N_MAB = 1)
        T("lbf_nofwd" + s, ["l1bmm $lb16 $lr0v", "l1bmp $lb3 $lr4v;noforward", "lpassa $lbf $ls0v",
                            "l1bmm@0 $lr0v $lbi", "nop", "l1bmm $lbi $lr8v;noforward", "nop",
                            "l1bmm $lbi $lr12v"], mabs=m),
        # ---------------------------------------------------------------- reductions
        T("r16_d" + s, ["l1bmrdfadd $lr0v $lb64", "l1bmrdmax $ls0v $lb128", "l1bmrdmin $lm0v $lb192"], data="f64",
          mabs=m),
        T("r16_f" + s, ["l1bmrffadd $lr0v $lb64", "l1bmrfmax $ls0v $lb128", "l1bmrfmin $lm0v $lb192",
                        "l1bmrffadd $llr8v $llb256"], data="f32", mabs=m),
        T("r16_h" + s, ["l1bmrhfadd $lr0v $lb64", "l1bmrhmax $ls0v $lb128", "l1bmrhmin $lm0v $lb192",
                        "l1bmrhfadd $llr8v $lb256"], data="f16", mabs=m),
        T("r16_int" + s, ["l1bmrliadd $lr0v $lb64", "l1bmriiadd $ls0v $lb128", "l1bmrsiadd $lm0v $lb192",
                          "l1bmrlbor $llr8v $llb256"], data="int", mabs=m),
        T("r16_bits" + s, ["l1bmrlband $lr0v $lb64", "l1bmriand $ls0v $lb128", "l1bmrsor $lm0v $lb192",
                           "l1bmrsbor $llr8v $llb256", "l1bmribor $ln0v $lb320", "l1bmrlor $t $lb384"],
          data="bits", mabs=m),
        T("r4_mix" + s, ["l1bmr4dfadd $lr0v $lb64", "l1bmr4ffadd $llr8v $llb128", "l1bmr4hfadd $ls0v $lb256",
                         "l1bmr4siadd $lm0v $lb320", "l1bmr4iband $ln0v $lb384", "l1bmr4hmax $t $lb448"],
          data="f16", mabs=m),
        T("r_ext" + s, ["l1bmrffadd $lr0ve $llb0", "l1bmrfmax $ls0ve $llb64", "l1bmr4ffadd $lm0ve $llb128",
                        "l1bmr4fmin $ln0ve $llb256"], data="f16", mabs=m),
        T("r_round" + s, ["l1bmrffaddr $llr0v $lb0", "l1bmrfmaxr $llr8v $lb64", "l1bmr4ffaddr $lls0v $lb128",
                          "l1bmrffaddr $lr16v $lb256", "l1bmrfminr $lm0ve $lb320"], data="f32", mabs=m),
        T("r_minmax_er" + s, ["l1bmrfmax $lr0ve $llb0", "l1bmr4fmin $ls0ve $llb64", "l1bmrfmaxr $llr8v $lb192",
                              "l1bmr4fminr $lls8v $lb256", "l1bmrfmaxr $lm0v $lb320", "l1bmrfmaxr $ln0ve $lb384"],
          data="f16", mabs=m),
        T("r_minmax_r32" + s, ["l1bmrfmaxr $llr0v $lb0", "l1bmrfminr $lls0v $lb64", "l1bmr4fmaxr $llr8v $lb128"],
          data="f32", mabs=m),
        T("r_wl_edits" + s, ["l1bmrffadd $lr0ve $llb0", "l1bmrhfadd $lr8v $lb64", "l1bmrdfadd $lr16v $lb128",
                             "l1bmr4ffaddr $llr0v $lb192"], data="f16", mabs=m,
          edits=[(0, {"l1bm_wl": 0}), (1, {"l1bm_wl": 1}), (2, {"l1bm_bmode": 0}), (3, {"l1bm_wl": 1})]),
        T("r_turn" + s, ["l1bmrhfadd $lr0v $lbi", "l1bmm $lbi $lr8v", "l1bmr4ffadd $lls16v $llbi",
                         "l1bmm4 $llbi $llm0v", "l1bmr4hmax $lr0v $lb0", "l1bmm4 $lbi $lm16v;l1bmr4hmin $ls0v $lb64",
                         "l1bmm4 $lbi $ln0v"], data="f16", mabs=m),
        # ---------------------------------------------------------------- sequences
        T("seq_roundtrip" + s, ["l1bmd $lr0v $lb0", "nop/2", "l1bmd $lb0 $ls0v", "nop", "l1bmm@0 $ls0v $lb64",
                                "nop/2", "l1bmm $lb64 $lm0v"], mabs=m),
        T("seq_reduce_bcast" + s, ["l1bmrffadd $lr0v $lb0", "nop/2", "l1bmm $lb0 $ls0v", "l1bmp $lb2 $lm0v"],
          data="f32", mabs=m),
        # ---------------------------------------------------------------- stops (contract 3)
        T("e_range_read" + s, ["l1bmm $lb16 $lr0v", "l1bmp $lb1022 $lr8v"], mabs=m, stop=(1, 1, 0)),
        T("e_range_write" + s, ["l1bmm@0 $lr0v $lb16", "l1bmm@0 $lr0v $lb1016"], mabs=m, stop=(1, 1, 0)),
        T("e_range_gather" + s, ["l1bmd $lr0v $lb0", "l1bmd $lr0v $lb960"], mabs=m, stop=(1, 1, 0)),
        T("e_range_wrap" + s, ["l1bmm $lb16 $lr0v", "l1bmp $lb8190 $lr8v"], mabs=m, stop=(1, 1, 0)),
        T("e_unsup_dr" + s, ["l1bmm $lb16 $lr0v", "l1bmrdfaddr $ls0v $lb0"], data="f64", mabs=m,
          stop=(1, 2, F_ROUND)),
        T("e_unsup_de" + s, ["l1bmm $lb16 $lr0v", "l1bmrdfadd $ls0ve $lb0"], data="f64", mabs=m,
          stop=(1, 2, F_EXT)),
        T("e_unsup_rgather" + s, ["l1bmm $lb16 $lr0v", "l1bmrdfadd $ls0v $lb0"], data="f64", mabs=m,
          stop=(1, 2, F_RMODE), edits=[(1, {"l1bm_bmode": 3})]),
    ]
    return t


def tests_m1() -> List[Prog]:
    t = tests_common(1)
    t += [
        # with only MAB 0, the reductions are of one value and zeros
        T("r16_specials_1", ["l1bmrffadd $lr0v $lb64", "l1bmrfmax $ls0v $lb128", "l1bmrfmin $lm0v $lb192",
                             "l1bmriand $ln0v $lb256"], data="f32", mabs=1),
        T("trap_none_1", ["l1bmd $lb768 $lr0v", "l1bmm4 $llb896 $llr8v"], mabs=1),
    ]
    return t


def tests_m16() -> List[Prog]:
    return tests_common(16)


# --------------------------------------------------------------------------------- generator
def emit(p: Prog, words: List[str], dump: Dict, npe: int) -> List[str]:
    seed = LP.Init(p).seed
    lines = [f"# {p.name}: {' | '.join(p.body)}" + (f"  edits {p.edits}" if p.edits else "") +
             (f"  stop {p.stop}" if p.stop else ""),
             f"T {p.name} {p.init_mabs} {seed:016x} {LP.STYLES[p.data]} {int(p.lb_zero)}"]
    for k, w in enumerate(words):
        kind, arg = 0, 0
        if p.stop and k == p.stop[0]:
            kind, arg = p.stop[1], p.stop[2]
        lines.append(f"W {kind} {arg} {int(w, 2):0107x}")
        if kind:
            break
    lines += hashes(dump, npe)
    lines.append("E")
    return lines


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="comma separated test names (written to build/, not fixed/)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--no-model", action="store_true")
    a = ap.parse_args(argv)
    sets = {"m1": tests_m1(), "m16": tests_m16()}
    if a.only:
        keep = set(a.only.split(","))
        sets = {k: [p for p in v if p.name in keep] for k, v in sets.items()}
    allp = [p for v in sets.values() for p in v]
    names = [p.name for p in allp]
    assert len(names) == len(set(names)), "duplicate test names"
    t0 = time.time()
    res = LP.run(allp, BUILD / "emu", jobs=a.jobs)
    # stop tests: the expected state is the emulator's state before the stopping word
    stops = [p for p in allp if p.stop]
    tr = {}
    if stops:
        trunc = []
        for p in stops:
            q = Prog(p.name + "__pre", p.body[:p.stop[0]], init_mabs=p.init_mabs, data=p.data,
                     edits=[e for e in p.edits if e[0] < p.stop[0]], seed=p.seed, lb_zero=p.lb_zero)
            q.name = p.name   # the same data (Init uses the name)
            trunc.append(q)
        tr = LP.run(trunc, BUILD / "emu_pre", jobs=a.jobs)
    print(f"[official] {len(allp)} programs, {time.time() - t0:.0f} s")
    ok = True
    for fname, progs in sets.items():
        out = [f"# WP31 L1BM unit tests ({fname}): generated by gen_tests.py from the official emulator.",
               "# Format: tb_l1bm_env.v. Do not edit by hand."]
        npe_file = 4 * (1 if fname == "m1" else 16)
        for p in progs:
            r, ini, words = res[p.name]
            if r.asm_err:
                print(f"{p.name}: ASSEMBLER ERROR {r.asm_err.strip().splitlines()[-1][:160]}")
                ok = False
                continue
            if p.stop:
                rp, _, pre_words = tr[p.name]
                if rp.asm_err or not rp.ok:
                    print(f"{p.name}: the run before the stop failed: {rp.asm_err or rp.emu_out[-200:]}")
                    ok = False
                    continue
                dump = rp.dump
                mwords = words[:p.stop[0]]
                assert [w for w in pre_words] == mwords, f"{p.name}: words before the stop differ"
            else:
                if not r.ok:
                    print(f"{p.name}: EMULATOR rc={r.emu_rc} {r.emu_out.strip()[-200:]}")
                    ok = False
                    continue
                dump = r.dump
                mwords = words
            if len(words) != len([b for b in p.body for _ in range(int(b.split('/')[1]) if b.startswith('nop/') else 1)]):
                print(f"{p.name}: {len(words)} words for {len(p.body)} lines")
            note = ""
            if not a.no_model:
                for nm in ((1, 16) if p.init_mabs == 1 else (16,)):
                    try:
                        bad, lines = LP.compare(p, _Res(dump), ini, mwords, n_mab=nm, verbose=3)
                    except Exception as e:  # noqa
                        bad, lines = [1], [f"  model error {e!r}"]
                    note += f" model(N_MAB={nm}): {'ok' if not bad else 'DIFF %d' % len(bad)}"
                    if bad:
                        print(f"{p.name}: the model with N_MAB = {nm} differs from the emulator")
                        for ln in lines:
                            print(ln)
                        if nm == 1:
                            ok = False   # not a valid reduced-topology test
            print(f"{p.name}: {len(mwords)} words{note}")
            out += emit(p, words, dump, npe_file)
        dst = (BUILD if a.only else FIXED) / f"{fname}.tst"
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
        print(f"-> {dst} ({len(progs)} tests)")
    return 0 if ok else 1


class _Res:
    def __init__(self, dump):
        self.dump = dump


if __name__ == "__main__":
    sys.exit(main())

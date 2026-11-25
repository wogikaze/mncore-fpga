#!/usr/bin/env python3
"""WP32: probes of the L2BM semantics on the official emulator, compared with l2model.py.

    python mncore/sim/tb/l2bm/probe.py <set> [--jobs 8] [--show N]

Each probe is a program (l2prog.Prog); the official result (L2BM of n0c0, L1BM of n0c0b0..b7)
is compared with the model (l2model.py) on the same j words. The sets below record the probes
that fixed the semantics (rtl/l2bm/README.md); gen_tests.py turns the important ones into tests.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import l2model as M  # noqa: E402
import l2prog as LP  # noqa: E402
from l2prog import Prog  # noqa: E402

BUILD = HERE / "build"


def model_dump(p: Prog, ini: LP.Init, words, n_l1b=8):
    st = M.L2State(n_l1b=n_l1b)
    for a, v in enumerate(ini.l2):
        st.l2bm[a] = v
    for b, vals in enumerate(ini.l1):
        if b < n_l1b:
            for a, v in enumerate(vals):
                st.l1bm[b][a] = v
    for w in words:
        M.l2_step(st, LP.fields(w))
    return st


def compare(p, r, ini, words, n_l1b=8, show=6):
    st = model_dump(p, ini, words, n_l1b)
    bad = []
    for (space, loc, a), v in sorted(r.dump.items()):
        if space == "L2BM" and loc == "n0c0" and a < LP.L2:
            g = st.l2bm[a]
        elif space == "L1BM" and loc.startswith("n0c0b"):
            b = int(loc[5:])
            if b >= n_l1b:
                continue
            g = st.l1bm[b][a]
        else:
            continue
        if g != v:
            bad.append((space, loc, a, v, g))
    lines = [f"    {s} {l} {a:#06x}: official {v:016x} model {g:016x}" for s, l, a, v, g in bad[:show]]
    return bad, lines


def T(name, body, **kw):
    return Prog(name, body, **kw)


SETS = {
    # basic forms, 8 L1Bs with data
    "basic": [
        T("b_bcast", ["l2bmb $lc64 $lb128"], l1bs=8),
        T("b_bcast_set", ["l2bmb@[0,4] $lc64 $lb128", "nop/2", "l2bmb@5/6 $lc256 $lb512"], l1bs=8),
        T("b_bcast2", ["l2bmb2 $lc128 $lb64", "nop/2", "l2bmb2@2/1 $lc512 $lb256"], l1bs=8),
        T("b_distrib", ["l2bmd $lc128 $lb64", "nop/2", "l2bmd@[1,3] $lc512 $lb256"], l1bs=8),
        T("b_from", ["l2bm@5 $lb64 $lc256", "nop/3", "l2bm@0 $lb128 $lc512"], l1bs=8),
        T("b_gather", ["l2bmd $lb64 $lc256"], l1bs=8),
        T("b_reduce", ["l2bmrliadd $lb64 $lc256", "nop/3", "l2bmrliadd@[0,4] $lb128 $lc512",
                       "nop/3", "l2bmrlband@1/6 $lb128 $lc768"], l1bs=8, data="int"),
        T("b_reduce2", ["l2bmr2liadd $lb64 $lc256", "nop/3", "l2bmr2sbor $lb128 $lc512"], l1bs=8, data="int"),
        T("b_imcast", ["l2bmi@0/4 $lb64 $lb128", "nop/3", "l2bmi@3 $lb256 $lb512", "nop/3",
                       "l2bmi@1/2 $lb64 $lb64"], l1bs=8),
    ],
    # reductions: identities of every operation (sets), formats
    "ident": [
        T("i_" + op, [f"l2bmr{op}@{s} $lb64 $lc256" if s else f"l2bmr{op} $lb64 $lc256"],
          l1bs=8, data={"d": "f64", "f": "f32", "h": "f16", "l": "int", "i": "int", "s": "int"}[op[0]])
        for op in ("dfadd", "ffadd", "hfadd", "dmax", "fmax", "hmax", "dmin", "fmin", "hmin",
                   "liadd", "siadd", "lband", "iband", "land", "sand", "lbor", "lor", "ior")
        for s in ("[0,4]",)
    ],
    # is l2bm@n a bor reduction over the set {n}? is the gather a reduction? (edited fields)
    "edits": [
        T("e_from_set", ["l2bm@5 $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_immode": 1})]),
        T("e_from_iadd", ["l2bm@5 $lb64 $lc256"], l1bs=8, data="int",
          edits=[(0, {"l2bm_immode": 7, "l2bm_opcode": 8})]),
        T("e_from_fadd", ["l2bm@5 $lb64 $lc256"], l1bs=8, data="f32",
          edits=[(0, {"l2bm_opcode": 0, "l2bm_dmode": 1})]),
        T("e_gather_fadd", ["l2bmd $lb64 $lc256"], l1bs=8, data="f32",
          edits=[(0, {"l2bm_opcode": 0, "l2bm_dmode": 1})]),
        T("e_gather_band", ["l2bmd $lb64 $lc256"], l1bs=8, data="int",
          edits=[(0, {"l2bm_opcode": 9, "l2bm_dmode": 0})]),
        T("e_gather_set", ["l2bmd $lb64 $lc256"], l1bs=8, data="int",
          edits=[(0, {"l2bm_immode": 3, "l2bm_l1adr": 4})]),
        T("e_bcast_op", ["l2bmb $lc64 $lb128"], l1bs=8, data="f32",
          edits=[(0, {"l2bm_opcode": 0, "l2bm_dmode": 1})]),
        T("e_reduce2_set", ["l2bmr2liadd $lb64 $lc256"], l1bs=8, data="int",
          edits=[(0, {"l2bm_immode": 1, "l2bm_l1adr": 2})]),
        T("e_imcast_op", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, data="f32",
          edits=[(0, {"l2bm_opcode": 0, "l2bm_dmode": 1})]),
    ],
}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("set", choices=sorted(SETS))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--show", type=int, default=6)
    ap.add_argument("--only")
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args(argv)
    progs = SETS[a.set]
    if a.only:
        keep = set(a.only.split(","))
        progs = [p for p in progs if p.name in keep]
    t0 = time.time()
    dprogs = [p for p in progs if p.dar]
    progs = [p for p in progs if not p.dar]
    res = LP.run(progs, BUILD / f"probe_{a.set}", jobs=a.jobs, reuse=a.reuse) if progs else {}
    dres = LP.run(dprogs, BUILD / f"probe_{a.set}_dar", jobs=a.jobs, reuse=a.reuse, observe_dar=True) if dprogs else {}
    print(f"[official] {len(progs) + len(dprogs)} programs, {time.time() - t0:.0f} s")
    for p in dprogs:
        r, ini, words = dres[p.name]
        if r.asm_err:
            print(f"{p.name}: ASSEMBLER ERROR {r.asm_err.strip().splitlines()[-1][:200]}")
            continue
        if not r.ok:
            print(f"{p.name}: EMULATOR rc={r.emu_rc} {r.emu_out.strip()[-300:]}")
            continue
        nbody = len([w for w in words]) - 6      # the observer adds 6 nops
        st = model_dump(p, ini, words[:nbody])
        a0, n = p.dar
        got = LP.dar_of(r.dump, a0, n)
        want = [st.dar[(a0 + i) % 1024] for i in range(n)]
        bad = [(a0 + i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w]
        print(f"{p.name}: DAR[{a0}..{a0 + n - 1}] {'ok' if not bad else 'DIFF %d' % len(bad)}"
              f"  official {got[:12]}")
        for e, g, w in bad[:a.show]:
            print(f"    DAR[{e}]: official {g} model {w}")
    for p in progs:
        r, ini, words = res[p.name]
        if r.asm_err:
            print(f"{p.name}: ASSEMBLER ERROR {r.asm_err.strip().splitlines()[-1][:200]}")
            continue
        if not r.ok:
            print(f"{p.name}: EMULATOR rc={r.emu_rc} {r.emu_out.strip()[-300:]}")
            continue
        if p.pes:
            import l2pe
            out = []
            for order in l2pe.ORDERS:
                try:
                    bad, lines = l2pe.compare(p, r.dump, ini, words, n_l1b=p.l1bs, order=order, show=a.show)
                    out.append(f"{order}={'ok' if not bad else len(bad)}")
                except Exception as e:  # noqa
                    out.append(f"{order}=error {e!r}")
            print(f"{p.name}: {len(words)} words, " + " ".join(out))
            continue
        try:
            bad, lines = compare(p, r, ini, words, show=a.show)
        except Exception as e:  # noqa
            print(f"{p.name}: model error {e!r}")
            continue
        print(f"{p.name}: {len(words)} words, {'ok' if not bad else 'DIFF %d' % len(bad)}")
        for ln in lines:
            print(ln)
    return 0


SETS["gset"] = [
    T(f"g_set_{a}_{i}", ["l2bmd $lb64 $lc256"], l1bs=8, data="bits",
      edits=[(0, {"l2bm_l1adr": a, "l2bm_immode": i})])
    for a, i in ((0, 0), (1, 0), (5, 0), (0, 1), (2, 1), (0, 3), (4, 3), (0, 6), (1, 6), (0, 5), (7, 7), (3, 7))
]

SETS["odd"] = [
    # bdmode 11 and other combinations the assembler never makes
    T("o_gw_bd3", ["l2bmb $lc64 $lb128"], l1bs=8, edits=[(0, {"l2bm_bdmode": 3})]),
    T("o_lw_bd3", ["l2bmrliadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_bdmode": 3})]),
    T("o_im_bd1", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l2bm_bdmode": 1})]),
    T("o_im_bd2", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l2bm_bdmode": 2})]),
    T("o_im_all", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l2bm_immode": 7})]),
    T("o_red_dm3", ["l2bmrliadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_dmode": 3})]),
    T("o_red2_dm3", ["l2bmr2liadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_dmode": 3})]),
    T("o_from_dm3", ["l2bm@3 $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_dmode": 3})]),
    T("o_red_op3", ["l2bmrliadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_opcode": 3})]),
    T("o_red_op11", ["l2bmrliadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_opcode": 11})]),
    T("o_red_op15", ["l2bmrliadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_opcode": 15})]),
    T("o_red_op5", ["l2bmrliadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_opcode": 5})]),
    # unaligned addresses (only by editing: the fields are in units of 8 / 16 long words)
    T("u_bcast_b8", ["l2bmb $lc64 $lb128"], l1bs=8, edits=[(0, {"l1bm_gadr": 17})]),
    T("u_bcast2_c16", ["l2bmb2 $lc128 $lb64"], l1bs=8, edits=[(0, {"l2bm_ladr": 9})]),
    T("u_dist_c16", ["l2bmd $lc128 $lb64"], l1bs=8, edits=[(0, {"l2bm_ladr": 10})]),
    T("u_from_b8", ["l2bm@5 $lb64 $lc256"], l1bs=8, edits=[(0, {"l1bm_gadr": 9})]),
    T("u_gather_c16", ["l2bmd $lb64 $lc256"], l1bs=8, edits=[(0, {"l2bm_ladr": 17})]),
    T("u_red2_c16", ["l2bmr2liadd $lb64 $lc256"], l1bs=8, data="int", edits=[(0, {"l2bm_ladr": 19, "l1bm_gadr": 9})]),
    T("u_im_b8", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l1bm_gadr": 9})]),
    T("u_im_hi", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l2bm_ladr": 512 + 8})]),
    # noforward
    T("n_nofwd", ["l2bmb $lc64 $lb128", "nop/3", "l2bmrliadd $lb64 $lc256"], l1bs=8, data="int",
      edits=[(0, {"ll": 3}), (4, {"ll": 3})]),
]


SETS["dar"] = [
    T("d_basic", ["l2bmdars $lc0@.0 $dar0; l2bmdarw"], data="dar", dar=(0, 16)),
    T("d_later", ["l2bmdars $lc64@.0 $dar16", "nop", "l2bmdarw", "l2bmdarw", "nop/2", "l2bmdarw"],
      data="dar", dar=(12, 32)),
    T("d_first", ["l2bmdarw", "l2bmdars $lc128@.0 $dar4; l2bmdarw", "l2bmdarw"], data="dar", dar=(0, 16)),
    T("d_wrap", ["l2bmdars $lc0@.0 $dar1022; l2bmdarw", "l2bmdarw"], data="dar", dar=(1016, 16)),
    T("d_wrap0", ["l2bmdars $lc0@.0 $dar1022; l2bmdarw", "l2bmdarw"], data="dar", dar=(0, 8)),
    T("d_buf512", ["l2bmdars $lc256@.0 $dar0; l2bmdarw"] + ["l2bmdarw"] * 128, data="dar", dar=(504, 16)),
    T("d_l2b1", ["l2bmdars $lc0@.1 $dar0; l2bmdarw", "l2bmdarw"], data="dar", dar=(0, 8)),
    T("d_restart", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdarw", "l2bmdars $lc512@.0 $dar4; l2bmdarw"],
      data="dar", dar=(0, 16)),
    T("d_nofwd", ["l2bmdars $lc0@.0 $dar8; l2bmdarw", "l2bmdarw"], data="dar", dar=(4, 16),
      edits=[(0, {"ll": 3}), (1, {"ll": 3})]),
    T("d_with_l2", ["l2bmdars $lc0@.0 $dar0", "l2bmb $lc64 $lb128; l2bmdarw", "nop/2",
                    "l2bmrliadd $lb64 $lc0; l2bmdarw"], data="dar", dar=(0, 8)),
    T("d_ll0", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdarw", "l2bmdarw"], data="dar", dar=(0, 16),
      edits=[(1, {"ll": 0})]),
    T("d_l2b2", ["l2bmdars $lc0@.0 $dar0; l2bmdarw"], data="dar", dar=(0, 8),
      edits=[(0, {"l2bm_opcode": 2})]),
    T("d_l2b3", ["l2bmdars $lc0@.0 $dar0; l2bmdarw"], data="dar", dar=(0, 8),
      edits=[(0, {"l2bm_opcode": 3})]),
    T("d_lwrite", ["l2bmdars $lc0@.0 $dar0; l2bmdarw"], data="dar", dar=(0, 8),
      edits=[(0, {"l2bm_lwrite": 1})]),
]


SETS["same"] = [
    T("s_bcast_read", ["l2bmb $lc64 $lb16; l1bmm $lb16 $lr0v"], pes=True),
    T("s_pew_from", ["l1bmm@0 $lr0v $lb16; l2bm@0 $lb16 $lc256"], pes=True),
    T("s_ww", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb16"], pes=True),
    T("s_ww_dist", ["l2bmd $lc64 $lb16; l1bmm@0 $llr0v $llb16"], pes=True),
    T("s_gath", ["l2bmd $lb16 $lc256; l1bmd $lr0v $lb16"], pes=True),
    T("s_red", ["l2bmrliadd $lb16 $lc256; l1bmrliadd $lr0v $lb16"], pes=True, data="int"),
    T("s_imc_read", ["l2bmi@1 $lb16 $lb64; l1bmm $lb64 $lr0v"], pes=True),
    T("s_dist_read", ["l2bmb $lc64 $lb16; l1bmd $lb16 $lr0v"], pes=True),
    T("s_bcast_ta", ["l1bmm@0 $lr0v $lb16", "l2bmb $lc64 $lb16; l1bmm $lbi $lr8v"], pes=True),
    T("s_red_ta", ["l2bmrliadd $lb16 $lc256; l1bmrliadd $lr0v $lbi", "l1bmm $lbi $lr8v"], pes=True, data="int"),
]


SETS["ww"] = [
    T("w_m_b16", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb16"], pes=True),
    T("w_m_b20", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb20"], pes=True),
    T("w_m_b0", ["l2bmb $lc64 $lb32; l1bmm@0 $lr0v $lb24"], pes=True),
    T("w_mw_b16", ["l2bmb $lc64 $lb16; l1bmm@0 $llr0v $llb16"], pes=True),
    T("w_m4_b16", ["l2bmb $lc64 $lb16; l1bmm4@0 $lr0v $lb16"], pes=True),
    T("w_m4_b32", ["l2bmb $lc64 $lb32; l1bmm4@0 $lr0v $lb16"], pes=True),
    T("w_m4w_b0", ["l2bmb $lc64 $lb0; l1bmm4@0 $llr0v $llb16"], pes=True),
    T("w_d_b0", ["l2bmb $lc64 $lb0; l1bmd $lr0v $lb0"], pes=True),
    T("w_d_b64", ["l2bmb $lc64 $lb64; l1bmd $lr0v $lb0"], pes=True),
    T("w_d_b128", ["l2bmb $lc64 $lb128; l1bmd $lr0v $lb64"], pes=True),
    T("w_dist_m", ["l2bmd $lc64 $lb8; l1bmm@0 $lr0v $lb16"], pes=True),
    T("w_dist_mw", ["l2bmd $lc64 $lb16; l1bmm@0 $llr0v $llb24"], pes=True),
    T("w_b2_m4", ["l2bmb2 $lc64 $lb32; l1bmm4@0 $lr0v $lb16"], pes=True),
    T("w_imc_m", ["l2bmi@1 $lb16 $lb64; l1bmm@0 $lr0v $lb68"], pes=True),
    T("w_red_m", ["l2bmb $lc64 $lb16; l1bmrliadd $lr0v $lb20"], pes=True, data="int"),
    T("w_red4_m", ["l2bmb $lc64 $lb0; l1bmr4liadd $lr0v $lb16"], pes=True, data="int"),
    T("w_me0", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lbi"], pes=True, edits=[(0, {"l1bm_me": 0, "l1bm_ladr": 20})]),
    T("w_nofwd", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb20"], pes=True, edits=[(0, {"ll": 3})]),
]


SETS["dar2"] = [
    T("q1_consec", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar", dar=(0, 16)),
    T("q1_consec_b", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar",
      dar=(96, 16)),
    T("q2_alone", ["l2bmdars $lc0@.0 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdarw"], data="dar", dar=(0, 8)),
    T("q2_alone_b", ["l2bmdars $lc0@.0 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdarw"], data="dar", dar=(96, 8)),
    T("q3_nop", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "nop", "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar",
      dar=(96, 8)),
    T("q3_nop_b", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "nop", "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar",
      dar=(0, 8)),
    T("q5_three", ["l2bmdars $lc0@.0 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdars $lc128@.0 $dar200", "l2bmdarw"],
      data="dar", dar=(0, 8)),
    T("q5_three_b", ["l2bmdars $lc0@.0 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdars $lc128@.0 $dar200", "l2bmdarw"],
      data="dar", dar=(96, 8)),
    T("q5_three_c", ["l2bmdars $lc0@.0 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdars $lc128@.0 $dar200", "l2bmdarw"],
      data="dar", dar=(196, 8)),
    T("q6_odd_nop", ["l2bmdars $lc0@.0 $dar1; l2bmdarw", "nop", "l2bmdars $lc192@.0 $dar1021; l2bmdarw"], data="dar",
      dar=(1016, 16)),
    T("q8_l2b3", ["l2bmdars $lc64@.0 $dar8; l2bmdarw"], data="dar", dar=(4, 8), edits=[(0, {"l2bm_opcode": 3})]),
    T("q8_l2b2", ["l2bmdars $lc64@.0 $dar8; l2bmdarw"], data="dar", dar=(4, 8), edits=[(0, {"l2bm_opcode": 2})]),
    T("q9_other", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmb $lc0 $lb0", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
      data="dar", dar=(96, 8)),
    T("q10_darw_between", ["l2bmdars $lc0@.0 $dar0", "l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
      data="dar", dar=(96, 8)),
]


SETS["dar3"] = [
    T("r1_mv", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "mvp/n64 $lc1024@0.0 $d0@0", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
      data="dar", dar=(96, 8)),
    T("r1_mv_b", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "mvp/n64 $lc1024@0.0 $d0@0", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
      data="dar", dar=(0, 8)),
    T("r2_ll0", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc128@.0 $dar50; l2bmdarw",
                 "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar", dar=(96, 8), edits=[(1, {"ll": 0})]),
    T("r3_nofwd", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc128@.0 $dar50; l2bmdarw"], data="dar",
      dar=(0, 8), edits=[(1, {"ll": 3})]),
    T("r4_darw_only_first", ["l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar", dar=(96, 8)),
    T("r5_long", ["l2bmdars $lc0@.0 $dar0", "l2bmdars $lc64@.0 $dar100", "nop", "l2bmdars $lc128@.0 $dar200; l2bmdarw"],
      data="dar", dar=(196, 8)),
]


SETS["dar4"] = [
    T("s1_l2b1_then_0", ["l2bmdars $lc0@.1 $dar0; l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar",
      dar=(0, 8)),
    T("s2_l2b0_then_1", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc64@.1 $dar100; l2bmdarw"], data="dar",
      dar=(0, 8)),
    T("s3_sep_1_then_0", ["l2bmdars $lc0@.1 $dar0; l2bmdarw", "nop", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
      data="dar", dar=(96, 8)),
    T("s4_three", ["l2bmdars $lc0@.1 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdars $lc128@.0 $dar200",
                   "l2bmdarw", "l2bmdarw"], data="dar", dar=(0, 8)),
]


SETS["fields"] = [
    T("f_bcast_op3", ["l2bmb $lc64 $lb128"], l1bs=8, edits=[(0, {"l2bm_opcode": 3})]),
    T("f_bcast2_op15", ["l2bmb2 $lc64 $lb128"], l1bs=8, edits=[(0, {"l2bm_opcode": 15, "l2bm_dmode": 0})]),
    T("f_dist_op5", ["l2bmd $lc64 $lb128"], l1bs=8, edits=[(0, {"l2bm_opcode": 5})]),
    T("f_gath_op3", ["l2bmd $lb64 $lc256"], l1bs=8, edits=[(0, {"l2bm_opcode": 3})]),
    T("f_gath_dm3", ["l2bmd $lb64 $lc256"], l1bs=8, edits=[(0, {"l2bm_dmode": 3})]),
    T("f_imc_op3", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l2bm_opcode": 3})]),
    T("f_imc_dm0", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l2bm_dmode": 0, "l2bm_opcode": 12})]),
    T("f_dars_bits", ["l2bmdars $lc0@.0 $dar0; l2bmdarw"], data="dar", dar=(0, 8),
      edits=[(0, {"l2bm_bdmode": 3, "l1bm_gadr": 5})]),
]


if __name__ == "__main__":
    sys.exit(main())

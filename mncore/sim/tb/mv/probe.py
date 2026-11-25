#!/usr/bin/env python3
"""WP33: probes that pinned the MV semantics on the official emulator (whole chip).

    python mncore/sim/tb/mv/probe.py <set> [<set> ...] [--jobs 16] [--reuse]
    sets: forms nw unal wrap ind ndw tags wait order overlap (all: every set)

Every probe initialises all 4 groups and all 8 L2BMs with distinct values (DRAM group g long word a:
0xD000.. | g << 40 | a, PDM: 0xB000.. | g << 40 | a (copied from DRAM 0x8000), L2BM n<g>c<c>:
0xC000.. | (2g + c) << 40 | a; for the indirect probes DAR_g[e] = (7 e + 3 g) % 40 through
l2bmdars / l2bmdarw), runs the body (words edited after the assembly where the probe says so) and
reads every L2BM, every DRAM and every PDM (copied to DRAM 0x4000 at the end). The result is
compared with the full-chip model (mvmodel.py): "model ok" or the differences; probes on which the
emulator aborts are listed with its message (the model must raise Unsupported). The official
binaries are only called (contract 06 section 9). The findings are in mncore/rtl/mv/README.md.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mvmodel as MM  # noqa: E402
from mvemu import fields, mfields, rline, run  # noqa: E402

W, WC, NDAR, DARA = 1024, 512, 64, 3584


def dval(g, a):
    return 0xD000000000000000 | (g << 40) | a


def pval(g, a):
    return 0xB000000000000000 | (g << 40) | a


def cval(i, a):
    return 0xC000000000000000 | (i << 40) | a


def darv(g, e):
    return (e * 7 + g * 3) % 40


def init(dar: bool):
    out = []
    for g in range(4):
        out += rline(g, 0, [dval(g, a) for a in range(W)])
        out += rline(g, 0x8000, [pval(g, a) for a in range(512)])
    for g in range(4):
        for c in range(2):
            out.append(f"d set $lc0n{g}c{c} {WC} " + "".join(f"{cval(2 * g + c, a):016x}" for a in range(WC)))
        if dar:
            longs = [(darv(g, 2 * i) << 32) | darv(g, 2 * i + 1) for i in range(NDAR // 2)]
            out.append(f"d set $lc{DARA}n{g}c0 {len(longs)} " + "".join(f"{v:016x}" for v in longs))
    for g in range(4):
        out += [f"mvp/n512 $d0x8000@{g} $p0@{g}", "nop/3"]
    if dar:
        out += [f"l2bmdars $lc{DARA}@.0 $dar0; l2bmdarw"] + ["l2bmdarw"] * (NDAR // 4 - 1) + ["nop/3"]
    return out


def obs():
    out = []
    for g in range(4):
        out += [f"mvp/n512 $p0@{g} $d0x4000@{g}", "nop/3"]
    for g in range(4):
        for c in range(2):
            out.append(f"d get $lc0n{g}c{c} {WC}")
    for g in range(4):
        out.append(f"d get $d0n{g} {W}")
        out.append(f"d get $d0x4000n{g} 512")
    return out


def model_state(dar: bool) -> MM.State:
    st = MM.State(topo=MM.Topo.full())
    for g in range(4):
        for a in range(W):
            st.dram[g][a] = dval(g, a)
        for a in range(512):
            st.dram[g][0x8000 + a] = pval(g, a)
        for c in range(2):
            l2 = st.l2bm(g, c)
            for a in range(WC):
                l2[a] = cval(2 * g + c, a)
        if dar:
            l2 = st.l2bm(g, 0)
            for i in range(NDAR // 2):
                l2[DARA + i] = (darv(g, 2 * i) << 32) | darv(g, 2 * i + 1)
    return st


BASE = "mvp/n64 $d64@1 $lc128@2.1"        # d2c single, srcid 2 (group 1), destid 5 (n2c1), adra 4, adrb 8


def probes():
    """name -> (body, edits {(kind, index in the body's words of that kind): fields}, dar)."""
    P = {}
    # every (mmode, tmode) on the same fields: srcid 2, destid 5, adra 4, adrb 8, nw 4
    for mm in range(8):
        for tm in range(8):
            P[f"forms_{mm}{tm}"] = ([BASE], {0: {"mmode": mm, "tmode": tm}}, False)
    # nw = 5 in the forms of the assembler
    forms = {"p2c_b": "mvb/n64 $p64@1 $lc128", "c2p_b": "mvrliadd/n64 $lc64 $p128@2", "d2c_b": "mvb/n64 $d64 $lc128",
             "c2d_b": "mvrliadd/n64 $lc64 $d128", "d2c_b2": "mvb2/n64 $d64 $lc128", "c2d_b2": "mvr2liadd/n64 $lc64 $d128",
             "c2p_b2": "mvr2liadd/n64 $lc64@2 $p128@2", "d2c_b4": "mvb4/n64 $d64 $lc128", "c2d_b4": "mvr4liadd/n64 $lc64 $d128",
             "p2c_d": "mvd/n64 $p64@1 $lc128", "c2p_d": "mvd/n64 $lc64 $p128@2", "p2d_d": "mvd/n64 $p64@1 $d128",
             "d2p_d": "mvd/n64 $d64 $p128@2", "p2c_par": "mvp/n64 $p64 $lc128@.1", "c2d_par": "mvp/n64 $lc64@.1 $d128",
             "p2p": "mvp/n64 $p64@1 $p128@2", "p2c_b2": "mvp/n64 $p64@2 $lc128@2.0"}
    for k, s in forms.items():
        ed = {"nw": 5}
        if k == "p2c_b2":
            ed["tmode"] = 2
        P[f"nw_{k}"] = ([s], {0: ed}, False)
        P[f"unal_{k}"] = ([s], {0: {"__low__": 1}}, False)
    # wrap: DRAM 2**29 + 64 (write, read), 2**33 + 128, L2BM 2**15 + 128, PDM 2**19 - 64 + 128
    P["wrap_d29w"] = (["mvp/n64 $lc0@0.0 $d0@0"], {0: {"adra": (1 << 25) + 4}}, False)
    P["wrap_d29r"] = (["mvp/n64 $d0@0 $lc0@0.0"], {0: {"adra": (1 << 25) + 4}}, False)
    P["wrap_d33w"] = (["mvp/n64 $lc0@0.0 $d0@0"], {0: {"adra": (1 << 29) + 8}}, False)
    P["wrap_c15"] = (["mvp/n64 $d0@0 $lc0@0.0"], {0: {"adrb": 2048 + 8}}, False)
    P["wrap_p19"] = (["mvp/n128 $d0@0 $p0x7ffc0@0"], {}, False)
    # indirect DRAM in every form with DRAM (DAR_g from the L2BM of group g)
    ind = {"c2d_s": "mvp/n128nd2 $lc0@1.1 $di4@2", "d2c_s": "mvp/n128 $di4@1 $lc0@2.1", "p2d_s": "mvp/n128nd3 $p0@1 $di4@3",
           "d2p_s": "mvp/n128nd2 $di4@2 $p64@1", "c2d_p": "mvp/n128nd3 $lc0@.1 $di4", "d2c_p": "mvp/n128nd2 $di4 $lc64@.0",
           "d2c_b": "mvb/n128nd2 $di4 $lc0", "d2c_b2": "mvb2/n128nd2 $di4 $lc0", "d2c_b4": "mvb4/n128nd3 $di4 $lc0",
           "c2d_b": "mvrlbor/n128nd2 $lc0 $di4", "c2d_b2": "mvr2lbor/n128nd2 $lc0 $di4", "c2d_b4": "mvr4lbor/n128nd3 $lc0 $di4",
           "p2d_d": "mvd/n128nd2 $p0@1 $di4", "d2p_d": "mvd/n128nd2 $di4 $p64@2", "nd1": "mvp/n128nd1 $lc0@0.0 $di4@0",
           "nd0": "mvp/n128 $di60@0 $lc0@0.0", "big": "mvp/n256nd5 $lc0@0.0 $di1@0"}
    for k, s in ind.items():
        P[f"ind_{k}"] = ([s], {}, True)
    for nd in (0x13, 0x1F, 0x23, 0x43, 0x83, 0x103, 0x203, 0x403, 0x80003):
        P[f"ndw_{nd:x}"] = (["mvp/n128nd3 $lc0@0.0 $di4@0"], {0: {"adra": (nd << 10) | 4}}, True)
    # tags: no-op forms and mvnop with a tag, then a wait and an MV
    tail = ["nop; wait i01", "mvp/n64 $d64@0 $lc64@0.0"]
    P["tags_mm7"] = (["mvp/n64i01 $d0@0 $lc0@0.0"] + tail, {0: {"mmode": 7}}, False)
    P["tags_tm6"] = (["mvp/n64i01 $d0@0 $lc0@0.0"] + tail, {0: {"tmode": 6}}, False)
    P["tags_valid0"] = (["mvp/n64i01 $d0@0 $lc0@0.0"] + tail, {0: {"valid": 0}}, False)
    # waits
    P["wait_twice"] = (["mvp/n64i01 $d0@0 $lc0@0.0", "nop; wait i01", "nop; wait i01", "mvp/n64 $d64@0 $lc64@0.0"], {}, False)
    P["wait_reuse"] = (["mvp/n64i01 $d0@0 $lc0@0.0", "nop; wait i01", "mvp/n64i01 $d0@0 $lc64@0.0", "nop; wait i01",
                        "mvp/n64 $d64@0 $lc128@0.0"], {}, False)
    P["wait_double"] = (["mvp/n64i01 $d0@0 $lc0@0.0", "mvp/n64i01 $d0@0 $lc64@0.0", "nop; wait i01",
                         "mvp/n64 $d64@0 $lc128@0.0"], {}, False)
    P["wait_before"] = (["nop; wait i01", "mvp/n64i01 $d0@0 $lc0@0.0", "mvp/n64 $d64@0 $lc128@0.0"], {}, False)
    P["wait_nowait"] = (["mvp/n64i01 $d0@0 $lc0@0.0", "mvp/n64i01 $d0@0 $lc64@0.0", "mvp/n64 $d64@0 $lc128@0.0"], {}, False)
    # order: an MV and the L2BM instructions next to it
    P["order_mv_l2bmb"] = (["mvp/n64 $d0@0 $lc0@0.0", "l2bmb $lc0 $lb0", "nop/3", "l2bm@0 $lb0 $lc256", "nop",
                            "mvp/n64 $lc256@0.0 $d512@0"], {}, False)
    P["order_chain"] = (["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $lc0@0.0 $p0@0", "mvp/n64 $p0@0 $d512@0"], {}, False)
    # overlapping PDM -> PDM (all reads first)
    P["overlap_up"] = (["mvp/n256 $p0@0 $p64@0"], {0: {"adrb": 1}}, False)
    P["overlap_down"] = (["mvp/n256 $p64@0 $p0@0"], {0: {"adrb": 3}}, False)
    return P


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args(argv)
    P = probes()
    sel = {k: v for k, v in P.items() if "all" in a.sets or k.split("_")[0] in a.sets}
    if not sel:
        raise SystemExit(f"no probes in {a.sets}")
    texts, edits = {}, {}
    for name, (body, ed, dar) in sel.items():
        pre = init(dar)
        npre_m = sum(1 for ln in pre if ln.startswith("mv"))
        texts[name] = "\n".join(pre + body + ["nop/3"] + obs()) + "\n"
        if ed:
            edits[name] = []
            for k, ch in ed.items():
                edits[name].append(("m", npre_m + k, ch))
    # __low__: set bit 0 of adra and adrb of the assembled word (unaligned addresses)
    low = [n for n, e in edits.items() if any("__low__" in ch for _, _, ch in e)]
    if low:
        r0 = run({n: texts[n] for n in low}, HERE / "build" / "probe_pre", jobs=a.jobs, reuse=a.reuse)
        for n in low:
            ms = [b for k, b in r0[n].seq if k == "m"]
            new = []
            for kind, idx, ch in edits[n]:
                if "__low__" in ch:
                    f = mfields(ms[idx])
                    ch = {"adra": f["adra"] | 1, "adrb": f["adrb"] | 1}
                new.append((kind, idx, ch))
            edits[n] = new
    res = run(texts, HERE / "build" / "probe", jobs=a.jobs, reuse=a.reuse, edits=edits)
    nbad = 0
    for name in sel:
        r = res[name]
        dar = sel[name][2]
        st = model_state(dar)
        err = None
        for k, b in [(k, b) for k, b in r.seq if k in "jm"]:
            try:
                MM.step(st, k, mfields(b) if k == "m" else fields(b))
            except MM.Unsupported as e:
                err = e
                break
        if r.asm_err:
            print(f"{name}: assembler: {r.asm_err.strip().splitlines()[-1][:120]}")
            continue
        if r.emu_rc != 0:
            msg = [ln for ln in r.emu_out.splitlines() if "exception" in ln or "what()" in ln]
            ok = err is not None
            nbad += not ok
            print(f"{name}: the emulator aborts ({(msg[0] if msg else '')[:100]}); "
                  f"model {'Unsupported ' + err.field if ok else 'runs it: DIFFERENT'}")
            continue
        if err is not None:
            nbad += 1
            print(f"{name}: the emulator runs it, the model raises {err}")
            continue
        bad = 0
        for (sp, loc, ad), v in r.dump.items():
            g = int(loc[1])
            mv = st.l2bm(g, int(loc[3]))[ad] if sp == "L2BM" else st.dram[g][ad]
            bad += mv != v
        nbad += bad != 0
        print(f"{name}: {len(r.dump)} long words, " + ("model ok" if not bad else f"{bad} DIFFERENT") +
              (" (the program stopped at a wait)" if st.halted else ""))
    print("ALL AGREE" if nbad == 0 else f"{nbad} probes differ from the model")
    return 0 if nbad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

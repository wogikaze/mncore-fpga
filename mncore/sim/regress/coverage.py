#!/usr/bin/env python3
"""Which PE word features the regression exercises (WP20).

usage: python mncore/sim/regress/coverage.py [--only TEXT] [--results build/results.tsv]

Decodes the j words of build/<name>/official.asm (the programs that passed in results.tsv, or
all with --all) and counts, per feature, the words and programs that use it: ALU operation x
precision, MAU operation x precision x options, operand sources, destinations, masks, zero
flush, $omr, noforward, nop, wait, T indirect, $mb/$nb, madpe. Used for the WP20 report and to
pick the directed tests (mncore/sim/tb/core/gen_fixed.py) for what the corpus lacks.
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run as rg  # noqa: E402

ALUOP = {0: "add", 1: "sub", 2: "inc", 3: "dec", 4: "not", 5: "and", 6: "or", 7: "xor", 8: "max", 9: "min",
         10: "passa", 11: "lsl", 12: "lsr", 13: "bsl", 14: "bsr", 15: "lnot", 16: "rsqrt", 17: "msl", 18: "msr",
         19: "packbit", 20: "relu0", 21: "relu1", 22: "relu2", 23: "relu3", 24: "lrelud", 25: "lreluo",
         26: "ilrelud", 27: "fmax", 28: "fmin", 29: "zero/bfe", 30: "floor/ftoi/bfn", 31: "imm"}
PREC = {0: "d/l", 1: "f/i", 2: "h/s", 3: "g"}
SRC = {0: "$lr", 1: "$ls", 2: "$t", 3: "$lm", 4: "$ln", 5: "$peid", 6: "$l1bid", 7: "$l2bid", 8: "$msb1",
       9: "$subpeid", 10: "$mabid", 11: "$mauf", 12: "$aluf", 13: "$lbf", 14: "$mreadf"}
ISEL = {0: "mau", 1: "alu", 2: "l1bm", 3: "mread"}


def f(w, pos, width):
    return rg.jfield(w, pos, width)


def features(w: int):
    out = []
    ll = f(w, 0, 2)
    if ll == 0:
        out.append("nop")
        if f(w, 238, 8):
            out.append("nop+wait")
        return out
    if ll == 3:
        out.append("noforward (ll=11)")
    if f(w, 238, 8):
        out.append("wait")
    a_dm, a_op, a_u = f(w, 145, 2), f(w, 147, 5), f(w, 152, 1)
    a_ra, a_rb, a_sa, a_sb = f(w, 153, 1), f(w, 154, 1), f(w, 155, 4), f(w, 159, 3)
    alu = not (a_dm == 3 and a_op == 0)
    if alu:
        if a_op == 31:
            out.append("alu imm" + ("u" if a_u else ""))
        elif a_op == 29 and a_u and a_sa == 5:
            out.append("alu zero")
        else:
            name = ALUOP[a_op]
            if a_op == 30:
                name = {6: "floor", 7: "ftoi"}.get(a_sb, "bfn")
            out.append(f"alu {name} {PREC[a_dm]}" + (" u" if a_u else "") + (" r" if (a_ra or a_rb) else ""))
            out.append(f"alu x {SRC.get(a_sa, a_sa)}")
            if rg.jfield(w, 147, 5) in (0, 1, 5, 6, 7, 8, 9, 11, 12, 13, 14, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28):
                out.append(f"alu y {SRC.get(a_sb if a_sb < 5 else a_sb + 6)}")
    m_dm, enfma, mmode, rnd, mw = f(w, 116, 2), f(w, 118, 1), f(w, 119, 1), f(w, 120, 1), f(w, 121, 1)
    passa, zeroc, side = f(w, 128, 1), f(w, 129, 1), f(w, 130, 1)
    sa, sc, sb = f(w, 126, 1), f(w, 127, 1), f(w, 135, 1)
    ea, eb, ec = f(w, 132, 1), f(w, 133, 1), f(w, 134, 1)
    if enfma:
        kind = "passa" if (passa and zeroc) else "add" if passa else "mul" if zeroc else "fma"
        opts = "".join(x for x, on in (("r", rnd), ("-a", sa), ("-b", sb), ("-c", sc), ("ea", ea), ("eb", eb),
                                       ("ec", ec), ("side", side)) if on)
        out.append(f"mau {'matrix ' if mmode else ''}{kind} {'dfhg'[m_dm]}" + (f" {opts}" if opts else ""))
        for nm, pos, used in (("a", 136, True), ("b", 139, not passa), ("c", 142, not zeroc)):
            if used:
                s = f(w, pos, 3)
                out.append(f"mau {nm} {SRC[s if s < 5 else s + 6]}")
    if mw:
        out.append("mwrite")
    imr, mwl, zero, zsel, omr, ifsel = f(w, 2, 5), f(w, 7, 1), f(w, 14, 1), f(w, 15, 2), f(w, 17, 4), f(w, 21, 1)
    targets = f(w, 8, 6)
    if imr and targets:
        out.append(("write mask $imr" if imr < 16 else "write mask pattern") + (" ll" if mwl else ""))
    if zero:
        out.append(f"zero flush {ISEL[zsel]}" + (" $imr" if 0 < imr < 16 else ""))
    if omr:
        out.append(f"$omr write from {'mau' if ifsel else 'alu'}")
    for nm, wpos, ipos, wl in (("T", 22, 23, None), ("GRF0", 25, 26, 37), ("GRF1", 50, 51, 62),
                               ("LM0", 75, 76, 94), ("LM1", 96, 97, 114)):
        if f(w, wpos, 1) and not (nm == "LM0" and a_op == 31):
            base = nm in ("LM0", "LM1") and f(w, wpos + 16, 1) == 0 and f(w, wpos + 17, 2) == 3
            wls = "" if wl is None else ["w", "l", "ll", "?"][f(w, wl, 2)]
            out.append(f"write {'$mb/$nb' if base else nm} {wls} from {ISEL[f(w, ipos, 2)]}".replace("  ", " "))
    if f(w, 90, 1) and a_op != 31:
        out.append("LM0 T-indirect")
    if f(w, 91, 1) and a_op != 31:
        out.append("LM0 madpe")
    if f(w, 111, 1):
        out.append("LM1 madpe")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only")
    ap.add_argument("--all", action="store_true", help="every program with an official result")
    a = ap.parse_args(argv)
    res = {}
    with open(rg.BUILD / "results.tsv", encoding="utf-8") as fh:
        head = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            r = dict(zip(head, line.rstrip("\n").split("\t")))
            res[r["path"]] = r["result"]
    words = Counter()
    progs = defaultdict(set)
    for path, result in res.items():
        if a.only and a.only not in path:
            continue
        if result != "pass" and not a.all:
            continue
        asm = rg.BUILD / rg.prog_name(path) / "official.asm"
        if not asm.exists():
            continue
        entries, _, _ = rg.parse_official_asm(asm.read_text(encoding="utf-8"))
        for tag, w in entries:
            if tag != "j":
                words["m word"] += 1
                progs["m word"].add(path)
                continue
            for ft in features(w):
                words[ft] += 1
                progs[ft].add(path)
    print("feature\twords\tprograms")
    for ft in sorted(words):
        print(f"{ft}\t{words[ft]}\t{len(progs[ft])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

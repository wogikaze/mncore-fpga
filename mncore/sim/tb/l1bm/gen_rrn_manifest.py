#!/usr/bin/env python3
"""WP31: manifest of the rrn vector files for tb_l1bm_rrn (mn_l1bm_rrn against the vectors).

    python mncore/sim/tb/l1bm/gen_rrn_manifest.py

Writes mncore/sim/tb/l1bm/rrn_manifest.txt: one line per file of the unit `rrn` (WP03,
vecgen/FORMAT.md), the RRN configuration and the file name:
    <op> <fmt> <out_half> <two_stage> <nin_m1> <ext> <ninputs> <name>
op: 0 fadd 1 max 2 min 3 iadd 4 band 5 and 6 bor 7 or; fmt: 0 d/l 1 f/i 2 h/s.
ext = 1: the inputs are halves that the caller extends to single (the L1BM hfadd: fmt 1 with
out_half). The testbench reads <dir>/<name>.vec, dir = mncore/sim/vectors_fixed/rrn by default
(+rrndir=mncore/sim/vectors/rrn for the full generated set).
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
OPS = {"fadd": 0, "max": 1, "min": 2, "iadd": 3, "band": 4, "and": 5, "bor": 6, "or": 7}
FMT = {"d": 0, "l": 0, "f": 1, "i": 1, "h": 2, "s": 2}


def main():
    src = ROOT / "mncore" / "sim" / "vectors_fixed" / "rrn"
    lines = []
    for fn in sorted(src.glob("*.vec")):
        name = fn.stem
        kv = dict(x.split("=", 1) for x in fn.open().readline().split() if "=" in x)
        rrn = kv["rrn"]
        prec, op = rrn[0], rrn[1:]
        nin = int(kv["inputs"])
        fmt, out_half, ext = FMT[prec], 0, 0
        l1 = name.startswith("l1bmr")
        if prec == "h" and op == "fadd" and l1:
            fmt, out_half, ext = 1, 1, 1      # L1BM hfadd = single fadd of extended halves, rounded
        two = 1 if (l1 and not name.startswith("l1bmr4")) else 0
        lines.append(f"{OPS[op]} {fmt} {out_half} {two} {nin - 1 if not two else 3} {ext} {nin} {name}")
    out = HERE / "rrn_manifest.txt"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"{len(lines)} files -> {out}")


if __name__ == "__main__":
    main()

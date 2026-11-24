"""Checks the Python reference model (mnfp_ref.py) against the fp and mau vectors.

    python mncore/sim/tb/fpu_tools/check_model.py [--fixed] [--sim]

--fixed  use mncore/sim/vectors_fixed even if mncore/sim/vectors exists
--sim    model the Rust simulator instead of the official emulator (for files without
         expect=official, whose disputed rows still hold simulator values)
"""

import argparse
import sys

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import mnfp_ref as R  # noqa: E402
from vecio import VecFile, vec_dir  # noqa: E402

PREC_OF_W = {64: "d", 32: "f", 16: "h"}


def f2h_official(x):
    """ALU `r` option (single to half), official emulator (WP03 r_round)."""
    s = (x >> 31) & 1
    e = (x >> 23) & 0xFF
    m = x & 0x7FFFFF
    k = m >> 14
    rem = m & 0x3FFF
    if rem > 0x2000 or (rem == 0x2000 and k & 1):
        k += 1
    carry = k >> 9
    eh = min(max(e - 96 + carry, 0), 63)
    return (s << 15) | (eh << 9) | (k & 0x1FF)


def check_fp(f, official):
    bad = []
    if f.get("op") == "cvt_f2h":
        for i, (ins, outs) in enumerate(f.rows):
            want = f2h_official(ins[0]) if official else R.encode(R.HALF, R.decode(R.SINGLE, ins[0]))
            if want != outs[0]:
                bad.append((i, outs, [want]))
        return bad
    prec = PREC_OF_W[int(f.get("fmt_ab"))]
    rnd = int(f.get("fmt_z")) < int(f.get("fmt_c"))
    for i, (ins, outs) in enumerate(f.rows):
        z = R.fp_row(prec, rnd, ins[0], ins[1], ins[2], official)
        if z != outs[0]:
            bad.append((i, outs, [z]))
    return bad


def check_mau(f, official):
    bad = []
    prec = f.get("prec")
    kind = f.get("kind")
    rnd = f.get("round_out") == "1"
    side = None
    if prec == "d" and kind in ("fma", "mul"):
        side = "d" if f.get("mdw_side") == "1" else "u"
    for i, (ins, outs) in enumerate(f.rows):
        pe, sa, sb, sc, ea, eb, ec = ins[:7]
        a = (ins[7] << 64) | ins[8]
        b = (ins[9] << 64) | ins[10]
        c = (ins[11] << 64) | ins[12]
        z, fl = R.mau_row(prec, kind, side, rnd, pe, (sa, sb, sc), (ea, eb, ec), a, b, c, official)
        got = [z >> 64, z & ((1 << 64) - 1), fl]
        if got != outs:
            bad.append((i, outs, got))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixed", action="store_true")
    ap.add_argument("--sim", action="store_true")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    official = not a.sim
    total = nbad = 0
    for unit, fn in (("fp", check_fp), ("mau", check_mau)):
        d = vec_dir(unit, not a.fixed)
        urows = ubad = 0
        for p in sorted(d.glob("*.vec")):
            if a.only and a.only not in p.stem:
                continue
            f = VecFile(p)
            bad = fn(f, official)
            urows += len(f.rows)
            ubad += len(bad)
            if bad:
                print(f"{unit}/{p.stem}: {len(bad)} / {len(f.rows)} rows differ "
                      f"(disputed={f.get('disputed')}, expect={f.get('expect')})")
                for i, want, got in bad[:3]:
                    ins = " ".join(f"{x:x}" for x in f.rows[i][0])
                    print(f"  line {i + 2}: {ins} | vec {[hex(x) for x in want]} model {[hex(x) for x in got]}")
        print(f"{unit}: {urows} rows from {d}, {ubad} differ")
        total += urows
        nbad += ubad
    print(f"total {total} rows, {nbad} differ")
    return 1 if nbad else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""WP32 (development aid): where did the changed values of a probe come from?

    python mncore/sim/tb/l2bm/where.py <set> <name> [...]   (after probe.py <set>)
Prints, per changed L2BM / L1BM block of 16 long words, the source of every value (initial L2BM
'c<addr>', initial L1BM 'b<l1b>@<addr>', 0, or ?)."""
import sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import probe  # noqa: E402
import l2prog as LP  # noqa: E402


def main():
    sname, names = sys.argv[1], sys.argv[2:]
    progs = [p for p in probe.SETS[sname] if p.name in names]
    res = LP.run(progs, probe.BUILD / f"probe_{sname}", reuse=True)
    for p in progs:
        r, ini, w = res[p.name]
        print(f"== {p.name} ok={r.ok} fields: " + " ".join(f"{k}={v}" for k, v in LP.fields(w[0]).items()
                                                        if (k.startswith('l2bm') or k.startswith('l1bm_g'))))
        idx = {}
        for a, v in enumerate(ini.l2):
            idx.setdefault(v, f"c{a}")
        for b in range(len(ini.l1)):
            for a, v in enumerate(ini.l1[b]):
                idx.setdefault(v, f"b{b}@{a}")
        for space, nb in (("L2BM", 1), ("L1BM", 8)):
            for b in range(nb):
                loc = "n0c0" if space == "L2BM" else f"n0c0b{b}"
                n = LP.L2 if space == "L2BM" else LP.L1
                init = ini.l2 if space == "L2BM" else (ini.l1[b] if b < len(ini.l1) else [0] * LP.L1)
                for blk in range(0, n, 16):
                    vals = [r.dump.get((space, loc, a), 0) for a in range(blk, blk + 16)]
                    if all(v == init[a] for v, a in zip(vals, range(blk, blk + 16))):
                        continue
                    srcs = []
                    for a, v in zip(range(blk, blk + 16), vals):
                        srcs.append("-" if v == init[a] else idx.get(v, "0" if v == 0 else "?"))
                    print(f"  {space} {loc} {blk:5d}: {' '.join(srcs)}")


if __name__ == "__main__":
    main()

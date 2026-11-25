#!/usr/bin/env python3
"""Resources of the M2 board design and its parts (WP37): yosys synth_gowin -family gw2a -nowidelut.

usage: python mncore/sim/tb/m2/synth_stat.py [--top mn_top_m2] [--flat] [--param K=V ...]

The RTL is mncore/fpga/top_m2/files.txt. With -noflatten (default) it prints the cells of every module
(LUT, ALU, MUX2, FF, SSRAM = RAM16SDP4, BSRAM, DSP) and LUT_eq = LUT + ALU + 8 * SSRAM; the hierarchy
totals at the end. Log: mncore/sim/tb/m2/build/synth_<top>_<tag>.log.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "core"))
import simrun  # noqa: E402,F401  (PATH)
from synth_stat import KINDS, parse_stat  # noqa: E402  (WP20's parser)


def files():
    out, inc = [], []
    for raw in (ROOT / "mncore" / "fpga" / "top_m2" / "files.txt").read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("rtl_top:"):
            continue
        if line.startswith("incdir:"):
            inc.append(line.split(":", 1)[1].strip())
            continue
        out.append(line)
    return out, inc


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", default="mn_top_m2")
    ap.add_argument("--flat", action="store_true")
    ap.add_argument("--param", action="append", default=[])
    a = ap.parse_args(argv)
    rtl, inc = files()
    incs = " ".join(f"-I{d}" for d in inc)
    reads = " ".join(f"read_verilog {incs} {f};" for f in rtl)
    chp = "".join(f" chparam -set {kv.split('=', 1)[0]} {kv.split('=', 1)[1]} {a.top};" for kv in a.param)
    opts = "-nowidelut" + ("" if a.flat else " -noflatten")
    script = f"{reads}{chp} synth_gowin -family gw2a -top {a.top} {opts}; stat"
    build = HERE / "build"
    build.mkdir(exist_ok=True)
    tag = ("flat" if a.flat else "hier") + "".join(f"_{kv.replace('=', '')}" for kv in a.param)
    log = build / f"synth_{a.top}_{tag}.log"
    r = subprocess.run(["yosys", "-p", script], cwd=ROOT, capture_output=True, text=True)
    log.write_text(r.stdout + r.stderr, encoding="utf-8")
    if r.returncode != 0:
        print((r.stdout + r.stderr)[-3000:])
        print(f"FAIL yosys (log {log})")
        return 1
    mods = parse_stat(r.stdout[r.stdout.rfind("Printing statistics"):])
    cols = [k for k, _ in KINDS]
    print(f"synth_gowin -family gw2a {opts}  (log {log.relative_to(ROOT)})")
    print("module".ljust(48) + "".join(c.rjust(7) for c in cols) + "LUT_eq".rjust(8))
    for name, cnt in mods.items():
        if name == "__hier__" or not any(cnt.values()):
            continue
        eq = cnt.get("LUT", 0) + cnt.get("ALU", 0) + 8 * cnt.get("SSRAM", 0)
        print(name[:48].ljust(48) + "".join(str(cnt.get(c, 0)).rjust(7) for c in cols) + str(eq).rjust(8))
    if "__hier__" in mods:
        cnt = mods["__hier__"]
        eq = cnt.get("LUT", 0) + cnt.get("ALU", 0) + 8 * cnt.get("SSRAM", 0)
        print("TOTAL (design hierarchy)".ljust(48) + "".join(str(cnt.get(c, 0)).rjust(7) for c in cols) +
              str(eq).rjust(8))
    return 0


if __name__ == "__main__":
    sys.exit(main())

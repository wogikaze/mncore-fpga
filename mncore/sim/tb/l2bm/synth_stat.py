#!/usr/bin/env python3
"""Resource usage of mn_l2bm (WP32): yosys synth_gowin -family gw2a.

usage: python mncore/sim/tb/l2bm/synth_stat.py [--default-synth] [--flat] [--param N_L1B=1 ...]

Runs `synth_gowin -family gw2a -noiopads [-nowidelut]` (contract 06 section 6: -nowidelut is
the standard) with -noflatten unless --flat, and prints the cell counts per module and the
totals (LUT, ALU, MUX2, FF, SSRAM, BSRAM, DSP; the parser is WP31's sim/tb/l1bm/synth_stat.py).
The RTL list is the unit's files.txt (tb_*, the decoder and mn_l1bm excluded).
Logs: mncore/sim/tb/l2bm/build/synth_*.log.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
sys.path.insert(0, str(HERE.parent / "l1bm"))
import simrun  # noqa: E402  (also puts OSS CAD Suite on PATH)
from synth_stat import KINDS, parse_stat  # noqa: E402  (WP31)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", default="mn_l2bm")
    ap.add_argument("--default-synth", action="store_true", help="without -nowidelut")
    ap.add_argument("--flat", action="store_true", help="flatten (totals only, like a real build)")
    ap.add_argument("--param", action="append", default=[], help="top parameter K=V (e.g. RRN=2)")
    a = ap.parse_args(argv)
    files, cfg = simrun.parse_files("l2bm")
    rtl = [f for f in files if not Path(f).name.startswith("tb_") and "mn_dec_j" not in f
           and not f.endswith("mn_l1bm.v")]
    inc = " ".join(f"-I{d}" for d in cfg["incdir"])
    reads = " ".join(f"read_verilog {inc} {f};" for f in rtl)
    chp = "".join(f" chparam -set {kv.split('=', 1)[0]} {kv.split('=', 1)[1]} {a.top};" for kv in a.param)
    opts = "-noiopads" + ("" if a.default_synth else " -nowidelut") + ("" if a.flat else " -noflatten")
    script = f"{reads}{chp} synth_gowin -family gw2a -top {a.top} {opts}; stat"
    build = HERE / "build"
    build.mkdir(exist_ok=True)
    tag = ("default" if a.default_synth else "nowidelut") + ("_flat" if a.flat else "") + \
        "".join(f"_{kv.replace('=', '')}" for kv in a.param)
    log = build / f"synth_{a.top}_{tag}.log"
    r = subprocess.run(["yosys", "-p", script], cwd=ROOT, capture_output=True, text=True)
    log.write_text(r.stdout + r.stderr, encoding="utf-8")
    if r.returncode != 0:
        print((r.stdout + r.stderr)[-3000:])
        print(f"FAIL yosys (log {log})")
        return 1
    stat = r.stdout[r.stdout.rfind("Printing statistics"):]
    mods = parse_stat(stat)
    cols = [k for k, _ in KINDS]
    print(f"synth_gowin -family gw2a {opts} {' '.join(a.param)}  (log {log.relative_to(ROOT)})")
    print("module".ljust(40) + "".join(c.rjust(7) for c in cols))
    for name, cnt in mods.items():
        if name == "__hier__" or not any(cnt.values()):
            continue
        print(name[:40].ljust(40) + "".join(str(cnt.get(c, 0)).rjust(7) for c in cols))
    if "__hier__" in mods:
        print("TOTAL (design hierarchy)".ljust(40) + "".join(str(mods["__hier__"].get(c, 0)).rjust(7) for c in cols))
    return 0


if __name__ == "__main__":
    sys.exit(main())

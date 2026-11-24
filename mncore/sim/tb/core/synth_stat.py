#!/usr/bin/env python3
"""Resource usage of mn_core and its parts (WP20): yosys synth_gowin -family gw2a.

usage: python mncore/sim/tb/core/synth_stat.py [--default-synth] [--top mn_core] [--flat]

Runs `synth_gowin -family gw2a -noiopads [-nowidelut]` (contract 06 section 6: -nowidelut is
the standard) with -noflatten unless --flat, and prints the cell counts of every module and the
totals of the top: LUT (LUT1..LUT4), ALU (carry cells), MUX2 (MUX2_LUT5..8), FF (DFF*),
SSRAM (RAM16SDP4), BSRAM (SDP* / DP* / SP*), DSP (MULT*). Logs go to build/synth_*.log.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402  (also puts OSS CAD Suite on PATH)

KINDS = [("LUT", r"^LUT[1-4]$"), ("ALU", r"^ALU$"), ("MUX2", r"^MUX2_LUT[5-8]$"), ("FF", r"^DFF"),
         ("SSRAM", r"^RAM16S"), ("BSRAM", r"^(SDP|DP|SP|ROM)"), ("DSP", r"^(MULT|PADD|ALU54)")]


def kind_of(cell: str):
    for k, rx in KINDS:
        if re.match(rx, cell):
            return k
    return None


def parse_stat(text: str):
    """{module: {kind: count}} from yosys `stat` output (one block per module)."""
    mods = {}
    cur = None
    for line in text.splitlines():
        m = re.match(r"^=== (\S+) ===", line.strip())
        if m:
            cur = m.group(1)
            mods[cur] = {}
            continue
        if line.strip().startswith("=== design hierarchy ==="):
            cur = "__hier__"
            mods[cur] = {}
            continue
        if cur is None:
            continue
        m = re.match(r"^\s+(\d+)\s+(?:[\d.]+\s+)?(\$?\S+)\s*$", line)
        if not m:
            m2 = re.match(r"^\s+(\S+)\s+(\d+)\s*$", line)
            if m2:
                cell, n = m2.group(1), int(m2.group(2))
            else:
                continue
        else:
            n, cell = int(m.group(1)), m.group(2)
        k = kind_of(cell)
        if k:
            mods[cur][k] = mods[cur].get(k, 0) + n
    return mods


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", default="mn_core")
    ap.add_argument("--default-synth", action="store_true", help="without -nowidelut")
    ap.add_argument("--flat", action="store_true", help="flatten (totals only, like a real build)")
    a = ap.parse_args(argv)
    files, cfg = simrun.parse_files("core")
    rtl = [f for f in files if not Path(f).name.startswith("tb_")]
    inc = " ".join(f"-I{d}" for d in cfg["incdir"])
    reads = " ".join(f"read_verilog {inc} {f};" for f in rtl)
    opts = "-noiopads" + ("" if a.default_synth else " -nowidelut") + ("" if a.flat else " -noflatten")
    script = f"{reads} synth_gowin -family gw2a -top {a.top} {opts}; stat"
    build = HERE / "build"
    build.mkdir(exist_ok=True)
    tag = ("default" if a.default_synth else "nowidelut") + ("_flat" if a.flat else "")
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
    print(f"synth_gowin -family gw2a {opts}  (log {log.relative_to(ROOT)})")
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

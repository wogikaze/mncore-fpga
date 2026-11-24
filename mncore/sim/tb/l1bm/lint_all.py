#!/usr/bin/env python3
"""WP31: verilator --lint-only -Wall of mn_l1bm in every configuration the testbench uses.

    python mncore/sim/tb/l1bm/lint_all.py

simrun.py l1bm --lint checks the defaults (N_MAB = 1, RRN = 1); this adds N_MAB = 16 and
RRN = 0 / 2, and mn_l1bm_rrn alone. Last line PASS / FAIL.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402  (PATH and VERILATOR_ROOT)

CONFIGS = [("mn_l1bm", []), ("mn_l1bm", ["-GN_MAB=16"]), ("mn_l1bm", ["-GRRN=2"]), ("mn_l1bm", ["-GRRN=0"]),
           ("mn_l1bm", ["-GN_MAB=16", "-GRRN=0"]), ("mn_l1bm", ["-GCLEAR=0"]), ("mn_l1bm_rrn", [])]


def main() -> int:
    files, cfg = simrun.parse_files("l1bm")
    rtl = [f for f in files if not Path(f).name.startswith("tb_") and "mn_dec_j" not in f]
    inc = [f"-I{d}" for d in cfg["incdir"]]
    verilator = shutil.which("verilator_bin") or shutil.which("verilator")
    ok = True
    for top, params in CONFIGS:
        cmd = [verilator, "--lint-only", "-Wall", "--top-module", top] + params + inc + rtl
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        good = r.returncode == 0
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} {top} {' '.join(params)}")
        if not good:
            print((r.stdout + r.stderr)[-3000:])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

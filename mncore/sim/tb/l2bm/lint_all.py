#!/usr/bin/env python3
"""WP32: verilator --lint-only -Wall of mn_l2bm in every configuration of interest.

    python mncore/sim/tb/l2bm/lint_all.py

simrun.py l2bm --lint checks the defaults (N_L1B = 1, RRN = 1, DAR = 1); this adds RRN = 2 / 0,
N_L1B = 8, DAR = 0 and CLEAR = 0, and the chip-size memories. Last line PASS / FAIL.
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

CONFIGS = [[], ["-GRRN=2"], ["-GRRN=0"], ["-GRRN=2", "-GDAR=0"], ["-GRRN=0", "-GDAR=0", "-GCLEAR=0"],
           ["-GN_L1B=8"], ["-GN_L1B=8", "-GRRN=0", "-GDAR=0"], ["-GN_L1B=3", "-GRRN=1"],
           ["-GAW=15", "-GL1AW=13"]]


def main() -> int:
    files, cfg = simrun.parse_files("l2bm")
    rtl = [f for f in files if not Path(f).name.startswith("tb_") and "mn_dec_j" not in f
           and not f.endswith("mn_l1bm.v")]
    inc = [f"-I{d}" for d in cfg["incdir"]]
    verilator = shutil.which("verilator_bin") or shutil.which("verilator")
    ok = True
    for params in CONFIGS:
        cmd = [verilator, "--lint-only", "-Wall", "--top-module", "mn_l2bm"] + params + inc + rtl
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        good = r.returncode == 0
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} mn_l2bm {' '.join(params)}")
        if not good:
            print((r.stdout + r.stderr)[-3000:])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

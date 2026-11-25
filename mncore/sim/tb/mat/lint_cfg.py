#!/usr/bin/env python3
"""Verilator lint (-Wall) of the WP36 RTL in its configurations.

    python mncore/sim/tb/mat/lint_cfg.py

mn_core with N_PE = 4, MAT = 1 for FPALU 0 / 1 / 3 x MAU 0 / 1 x BFN 0 / 1, mn_core N_PE = 1 with
MAT = 1 (ignored: one PE has no matrix register), mn_mab, mn_mab_mat and mn_mab_mrnd on their own,
and the board top mn_top_mab with MAT = 1 (mncore/fpga/top_mab). The MAT = 0 configurations are
WP30's (mncore/sim/tb/mab/lint_cfg.py). Prints one line per configuration and PASS / FAIL.
"""
from __future__ import annotations

import itertools
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "mab"))
import lint_cfg as l30  # noqa: E402  (rtl(), lint(); PATH and VERILATOR_ROOT)


def main() -> int:
    core_files, core_inc = l30.rtl(HERE / "files.txt")
    top_files, top_inc = l30.rtl(ROOT / "mncore" / "fpga" / "top_mab" / "files.txt")
    cfgs = []
    for fp, mau, bfn in itertools.product((0, 1, 3), (0, 1), (0, 1)):
        cfgs.append(("mn_core", dict(N_PE=4, LM_AW=8, FPALU=fp, MAU=mau, BFN=bfn, MAT=1), core_files, core_inc))
    cfgs.append(("mn_core", dict(N_PE=1, FPALU=0, MAT=1), core_files, core_inc))
    cfgs.append(("mn_mab", dict(MAT=1), core_files, core_inc))
    cfgs.append(("mn_mab", dict(MAT=1, MAU=0, FPALU=0, BFN=0), core_files, core_inc))
    cfgs.append(("mn_mab_mat", {}, core_files, core_inc))
    cfgs.append(("mn_mab_mrnd", {}, core_files, core_inc))
    for fp, mau, bfn in ((0, 0, 1), (0, 1, 0), (0, 0, 0), (3, 0, 1)):
        cfgs.append(("mn_top_mab", dict(FPALU=fp, MAU=mau, BFN=bfn, MAT=1), top_files, top_inc))
    ok_all = True
    for top, prm, files, inc in cfgs:
        ok, msg = l30.lint(top, prm, files, inc)
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} {top} {' '.join(f'{k}={v}' for k, v in prm.items())}", flush=True)
        if not ok:
            print(msg[:3000])
    print("PASS" if ok_all else "FAIL")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())

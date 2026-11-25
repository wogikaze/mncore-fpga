#!/usr/bin/env python3
"""WP33: verilator --lint-only -Wall of mn_mv in several configurations and of the test design.

    python mncore/sim/tb/mv/lint_all.py [--only NAME]
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402,F401  (puts OSS CAD Suite on PATH, VERILATOR_ROOT)

MV = ["mncore/fpga/recipes/mn_ram_lut.v", "mncore/rtl/mv/mn_mv_tags.v", "mncore/rtl/mv/mn_mv_red.v",
      "mncore/rtl/mv/mn_mv.v"]
CORE = ["mncore/fpga/recipes/mn_ram_1r1w.v", "mncore/rtl/l1bm/mn_l1bm_rrn.v", "mncore/rtl/l2bm/mn_l2bm.v",
        "mncore/rtl/dec/mn_dec_j.v", "mncore/fpga/mv_test/mvt_l1mem.v", "mncore/fpga/mv_test/mvt_core.v"]
SDR = ["mncore/rtl/sdram/sdr_tmr.v", "mncore/rtl/sdram/sdr_ctrl.v", "mncore/rtl/sdram/sdr_fifo.v",
       "mncore/rtl/sdram/sdr_afifo.v", "mncore/rtl/sdram/sdr_bus64.v", "mncore/rtl/sdram/sdr_gw_pll.v",
       "mncore/rtl/sdram/sdr_gw_clkout.v"]
BRD = ["mncore/rtl/board/brd_ram_1r1w.v", "mncore/rtl/board/brd_fifo.v", "mncore/rtl/board/brd_uart_rx.v",
       "mncore/rtl/board/brd_uart_tx.v", "mncore/rtl/board/brd_host_if.v"]
CONFIGS = {
    "mn_mv": ("mn_mv", MV, []),
    "mn_mv_small": ("mn_mv", MV, ["-GL2AW=10", "-GPDM_AW=12", "-GDRAM_AW=14", "-GPDM_BASE=20'h04000"]),
    "mn_mv_big": ("mn_mv", MV, ["-GL2AW=15", "-GPDM_AW=19", "-GDRAM_AW=19", "-GPDM_BASE=20'h80000"]),
    "mvt_core": ("mvt_core", MV + CORE, []),
    "mvt_core_dar0": ("mvt_core", MV + CORE, ["-GL2_DAR=0"]),
    "mvt_core_rrn0": ("mvt_core", MV + CORE, ["-GL2_RRN=0", "-GL2AW=10", "-GPDM_AW=12", "-GDRAM_AW=14",
                                               "-GPDM_BASE=20'h04000"]),
    "mvt_top": ("mvt_top", MV + CORE + SDR + BRD + ["mncore/fpga/mv_test/mvt_top.v"], []),
}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    a = ap.parse_args(argv)
    v = shutil.which("verilator_bin") or shutil.which("verilator")
    ok = True
    for name, (top, files, extra) in CONFIGS.items():
        if a.only and name != a.only:
            continue
        cmd = [v, "--lint-only", "-Wall", "-Imncore/rtl/dec", "--top-module", top] + extra + files
        r = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
        out = (r.stdout + r.stderr).strip()
        print(f"{name}: {'ok' if r.returncode == 0 else 'FAIL'}")
        if r.returncode or out:
            print(out[-6000:])
        ok &= r.returncode == 0
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

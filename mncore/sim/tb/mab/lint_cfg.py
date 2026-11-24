#!/usr/bin/env python3
"""Verilator lint (-Wall) of the WP30 RTL in its configurations.

    python mncore/sim/tb/mab/lint_cfg.py

mn_core with N_PE = 4 (LM_AW = 8) for FPALU 0 / 1 / 2 / 3 x MAU 0 / 1 x BFN 0 / 1, mn_core with
N_PE = 1 (the M1 core, FPALU 0 / 1 / 3), mn_mab and mn_mab_mem on their own, and the board top
mn_top_mab (mncore/fpga/top_mab). Prints one line per configuration and PASS / FAIL at the end.
"""
from __future__ import annotations

import itertools
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402  (PATH, VERILATOR_ROOT)


def rtl(unit_files: Path):
    files, inc = [], []
    for raw in unit_files.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or (":" in line and line.split(":", 1)[0] in ("top", "rtl_top", "define")):
            continue
        if line.startswith("incdir:"):
            inc.append(line.split(":", 1)[1].strip())
            continue
        if not Path(line).name.startswith("tb_"):
            files.append(line)
    return files, inc


def lint(top: str, params: dict, files, inc) -> tuple[bool, str]:
    v = shutil.which("verilator_bin") or shutil.which("verilator")
    cmd = [v, "--lint-only", "-Wall", "--top-module", top] + [f"-I{d}" for d in inc]
    cmd += [f"-G{k}={val}" for k, val in params.items()] + files
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    msg = "\n".join(ln for ln in (r.stdout + r.stderr).splitlines() if ln.startswith("%"))
    return r.returncode == 0, msg


def main() -> int:
    core_files, core_inc = rtl(HERE / "files.txt")
    top_files, top_inc = rtl(ROOT / "mncore" / "fpga" / "top_mab" / "files.txt")
    cfgs = []
    for fp, mau, bfn in itertools.product((0, 1, 2, 3), (0, 1), (0, 1)):
        cfgs.append(("mn_core", dict(N_PE=4, LM_AW=8, FPALU=fp, MAU=mau, BFN=bfn), core_files, core_inc))
    for fp in (0, 1, 3):
        cfgs.append(("mn_core", dict(N_PE=1, FPALU=fp), core_files, core_inc))
    cfgs.append(("mn_mab", {}, core_files, core_inc))
    cfgs.append(("mn_mab", dict(N_PE=1, LM_AW=9), core_files, core_inc))
    cfgs.append(("mn_mab_mem", {}, core_files, core_inc))
    for fp, mau, bfn in ((0, 1, 0), (3, 0, 1), (1, 1, 1)):
        cfgs.append(("mn_top_mab", dict(FPALU=fp, MAU=mau, BFN=bfn), top_files, top_inc))
    ok_all = True
    for top, prm, files, inc in cfgs:
        ok, msg = lint(top, prm, files, inc)
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} {top} {' '.join(f'{k}={v}' for k, v in prm.items())}", flush=True)
        if not ok:
            print(msg[:3000])
    print("PASS" if ok_all else "FAIL")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())

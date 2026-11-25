#!/usr/bin/env python3
"""Verilator lint (-Wall) of the WP37 RTL in its configurations.

    python mncore/sim/tb/m2/lint_cfg.py [-j N]

mn_core with N_PE = 4 and M2 = 1 (the L1BM / L2BM / MV units) for the units of the bitstreams and the
others (FPALU, MAU, BFN, MAT, REPLICA, SDCLR, the units' RRN / DAR), mn_core without the units (N_PE = 4
and N_PE = 1), mn_mab with BM = 1, mn_mab_mem, mn_l1bm / mn_l2bm with REPLICA, and the board tops
mn_top_m2 (mncore/fpga/top_m2), mn_top_mab and mn_top_1pe. Prints one line per configuration and PASS /
FAIL at the end. The WP30 / WP36 configurations are mncore/sim/tb/mab/lint_cfg.py and
mncore/sim/tb/mat/lint_cfg.py.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
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
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", "--jobs", type=int, default=8)
    a = ap.parse_args()
    m2_files, m2_inc = rtl(HERE / "files.txt")
    top_files, top_inc = rtl(ROOT / "mncore" / "fpga" / "top_m2" / "files.txt")
    mab_files, mab_inc = rtl(ROOT / "mncore" / "fpga" / "top_mab" / "files.txt")
    pe1_files, pe1_inc = rtl(ROOT / "mncore" / "sim" / "tb" / "top_1pe" / "files.txt")
    base = dict(N_PE=4, LM_AW=8, M2=1)
    cfgs = []
    for fp, mau, bfn, mat in ((0, 1, 0, 0), (1, 1, 1, 0), (1, 1, 1, 1), (0, 0, 1, 1), (3, 0, 1, 0), (0, 1, 0, 1)):
        for rep in (0, 1):
            cfgs.append(("mn_core", dict(base, FPALU=fp, MAU=mau, BFN=bfn, MAT=mat, REPLICA=rep), m2_files, m2_inc))
    cfgs.append(("mn_core", dict(base, FPALU=0, BFN=0, SDCLR=1), m2_files, m2_inc))
    for l1, l2, dar in ((1, 1, 1), (0, 0, 0), (2, 2, 1), (1, 2, 0)):
        cfgs.append(("mn_core", dict(base, FPALU=0, BFN=0, L1_RRN=l1, L2_RRN=l2, L2_DAR=dar), m2_files, m2_inc))
    for fp, mau, bfn in ((0, 1, 0), (1, 1, 1), (3, 0, 1)):
        cfgs.append(("mn_core", dict(N_PE=4, LM_AW=8, FPALU=fp, MAU=mau, BFN=bfn), m2_files, m2_inc))
    for fp in (0, 1, 3):
        cfgs.append(("mn_core", dict(N_PE=1, FPALU=fp), m2_files, m2_inc))
    cfgs.append(("mn_m2_harness", {}, m2_files, m2_inc))
    cfgs.append(("mn_mab", dict(BM=1), m2_files, m2_inc))
    cfgs.append(("mn_mab", dict(BM=1, MAT=1, MAU=0), m2_files, m2_inc))
    cfgs.append(("mn_mab_mem", {}, m2_files, m2_inc))
    for rep in (0, 1):
        for rrn in (0, 1, 2):
            cfgs.append(("mn_l1bm", dict(REPLICA=rep, RRN=rrn), m2_files, m2_inc))
            cfgs.append(("mn_l2bm", dict(REPLICA=rep, RRN=rrn, DAR=0), m2_files, m2_inc))
        cfgs.append(("mn_l1bm", dict(REPLICA=rep, RRN=1, N_MAB=16), m2_files, m2_inc))
        cfgs.append(("mn_l2bm", dict(REPLICA=rep, RRN=1, N_L1B=8), m2_files, m2_inc))
    for fp, mau, bfn, mat, rep in ((0, 1, 0, 0, 0), (0, 1, 0, 0, 1), (0, 0, 1, 1, 0), (3, 0, 0, 0, 0)):
        cfgs.append(("mn_top_m2", dict(FPALU=fp, MAU=mau, BFN=bfn, MAT=mat, REPLICA=rep), top_files, top_inc))
    for fp, mau, bfn in ((0, 1, 0), (3, 0, 1)):
        cfgs.append(("mn_top_mab", dict(FPALU=fp, MAU=mau, BFN=bfn), mab_files, mab_inc))
    cfgs.append(("mn_top_1pe", {}, pe1_files, pe1_inc))
    ok_all = True
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        outs = list(ex.map(lambda c: lint(c[0], c[1], c[2], c[3]), cfgs))
    for (top, prm, _, _), (ok, msg) in zip(cfgs, outs):
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} {top} {' '.join(f'{k}={v}' for k, v in prm.items())}", flush=True)
        if not ok:
            print(msg[:3000])
    print(f"{len(cfgs)} configurations")
    print("PASS" if ok_all else "FAIL")
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())

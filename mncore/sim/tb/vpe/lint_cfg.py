#!/usr/bin/env python3
"""Verilator lint (-Wall) of the WP34 RTL (the virtual PEs) in its configurations.

    python mncore/sim/tb/vpe/lint_cfg.py [-j N]

mn_core with VPE = 1 (through mn_vpe_harness and directly): N_MAB 16 / 1, LM_AW 11 / 8, with and without the
units (M2), the arithmetic units of the bitstreams and the full set, REPLICA, SDCLR, MAT with one MAB, the
whole-context check (VPE_CXALL); mn_vpe, mn_vpe_ctx, mn_vpe_store, mn_vpe_arb on their own; mn_l1bm with
BS = 1; the board top mn_top_vpe (mncore/fpga/top_vpe). Prints one line per configuration and PASS / FAIL at
the end. The configurations without the virtual PEs: mncore/sim/tb/m2/lint_cfg.py, mab/, mat/.
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
import simrun  # noqa: E402,F401  (PATH, VERILATOR_ROOT)


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
    files, inc = rtl(HERE / "files.txt")
    top_files, top_inc = rtl(ROOT / "mncore" / "fpga" / "top_vpe" / "files.txt")
    cfgs = []
    for nm, lm in ((16, 11), (1, 11), (1, 8), (16, 8), (4, 11)):
        for m2 in (1, 0):
            cfgs.append(("mn_vpe_harness", dict(N_MAB=nm, LM_AW=lm, M2=m2), files, inc))
    for fp, mau, bfn in ((1, 1, 1), (3, 0, 1), (0, 1, 0)):
        cfgs.append(("mn_vpe_harness", dict(FPALU=fp, MAU=mau, BFN=bfn), files, inc))
    cfgs.append(("mn_vpe_harness", dict(REPLICA=1), files, inc))
    cfgs.append(("mn_vpe_harness", dict(SDCLR=0), files, inc))
    base = dict(N_PE=4, VPE=1, M2=1)
    cfgs.append(("mn_core", dict(base, N_MAB=1, LM_AW=11, MAT=1, MAU=0, FPALU=0), files, inc))
    cfgs.append(("mn_core", dict(base, N_MAB=1, LM_AW=8, MAT=1), files, inc))
    cfgs.append(("mn_core", dict(base, N_MAB=16, LM_AW=11, VPE_CXALL=1), files, inc))
    cfgs.append(("mn_core", dict(base, N_MAB=16, LM_AW=11, L1_RRN=0, L2_RRN=1, L2_DAR=1), files, inc))
    cfgs.append(("mn_core", dict(N_PE=4, VPE=1, M2=0, N_MAB=16, LM_AW=11, SDCLR=1), files, inc))
    cfgs.append(("mn_core", dict(N_PE=4, VPE=1, M2=1, L2MV=0, N_MAB=16, LM_AW=11, SDCLR=1), files, inc))
    cfgs.append(("mn_core", dict(N_PE=4, VPE=0, M2=1, L2MV=0, LM_AW=8), files, inc))
    cfgs.append(("mn_vpe", dict(N_MAB=16, BM=0), files, inc))
    cfgs.append(("mn_vpe", dict(N_MAB=1, BM=1, MAU=1, FPALU=1, BFN=1), files, inc))
    cfgs.append(("mn_vpe_ctx", {}, files, inc))
    cfgs.append(("mn_vpe_ctx", dict(MAU=0), files, inc))
    cfgs.append(("mn_vpe_store", {}, files, inc))
    cfgs.append(("mn_vpe_arb", {}, files, inc))
    for rrn in (1, 0):
        cfgs.append(("mn_l1bm", dict(N_MAB=16, RRN=rrn, BS=1), files, inc))
    cfgs.append(("mn_l1bm", dict(N_MAB=16, RRN=1, BS=1, REPLICA=1), files, inc))
    for prm in (dict(), dict(M2=1), dict(M2=1, L2MV=0), dict(N_MAB=1, M2=1), dict(M2=1, REPLICA=1),
                dict(FPALU=3, BFN=1)):
        cfgs.append(("mn_top_vpe", prm, top_files, top_inc))
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

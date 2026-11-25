#!/usr/bin/env python3
"""Verilator lint (-Wall) of mn_top_multi (WP38) in the configurations of the bitstream set.

    python mncore/sim/tb/multi/lint_cfg.py [-j N]

UNITS 2 / 0 with the RTL of mncore/fpga/multi/files.txt, UNITS 1 with files_l1.txt (the stubs of mn_l2bm /
mn_mv), with and without the SDRAM, the units of the members (MAU, FPALU, MAT, BFN, REPLICA, L1_RRN) and the
stubs alone. Prints one line per configuration and PASS / FAIL at the end.
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


def rtl(listfile: Path):
    files, inc = [], []
    for raw in listfile.read_text(encoding="utf-8").splitlines():
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
    multi = ROOT / "mncore" / "fpga" / "multi"
    f2, i2 = rtl(multi / "files.txt")
    f1, i1 = rtl(multi / "files_l1.txt")
    cfgs = [
        ("mn_top_multi", dict(UNITS=2), f2, i2),                               # M2a
        ("mn_top_multi", dict(UNITS=2, REPLICA=1), f2, i2),                    # M2aR
        ("mn_top_multi", dict(UNITS=0, MAU=1), f2, i2),                        # MAU
        ("mn_top_multi", dict(UNITS=0, MAU=1, FPALU=3), f2, i2),
        ("mn_top_multi", dict(UNITS=0, MAU=1, FPALU=3, SDRAM=0), f2, i2),
        ("mn_top_multi", dict(UNITS=0, MAT=1, BFN=1, SDRAM=0), f2, i2),
        ("mn_top_multi", dict(UNITS=1, MAU=1), f1, i1),
        ("mn_top_multi", dict(UNITS=1, MAU=1, L1_RRN=0, SDRAM=0), f1, i1),
        ("mn_top_multi", dict(UNITS=1, MAU=1, L1_RRN=2, SDRAM=0, REPLICA=1), f1, i1),
        ("mn_l2bm", {}, f1, i1),
        ("mn_mv", {}, f1, i1),
    ]
    ok = True
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [(c, ex.submit(lint, *c)) for c in cfgs]
        for (top, prm, fl, _), fu in futs:
            good, msg = fu.result()
            ok &= good
            tag = "stubs" if any("stub" in f for f in fl) else "rtl"
            print(f"{'PASS' if good else 'FAIL'}  {top} {prm} ({tag})")
            if not good:
                print(msg[:3000])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

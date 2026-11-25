#!/usr/bin/env python3
"""WP33: clocks of single MV words on the test core (tb_mv, +mvtime).

    python mncore/sim/tb/mv/timing.py            # writes build/timing.tst and runs it on env a and b

Takes MV words from fixed/mv.tst (gen_tests.py) and makes one test per word whose only entry is
that word (no fills, no hashes: the data does not matter for the time), then runs tb_mv with
+mvtime: the RUN of one entry = fetch, check pass, transfer, the end of the MV (core clocks).
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402,F401  (PATH)

# (test, index of the m word among the test's words (0 = the PDM preamble), description)
PICK = [
    ("o_chain", 1, "mvp/n64 $d0@0 $lc0@0.0 (DRAM -> L2BM, 64)"),
    ("o_chain", 2, "mvp/n64 $lc0@0.0 $p0@0 (L2BM -> PDM, 64)"),
    ("o_chain", 3, "mvp/n64 $p0@0 $d1024@0 (PDM -> DRAM, 64)"),
    ("big", 1, "mvp/n2048 $d0@0 $lc0@0.0 (DRAM -> L2BM, 2048)"),
    ("big", 2, "mvp/n2048 $lc0@0.0 $d4096@0 (L2BM -> DRAM, 2048)"),
    ("p2d", 0, "mvp/n1024 $d32768@0 $p0@0 (DRAM -> PDM, 1024)"),
    ("red_f64", 1, "mvrdfadd/n64 $lc0 $d512 (reduction to DRAM, 64)"),
    ("b", 1, "mvb/n128 $d64 $lc256 (DRAM -> L2BM, 128; 3/4 zero chunks)"),
    ("d_c2p", 1, "mvd/n64 $lc64 $p0@0 (L2BM -> PDM, 64 -> 512; 7/8 zero chunks)"),
    ("p2c", 2, "mvp/n64 $p0@0 $lc512@0.1 (to L2B 1: nothing)"),
]


def main() -> int:
    tests, cur = {}, None
    for line in (HERE / "fixed" / "mv.tst").read_text(encoding="utf-8").splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "T":
            cur = tests.setdefault(p[1], [])
        elif p[0] == "M" and cur is not None:
            cur.append(p[1])
    out = []
    for i, (name, k, desc) in enumerate(PICK):
        out += [f"# {desc}", f"T t{i}_{name} 0000000000000001", f"M {tests[name][k]}", "R 0 0 1 1", "E"]
    tst = HERE / "build" / "timing.tst"
    tst.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    vvp = HERE / "build" / "sim.vvp"
    for env in ("a", "b"):
        other = "b" if env == "a" else "a"
        r = subprocess.run(["vvp", "-n", str(vvp), f"+mv{env}={tst}", f"+mv{other}=skip", "+mvtime"],
                           cwd=ROOT, capture_output=True, text=True)
        clocks = {m.group(1): int(m.group(2)) for m in re.finditer(r"^\w (\S+): RUN of \d+ entries: (\d+) clocks",
                                                                     r.stdout, re.MULTILINE)}
        print(f"env {env} ({'core 27 MHz, SDRAM 108 MHz' if env == 'a' else '54 MHz, one clock'}):")
        for i, (name, k, desc) in enumerate(PICK):
            print(f"  {clocks.get(f't{i}_{name}', '?'):>7} clocks  {desc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

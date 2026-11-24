#!/usr/bin/env python3
"""Runs a .vsm on the Rust simulator (third_party/mncore/viz/core) and writes the ndmp.

usage: python mncore/tools/golden/run_rust.py X.vsm [--testcase auto|none|PATH]
           [--probe wide|mab|pe|none] [--out DIR] [-o OUT.ndmp] [--no-build] [--threads N]

The program is composed exactly as run_official.py does (goldenlib.load_program) and executed by
``mncore/golden_rs`` (bin ``golden_dump``), which is built with ``cargo build --release`` first.
Output: DIR/rust.ndmp (default DIR is mncore/tools/golden/build/<name>/).
Exit code: 0 ok, 1 the simulator rejected the program (status printed), 2 usage error.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import goldenlib as gl  # noqa: E402
import ndmp  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vsm")
    ap.add_argument("--testcase", default="auto", help="auto (default), none, or a testcase.vsm path")
    ap.add_argument("--probe", default=gl.DEFAULT_PROBE, choices=gl.PROBES)
    ap.add_argument("--out", help="output directory")
    ap.add_argument("-o", dest="ndmp_out", help="write the ndmp here instead of DIR/rust.ndmp")
    ap.add_argument("--no-build", action="store_true", help="do not run cargo build")
    ap.add_argument("--threads", type=int, help="RAYON_NUM_THREADS for the simulator")
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args(argv)

    vsm = Path(a.vsm)
    if not vsm.is_file():
        print(f"no such file: {vsm}", file=sys.stderr)
        return 2
    exe = gl.golden_dump_exe() if a.no_build else gl.build_rust()
    prog = gl.load_program(vsm, a.testcase, a.probe)
    print(f"[rust] {gl.rel(prog.src)} kind={prog.kind} testcase={gl.rel(prog.testcase)} probe={a.probe}",
          file=sys.stderr)
    res = gl.run_rust_program(prog, exe, threads=a.threads, timeout=a.timeout)
    if res.status != "ok":
        print(f"[rust] {res.status}: {res.message}", file=sys.stderr)
        return 1
    out = Path(a.out) if a.out else gl.BUILD / gl.safe_name(vsm)
    out.mkdir(parents=True, exist_ok=True)
    nd = Path(a.ndmp_out) if a.ndmp_out else out / "rust.ndmp"
    meta = dict(prog.meta)
    meta["producer"] = "rust"
    res.write(nd, meta)
    ndmp.read(str(nd))  # validates the format
    print(f"[rust] words={res.words} -> {nd}", file=sys.stderr)
    print(nd)
    return 0


if __name__ == "__main__":
    sys.exit(main())

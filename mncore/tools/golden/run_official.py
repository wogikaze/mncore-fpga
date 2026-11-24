#!/usr/bin/env python3
"""Runs a .vsm on the official assembler + emulator (WSL) and writes the ndmp.

usage: python mncore/tools/golden/run_official.py X.vsm [--testcase auto|none|PATH]
           [--probe wide|mab|pe|none] [--out DIR] [-o OUT.ndmp] [--timeout SEC]

The program is composed like judge.py does (see goldenlib.py): a solution of a known problem is
wrapped with its testcase, a testcase runs with an empty solution. assemble3 runs with
``--instruction-mode flat --disable-packer`` and the emulator with ``--offchip-memory-init zero``.

Outputs in DIR (default mncore/tools/golden/build/<name>/):
  main.asm        the assembled solution (flat j / m words, d lines)
  official.asm    the whole emulator input (testcase prefix + main + suffix + output + probe)
  official.dmp    the emulator debug dump
  official.ndmp   normalized dump (also written to -o if given)
Exit code: 0 ok, 1 the official tools failed on this program (status printed), 2 usage error.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import goldenlib as gl  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vsm")
    ap.add_argument("--testcase", default="auto", help="auto (default), none, or a testcase.vsm path")
    ap.add_argument("--probe", default=gl.DEFAULT_PROBE, choices=gl.PROBES)
    ap.add_argument("--out", help="output directory")
    ap.add_argument("-o", dest="ndmp_out", help="also copy the ndmp here")
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args(argv)

    vsm = Path(a.vsm)
    if not vsm.is_file():
        print(f"no such file: {vsm}", file=sys.stderr)
        return 2
    prog = gl.load_program(vsm, a.testcase, a.probe)
    out = Path(a.out) if a.out else gl.BUILD / gl.safe_name(vsm)
    print(f"[official] {gl.rel(prog.src)} kind={prog.kind} testcase={gl.rel(prog.testcase)} probe={a.probe}",
          file=sys.stderr)
    gl.write_official_job(prog, out)
    gl.run_official_jobs([out], parallel=1, keep=True, timeout=a.timeout, on_line=lambda s: None)
    status = gl.read_status(out)
    if status != "ok":
        print(f"[official] {status}", file=sys.stderr)
        log = out / "official.log"
        if log.exists():
            sys.stderr.write(log.read_text(encoding="utf-8", errors="replace")[-3000:])
        return 1
    nd = out / "official.ndmp"
    if a.ndmp_out:
        shutil.copyfile(nd, a.ndmp_out)
    print(f"[official] words={(out / 'words.txt').read_text().strip()} -> {nd}", file=sys.stderr)
    print(nd)
    return 0


if __name__ == "__main__":
    sys.exit(main())

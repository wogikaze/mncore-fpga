#!/usr/bin/env python3
"""Run one .vsm on the M2 core (RTL), the official emulator and the reduced-topology Rust simulator, and
compare (WP37 debugging aid).

    python mncore/sim/tb/m2/m2_try.py X.vsm [--out DIR] [--define TB_REPLICA=1] [--probe] [--keep-vvp]

The program is taken as it is (standalone: its own d set / r / d get lines; with --probe the M2 probe is
appended). Prints the records where the RTL differs from the official (cut to the implemented units) and
from the Rust run (the zero rule). Outputs in DIR (default mncore/sim/tb/m2/build/try/<name>/).
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
import run as regress  # noqa: E402
import ndmp  # noqa: E402

regress.configure(4, m2=True)
gl = regress.gl


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vsm")
    ap.add_argument("--out")
    ap.add_argument("--define", action="append", default=[])
    ap.add_argument("--probe", action="store_true")
    a = ap.parse_args(argv)
    vsm = Path(a.vsm).resolve()
    name = vsm.stem
    job = Path(a.out) if a.out else HERE / "build" / "try" / name
    job.mkdir(parents=True, exist_ok=True)
    prog = gl.load_program(vsm, "none", "none")
    if a.probe:
        prog.probe = "m2"
        prog.probe_text = regress.probe_text()
    gl.write_official_job(prog, job)
    gl.run_official_jobs([job], parallel=1, keep=True, on_line=lambda s: None)
    st = gl.read_status(job)
    print(f"official: {st}")
    # Rust on the reduced topology
    r = subprocess.run([str(regress.TOPO_DUMP), "--topology", regress.TOPO_M2, "-"],
                       input=prog.rust_source().encode(), capture_output=True)
    (job / "rust.ndmp").write_text("# ndmp v1\n" + r.stdout.decode(), encoding="utf-8")
    print(f"rust: rc {r.returncode} {r.stderr.decode().strip()[:200]}")
    if st != "ok":
        print((job / "official.log").read_text(errors="replace")[-2000:])
        return 1
    entries, events, _ = regress.parse_official_asm((job / "official.asm").read_text(encoding="utf-8"))
    script, runs, gets = regress.make_script(entries, events)
    (job / "rtl.scr").write_text(script, encoding="utf-8", newline="\n")
    vvp = regress.compile_tb(print, a.define)
    rr = subprocess.run(["vvp", "-n", str(vvp), f"+script={(job / 'rtl.scr').as_posix()}", "+quiet",
                         "+maxclk=50000000"], cwd=ROOT, capture_output=True, text=True)
    (job / "rtl.out").write_text(rr.stdout, encoding="utf-8")
    reads = {}
    for line in rr.stdout.splitlines():
        p = line.split()
        if p and p[0] == "D":
            reads[(int(p[1], 16), int(p[2], 16), int(p[3], 16))] = int(p[4], 16)
        elif p and p[0] in ("S", "ERR", "DERR") or "ERROR" in line:
            print("  " + line)
    rtl = regress.rtl_records(gets, reads)
    off, _ = ndmp.read(str(job / "official.ndmp"))
    rust, _ = ndmp.read(str(job / "rust.ndmp"))
    keep = regress.keep_record
    for nm, ref in (("official", off), ("rust", rust)):
        A = {k: v for k, v in ref.items() if keep(k)}
        B = {k: v for k, v in rtl.items() if keep(k)}
        m, oa, ob = regress.diff(A, B)
        print(f"rtl vs {nm}: {len(A.keys() & B.keys())} compared, {len(m)} differ, {len(oa)} only {nm}, "
              f"{len(ob)} only rtl")
        for k in (m + oa + ob)[:12]:
            print(f"   {k[0]} {k[1]} {k[2]:#x} {nm}={A.get(k, 0):016x} rtl={B.get(k, 0):016x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

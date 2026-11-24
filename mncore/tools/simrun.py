#!/usr/bin/env python3
"""Run a unit testbench: python mncore/tools/simrun.py <unit> [--lint] [--synth] [--top TB]

Reads mncore/sim/tb/<unit>/files.txt:
  - one path per line, relative to the repo root (blank lines and '#' comments ignored)
  - optional directives:  'top: <tb_module>'   'rtl_top: <module for lint/synth>'
                          'incdir: <dir>'      'define: NAME[=VAL]'
  - files whose basename starts with 'tb_' are testbench-only (excluded from lint/synth)
The simulation passes iff the last non-empty stdout line starts with 'PASS'.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Shells started before OSS CAD Suite was added to the user PATH do not see it; add it here.
if shutil.which("iverilog") is None:
    _oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
    os.environ["PATH"] = os.pathsep.join([str(_oss / "bin"), str(_oss / "lib"), os.environ.get("PATH", "")])
# verilator_bin from OSS CAD Suite on Windows needs VERILATOR_ROOT to find its include files.
if "VERILATOR_ROOT" not in os.environ and shutil.which("verilator_bin"):
    _vr = Path(shutil.which("verilator_bin")).resolve().parents[1] / "share" / "verilator"
    if _vr.exists():
        os.environ["VERILATOR_ROOT"] = str(_vr)


def parse_files(unit):
    spec = ROOT / "mncore" / "sim" / "tb" / unit / "files.txt"
    if not spec.exists():
        sys.exit(f"no such unit: {spec}")
    files, cfg = [], {"incdir": [], "define": []}
    for raw in spec.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if ":" in line and line.split(":", 1)[0] in ("top", "rtl_top", "incdir", "define"):
            k, v = (s.strip() for s in line.split(":", 1))
            if k in ("incdir", "define"):
                cfg[k].append(v)
            else:
                cfg[k] = v
            continue
        files.append(line)
    return files, cfg


def run(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("unit")
    ap.add_argument("--lint", action="store_true")
    ap.add_argument("--synth", action="store_true")
    ap.add_argument("--no-sim", action="store_true")
    ap.add_argument("--top")
    a = ap.parse_args()

    files, cfg = parse_files(a.unit)
    build = ROOT / "mncore" / "sim" / "tb" / a.unit / "build"
    build.mkdir(exist_ok=True)
    rtl = [f for f in files if not Path(f).name.startswith("tb_")]
    inc = [f"-I{d}" for d in cfg["incdir"]]
    ok = True

    if not a.no_sim:
        top = a.top or cfg.get("top")
        vvp = build / "sim.vvp"
        cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", str(vvp)] + inc
        cmd += [f"-D{d}" for d in cfg["define"]]
        if top:
            cmd += ["-s", top]
        r = run(cmd + files)
        sys.stdout.write(r.stdout + r.stderr)
        if r.returncode:
            print("FAIL iverilog compile")
            return 1
        r = run(["vvp", "-n", str(vvp)])
        sys.stdout.write(r.stdout + r.stderr)
        # verdict = last line starting with PASS/FAIL (vvp's "$finish called" note may follow it)
        verdicts = [l.strip() for l in r.stdout.splitlines() if l.strip().startswith(("PASS", "FAIL"))]
        sim_ok = r.returncode == 0 and bool(verdicts) and verdicts[-1].startswith("PASS")
        print(f"[sim] {'PASS' if sim_ok else 'FAIL'}")
        ok &= sim_ok

    if a.lint:
        verilator = shutil.which("verilator_bin") or shutil.which("verilator")
        cmd = [verilator, "--lint-only", "-Wall"] + inc
        if cfg.get("rtl_top"):
            cmd += ["--top-module", cfg["rtl_top"]]
        r = run(cmd + rtl)
        sys.stdout.write(r.stdout + r.stderr)
        print(f"[lint] {'PASS' if r.returncode == 0 else 'FAIL'}")
        ok &= r.returncode == 0

    if a.synth:
        reads = " ".join(f"read_verilog {' '.join(inc)} {f};" for f in rtl)
        top = f"-top {cfg['rtl_top']}" if cfg.get("rtl_top") else ""
        script = f"{reads} synth_gowin -family gw2a {top} -json {build.as_posix()}/synth.json; stat"
        r = run(["yosys", "-q", "-p", script])
        out = r.stdout + r.stderr
        sys.stdout.write(out[-4000:])
        print(f"[synth] {'PASS' if r.returncode == 0 else 'FAIL'}")
        ok &= r.returncode == 0

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

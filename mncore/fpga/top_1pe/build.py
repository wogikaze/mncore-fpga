#!/usr/bin/env python3
"""Build the 1-PE board design mn_top_1pe (WP21) for the Tang Nano 20K, optionally load it.

  python mncore/fpga/top_1pe/build.py                       # FPALU=3 (relu, lrelu*, rsqrt; stage 2), 27 MHz
  python mncore/fpga/top_1pe/build.py --param FPALU=0       # no FP ALU (stage 1)
  python mncore/fpga/top_1pe/build.py --seeds 1,2,3         # try placement seeds, keep the first that meets timing
  python mncore/fpga/top_1pe/build.py --program             # ... and load it into the FPGA SRAM
  python mncore/fpga/top_1pe/build.py --fs mncore/fpga/top_1pe/build/FPALU3/top_1pe.fs   # only load it

With the WP21 RTL, FPALU=1 (full FP ALU, LUT4 83 %) and FPALU=2 (no floor / ftoi, 77 %) synthesized but
did not place (nextpnr's legaliser gave up). After the WP35 area work the full core places and routes:
  python mncore/fpga/top_1pe/build.py --param FPALU=1      # all FP ALU instructions (WP35 report)
(yosys LUT + ALU + 8 * SSRAM: FPALU=1 14,434, 3 13,100, 2 13,485, 0 12,584). One place & route takes
20 to 40 minutes (longer while other jobs load the machine).

Steps: yosys `synth_gowin -family gw2a -nowidelut` (contract 06 section 6) -> nextpnr-himbaechel
(GW2AR-LV18QN88C8/I7, family GW2A-18C, top_1pe.cst) -> gowin_pack. The RTL list is the one of the
simulation unit mncore/sim/tb/top_1pe/files.txt (testbench files left out). Products and logs go to
mncore/fpga/top_1pe/build/<tag>/: synth.json, pnr<seed>.json, top_1pe.fs, yosys.log, nextpnr<seed>.log,
summary.txt (utilisation, Fmax, critical path).

--program loads the bitstream with `openFPGALoader -b tangnano20k <fs>` into the SRAM only (volatile;
the Flash is never written, contract 06 section 9). Take the board lock first:
C:\\wgkz\\nano20k\\mncore\\.board.lock (the main checkout's path).
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402  (also puts OSS CAD Suite on PATH)

DEVICE = "GW2AR-LV18QN88C8/I7"
FAMILY = "GW2A-18C"
TOP = "mn_top_1pe"


def run(cmd, log: Path | None = None, timeout: int = 7200) -> tuple[int, str]:
    t0 = time.time()
    r = subprocess.run([str(c) for c in cmd], cwd=ROOT, text=True, capture_output=True, timeout=timeout)
    out = r.stdout + r.stderr
    if log:
        log.write_text(out, encoding="utf-8")
    print(f"  ({time.time() - t0:.0f} s) {Path(str(cmd[0])).name}: rc {r.returncode}", flush=True)
    return r.returncode, out


def parse_pnr(text: str) -> dict:
    res: dict = {}
    fm = re.findall(r"Max frequency for clock '[^']*': ([0-9.]+) MHz \((PASS|FAIL)", text)
    res["fmax"] = float(fm[-1][0]) if fm else None
    util = {}
    for m in re.finditer(r"Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+(\d+)%", text):
        util[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    res["util"] = util
    blocks = text.split("Critical path report for clock")
    if len(blocks) > 1:
        last = blocks[-1].split("Max frequency")[0]
        src = re.search(r"Source (\S+)", last)
        sinks = re.findall(r"Sink (\S+)", last)
        lr = re.search(r"([0-9.]+) ns logic, ([0-9.]+) ns routing", last)
        res["crit"] = f"{src.group(1) if src else '?'} -> {sinks[-1] if sinks else '?'}"
        res["crit_ns"] = f"{lr.group(1)} ns logic + {lr.group(2)} ns routing" if lr else ""
    return res


def synth_cells(text: str) -> dict:
    """Cell counts of the top from the yosys `stat` output (the last one): the "design hierarchy"
    block (counts including the kept submodules, e.g. mn_alu_rot_stage) when there is one."""
    blk = text[text.rfind(f"=== {TOP} ==="):]
    if "=== design hierarchy ===" in blk:
        blk = blk[blk.find("=== design hierarchy ==="):]
    cnt: dict = {}
    for m in re.finditer(r"^\s+(\d+)\s+(?:[\d.]+\s+)?(\S+)\s*$", blk, flags=re.MULTILINE):
        cnt[m.group(2)] = cnt.get(m.group(2), 0) + int(m.group(1))
    kinds = {"LUT": r"^LUT[1-4]$", "ALU": r"^ALU$", "MUX2": r"^MUX2_LUT", "FF": r"^DFF",
             "SSRAM": r"^RAM16S", "BSRAM": r"^(SDP|DP|SP|ROM)", "DSP": r"^(MULT|PADD|ALU54)"}
    out = {k: 0 for k in kinds}
    for cell, n in cnt.items():
        for k, rx in kinds.items():
            if re.match(rx, cell):
                out[k] += n
    out["LUT_eq"] = out["LUT"] + out["ALU"] + 8 * out["SSRAM"]
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--param", action="append", default=[], help=f"{TOP} parameter K=V (e.g. FPALU=2)")
    ap.add_argument("--seeds", default="1", help="nextpnr placement seeds to try, comma separated")
    ap.add_argument("--freq", type=float, default=27.0, help="clock constraint in MHz (the board clock is 27)")
    ap.add_argument("--tag", help="build sub-directory (default from the parameters)")
    ap.add_argument("--default-synth", action="store_true", help="synth_gowin without -nowidelut")
    ap.add_argument("--no-pnr", action="store_true", help="synthesis only")
    ap.add_argument("--reuse-synth", action="store_true", help="use build/<tag>/synth.json as it is")
    ap.add_argument("--pnr-arg", action="append", default=[],
                    help="extra nextpnr argument, e.g. --pnr-arg=--placer --pnr-arg=sa")
    ap.add_argument("--program", action="store_true", help="load the bitstream into the FPGA SRAM")
    ap.add_argument("--fs", help="with --program: load this bitstream instead of building")
    a = ap.parse_args(argv)

    if a.fs:
        fs = Path(a.fs).resolve()
        rc, out = run(["openFPGALoader", "-b", "tangnano20k", fs])
        print(out[-1500:])
        return rc

    prm = dict(kv.split("=", 1) for kv in a.param)
    prm.setdefault("FPALU", "3")
    tag = a.tag or "_".join(f"{k}{v}" for k, v in sorted(prm.items())) + ("_default" if a.default_synth else "")
    d = HERE / "build" / tag
    d.mkdir(parents=True, exist_ok=True)
    files, cfg = simrun.parse_files("top_1pe")
    rtl = [f for f in files if not Path(f).name.startswith("tb_")]
    inc = " ".join(f"-I{x}" for x in cfg["incdir"])
    reads = " ".join(f"read_verilog {inc} {f};" for f in rtl)
    chp = "".join(f" chparam -set {k} {v} {TOP};" for k, v in prm.items())
    opt = "" if a.default_synth else " -nowidelut"
    synth = d / "synth.json"
    if a.reuse_synth and synth.exists():
        out = (d / "yosys.log").read_text(encoding="utf-8")
    else:
        print(f"== yosys {TOP} {prm}{opt}", flush=True)
        rc, out = run(["yosys", "-p", f"{reads}{chp} synth_gowin -family gw2a -top {TOP}{opt} -json {synth.as_posix()}; stat"],
                      d / "yosys.log")
        if rc:
            print(out[-3000:])
            return 1
    cells = synth_cells(out)
    lines = [f"design {TOP} {prm} synth_gowin -family gw2a{opt}",
             "yosys: " + ", ".join(f"{k} {v}" for k, v in cells.items()) +
             f"  (LUT_eq = LUT + ALU + 8 * SSRAM = {cells['LUT_eq']}, {100 * cells['LUT_eq'] / 20736:.1f} % of 20736)"]
    print(lines[-1], flush=True)
    if a.no_pnr:
        (d / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        return 0

    best = None
    for seed in a.seeds.split(","):
        pnr = d / f"pnr{seed}.json"
        print(f"== nextpnr seed {seed} ({a.freq} MHz)", flush=True)
        rc, out = run(["nextpnr-himbaechel", "--json", synth, "--write", pnr, "--device", DEVICE,
                       "--vopt", f"family={FAMILY}", "--vopt", f"cst={(HERE / 'top_1pe.cst').as_posix()}",
                       "--freq", str(a.freq), "--seed", seed, "--timing-allow-fail"] + a.pnr_arg,
                      d / f"nextpnr{seed}.log")
        if rc:
            err = re.findall(r"ERROR: .*", out)
            lines.append(f"seed {seed}: nextpnr failed: {err[-1] if err else rc}")
            print(lines[-1], flush=True)
            continue
        p = parse_pnr(out)
        util = ", ".join(f"{k} {u}/{t} ({100 * u / t:.0f} %)" for k, (u, t) in p["util"].items() if u)
        ok = p["fmax"] is not None and p["fmax"] >= a.freq
        lines.append(f"seed {seed}: Fmax {p['fmax']} MHz ({'PASS' if ok else 'FAIL'} at {a.freq} MHz); "
                     f"critical {p.get('crit', '?')} ({p.get('crit_ns', '')})")
        lines.append(f"  utilisation: {util}")
        print("\n".join(lines[-2:]), flush=True)
        if ok:
            best = (seed, pnr)
            break
    if best is None:
        lines.append("no seed met timing")
        (d / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(lines[-1])
        return 1
    fs = d / "top_1pe.fs"
    print("== gowin_pack", flush=True)
    rc, out = run(["gowin_pack", "-c", "-d", FAMILY, "-o", fs, best[1]], d / "pack.log")
    if rc:
        print(out[-2000:])
        return 1
    lines.append(f"bitstream: {fs.relative_to(ROOT).as_posix()} (seed {best[0]})")
    (d / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(lines[-1], flush=True)
    if a.program:
        if shutil.which("openFPGALoader") is None:
            print("openFPGALoader not found")
            return 1
        rc, out = run(["openFPGALoader", "-b", "tangnano20k", fs])
        print(out[-1500:])
        return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Build the M2 board design mn_top_m2 (WP37) for the Tang Nano 20K, optionally load it.

  python mncore/fpga/top_m2/build.py                  # M2a: FPALU=0 MAU=0 BFN=0 MAT=0 REPLICA=0 (default)
  python mncore/fpga/top_m2/build.py --param MAU=1    # with the MAU: LUT_eq 96 %, does not fit (WP37)
  python mncore/fpga/top_m2/build.py --param REPLICA=1   # the replica rule (WP-3x)
  python mncore/fpga/top_m2/build.py --no-pnr         # synthesis only (resources)
  python mncore/fpga/top_m2/build.py --program        # ... and load it into the FPGA SRAM
  python mncore/fpga/top_m2/build.py --fs <file.fs>   # only load it

Function-specific bitstreams (mncore/wp/WP-3x.md): the parameters FPALU / MAU / BFN / MAT / REPLICA of
mn_top_m2 choose the units; the L1BM, L2BM and MV units are always there.
Steps: yosys `synth_gowin -family gw2a -nowidelut` (contract 06 section 6) -> nextpnr-himbaechel
(GW2AR-LV18QN88C8/I7, family GW2A-18C, top_m2.cst; the embedded SDRAM ports are bound by name) ->
gowin_pack. Two clocks: the core on the 27 MHz board clock, the SDRAM controller on the rPLL's
54 MHz (mn_top_m2's defaults: WP05's 54 MHz setting; its 99 MHz is not reached in this design, WP37).
nextpnr gets --freq for both (the SDRAM clock needs 54); the summary lists the Fmax of every clock. Products and logs: mncore/fpga/top_m2/build/<tag>/ (synth.json, pnr<seed>.json, top_m2.fs,
yosys.log, nextpnr<seed>.log, summary.txt).

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
import simrun  # noqa: E402,F401  (also puts OSS CAD Suite on PATH)

DEVICE = "GW2AR-LV18QN88C8/I7"
FAMILY = "GW2A-18C"
TOP = "mn_top_m2"
DEFAULTS = {"FPALU": "0", "MAU": "0", "BFN": "0", "MAT": "0", "REPLICA": "0"}   # M2a (WP37)


def rtl_files():
    files, cfg = [], {"incdir": []}
    for raw in (HERE / "files.txt").read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if ":" in line and line.split(":", 1)[0] in ("rtl_top", "incdir"):
            k, v = (s.strip() for s in line.split(":", 1))
            if k == "incdir":
                cfg[k].append(v)
            else:
                cfg[k] = v
            continue
        files.append(line)
    return files, cfg


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
    fm = re.findall(r"Max frequency for clock\s+'([^']*)': ([0-9.]+) MHz \((PASS|FAIL) at ([0-9.]+) MHz\)", text)
    res["clocks"] = {}
    for name, f, _pf, _tgt in fm:
        res["clocks"][name] = float(f)          # the last report of a clock wins
    util = {}
    for m in re.finditer(r"Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+(\d+)%", text):
        util[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    res["util"] = util
    return res


def synth_cells(text: str) -> dict:
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
    ap.add_argument("--param", action="append", default=[], help=f"{TOP} parameter K=V")
    ap.add_argument("--seeds", default="1", help="nextpnr placement seeds to try, comma separated")
    ap.add_argument("--freq", type=float, default=54.0,
                    help="nextpnr --freq (MHz; one target for both clocks: the SDRAM clock needs 54)")
    ap.add_argument("--core-mhz", type=float, default=27.0, help="the board clock domain must reach this")
    ap.add_argument("--sdr-mhz", type=float, default=54.0, help="the SDRAM clock domain must reach this")
    ap.add_argument("--tag", help="build sub-directory (default from the parameters)")
    ap.add_argument("--no-pnr", action="store_true")
    ap.add_argument("--reuse-synth", action="store_true")
    ap.add_argument("--program", action="store_true")
    ap.add_argument("--fs")
    a = ap.parse_args(argv)

    if a.fs:
        rc, out = run(["openFPGALoader", "-b", "tangnano20k", Path(a.fs).resolve()])
        print(out[-1500:])
        return rc

    prm = dict(DEFAULTS)
    prm.update(dict(kv.split("=", 1) for kv in a.param))
    tag = a.tag or "_".join(f"{k}{v}" for k, v in sorted(prm.items()))
    d = HERE / "build" / tag
    d.mkdir(parents=True, exist_ok=True)
    files, cfg = rtl_files()
    inc = " ".join(f"-I{x}" for x in cfg["incdir"])
    reads = " ".join(f"read_verilog {inc} {f};" for f in files)
    chp = "".join(f" chparam -set {k} {v} {TOP};" for k, v in prm.items())
    synth = d / "synth.json"
    if a.reuse_synth and synth.exists():
        out = (d / "yosys.log").read_text(encoding="utf-8")
    else:
        print(f"== yosys {TOP} {prm} -nowidelut", flush=True)
        rc, out = run(["yosys", "-p", f"{reads}{chp} synth_gowin -family gw2a -top {TOP} -nowidelut "
                       f"-json {synth.as_posix()}; stat"], d / "yosys.log")
        if rc:
            print(out[-3000:])
            return 1
    cells = synth_cells(out)
    lines = [f"design {TOP} {prm} synth_gowin -family gw2a -nowidelut",
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
                       "--vopt", f"family={FAMILY}", "--vopt", f"cst={(HERE / 'top_m2.cst').as_posix()}",
                       "--freq", str(a.freq), "--seed", seed, "--timing-allow-fail"], d / f"nextpnr{seed}.log")
        if rc:
            err = re.findall(r"ERROR: .*", out)
            lines.append(f"seed {seed}: nextpnr failed: {err[-1] if err else rc}")
            print(lines[-1], flush=True)
            continue
        p = parse_pnr(out)
        util = ", ".join(f"{k} {u}/{t} ({100 * u / t:.0f} %)" for k, (u, t) in p["util"].items() if u)
        clk = p["clocks"]
        # the SDRAM controller's clock is the net sclk (the rPLL output); the rest is the board clock
        core = [f for n, f in clk.items() if n != "sclk"]
        sdr = [f for n, f in clk.items() if n == "sclk"]
        ok = bool(core) and min(core) >= a.core_mhz and bool(sdr) and min(sdr) >= a.sdr_mhz
        lines.append(f"seed {seed}: Fmax " + ", ".join(f"{n} {f} MHz" for n, f in clk.items()) +
                     f" -> {'PASS' if ok else 'FAIL'} (core >= {a.core_mhz}, SDRAM sclk >= {a.sdr_mhz})")
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
    fs = d / "top_m2.fs"
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

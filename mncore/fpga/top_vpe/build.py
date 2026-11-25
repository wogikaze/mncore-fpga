#!/usr/bin/env python3
"""Build the virtual-PE board design mn_top_vpe (WP34) for the Tang Nano 20K, optionally load it.

  python mncore/fpga/top_vpe/build.py                     # V64: 64 PEs (N_MAB 16), LM 2048, integer ALU
  python mncore/fpga/top_vpe/build.py --param M2=1 --param L2MV=0   # ... with the L1BM of the 16 MABs
  python mncore/fpga/top_vpe/build.py --param M2=1        # ... with the L1BM / L2BM / MV units (77 %: too big)
  python mncore/fpga/top_vpe/build.py --param N_MAB=1 --param M2=1   # 4 PEs with the chip's LM and the units
  python mncore/fpga/top_vpe/build.py --no-pnr            # synthesis only (resources)
  python mncore/fpga/top_vpe/build.py --program           # ... and load it into the FPGA SRAM
  python mncore/fpga/top_vpe/build.py --fs <file.fs>      # only load it

Function-specific bitstreams (mncore/wp/WP-3x.md): the parameters FPALU / MAU / BFN / M2 / REPLICA of
mn_top_vpe choose the units, N_MAB / LM_AW the virtual PEs. Steps: yosys `synth_gowin -family gw2a
-nowidelut` (contract 06 section 6) -> nextpnr-himbaechel (GW2AR-LV18QN88C8/I7, family GW2A-18C,
top_vpe.cst; the embedded SDRAM ports are bound by name) -> gowin_pack. Two clocks: the core on the
27 MHz board clock, the SDRAM controller on the rPLL's 54 MHz (as mn_top_m2). Products and logs:
mncore/fpga/top_vpe/build/<tag>/ (synth.json, pnr<seed>.json, top_vpe.fs, yosys.log, nextpnr<seed>.log,
summary.txt).

--program loads the bitstream with `openFPGALoader -b tangnano20k <fs>` into the SRAM only (volatile; the
Flash is never written, contract 06 section 9). Take the board lock first:
C:\\wgkz\\nano20k\\mncore\\.board.lock (the main checkout's path).
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
import time
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
sys.path.insert(0, str(ROOT / "mncore" / "fpga" / "top_m2"))
import simrun  # noqa: E402,F401  (also puts OSS CAD Suite on PATH)
import build as m2build  # noqa: E402  (run, parse_pnr, synth_cells of WP37's build.py)

DEVICE = "GW2AR-LV18QN88C8/I7"
FAMILY = "GW2A-18C"
TOP = "mn_top_vpe"
DEFAULTS = {"FPALU": "0", "MAU": "0", "BFN": "0", "M2": "0", "L2MV": "1", "N_MAB": "16", "LM_AW": "11",
            "REPLICA": "0"}
m2build.TOP = TOP          # synth_cells reads the top's statistics
run = m2build.run
parse_pnr = m2build.parse_pnr
synth_cells = m2build.synth_cells


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
        t0 = time.time()
        rc, out = run(["yosys", "-p", f"{reads}{chp} synth_gowin -family gw2a -top {TOP} -nowidelut "
                       f"-json {synth.as_posix()}; stat"], d / "yosys.log")
        if rc:
            print(out[-3000:])
            return 1
        print(f"  yosys {time.time() - t0:.0f} s", flush=True)
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
                       "--vopt", f"family={FAMILY}", "--vopt", f"cst={(HERE / 'top_vpe.cst').as_posix()}",
                       "--freq", str(a.freq), "--seed", seed, "--timing-allow-fail"], d / f"nextpnr{seed}.log")
        if rc:
            err = re.findall(r"ERROR: .*", out)
            lines.append(f"seed {seed}: nextpnr failed: {err[-1] if err else rc}")
            print(lines[-1], flush=True)
            continue
        p = parse_pnr(out)
        util = ", ".join(f"{k} {u}/{t} ({100 * u / t:.0f} %)" for k, (u, t) in p["util"].items() if u)
        clk = p["clocks"]
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
    fs = d / "top_vpe.fs"
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

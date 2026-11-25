#!/usr/bin/env python3
"""Build the members of the bitstream set of mnrun.py (WP38): mn_top_multi for the Tang Nano 20K.

  python mncore/fpga/multi/build.py --member M2a             # one member of set.json
  python mncore/fpga/multi/build.py --all                     # every member of set.json, one after the other
  python mncore/fpga/multi/build.py --member L1MAU --no-pnr   # synthesis only (resources)
  python mncore/fpga/multi/build.py --param UNITS=1 --param MAU=1 --tag try1 --no-pnr   # a trial
  python mncore/fpga/multi/build.py --member M2a --program    # ... and load it into the FPGA SRAM

The set (mncore/fpga/multi/set.json) lists the members: their parameters of mn_top_multi (UNITS, FPALU,
MAU, BFN, MAT, REPLICA, L1_RRN) and the file list (files.txt, or files_l1.txt for UNITS = 1). Steps
as mncore/fpga/top_m2/build.py (WP37): yosys `synth_gowin -family gw2a -nowidelut` (contract 06 section
6) -> nextpnr-himbaechel (GW2AR-LV18QN88C8/I7, family GW2A-18C, top_multi.cst; the embedded SDRAM ports
are bound by name; --freq 54 for both clocks, the core must reach 27 MHz, the SDRAM clock 54) ->
gowin_pack. Products and logs: mncore/fpga/multi/build/<name>/ (synth.json, pnr<seed>.json,
top_multi.fs, yosys.log, nextpnr<seed>.log, summary.txt). mnrun.py loads build/<name>/top_multi.fs.

--program loads the bitstream with `openFPGALoader -b tangnano20k <fs>` into the SRAM only (contract 06
section 9: take the board lock C:\\wgkz\\nano20k\\mncore\\.board.lock first).
"""
from __future__ import annotations

import argparse
import json
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
TOP = "mn_top_multi"
DEFAULTS = {"UNITS": "2", "SDRAM": "1", "FPALU": "0", "MAU": "0", "BFN": "0", "MAT": "0", "REPLICA": "0",
            "L1_RRN": "2"}


def load_set(path: Path = HERE / "set.json") -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def rtl_files(listfile: Path):
    files, cfg = [], {"incdir": []}
    for raw in listfile.read_text(encoding="utf-8").splitlines():
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
    res: dict = {"clocks": {}}
    for name, f, _pf, _tgt in re.findall(r"Max frequency for clock\s+'([^']*)': ([0-9.]+) MHz \((PASS|FAIL) at ([0-9.]+) MHz\)", text):
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


def member_config(name: str | None, params: list[str]) -> tuple[str, dict, Path]:
    prm = dict(DEFAULTS)
    files = "files.txt"
    if name:
        members = {m["name"]: m for m in load_set()["members"]}
        if name not in members:
            raise SystemExit(f"no member {name} in set.json ({', '.join(members)})")
        m = members[name]
        prm.update({k: str(v) for k, v in m["params"].items()})
        files = m.get("files", files)
    prm.update(dict(kv.split("=", 1) for kv in params))
    if prm["UNITS"] == "1" and files == "files.txt":
        files = "files_l1.txt"
    return name or "", prm, HERE / files


def build(name: str, prm: dict, listfile: Path, a) -> int:
    tag = a.tag or name or "_".join(f"{k}{v}" for k, v in sorted(prm.items()))
    d = HERE / "build" / tag
    d.mkdir(parents=True, exist_ok=True)
    files, cfg = rtl_files(listfile)
    inc = " ".join(f"-I{x}" for x in cfg["incdir"])
    reads = " ".join(f"read_verilog {inc} {f};" for f in files)
    chp = "".join(f" chparam -set {k} {v} {TOP};" for k, v in prm.items())
    synth = d / "synth.json"
    if a.reuse_synth and synth.exists():
        out = (d / "yosys.log").read_text(encoding="utf-8")
    else:
        print(f"== {tag}: yosys {TOP} {prm} ({listfile.name}) -nowidelut", flush=True)
        rc, out = run(["yosys", "-p", f"{reads}{chp} synth_gowin -family gw2a -top {TOP} -nowidelut "
                       f"-json {synth.as_posix()}; stat"], d / "yosys.log")
        if rc:
            print(out[-3000:])
            return 1
    cells = synth_cells(out)
    lines = [f"design {TOP} {prm} ({listfile.name}) synth_gowin -family gw2a -nowidelut",
             "yosys: " + ", ".join(f"{k} {v}" for k, v in cells.items()) +
             f"  (LUT_eq = LUT + ALU + 8 * SSRAM = {cells['LUT_eq']}, {100 * cells['LUT_eq'] / 20736:.1f} % of 20736)"]
    print(f"{tag}: {lines[-1]}", flush=True)
    if a.no_pnr:
        (d / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        return 0
    best = None
    for seed in a.seeds.split(","):
        pnr = d / f"pnr{seed}.json"
        print(f"== {tag}: nextpnr seed {seed} ({a.freq} MHz)", flush=True)
        rc, out = run(["nextpnr-himbaechel", "--json", synth, "--write", pnr, "--device", DEVICE,
                       "--vopt", f"family={FAMILY}", "--vopt", f"cst={(HERE / 'top_multi.cst').as_posix()}",
                       "--freq", str(a.freq), "--seed", seed, "--timing-allow-fail"], d / f"nextpnr{seed}.log")
        if rc:
            err = re.findall(r"ERROR: .*", out)
            lines.append(f"seed {seed}: nextpnr failed: {err[-1] if err else rc}")
            print(f"{tag}: {lines[-1]}", flush=True)
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
        print(f"{tag}: " + "\n".join(lines[-2:]), flush=True)
        if ok:
            best = (seed, pnr)
            break
    if best is None:
        lines.append("no seed met timing")
        (d / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"{tag}: {lines[-1]}")
        return 1
    fs = d / "top_multi.fs"
    print(f"== {tag}: gowin_pack", flush=True)
    rc, out = run(["gowin_pack", "-c", "-d", FAMILY, "-o", fs, best[1]], d / "pack.log")
    if rc:
        print(out[-2000:])
        return 1
    lines.append(f"bitstream: {fs.relative_to(ROOT).as_posix()} (seed {best[0]})")
    (d / "summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{tag}: {lines[-1]}", flush=True)
    if a.program:
        if shutil.which("openFPGALoader") is None:
            print("openFPGALoader not found")
            return 1
        rc, out = run(["openFPGALoader", "-b", "tangnano20k", fs])
        print(out[-1500:])
        return rc
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--member", help="a member of set.json")
    ap.add_argument("--all", action="store_true", help="every member of set.json")
    ap.add_argument("--param", action="append", default=[], help=f"{TOP} parameter K=V (overrides)")
    ap.add_argument("--seeds", default="1", help="nextpnr placement seeds to try, comma separated")
    ap.add_argument("--freq", type=float, default=54.0)
    ap.add_argument("--core-mhz", type=float, default=27.0)
    ap.add_argument("--sdr-mhz", type=float, default=54.0)
    ap.add_argument("--tag", help="build sub-directory (default: the member name or the parameters)")
    ap.add_argument("--no-pnr", action="store_true")
    ap.add_argument("--reuse-synth", action="store_true")
    ap.add_argument("--program", action="store_true")
    a = ap.parse_args(argv)
    if a.all:
        rc = 0
        for m in load_set()["members"]:
            name, prm, lf = member_config(m["name"], a.param)
            rc |= build(name, prm, lf, a)
        return rc
    name, prm, lf = member_config(a.member, a.param)
    return build(name, prm, lf, a)


if __name__ == "__main__":
    sys.exit(main())

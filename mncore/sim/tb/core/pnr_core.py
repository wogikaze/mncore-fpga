#!/usr/bin/env python3
"""Place & route mn_core in WP07's 3-pin harness: resources and Fmax from nextpnr-himbaechel
(GW2AR-LV18QN88C8/I7). WP20.

    python mncore/sim/tb/core/pnr_core.py [--top mn_core] [--seeds 1] [--default-synth] [--param K=V ...]

The harness feeds every input from one shift register and XOR-reduces every output through
registers (mncore/fpga/recipes/recipes.py), so every path of the core is register to register.
It costs about (outputs / 3) LUT4 and (inputs + outputs * 4/3) FF on top of the core; the
core-only synthesis numbers are printed too. Synthesis uses -nowidelut (contract 06 section 6)
unless --default-synth. Logs: mncore/sim/tb/core/build/pnr/<top>/.
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
spec = importlib.util.spec_from_file_location("recipes", ROOT / "mncore/fpga/recipes/recipes.py")
recipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipes)   # also puts OSS CAD Suite on PATH
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", default="mn_core")
    ap.add_argument("--seeds", default="1")
    ap.add_argument("--default-synth", action="store_true")
    ap.add_argument("--param", action="append", default=[], help="top parameter K=V (e.g. FPALU=0)")
    a = ap.parse_args()
    files, cfg = simrun.parse_files("core")
    rtl = [f for f in files if not Path(f).name.startswith("tb_")]
    inc = " ".join(f"-I{d}" for d in cfg["incdir"])
    prm = dict(kv.split("=", 1) for kv in a.param)
    tag = a.top + "".join(f"_{k}{v}" for k, v in prm.items()) + ("_default" if a.default_synth else "")
    d = HERE / "build" / "pnr" / tag
    d.mkdir(parents=True, exist_ok=True)
    reads = " ".join(f"read_verilog {inc} {f};" for f in rtl)
    opt = "" if a.default_synth else " -nowidelut"
    chp = "".join(f" chparam -set {k} {v} {a.top};" for k, v in prm.items())
    rc, out = recipes.run(["yosys", "-q", "-p",
                           f"{reads}{chp} synth_gowin -family gw2a -top {a.top} -noiopads{opt}"
                           f" -json {(d / 'dut.json').as_posix()};"
                           f" tee -q -o {(d / 'dut.stat.json').as_posix()} stat -json"])
    if rc:
        sys.exit("dut synth failed:\n" + out[-2000:])
    dut = recipes.summarise(recipes.stat_cells(d / "dut.stat.json", a.top))
    print("core synth:", json.dumps(dut), flush=True)
    ports = recipes.ports_of(d / "dut.json", a.top)
    (d / "top.v").write_text(recipes.harness(a.top, prm, ports))
    (d / "top.cst").write_text(recipes.CST)
    rc, out = recipes.run(["yosys", "-q", "-p",
                           f"{reads} read_verilog {(d / 'top.v').as_posix()}; synth_gowin -family gw2a -top top{opt}"
                           f" -json {(d / 'top.json').as_posix()}"])
    if rc:
        sys.exit("harness synth failed:\n" + out[-2000:])
    for s in a.seeds.split(","):
        rc, out = recipes.run(["nextpnr-himbaechel", "--json", d / "top.json", "--write", d / f"pnr{s}.json",
                               "--device", recipes.DEVICE, "--vopt", f"family={recipes.FAMILY}",
                               "--vopt", f"cst={(d / 'top.cst').as_posix()}", "--freq", "50",
                               "--timing-allow-fail", "--seed", s], timeout=7200)
        (d / f"pnr{s}.log").write_text(out)
        if rc:
            print(f"seed {s}: nextpnr failed:", (re.findall(r"ERROR: .*", out) or [f"rc={rc}"])[-1])
            continue
        p = recipes.parse_pnr(out)
        util = {k: v for k, v in p["util"].items() if v[0]}
        print(f"seed {s}: fmax {p['fmax']} MHz, critical {p.get('crit', '')} ({p.get('crit_ns', '')} ns)")
        print("  util:", ", ".join(f"{k} {u}/{t}" for k, (u, t) in sorted(util.items())))
        (d / f"pnr{s}.json").unlink(missing_ok=True)
    ni = sum(w for n, dd, w in ports if dd == "input" and n != "clk")
    no = sum(w for n, dd, w in ports if dd == "output")
    print(f"harness: {ni} input bits (shift register), {no} output bits (XOR tree)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Place & route mn_pe_mem (or another rtl/pe module) in WP07's 3-pin harness and report
the resources and Fmax that nextpnr-himbaechel gives (GW2AR-LV18QN88C8/I7).

    python mncore/sim/tb/pemem/pnr_measure.py [--top mn_pe_mem] [--seeds 1,2,3]

The harness feeds every input from one shift register and XOR-reduces every output through
registers (mncore/fpga/recipes/recipes.py), so all paths of the module are register to
register. The harness itself costs about (outputs / 3) LUT4 and (inputs + outputs * 4/3) FF;
the DUT-only synthesis numbers are printed too.
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location("recipes", ROOT / "mncore/fpga/recipes/recipes.py")
recipes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipes)   # also puts OSS CAD Suite on PATH

FILES = ["mncore/fpga/recipes/mn_ram_lut.v", "mncore/fpga/recipes/mn_ram_1r1w.v",
         "mncore/rtl/pe/mn_pe_agen.v", "mncore/rtl/pe/mn_pe_treg.v", "mncore/rtl/pe/mn_pe_store.v",
         "mncore/rtl/pe/mn_pe_lsu.v", "mncore/rtl/pe/mn_pe_mem.v", "mncore/rtl/pe/mn_pe_rduse.v"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", default="mn_pe_mem")
    ap.add_argument("--seeds", default="1")
    a = ap.parse_args()
    d = ROOT / "mncore/sim/tb/pemem/build/pnr" / a.top
    d.mkdir(parents=True, exist_ok=True)
    reads = " ".join(f"read_verilog {f};" for f in FILES)
    rc, out = recipes.run(["yosys", "-q", "-p",
                           f"{reads} synth_gowin -family gw2a -top {a.top} -noiopads -json {(d / 'dut.json').as_posix()};"
                           f" tee -q -o {(d / 'dut.stat.json').as_posix()} stat -json"])
    if rc:
        sys.exit("dut synth failed:\n" + out[-2000:])
    dut = recipes.summarise(recipes.stat_cells(d / "dut.stat.json", a.top))
    print("dut synth:", json.dumps(dut))
    ports = recipes.ports_of(d / "dut.json", a.top)
    (d / "top.v").write_text(recipes.harness(a.top, {}, ports))
    (d / "top.cst").write_text(recipes.CST)
    rc, out = recipes.run(["yosys", "-q", "-p",
                           f"{reads} read_verilog {(d / 'top.v').as_posix()}; synth_gowin -family gw2a -top top"
                           f" -json {(d / 'top.json').as_posix()}"])
    if rc:
        sys.exit("harness synth failed:\n" + out[-2000:])
    for s in a.seeds.split(","):
        rc, out = recipes.run(["nextpnr-himbaechel", "--json", d / "top.json", "--write", d / f"pnr{s}.json",
                               "--device", recipes.DEVICE, "--vopt", f"family={recipes.FAMILY}",
                               "--vopt", f"cst={(d / 'top.cst').as_posix()}", "--freq", recipes.PNR_FREQ,
                               "--timing-allow-fail", "--seed", s], timeout=3600)
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

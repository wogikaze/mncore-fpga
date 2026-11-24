#!/usr/bin/env python3
"""Resources and Fmax of the fpalu modules (WP13), with the 3-pin harness of WP07.

  python mncore/sim/tb/fpalu/pnr_fpalu.py [--seeds 1,2,3] [--only mn_fp_alu] [--default-synth]

For each module: yosys synth_gowin of the module alone (cell counts), then the WP07 harness
(inputs from a shift register fed by one pin, outputs XOR-reduced to one pin) placed and routed
by nextpnr-himbaechel for the Tang Nano 20K part. Fmax is nextpnr's post-route value, median
(min) over the seeds. Results go to mncore/sim/tb/fpalu/build/pnr/<module>[_default]/ and are
printed. synth_gowin runs with -nowidelut (contract section 6) unless --default-synth.
"""
import argparse
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "fpga" / "recipes"))
import recipes  # noqa: E402  (WP07: harness, CST, run, parse_pnr, stat_cells, summarise)

RTL = ROOT / "mncore" / "rtl"
MODULES = {
    "mn_fp_alu": ["alu/mn_alu_rnd", "fpu/mn_fp_alu_lane", "fpu/mn_fp_alu"],
    "mn_fp_alu_bfn": ["alu/mn_alu_rnd", "fpu/mn_fp_alu_bflane", "fpu/mn_fp_alu_bfn"],
}


def measure(mod, seeds, opts):
    d = HERE / "build" / "pnr" / (mod + ("" if "-nowidelut" in opts else "_default"))
    d.mkdir(parents=True, exist_ok=True)
    reads = " ".join(f"read_verilog {(RTL / (f + '.v')).as_posix()};" for f in MODULES[mod])
    script = (f"{reads} synth_gowin -family gw2a {opts} -top {mod} -noiopads -json {(d / 'dut.json').as_posix()};"
              f" tee -q -o {(d / 'dut.stat.json').as_posix()} stat -json")
    rc, out = recipes.run(["yosys", "-q", "-p", script])
    (d / "dut.yosys.log").write_text(out)
    if rc:
        return dict(mod=mod, error="dut synth failed: " + out[-500:])
    cells = recipes.stat_cells(d / "dut.stat.json", mod)
    dut = recipes.summarise(cells)
    ports = recipes.ports_of(d / "dut.json", mod)
    if not any(n == "clk" for n, _, _ in ports):
        return dict(mod=mod, dut=dut, fmax=[], note="combinational")
    (d / "top.v").write_text(recipes.harness(mod, {}, ports).replace(f"{mod} #() u", f"{mod} u"))
    (d / "top.cst").write_text(recipes.CST)
    script = (f"{reads} read_verilog {(d / 'top.v').as_posix()}; synth_gowin -family gw2a {opts} -top top"
              f" -json {(d / 'top.json').as_posix()}")
    rc, out = recipes.run(["yosys", "-q", "-p", script])
    if rc:
        return dict(mod=mod, dut=dut, error="harness synth failed: " + out[-500:])
    fmax, crit, util = [], "", {}
    for s in seeds:
        rc, out = recipes.run(["nextpnr-himbaechel", "--json", d / "top.json", "--write", d / f"pnr{s}.json",
                               "--device", recipes.DEVICE, "--vopt", f"family={recipes.FAMILY}",
                               "--vopt", f"cst={(d / 'top.cst').as_posix()}", "--freq", recipes.PNR_FREQ,
                               "--timing-allow-fail", "--seed", s])
        (d / f"pnr{s}.log").write_text(out)
        if rc:
            return dict(mod=mod, dut=dut, error=f"nextpnr seed {s} failed")
        p = recipes.parse_pnr(out)
        fmax.append(p["fmax"])
        if not crit:
            crit = f"{p.get('crit', '')} ({p.get('crit_ns', '')} ns)"
            util = p["util"]
        (d / f"pnr{s}.json").unlink(missing_ok=True)
    return dict(mod=mod, dut=dut, fmax=fmax, crit=crit, util=util)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--only")
    ap.add_argument("--default-synth", action="store_true", help="synth_gowin without -nowidelut")
    a = ap.parse_args()
    seeds = [int(s) for s in a.seeds.split(",")]
    opts = "" if a.default_synth else "-nowidelut"
    for mod in MODULES:
        if a.only and a.only != mod:
            continue
        r = measure(mod, seeds, opts)
        if "error" in r:
            print(f"{mod}: ERROR {r['error']}")
            continue
        u = r["dut"]
        line = (f"{mod} (synth_gowin {opts or 'default'}): LUT {u['lut']}, ALU {u['alu']}, FF {u['ff']}, MUX2 {u['mux']}, "
                f"DSP18 {u['dsp18']}, BSRAM {u['bsram']}, SSRAM {u['ssram']}")
        if r.get("fmax"):
            fm = r["fmax"]
            line += f"; Fmax {statistics.median(fm):.1f} ({min(fm):.1f}) MHz over seeds {a.seeds}"
            line += f"\n    critical path (seed {seeds[0]}): {r['crit']}"
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""WP11: resources and Fmax of mn_alu_int (yosys synth_gowin + nextpnr-himbaechel).

  python mncore/sim/tb/alu/measure_alu.py [--seeds 1,2,3] [-j N]

Uses the WP07 method (mncore/fpga/recipes/recipes.py): the module alone is synthesised for the
resource columns, then wrapped in the 3-pin harness (inputs from a shift register, outputs
registered and XOR-reduced) and placed and routed for GW2AR-LV18QN88C8/I7. Fmax is nextpnr's
post-route value, median (min) over the seeds. Variants: the pipeline registers
(rIPM = IREG, PREG, MREG), and synth_gowin with and without -nowidelut. Build products: mncore/sim/tb/alu/build/measure/ (git-ignored).
"""
import argparse
import concurrent.futures as cf
import importlib.util
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
_spec = importlib.util.spec_from_file_location("recipes", ROOT / "mncore" / "fpga" / "recipes" / "recipes.py")
rc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rc)

MOD = "mn_alu_int"
FILES = [ROOT / "mncore" / "rtl" / "alu" / f
         for f in ("mn_alu_cls.v", "mn_alu_rnd.v", "mn_alu_rot_stage.v", "mn_alu_int.v")]
BUILD = HERE / "build" / "measure"
VARIANTS = [
    ("r111", {"IREG": 1, "PREG": 1, "MREG": 1}, ""),
    ("r101", {"IREG": 1, "PREG": 0, "MREG": 1}, ""),
    ("r100", {"IREG": 1, "PREG": 0, "MREG": 0}, ""),
    ("r000", {"IREG": 0, "PREG": 0, "MREG": 0}, ""),
    ("r111_nowidelut", {"IREG": 1, "PREG": 1, "MREG": 1}, "-nowidelut"),
    ("r100_nowidelut", {"IREG": 1, "PREG": 0, "MREG": 0}, "-nowidelut"),
]


def measure(name, prm, opt, seeds):
    d = BUILD / name
    d.mkdir(parents=True, exist_ok=True)
    reads = " ".join(f"read_verilog {f.as_posix()};" for f in FILES)
    chparam = "chparam " + " ".join(f"-set {k} {v}" for k, v in prm.items()) + f" {MOD};"
    # mn_alu_rot_stage is kept as a submodule; flatten the mapped netlist so that stat counts it
    script = (f"{reads} {chparam} synth_gowin -family gw2a {opt} -top {MOD} -noiopads -json {(d / 'dut.json').as_posix()};"
              f" setattr -mod -unset keep_hierarchy *; flatten;"
              f" tee -q -o {(d / 'dut.stat.json').as_posix()} stat -json")
    code, out = rc.run(["yosys", "-q", "-p", script])
    (d / "dut.yosys.log").write_text(out)
    if code:
        return dict(name=name, error="dut synth failed")
    dut = rc.summarise(rc.stat_cells(d / "dut.stat.json", MOD))
    (d / "top.v").write_text(rc.harness(MOD, prm, rc.ports_of(d / "dut.json", MOD)))
    (d / "top.cst").write_text(rc.CST)
    script = (f"{reads} read_verilog {(d / 'top.v').as_posix()}; synth_gowin -family gw2a {opt} -top top"
              f" -json {(d / 'top.json').as_posix()}")
    code, out = rc.run(["yosys", "-q", "-p", script])
    (d / "top.yosys.log").write_text(out)
    if code:
        return dict(name=name, dut=dut, error="harness synth failed")
    fmax, crit, util = [], "", {}
    for s in seeds:
        code, out = rc.run(["nextpnr-himbaechel", "--json", d / "top.json", "--write", d / f"pnr{s}.json",
                            "--device", rc.DEVICE, "--vopt", f"family={rc.FAMILY}",
                            "--vopt", f"cst={(d / 'top.cst').as_posix()}",
                            "--freq", str(rc.PNR_FREQ), "--timing-allow-fail", "--seed", str(s)])
        (d / f"pnr{s}.log").write_text(out)
        if code:
            continue
        p = rc.parse_pnr(out)
        fmax.append(p["fmax"])
        if not crit:
            crit, util = f"{p.get('crit', '')} ({p.get('crit_ns', '')} ns)", p["util"]
        (d / f"pnr{s}.json").unlink(missing_ok=True)
    return dict(name=name, dut=dut, fmax=fmax, crit=crit, util=util)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("-j", "--jobs", type=int, default=4)
    a = ap.parse_args()
    seeds = [int(s) for s in a.seeds.split(",")]
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        res = list(ex.map(lambda v: measure(v[0], v[1], v[2], seeds), VARIANTS))
    lines = [f"| variant | LUT | ALU | MUX2 | FF | pnr LUT4 | Fmax MHz median (min), seeds {a.seeds} | critical path |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    for r in res:
        dut, fm = r.get("dut", {}), [x for x in (r.get("fmax") or []) if x]
        f = f"{statistics.median(fm):.1f} ({min(fm):.1f})" if fm else r.get("error", "-")
        lut4 = r.get("util", {}).get("LUT4", ("", ""))[0]
        lines.append(f"| {r['name']} | {dut.get('lut', '')} | {dut.get('alu', '')} | {dut.get('mux', '')} | "
                     f"{dut.get('ff', '')} | {lut4} | {f} | {r.get('crit', '')} |")
    text = "\n".join(lines) + "\n"
    print(text)
    (BUILD / "measure.md").write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()

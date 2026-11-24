"""Place-and-route Fmax of the WP12 modules (the 3-pin harness of WP07's recipes.py).

    python mncore/sim/tb/fpu_tools/fmax.py [--seeds 1,2,3] [--freq 150] [unit ...]
                                           (default units: fpu_fp fpu_mau)

The DUT (rtl_top of mncore/sim/tb/<unit>/files.txt) is wrapped in recipes.harness(): inputs
from a shift register fed by one pin, outputs registered and XOR-reduced to one pin, so every
DUT port is a register-to-register path. nextpnr-himbaechel does not time paths through DSP
cells (mncore/07-device-budget.md 3.1); the DSP tiles of mn_fp_mul53 have registers on both
sides, so the reported Fmax covers the fabric logic only.
Build products: mncore/sim/tb/<unit>/build/pnr/.
"""

import argparse
import concurrent.futures as cf
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "mncore" / "fpga" / "recipes"))
import recipes  # noqa: E402  (WP07: harness, CST, parse_pnr, DEVICE, FAMILY, run)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from synth_stat import files_of  # noqa: E402


def measure(unit, seeds, freq):
    rtl, top = files_of(unit)
    d = ROOT / "mncore" / "sim" / "tb" / unit / "build" / "pnr"
    d.mkdir(parents=True, exist_ok=True)
    reads = " ".join(f"read_verilog {f};" for f in rtl)
    rc, out = recipes.run(["yosys", "-q", "-p",
                           f"{reads} synth_gowin -family gw2a -noiopads -top {top} -json {(d / 'dut.json').as_posix()}"])
    if rc:
        sys.exit(f"{unit}: DUT synthesis failed\n{out[-2000:]}")
    (d / "top.v").write_text(recipes.harness(top, {"TAGW": 1}, recipes.ports_of(d / "dut.json", top)))
    (d / "top.cst").write_text(recipes.CST)
    rc, out = recipes.run(["yosys", "-q", "-p",
                           f"{reads} read_verilog {(d / 'top.v').as_posix()}; synth_gowin -family gw2a -top top"
                           f" -json {(d / 'top.json').as_posix()}"])
    if rc:
        sys.exit(f"{unit}: harness synthesis failed\n{out[-2000:]}")

    def pnr(s):
        rc, out = recipes.run(["nextpnr-himbaechel", "--json", d / "top.json", "--write", d / f"pnr{s}.json",
                               "--device", recipes.DEVICE, "--vopt", f"family={recipes.FAMILY}",
                               "--vopt", f"cst={(d / 'top.cst').as_posix()}",
                               "--freq", freq, "--timing-allow-fail", "--seed", s], timeout=7200)
        (d / f"pnr{s}.log").write_text(out)
        (d / f"pnr{s}.json").unlink(missing_ok=True)
        return s, rc, recipes.parse_pnr(out)

    with cf.ThreadPoolExecutor(len(seeds)) as ex:
        res = list(ex.map(pnr, seeds))
    fm = [p["fmax"] for _, rc, p in res if rc == 0 and p["fmax"]]
    for s, rc, p in res:
        print(f"{unit} seed {s}: rc={rc} fmax={p.get('fmax')} MHz  crit {p.get('crit', '')} ({p.get('crit_ns', '')} ns)")
    if fm:
        print(f"{unit}: Fmax median {statistics.median(fm):.1f} MHz, min {min(fm):.1f} MHz (fabric only)")
        util = res[0][2]["util"]
        print("  util: " + ", ".join(f"{k} {a}/{b}" for k, (a, b) in util.items()))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--freq", default="150")
    ap.add_argument("units", nargs="*", default=["fpu_fp", "fpu_mau"])
    a = ap.parse_args()
    for u in a.units:
        measure(u, [int(s) for s in a.seeds.split(",")], a.freq)

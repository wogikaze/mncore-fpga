#!/usr/bin/env python3
"""Build the SDRAM test bitstream (yosys -> nextpnr-himbaechel -> gowin_pack).

    python mncore/fpga/sdram_test/build.py                 # 108 MHz, CL3, phase sweep
    python mncore/fpga/sdram_test/build.py --freq 54       # 54 MHz, CL2
    python mncore/fpga/sdram_test/build.py --freq 108 --static-phase 8 --rdx 1   # no sweep

Output: mncore/fpga/sdram_test/build/<name>/sdram_test.fs (and the logs, pnr report).
Program and read the report with run_test.py.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

if shutil.which("yosys") is None:
    _oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
    os.environ["PATH"] = os.pathsep.join([str(_oss / "bin"), str(_oss / "lib"), os.environ.get("PATH", "")])

# 27 MHz input: f = 27 * (FBDIV_SEL + 1) / (IDIV_SEL + 1), VCO = f * ODIV_SEL in 500..1250 MHz
PLL = {
    54: dict(IDIV_SEL=0, FBDIV_SEL=1, ODIV_SEL=16, CL=2),
    81: dict(IDIV_SEL=0, FBDIV_SEL=2, ODIV_SEL=8, CL=2),
    99: dict(IDIV_SEL=2, FBDIV_SEL=10, ODIV_SEL=8, CL=2),
    108: dict(IDIV_SEL=0, FBDIV_SEL=3, ODIV_SEL=8, CL=3),
    135: dict(IDIV_SEL=0, FBDIV_SEL=4, ODIV_SEL=4, CL=3),
    162: dict(IDIV_SEL=0, FBDIV_SEL=5, ODIV_SEL=4, CL=3),
}

SOURCES = [
    "mncore/rtl/sdram/sdr_tmr.v",
    "mncore/rtl/sdram/sdr_ctrl.v",
    "mncore/rtl/sdram/sdr_fifo.v",
    "mncore/rtl/sdram/sdr_afifo.v",
    "mncore/rtl/sdram/sdr_bus64.v",
    "mncore/rtl/sdram/sdr_gw_pll.v",
    "mncore/rtl/sdram/sdr_gw_clkout.v",
    "mncore/fpga/sdram_test/sdr_test_uart_tx.v",
    "mncore/fpga/sdram_test/sdr_test_print.v",
    "mncore/fpga/sdram_test/sdr_test_ctl.v",
    "mncore/fpga/sdram_test/sdram_test_top.v",
]


def run(cmd, log):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    t0 = time.time()
    with open(log, "w", encoding="utf-8") as f:
        r = subprocess.run(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, text=True)
    print(f"  ({time.time() - t0:.1f} s, log {log.relative_to(ROOT)})")
    if r.returncode:
        sys.stdout.write("".join(open(log, encoding="utf-8", errors="replace").readlines()[-30:]))
        sys.exit(f"FAILED: {cmd[0]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--freq", type=int, default=108, choices=sorted(PLL))
    ap.add_argument("--cl", type=int, help="override the CAS latency")
    ap.add_argument("--static-phase", type=int, help="fixed SDRAM clock phase 0..15 (no phase sweep)")
    ap.add_argument("--rdx", type=int, default=1, help="read capture delay when not sweeping")
    ap.add_argument("--no-sweep", action="store_true", help="skip the sweep (needs --static-phase)")
    ap.add_argument("--aw", type=int, default=20, help="full test size: 2**aw long words")
    ap.add_argument("--qaw", type=int, default=14, help="sweep test size: 2**qaw long words")
    ap.add_argument("--baud", type=int, default=1000000,
                    help="report UART speed (the BL616 bridge did not deliver 115200 correctly)")
    ap.add_argument("--iob", choices=["none", "in", "all"], default="none",
                    help="pack registers into IOBs: none, input registers only, or input and output "
                         "(output-register packing garbled the UART output on the board, 2026-11-24)")
    ap.add_argument("--seed", type=int, default=1, help="nextpnr seed")
    ap.add_argument("--name", help="build directory name")
    a = ap.parse_args()

    p = dict(PLL[a.freq])
    cl = a.cl or p.pop("CL")
    p.pop("CL", None)
    dyn = a.static_phase is None
    params = dict(p, FREQ_HZ=a.freq * 1000000, CL=cl, DYN_PHASE=int(dyn),
                  PSDA=8 if dyn else a.static_phase, SWEEP=int(not a.no_sweep), FIX_K=a.rdx,
                  AW=a.aw, QAW=a.qaw, BAUD=a.baud)
    name = a.name or (f"f{a.freq}_cl{cl}" + ("_dyn" if dyn else f"_ph{a.static_phase}")
                      + ("_nosweep" if a.no_sweep else "") + f"_iob{a.iob}")
    out = HERE / "build" / name
    out.mkdir(parents=True, exist_ok=True)
    rel = out.relative_to(ROOT).as_posix()

    chparam = " ".join(f"-set {k} {v}" for k, v in params.items())
    script = "; ".join([*(f"read_verilog {s}" for s in SOURCES),
                        f"chparam {chparam} sdram_test_top",
                        f"synth_gowin -family gw2a -top sdram_test_top -json {rel}/synth.json",
                        "stat"])
    run(["yosys", "-p", script], out / "yosys.log")
    iob = {"none": [], "in": ["--vopt", "ireg_in_iob"],
           "all": ["--vopt", "ireg_in_iob", "--vopt", "oreg_in_iob", "--vopt", "ioreg_in_iob"]}[a.iob]
    run(["nextpnr-himbaechel", "--json", f"{rel}/synth.json", "--write", f"{rel}/pnr.json",
         "--device", "GW2AR-LV18QN88C8/I7", "--vopt", "family=GW2A-18C",
         "--vopt", "cst=mncore/fpga/sdram_test/sdram_test.cst", *iob,
         "--freq", str(a.freq), "--seed", str(a.seed), "--report", f"{rel}/report.json"],
        out / "nextpnr.log")
    run(["gowin_pack", "-c", "-d", "GW2A-18C", "-o", f"{rel}/sdram_test.fs", f"{rel}/pnr.json"],
        out / "pack.log")

    log = (out / "nextpnr.log").read_text(encoding="utf-8", errors="replace").splitlines()
    for line in log:
        if "Max frequency" in line or "IOLOGIC" in line or "  LUT4:" in line or "  DFF:" in line \
                or "BSRAM:" in line or "RAM16SDP4:" in line:
            print(line)
    print(f"OK {rel}/sdram_test.fs  params: {params}")


if __name__ == "__main__":
    main()

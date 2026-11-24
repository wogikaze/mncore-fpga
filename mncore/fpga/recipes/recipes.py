#!/usr/bin/env python3
"""WP07 recipe runner (inference recipes for GW2AR-18 / Tang Nano 20K).

  python mncore/fpga/recipes/recipes.py check            sim + lint + synth of every recipe
  python mncore/fpga/recipes/recipes.py measure [-j N] [--seeds 1,2,3] [--only SUBSTR]
                                                         synth + place & route of the experiments,
                                                         writes results/measure.csv and results/measure.md

check  = the three acceptance steps of contract section 6 (iverilog -g2012 -Wall + self-checking
         testbench, verilator_bin --lint-only -Wall, yosys synth_gowin -family gw2a).
measure: every experiment synthesises the DUT alone (resource columns), then wraps it in a
         3-pin harness (inputs from a shift register fed by one pin, outputs registered and
         XOR-reduced through a registered tree to one pin) and runs nextpnr-himbaechel for the
         Tang Nano 20K part. Fmax is nextpnr's post-route "Max frequency" for the clock.
Build products go to mncore/fpga/recipes/build/ (git-ignored).
"""
import argparse
import concurrent.futures as cf
import csv
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BUILD = HERE / "build"
RESULTS = HERE / "results"

DEVICE = "GW2AR-LV18QN88C8/I7"
FAMILY = "GW2A-18C"
PNR_FREQ = 250  # MHz target for the timing-driven placer (same for all experiments)

# Shells started before OSS CAD Suite was added to PATH do not see it; add it here.
if shutil.which("yosys") is None:
    _oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
    os.environ["PATH"] = os.pathsep.join([str(_oss / "bin"), str(_oss / "lib"), os.environ.get("PATH", "")])
if "VERILATOR_ROOT" not in os.environ and shutil.which("verilator_bin"):
    _vr = Path(shutil.which("verilator_bin")).resolve().parents[1] / "share" / "verilator"
    if _vr.exists():
        os.environ["VERILATOR_ROOT"] = str(_vr)


def rel(p):
    return Path(p).resolve().relative_to(ROOT).as_posix()


R = {  # recipe files
    "mn_ram_1r1w": HERE / "mn_ram_1r1w.v",
    "mn_ram_1r1w_be": HERE / "mn_ram_1r1w_be.v",
    "mn_ram_2r1w": HERE / "mn_ram_2r1w.v",
    "mn_ram_tdp": HERE / "mn_ram_tdp.v",
    "mn_ram_lut": HERE / "mn_ram_lut.v",
    "mn_mul_pipe": HERE / "mn_mul_pipe.v",
    # experiment-only modules (not recipes)
    "mn_xp_ram_rwchk": HERE / "exp" / "mn_xp_ram_rwchk.v",
    "mn_xp_mul_infer": HERE / "exp" / "mn_xp_mul_infer.v",
    "mn_xp_mul_dspreg": HERE / "exp" / "mn_xp_mul_dspreg.v",
    "mn_xp_mul_array": HERE / "exp" / "mn_xp_mul_array.v",
    "mn_xp_regfile_ff": HERE / "exp" / "mn_xp_regfile_ff.v",
}
DEPS = {"mn_ram_2r1w": ["mn_ram_1r1w"]}


def files_for(mod):
    return [R[d] for d in DEPS.get(mod, [])] + [R[mod]]


def run(cmd, cwd=ROOT, timeout=1800):
    r = subprocess.run([str(c) for c in cmd], cwd=cwd, text=True, capture_output=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


# --------------------------------------------------------------------------------------------
# check
# --------------------------------------------------------------------------------------------
SIM_CASES = [
    ("tb_mn_ram_1r1w", "mn_ram_1r1w", dict(W=64, AW=8, NWE=1, OREG=0)),
    ("tb_mn_ram_1r1w", "mn_ram_1r1w", dict(W=64, AW=8, NWE=2, OREG=0)),
    ("tb_mn_ram_1r1w", "mn_ram_1r1w", dict(W=64, AW=9, NWE=2, OREG=1)),
    ("tb_mn_ram_1r1w", "mn_ram_1r1w", dict(W=128, AW=7, NWE=4, OREG=1)),
    ("tb_mn_ram_1r1w", "mn_ram_1r1w", dict(W=36, AW=4, NWE=1, OREG=0)),
    ("tb_mn_ram_1r1w", "mn_ram_1r1w_be", dict(W=64, AW=8, BE=1)),
    ("tb_mn_ram_2r1w", "mn_ram_2r1w", dict(W=64, AW=8, NWE=2, OREG=0)),
    ("tb_mn_ram_2r1w", "mn_ram_2r1w", dict(W=64, AW=6, NWE=1, OREG=1)),
    ("tb_mn_ram_tdp", "mn_ram_tdp", dict(W=64, AW=8)),
    ("tb_mn_ram_tdp", "mn_ram_tdp", dict(W=18, AW=5)),
    ("tb_mn_ram_lut", "mn_ram_lut", dict(W=64, AW=3, NR=2)),
    ("tb_mn_ram_lut", "mn_ram_lut", dict(W=16, AW=5, NR=1)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=18, WB=18, IREG=0, PREG=0, LVLS=0)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=24, WB=24, IREG=1, PREG=1, LVLS=1)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=27, WB=18, IREG=1, PREG=0, LVLS=0)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=53, WB=53, IREG=1, PREG=1, LVLS=1)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=53, WB=53, IREG=1, PREG=1, LVLS=2)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=53, WB=53, IREG=0, PREG=0, LVLS=0)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=11, WB=11, IREG=1, PREG=1, LVLS=1)),
    ("tb_mn_mul_pipe", "mn_mul_pipe", dict(WA=53, WB=53, TW=17, IREG=1, PREG=1, LVLS=1)),
]

LINT_CASES = [
    ("mn_ram_1r1w", dict(W=64, AW=8, NWE=2, OREG=1)),
    ("mn_ram_1r1w", dict(W=64, AW=11, NWE=1, OREG=0)),
    ("mn_ram_1r1w_be", dict(W=64, AW=8)),
    ("mn_ram_2r1w", dict(W=64, AW=8, NWE=2, OREG=0)),
    ("mn_ram_tdp", dict(W=64, AW=8)),
    ("mn_ram_lut", dict(W=64, AW=3, NR=2)),
    ("mn_mul_pipe", dict(WA=53, WB=53, IREG=1, PREG=1, LVLS=1)),
    ("mn_mul_pipe", dict(WA=18, WB=18, IREG=0, PREG=0, LVLS=0)),
    ("mn_mul_pipe", dict(WA=24, WB=24, IREG=1, PREG=0, LVLS=2)),
]

SYNTH_CASES = ["mn_ram_1r1w", "mn_ram_1r1w_be", "mn_ram_2r1w", "mn_ram_tdp", "mn_ram_lut", "mn_mul_pipe"]


def cmd_check(_args):
    BUILD.mkdir(exist_ok=True)
    ok_all = True
    print("== sim (iverilog -g2012 -Wall) ==")
    for i, (tb, mod, prm) in enumerate(SIM_CASES):
        vvp = BUILD / f"sim_{i}.vvp"
        cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", vvp, "-s", tb]
        cmd += [f"-P{tb}.{k}={v}" for k, v in prm.items()]
        cmd += [rel(f) for f in files_for(mod)] + [rel(HERE / "tb" / f"{tb}.v")]
        rc, out = run(cmd)
        if rc:
            print(out)
            print(f"FAIL compile {tb} {prm}")
            ok_all = False
            continue
        if out.strip():
            print(out.strip())
        rc, out = run(["vvp", "-n", vvp])
        verdict = [l for l in out.splitlines() if l.startswith(("PASS", "FAIL"))]
        good = rc == 0 and verdict and verdict[-1].startswith("PASS")
        ok_all &= bool(good)
        print(verdict[-1] if verdict else f"FAIL no verdict {tb} {prm}\n{out[-2000:]}")

    print("== lint (verilator_bin --lint-only -Wall) ==")
    verilator = shutil.which("verilator_bin") or shutil.which("verilator")
    for mod, prm in LINT_CASES:
        cmd = [verilator, "--lint-only", "-Wall", "--top-module", mod]
        cmd += [f"-G{k}={v}" for k, v in prm.items()]
        cmd += [rel(f) for f in files_for(mod)]
        rc, out = run(cmd)
        good = rc == 0
        ok_all &= good
        print(f"{'PASS' if good else 'FAIL'} lint {mod} {prm}")
        msgs = [l for l in out.splitlines() if l.startswith(("%Warning", "%Error"))]
        if not good or msgs:
            print("\n".join(msgs) or out.strip()[-3000:])

    print("== synth (yosys synth_gowin -family gw2a) ==")
    for mod in SYNTH_CASES:
        reads = " ".join(f"read_verilog {rel(f)};" for f in files_for(mod))
        out_json = BUILD / f"synth_{mod}.stat.json"
        script = f"{reads} synth_gowin -family gw2a -top {mod} -noiopads; tee -q -o {out_json.as_posix()} stat -json"
        rc, out = run(["yosys", "-q", "-p", script])
        good = rc == 0
        ok_all &= good
        cells = stat_cells(out_json, mod) if good else {}
        print(f"{'PASS' if good else 'FAIL'} synth {mod} (default parameters): {summarise(cells)}")
        if not good:
            print(out[-3000:])

    print("PASS" if ok_all else "FAIL")
    return 0 if ok_all else 1


# --------------------------------------------------------------------------------------------
# measure
# --------------------------------------------------------------------------------------------
def E(group, name, mod, note="", **prm):
    return dict(group=group, name=name, mod=mod, prm=prm, note=note)


EXPERIMENTS = [
    # --- BSRAM, 1R1W, 64-bit, depth sweep (inferred, no_rw_check) ---
    E("ram1r1w", "sdp64x256", "mn_ram_1r1w", W=64, AW=8),
    E("ram1r1w", "sdp64x512", "mn_ram_1r1w", W=64, AW=9),
    E("ram1r1w", "sdp64x1024", "mn_ram_1r1w", W=64, AW=10),
    E("ram1r1w", "sdp64x2048", "mn_ram_1r1w", W=64, AW=11),
    E("ram1r1w", "sdp64x4096", "mn_ram_1r1w", W=64, AW=12),
    E("ram1r1w", "sdp64x256_oreg", "mn_ram_1r1w", "fabric output register", W=64, AW=8, OREG=1),
    E("ram1r1w", "sdp64x2048_oreg", "mn_ram_1r1w", "fabric output register", W=64, AW=11, OREG=1),
    # write lanes
    E("ram1r1w", "sdp64x256_we2", "mn_ram_1r1w", "2 lanes x 32 bit", W=64, AW=8, NWE=2),
    E("ram1r1w", "sdp64x2048_we2", "mn_ram_1r1w", "2 lanes x 32 bit", W=64, AW=11, NWE=2),
    E("ram1r1w", "sdp64x256_we4", "mn_ram_1r1w", "4 lanes x 16 bit", W=64, AW=8, NWE=4),
    E("ram1r1w", "sdp64x1024_we4", "mn_ram_1r1w", "4 lanes x 16 bit", W=64, AW=10, NWE=4),
    E("ram1r1w", "sdp64x256_we8", "mn_ram_1r1w", "8 lanes x 8 bit (split)", W=64, AW=8, NWE=8),
    E("ram1r1w", "sdp64x256_be8", "mn_ram_1r1w_be", "native byte enables", W=64, AW=8),
    E("ram1r1w", "sdp64x512_be8", "mn_ram_1r1w_be", "native byte enables", W=64, AW=9),
    E("ram1r1w", "sdp64x2048_be8", "mn_ram_1r1w_be", "native byte enables", W=64, AW=11),
    # read/write collision handling cost (no no_rw_check)
    E("ram1r1w", "sdp64x256_rwchk", "mn_xp_ram_rwchk", "plain coding, no no_rw_check", W=64, AW=8),
    E("ram1r1w", "sdp64x2048_rwchk", "mn_xp_ram_rwchk", "plain coding, no no_rw_check", W=64, AW=11),
    # 128-bit organisation (one MN-Core cycle per clock, 2-long-word access)
    E("ram1r1w", "sdp128x128_we4", "mn_ram_1r1w", "GRF 256 long words as 128 bit x 128", W=128, AW=7, NWE=4),
    E("ram1r1w", "sdp128x512_we4", "mn_ram_1r1w", "LM 1024 long words as 128 bit x 512", W=128, AW=9, NWE=4),
    E("ram1r1w", "sdp128x1024_we4", "mn_ram_1r1w", "LM 2048 long words as 128 bit x 1024", W=128, AW=10, NWE=4),
    # instruction memory
    E("ram1r1w", "imem426x512", "mn_ram_1r1w", "j word, 512 words", W=426, AW=9),
    E("ram1r1w", "imem426x256", "mn_ram_1r1w", "j word, 256 words", W=426, AW=8),
    E("ram1r1w", "imem213x512", "mn_ram_1r1w", "half j word x 512 rows = 256 words in 2 reads", W=213, AW=9),
    # --- 2R1W and true dual port ---
    E("ram2r", "2r1w64x256", "mn_ram_2r1w", W=64, AW=8),
    E("ram2r", "2r1w64x512", "mn_ram_2r1w", W=64, AW=9),
    E("ram2r", "2r1w64x2048", "mn_ram_2r1w", W=64, AW=11),
    E("ram2r", "tdp64x256", "mn_ram_tdp", W=64, AW=8),
    E("ram2r", "tdp64x512", "mn_ram_tdp", W=64, AW=9),
    E("ram2r", "tdp64x1024", "mn_ram_tdp", W=64, AW=10),
    E("ram2r", "tdp64x2048", "mn_ram_tdp", W=64, AW=11),
    # --- LUT RAM (SSRAM) ---
    E("lutram", "lut64x8_r1", "mn_ram_lut", "T register size", W=64, AW=3, NR=1),
    E("lutram", "lut64x8_r2", "mn_ram_lut", W=64, AW=3, NR=2),
    E("lutram", "lut64x16_r1", "mn_ram_lut", W=64, AW=4, NR=1),
    E("lutram", "lut64x32_r1", "mn_ram_lut", W=64, AW=5, NR=1),
    E("lutram", "lut64x64_r1", "mn_ram_lut", W=64, AW=6, NR=1),
    E("lutram", "ff64x8_r1", "mn_xp_regfile_ff", "T register in FFs", W=64, AW=3, NR=1),
    E("lutram", "ff64x8_r2", "mn_xp_regfile_ff", "T register in FFs", W=64, AW=3, NR=2),
    # --- multipliers: plain inference ---
    E("mulinf", "inf18x18", "mn_xp_mul_infer", "a*b, in+out regs", WA=18, WB=18),
    E("mulinf", "inf18x18s", "mn_xp_mul_infer", "signed", WA=18, WB=18, SGN=1),
    E("mulinf", "inf11x11", "mn_xp_mul_infer", "half mantissa", WA=11, WB=11),
    E("mulinf", "inf24x24", "mn_xp_mul_infer", "single mantissa", WA=24, WB=24),
    E("mulinf", "inf27x18", "mn_xp_mul_infer", WA=27, WB=18),
    E("mulinf", "inf36x36", "mn_xp_mul_infer", WA=36, WB=36),
    E("mulinf", "inf53x53", "mn_xp_mul_infer", "double mantissa", WA=53, WB=53),
    E("mulinf", "inf53x53_o3", "mn_xp_mul_infer", "3 output regs (no retiming)", WA=53, WB=53, NOUT=3),
    E("mulinf", "dspreg18x18", "mn_xp_mul_dspreg", "MULT18X18 instance, AREG/BREG/OUT_REG", AREG=1, BREG=1, PREG=0, OREG=1),
    E("mulinf", "dspreg18x18_p", "mn_xp_mul_dspreg", "MULT18X18 instance, +PIPE_REG", AREG=1, BREG=1, PREG=1, OREG=1),
    # --- multipliers: tiled recipe, pipeline sweep ---
    E("multile", "t18x18_i0p0", "mn_mul_pipe", WA=18, WB=18, IREG=0, PREG=0, LVLS=0),
    E("multile", "t18x18_i1p0", "mn_mul_pipe", WA=18, WB=18, IREG=1, PREG=0, LVLS=0),
    E("multile", "t18x18_i1p1", "mn_mul_pipe", WA=18, WB=18, IREG=1, PREG=1, LVLS=0),
    E("multile", "t11x11_i1p1", "mn_mul_pipe", WA=11, WB=11, IREG=1, PREG=1, LVLS=0),
    E("multile", "t24x24_i1p0l0", "mn_mul_pipe", WA=24, WB=24, IREG=1, PREG=0, LVLS=0),
    E("multile", "t24x24_i1p1l0", "mn_mul_pipe", WA=24, WB=24, IREG=1, PREG=1, LVLS=0),
    E("multile", "t24x24_i1p1l1", "mn_mul_pipe", WA=24, WB=24, IREG=1, PREG=1, LVLS=1),
    E("multile", "t27x18_i1p1l0", "mn_mul_pipe", WA=27, WB=18, IREG=1, PREG=1, LVLS=0),
    E("multile", "t36x36_i1p1l1", "mn_mul_pipe", WA=36, WB=36, IREG=1, PREG=1, LVLS=1),
    E("multile", "t53x53_i1p0l0", "mn_mul_pipe", WA=53, WB=53, IREG=1, PREG=0, LVLS=0),
    E("multile", "t53x53_i1p1l0", "mn_mul_pipe", WA=53, WB=53, IREG=1, PREG=1, LVLS=0),
    E("multile", "t53x53_i1p1l2", "mn_mul_pipe", WA=53, WB=53, IREG=1, PREG=1, LVLS=2),
    E("multile", "t53x53_i1p1l1", "mn_mul_pipe", WA=53, WB=53, IREG=1, PREG=1, LVLS=1),
    E("multile", "t53x53_i1p1l1_tw17", "mn_mul_pipe", "17-bit tiles", WA=53, WB=53, TW=17, IREG=1, PREG=1, LVLS=1),
    # --- capacity checks (first seed only; a place failure is the expected result for the "over" cases) ---
    E("cap", "cap_dsp48", "mn_xp_mul_array", "48 x 18x18", N18=48, N36=0),
    E("cap", "cap_dsp49", "mn_xp_mul_array", "49 x 18x18 (over)", N18=49, N36=0),
    E("cap", "cap_dsp44_36", "mn_xp_mul_array", "44 x 18x18 + 1 x 36x36", N18=44, N36=1),
    E("cap", "cap_dsp45_36", "mn_xp_mul_array", "45 x 18x18 + 1 x 36x36 (over)", N18=45, N36=1),
    E("cap", "cap_bsram46", "mn_ram_1r1w", "46 x36 columns", W=46 * 36, AW=9),
    E("cap", "cap_bsram47", "mn_ram_1r1w", "47 x36 columns (over)", W=47 * 36, AW=9),
]

BSRAM_CELLS = ("SDPB", "SDPX9B", "DPB", "DPX9B", "SP", "SPX9", "pROM", "pROMX9")
DSP_WEIGHT = {"MULT9X9": 0.5, "MULT18X18": 1, "MULT36X36": 4, "MULTALU18X18": 1, "MULTALU36X18": 2,
              "MULTADDALU18X18": 2, "ALU54D": 0}
LUT_CELLS = ("LUT1", "LUT2", "LUT3", "LUT4")
FF_PREFIX = "DFF"


def stat_cells(path, top):
    d = json.loads(Path(path).read_text())
    mods = d.get("modules", {})
    m = mods.get(top) or mods.get("\\" + top) or next(iter(mods.values()))
    return {k.lstrip("\\"): v for k, v in m.get("num_cells_by_type", {}).items()}


def summarise(c):
    lut = sum(v for k, v in c.items() if k in LUT_CELLS)
    alu = c.get("ALU", 0)
    ff = sum(v for k, v in c.items() if k.startswith(FF_PREFIX))
    mux = sum(v for k, v in c.items() if k.startswith("MUX2_LUT"))
    bsram = sum(v for k, v in c.items() if k in BSRAM_CELLS)
    ssram = sum(v for k, v in c.items() if k.startswith("RAM16"))
    dsp = sum(v * DSP_WEIGHT.get(k, 0) for k, v in c.items() if k in DSP_WEIGHT)
    dspcells = ",".join(f"{k}x{v}" for k, v in sorted(c.items()) if k in DSP_WEIGHT)
    bcells = ",".join(f"{k}x{v}" for k, v in sorted(c.items()) if k in BSRAM_CELLS)
    return dict(lut=lut, alu=alu, ff=ff, mux=mux, bsram=bsram, bsram_cells=bcells, ssram=ssram,
                dsp18=dsp, dsp_cells=dspcells)


def ports_of(netlist_json, top):
    d = json.loads(Path(netlist_json).read_text())
    m = d["modules"][top]
    return [(n, p["direction"], len(p["bits"])) for n, p in m["ports"].items()]


def harness(mod, prm, ports):
    ins = [(n, w) for n, d, w in ports if d == "input" and n != "clk"]
    outs = [(n, w) for n, d, w in ports if d == "output"]
    ni = sum(w for _, w in ins)
    no = sum(w for _, w in outs)
    lines = ["// generated by recipes.py: 3-pin harness for place & route",
             "module top (input wire clk, input wire sin, output wire sout);",
             f"    reg [{ni}:0] sh = 0;",
             f"    always @(posedge clk) sh <= {{sh[{ni - 1}:0], sin}};",
             f"    wire [{no - 1}:0] y;"]
    pstr = ", ".join(f".{k}({v})" for k, v in prm.items())
    conns, pos = [".clk(clk)"], 1
    for n, w in ins:
        conns.append(f".{n}(sh[{pos + w - 1}:{pos}])")
        pos += w
    opos = 0
    for n, w in outs:
        conns.append(f".{n}(y[{opos + w - 1}:{opos}])")
        opos += w
    lines.append(f"    {mod} #({pstr}) u (" + ", ".join(conns) + ");")
    # registered XOR tree, 4 inputs per LUT
    lines.append(f"    reg [{no - 1}:0] x0;")
    lines.append("    always @(posedge clk) x0 <= y;")
    width, lvl = no, 0
    while width > 1:
        nw = (width + 3) // 4
        lines.append(f"    reg [{nw - 1}:0] x{lvl + 1};")
        lines.append("    always @(posedge clk) begin")
        for i in range(nw):
            hi = min(4 * i + 3, width - 1)
            lines.append(f"        x{lvl + 1}[{i}] <= ^x{lvl}[{hi}:{4 * i}];")
        lines.append("    end")
        width, lvl = nw, lvl + 1
    lines.append(f"    assign sout = x{lvl}[0];")
    lines.append("endmodule")
    return "\n".join(lines) + "\n"


CST = """IO_LOC  "clk" 4;
IO_PORT "clk" IO_TYPE=LVCMOS33 PULL_MODE=NONE;
CLOCK_LOC "clk" BUFG;
IO_LOC "sin" 88;
IO_PORT "sin" IO_TYPE=LVCMOS33 PULL_MODE=DOWN;
IO_LOC "sout" 15;
IO_PORT "sout" IO_TYPE=LVCMOS33;
"""


def parse_pnr(log):
    res = {}
    fm = re.findall(r"Max frequency for clock '[^']*': ([0-9.]+) MHz", log)
    res["fmax"] = float(fm[-1]) if fm else None
    util = {}
    for m in re.finditer(r"Info:\s+(\w+):\s+(\d+)/\s*(\d+)", log):
        util[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    res["util"] = util
    blocks = log.split("Critical path report for clock")
    if len(blocks) > 1:
        last = blocks[-1].split("Max frequency")[0]
        src = re.search(r"Source (\S+)", last)
        sinks = re.findall(r"Sink (\S+)", last)
        lr = re.search(r"([0-9.]+) ns logic, ([0-9.]+) ns routing", last)
        res["crit"] = f"{src.group(1) if src else '?'} -> {sinks[-1] if sinks else '?'}"
        res["crit_ns"] = f"{lr.group(1)}+{lr.group(2)}" if lr else ""
    return res


def measure_one(e, seeds):
    d = BUILD / "measure" / e["name"]
    d.mkdir(parents=True, exist_ok=True)
    mod, prm = e["mod"], e["prm"]
    files = files_for(mod)
    reads = " ".join(f"read_verilog {Path(f).as_posix()};" for f in files)
    chp = " ".join(f"-set {k} {v}" for k, v in prm.items())
    chparam = f"chparam {chp} {mod};" if prm else ""
    # 1. DUT alone
    script = (f"{reads} {chparam} synth_gowin -family gw2a -top {mod} -noiopads -json {(d / 'dut.json').as_posix()};"
              f" tee -q -o {(d / 'dut.stat.json').as_posix()} stat -json")
    rc, out = run(["yosys", "-q", "-p", script])
    (d / "dut.yosys.log").write_text(out)
    if rc:
        return dict(e, error="dut synth failed")
    dut = summarise(stat_cells(d / "dut.stat.json", mod))
    # 2. harness
    (d / "top.v").write_text(harness(mod, prm, ports_of(d / "dut.json", mod)))
    (d / "top.cst").write_text(CST)
    script = (f"{reads} read_verilog {(d / 'top.v').as_posix()}; synth_gowin -family gw2a -top top"
              f" -json {(d / 'top.json').as_posix()}; tee -q -o {(d / 'top.stat.json').as_posix()} stat -json")
    rc, out = run(["yosys", "-q", "-p", script])
    (d / "top.yosys.log").write_text(out)
    if rc:
        return dict(e, dut=dut, error="harness synth failed")
    # 3. place & route
    fmax, crit, util, errs = [], "", {}, []
    if e["group"] == "cap":
        seeds = seeds[:1]
    for s in seeds:
        rc, out = run(["nextpnr-himbaechel", "--json", d / "top.json", "--write", d / f"pnr{s}.json",
                       "--device", DEVICE, "--vopt", f"family={FAMILY}", "--vopt", f"cst={(d / 'top.cst').as_posix()}",
                       "--freq", PNR_FREQ, "--timing-allow-fail", "--seed", s])
        (d / f"pnr{s}.log").write_text(out)
        if rc:
            errs.append(f"seed {s}: " + (re.findall(r"ERROR: .*", out) or ["rc=%d" % rc])[-1])
            continue
        p = parse_pnr(out)
        fmax.append(p["fmax"])
        if not crit:
            crit = f"{p.get('crit', '')} ({p.get('crit_ns', '')} ns)"
            util = p["util"]
        (d / f"pnr{s}.json").unlink(missing_ok=True)
    return dict(e, dut=dut, fmax=fmax, crit=crit, util=util, error="; ".join(errs))


def cmd_measure(a):
    seeds = [int(s) for s in a.seeds.split(",")]
    exps = [e for e in EXPERIMENTS if not a.only or a.only in e["name"] or a.only == e["group"]]
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(measure_one, e, seeds): e for e in exps}
        for f in cf.as_completed(futs):
            r = f.result()
            fm = r.get("fmax") or []
            print(f"{r['name']:22s} {r.get('error') or ''} fmax={fm} dut={r.get('dut', {})}", flush=True)
            results.append(r)
    order = {e["name"]: i for i, e in enumerate(EXPERIMENTS)}
    results.sort(key=lambda r: order[r["name"]])
    RESULTS.mkdir(exist_ok=True)
    rows = []
    for r in results:
        dut, u, fm = r.get("dut", {}), r.get("util", {}), [x for x in (r.get("fmax") or []) if x]
        rows.append({
            "group": r["group"], "name": r["name"], "module": r["mod"],
            "params": " ".join(f"{k}={v}" for k, v in r["prm"].items()), "note": r["note"],
            "dut_lut": dut.get("lut"), "dut_alu": dut.get("alu"), "dut_mux": dut.get("mux"), "dut_ff": dut.get("ff"),
            "dut_bsram": dut.get("bsram"), "dut_bsram_cells": dut.get("bsram_cells"), "dut_ssram": dut.get("ssram"),
            "dut_dsp18": dut.get("dsp18"), "dut_dsp_cells": dut.get("dsp_cells"),
            "pnr_bsram": u.get("BSRAM", ("", ""))[0], "pnr_mult18": u.get("MULT18X18", ("", ""))[0],
            "pnr_mult36": u.get("MULT36X36", ("", ""))[0], "pnr_ram16": u.get("RAM16SDP4", ("", ""))[0],
            "pnr_lut4": u.get("LUT4", ("", ""))[0], "pnr_alu": u.get("ALU", ("", ""))[0], "pnr_dff": u.get("DFF", ("", ""))[0],
            "fmax_seeds": " ".join(f"{x:.1f}" for x in fm),
            "fmax_min": f"{min(fm):.1f}" if fm else "", "fmax_med": f"{statistics.median(fm):.1f}" if fm else "",
            "crit": r.get("crit", ""), "error": r.get("error", ""),
        })
    # --only: merge the new rows into the existing tables (rows matched by name)
    csv_path = RESULTS / "measure.csv"
    if a.only and csv_path.exists():
        with open(csv_path, newline="", encoding="utf-8") as fh:
            old = {x["name"]: x for x in csv.DictReader(fh)}
        old.update({x["name"]: x for x in rows})
        rows = sorted(old.values(), key=lambda x: order.get(x["name"], 1 << 30))
    tag = ""
    with open(RESULTS / f"measure{tag}.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    with open(RESULTS / f"measure{tag}.md", "w", encoding="utf-8") as fh:
        fh.write(f"# WP07 measurements ({DEVICE}, nextpnr --freq {PNR_FREQ}, seeds {a.seeds})\n\n")
        fh.write("Generated by `python mncore/fpga/recipes/recipes.py measure`. Interpretation: mncore/07-device-budget.md.\n\n")
        fh.write("- LUT/ALU/FF/BSRAM/SSRAM/DSP: yosys synth_gowin of the module alone (LUT = LUT1..LUT4,"
                 " SSRAM = RAM16SDP4, DSP18 = 18x18-multiplier equivalents: MULT9X9 0.5, MULT36X36 4).\n")
        fh.write("- Fmax: nextpnr post-route value of the 3-pin harness, median (min) over the seeds.\n")
        fh.write("- **nextpnr-himbaechel does not time paths through DSP cells.** In the mul groups only the fabric"
                 " paths are analysed; when no register follows the DSP, the DSP path and everything after it"
                 " up to the next register are missing from the Fmax.\n\n")
        for g in dict.fromkeys(x["group"] for x in rows):
            fh.write(f"## {g}\n\n")
            fh.write("| name | module | params | LUT | ALU | FF | BSRAM | SSRAM | DSP18 | DSP cells |"
                     " Fmax med (min) MHz | critical path (logic+route ns) | note | error |\n")
            fh.write("|---|---|---|--:|--:|--:|--:|--:|--:|---|--:|---|---|---|\n")
            for x in rows:
                if x["group"] != g:
                    continue
                fh.write(f"| {x['name']} | {x['module']} | {x['params']} | {x['dut_lut']} | {x['dut_alu']} |"
                         f" {x['dut_ff']} | {x['dut_bsram']} | {x['dut_ssram']} | {x['dut_dsp18']} |"
                         f" {x['dut_dsp_cells']} | {x['fmax_med']} ({x['fmax_min']}) | {x['crit']} |"
                         f" {x['note']} | {x['error']} |\n")
            fh.write("\n")
    print(f"wrote {rel(RESULTS / f'measure{tag}.csv')} and .md")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("check")
    m = sp.add_parser("measure")
    m.add_argument("-j", "--jobs", type=int, default=min(16, os.cpu_count() or 4))
    m.add_argument("--seeds", default="1,2,3")
    m.add_argument("--only", default="")
    a = ap.parse_args()
    return cmd_check(a) if a.cmd == "check" else cmd_measure(a)


if __name__ == "__main__":
    sys.exit(main())

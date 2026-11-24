#!/usr/bin/env python3
"""Mutation check of the WP20 tests: each mutation must make the core unit test fail.

    python mncore/sim/tb/core/mutate.py [--only NAME,...] [-j 6] [--corpus]

Every mutation changes one line of mn_pe_core.v or mn_core.v (a copy in build/mut/<name>/),
recompiles tb_core and runs mncore/sim/tb/core/fixed/all.scr. With --corpus the corpus
regression (mncore/sim/regress/run.py --skip-official --vvp ...) runs on the mutant too.
Prints one line per mutation: detected (with the number of failed checks) or NOT DETECTED.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402  (also puts OSS CAD Suite on PATH)

PE = "mncore/rtl/pe/mn_pe_core.v"
CORE = "mncore/rtl/core/mn_core.v"

# (name, file, old text, new text, what it breaks)
MUTATIONS = [
    ("alu_result_bit", PE, ".res_alu(alu_z)", ".res_alu(alu_z ^ 128'h1)", "ALU result to the memories"),
    ("mau_result_bit", PE, ".res_mau(maub_rd[127:0])", ".res_mau(maub_rd[127:0] ^ {1'b1, 127'd0})",
     "MAU result to the memories"),
    ("alu_flags", PE, ".res_alu_flags(alu_f)", ".res_alu_flags({alu_f[0], alu_f[3:1]})", "ALU flags to $omr"),
    ("mau_flags", PE, ".res_mau_flags(maub_rd[131:128])", ".res_mau_flags(4'hf)", "MAU flags to $omr"),
    ("aluf_no_flush", PE, "wire [127:0] aluf_wd = (zf_en & (zf_sel == 2'b01)) ? (alu_z & zf_mask) : alu_z;",
     "wire [127:0] aluf_wd = alu_z;", "zero flush of $aluf"),
    ("mauf_no_flush", PE,
     "wire [127:0] mauf_wd = (zf_en & (zf_sel == 2'b00)) ? (maub_rd[127:0] & zf_mask) : maub_rd[127:0];",
     "wire [127:0] mauf_wd = maub_rd[127:0];", "zero flush of $mauf"),
    ("noforward_ignored", PE, "wire         fwd_on  = acc & ~unsup_q & ~d_noforward;",
     "wire         fwd_on  = acc & ~unsup_q;", "noforward"),
    ("aluf_cycle", PE, ".clk(clk), .we(fwd_on & alu_act), .waddr(coll_c), .wdata(aluf_wd),",
     ".clk(clk), .we(fwd_on & alu_act), .waddr(coll_c + 2'd1), .wdata(aluf_wd),", "$aluf entry per cycle"),
    ("alu_xy_swap", PE, ".imm32(d_imm32), .x(px), .y(py),", ".imm32(d_imm32), .x(py), .y(px),",
     "ALU operand ports"),
    ("mau_c_zero", PE, ".a_bus(pa), .b_bus(pb), .c_bus(pc),", ".a_bus(pa), .b_bus(pb), .c_bus(128'd0),",
     "MAU input c"),
    ("no_y_gather", PE, "alu_act & two_in, alu_act & ~d_is_imm};", "1'b0, alu_act & ~d_is_imm};",
     "gathering of ALU input y"),
    ("msb1", PE, "wire       fmsb = (gcode == 4'd8);", "wire       fmsb = 1'b0;", "$msb1"),
    ("peid", PE, "localparam [31:0] V_PEID  = POS_M * 4 + POS_P;", "localparam [31:0] V_PEID  = 32'd1;",
     "$peid"),
    ("rd_use_lm1", PE, "(s == 4'd3) ? 4'b0100 : (s == 4'd4) ? 4'b1000 : 4'd0;",
     "(s == 4'd3) ? 4'b0100 : (s == 4'd4) ? 4'b0000 : 4'd0;", "rd_use of LM1"),
    ("l1bm_allowed", PE, "wire u_l1  = d_grp[MN_J_GRP_L1BM];", "wire u_l1  = 1'b0;", "E_UNSUPPORTED of L1BM"),
    ("mask_not_checked", PE, "wire [425:0] jw_lsu = (ph == P_IDLE) ? jw_chk :",
     "wire [425:0] jw_lsu = (ph == P_IDLE) ? jw :", "E_RANGE of a write stopped by the mask"),
    ("unsup_executes", PE, "wire [425:0] jw_nul = {2'b00, jw[423:0]};", "wire [425:0] jw_nul = jw;",
     "no write by an unsupported word"),
    ("ll10_executed", CORE, "if (e_ll == 2'b10) begin", "if (1'b0) begin", "E_DECODE of ll = 10"),
    ("range_info", CORE, "info   <= (pe_st == 2'd1) ? pc : {9'd0, pe_field};",
     "info   <= (pe_st == 2'd1) ? pc + 16'd1 : {9'd0, pe_field};", "E_RANGE word number"),
    ("no_clear", CORE, "clr    <= (CLEAR != 0);", "clr    <= 1'b0;", "clear of the PE state after reset"),
    ("run_lost_in_clear", CORE, "if (run_start) run_pend <= 1'b1;", "if (1'b0) run_pend <= 1'b1;",
     "RUN that arrives during the clear"),
]


def run_mutation(m, corpus: bool):
    name, path, old, new, what = m
    src = (ROOT / path).read_text(encoding="utf-8")
    if src.count(old) != 1:
        return name, what, f"BAD MUTATION (the text occurs {src.count(old)} times)"
    mdir = HERE / "build" / "mut" / name
    mdir.mkdir(parents=True, exist_ok=True)
    (mdir / Path(path).name).write_text(src.replace(old, new), encoding="utf-8", newline="\n")
    files, cfg = simrun.parse_files("core")
    files = [(mdir / Path(path).name).as_posix() if f == path else f for f in files]
    vvp = mdir / "sim.vvp"
    cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", str(vvp)]
    cmd += [f"-I{d}" for d in cfg["incdir"]] + ["-s", cfg["top"]] + files
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        return name, what, "COMPILE ERROR " + (r.stdout + r.stderr)[-300:]
    r = subprocess.run(["vvp", "-n", str(vvp), "+quiet"], cwd=ROOT, capture_output=True, text=True)
    last = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
    verdict = last[-1] if last else "no verdict"
    res = "NOT DETECTED" if verdict.startswith("PASS") else f"detected ({verdict})"
    if corpus:
        r = subprocess.run([sys.executable, str(ROOT / "mncore" / "sim" / "regress" / "run.py"), "--skip-official",
                            "--vvp", str(vvp), "-j", "4"], cwd=ROOT, capture_output=True, text=True)
        tail = [ln for ln in r.stdout.splitlines() if "pass" in ln.lower() and "/" in ln]
        res += f"; corpus: {tail[-1] if tail else '?'}"
    return name, what, res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only")
    ap.add_argument("-j", "--jobs", type=int, default=6)
    ap.add_argument("--corpus", action="store_true")
    a = ap.parse_args(argv)
    only = set(a.only.split(",")) if a.only else None
    muts = [m for m in MUTATIONS if not only or m[0] in only]
    bad = 0
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for name, what, res in ex.map(lambda m: run_mutation(m, a.corpus), muts):
            print(f"{name:<20} {what:<40} {res}", flush=True)
            bad += not res.startswith("detected")
    print(f"{len(muts) - bad}/{len(muts)} mutations detected")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

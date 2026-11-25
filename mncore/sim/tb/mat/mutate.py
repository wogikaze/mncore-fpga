#!/usr/bin/env python3
"""Mutation check of the WP36 tests: each mutation must make the mat unit test fail.

    python mncore/sim/tb/mat/mutate.py [--only NAME,...] [-j 6]

Every mutation changes one line of the matrix RTL (mn_mab_mat.v, mn_mab_mrnd.v, mn_pe_core.v; a
copy in build/mut/<name>/), recompiles tb_core with N_PE = 4, MAT = 1 and runs
mncore/sim/tb/mat/fixed/all.scr. Prints one line per mutation: detected (with the verdict) or
NOT DETECTED.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import simrun  # noqa: E402  (also puts OSS CAD Suite on PATH)

MAT = "mncore/rtl/mab/mn_mab_mat.v"
RND = "mncore/rtl/mab/mn_mab_mrnd.v"
PE = "mncore/rtl/pe/mn_pe_core.v"

# (name, file, old text, new text, what it breaks)
MUTATIONS = [
    ("read_face_mw", MAT, "wire       f_r  = ~(w_readh ^ w_mw);", "wire       f_r  = ~w_readh;",
     "read face of a word with ?mwrite"),
    ("read_addr_mw", MAT, "wire [3:0] r_a  = w_mw ? {w_signa, w_signc, w_passa, w_zeroc} : w_ma;",
     "wire [3:0] r_a  = w_ma;", "read column of a word with ?mwrite"),
    ("mau_face", MAT, "wire       f_m  = w_readh;", "wire       f_m  = ~w_readh;", "face of the matrix MAU"),
    ("h_read_odd", MAT, "wire [2:0] rc_h   = r_a[3:1] + {1'b0, mr_cycle};",
     "wire [2:0] rc_h   = r_a[2:0] + {1'b0, mr_cycle};", "h read column (even)"),
    ("h_rows_odd", MAT, "wire [3:0]  mw_a2  = {w_ma[3:1] + {1'b0, mw_cycle}, 1'b0} | {3'd0, mw_k[1]};",
     "wire [3:0]  mw_a2  = (w_ma + {1'b0, mw_cycle, 1'b0}) | {3'd0, mw_k[1]};", "h two-row write row (even)"),
    ("ext_zero_mant", MAT, "s2d = (x[30:23] == 8'd0) ? {x[31], 63'd0} :",
     "s2d = (x[30:23] == 8'd0) ? {x[31], 11'd0, x[22:0], 29'd0} :", "e of a zero (sign only)"),
    ("signb", MAT, "mw_wd   = (mw_k[0] ? mw_f1 : mw_f0) ^ {w_signb, 31'd0};",
     "mw_wd   = (mw_k[0] ? mw_f1 : mw_f0);", "- on the ?mwrite source"),
    ("f_correction", MAT, "(p_f & (tp == 2'd0)) ? {7'd0, pp, 1'b0, (|ta_lo) & (|tb_lo), 3'd0} :",
     "(p_f & (tp == 2'd0)) ? {7'd0, pp, 5'd0} :", "f partial-product correction"),
    ("g_mant18", MAT, "wire [17:0] a_m = p_h ? {9'd0, a_h[8:0]} : tword[22:5];",
     "wire [17:0] a_m = p_h ? {9'd0, a_h[8:0]} : tword[17:0];", "g uses the top 18 mantissa bits"),
    ("signa", MAT, "wire        x_s = (p_h ? x_h[15] : txw[31]) ^ w_signa;",
     "wire        x_s = (p_h ? x_h[15] : txw[31]);", "- on x of ?mfma"),
    ("h_ext_shift", MAT,
     "tsh   <= {p_h & (a_e == 8'd0) & (x_e == 8'd0), p_h & ((a_e == 8'd0) ^ (x_e == 8'd0))};",
     "tsh   <= 2'd0;", "h extended elements (common - 6)"),
    ("grid_h", RND, "wire signed [11:0] kgrid = p_h ? 12'sd26 : p_f ? 12'sd39 : 12'sd34;",
     "wire signed [11:0] kgrid = p_h ? 12'sd28 : p_f ? 12'sd39 : 12'sd34;", "h adder grid (K = 26)"),
    ("grid_f", RND, "wire signed [11:0] kgrid = p_h ? 12'sd26 : p_f ? 12'sd39 : 12'sd34;",
     "wire signed [11:0] kgrid = p_h ? 12'sd26 : p_f ? 12'sd41 : 12'sd34;", "f adder grid (K = 39)"),
    ("grid_g", RND, "wire signed [11:0] kgrid = p_h ? 12'sd26 : p_f ? 12'sd39 : 12'sd34;",
     "wire signed [11:0] kgrid = p_h ? 12'sd26 : p_f ? 12'sd39 : 12'sd36;", "g adder grid (K = 34)"),
    ("drop_h", RND, "wire        drop_d = p_h & ~c_zero & ((uc - ep) >= 12'sd30);",
     "wire        drop_d = 1'b0;", "h product drop (T = 30)"),
    ("bf_inf", RND, "wire        bf_inf  = ~bf_zero & ((ca == emax) | (cb == emax));",
     "wire        bf_inf  = 1'b0;", "common exponent all ones gives +inf"),
    ("no_x_gather", PE, "wire [5:0] need = rdo_in ? {3'd0, mat_act, 1'b0, xpe} : need_n;",
     "wire [5:0] need = rdo_in ? {5'd0, xpe} : need_n;", "x of the 4 PEs in the check-only pass"),
    ("mreadf_flush", PE, "assign mr_hen = (zf_en & (zf_sel == 2'b11)) ? zf_hen : 8'hff;",
     "assign mr_hen = 8'hff;", "zero flush of $mreadf"),
    ("mreadf_kept", PE, "assign mr_upd = MX & fwd_on;", "assign mr_upd = 1'b0;", "$mreadf updated every step"),
    ("mread_zero", PE, ".res_mread(MX ? mr_val : 128'd0),", ".res_mread(128'd0),", "?mread result to memory"),
]


def run_mutation(m):
    name, path, old, new, what = m
    src = (ROOT / path).read_text(encoding="utf-8")
    if src.count(old) != 1:
        return name, what, f"BAD MUTATION (the text occurs {src.count(old)} times)"
    mdir = HERE / "build" / "mut" / name
    mdir.mkdir(parents=True, exist_ok=True)
    (mdir / Path(path).name).write_text(src.replace(old, new), encoding="utf-8", newline="\n")
    files, cfg = simrun.parse_files("mat")
    files = [(mdir / Path(path).name).as_posix() if f == path else f for f in files]
    vvp = mdir / "sim.vvp"
    cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", str(vvp)]
    cmd += [f"-I{d}" for d in cfg["incdir"]] + [f"-D{d}" for d in cfg["define"]] + ["-s", cfg["top"]] + files
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        return name, what, "COMPILE ERROR " + (r.stdout + r.stderr)[-300:]
    r = subprocess.run(["vvp", "-n", str(vvp), "+quiet"], cwd=ROOT, capture_output=True, text=True)
    last = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
    verdict = last[-1] if last else "no verdict"
    res = "NOT DETECTED" if verdict.startswith("PASS") else f"detected ({verdict})"
    return name, what, res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only")
    ap.add_argument("-j", "--jobs", type=int, default=6)
    a = ap.parse_args(argv)
    only = set(a.only.split(",")) if a.only else None
    muts = [m for m in MUTATIONS if not only or m[0] in only]
    bad = 0
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for name, what, res in ex.map(run_mutation, muts):
            print(f"{name:<16} {what:<42} {res}", flush=True)
            bad += not res.startswith("detected")
    print(f"{len(muts) - bad}/{len(muts)} mutations detected")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

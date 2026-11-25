#!/usr/bin/env python3
"""Mutation check of the WP34 tests: each mutation of the virtual-PE RTL must make its suite fail.

    python mncore/sim/tb/vpe/mutate.py [--only NAME,...] [-j 4]

Every mutation changes one line of the RTL (a copy in build/mut/<name>/), recompiles tb_core with the
defines of the unit that should catch it (vpe/mab: the WP30 4-PE programs on one virtual MAB; vpe: the M2
programs with the units and the MV unit on the shared SDRAM bus; vpe/m64: the 64-PE programs; vpe/m64r:
the 64-PE E_RANGE programs with LM_AW = 8) and runs its script. Prints one line per mutation: detected
(with the verdict) or NOT DETECTED.
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

VPE = "mncore/rtl/vpe/mn_vpe.v"
CTX = "mncore/rtl/vpe/mn_vpe_ctx.v"
STO = "mncore/rtl/vpe/mn_vpe_store.v"
ARB = "mncore/rtl/vpe/mn_vpe_arb.v"
MEM = "mncore/rtl/mab/mn_mab_mem.v"
PE = "mncore/rtl/pe/mn_pe_core.v"
L1 = "mncore/rtl/l1bm/mn_l1bm.v"

# (name, unit, file, old text, new text, what it breaks)
MUTATIONS = [
    ("store_lm_plane", "vpe/mab", STO, "(LM_BASE | {2'd0, pe, g[0], g_a[10:0]})",
     "(LM_BASE | {2'd0, pe, 1'b0, g_a[10:0]})", "LM1 in its own plane"),
    ("store_pe", "vpe/mab", STO, "(LM_BASE | {2'd0, pe, g[0], g_a[10:0]})",
     "(LM_BASE | {2'd0, pe[5:2], 2'd0, g[0], g_a[10:0]})", "the LM of each PE"),
    ("store_grf_pe", "vpe/mab", STO, "(GRF_BASE | {5'd0, pe, g[0], g_a[7:0]})",
     "(GRF_BASE | {5'd0, pe[5:2], 2'd0, g[0], g_a[7:0]})", "the GRF of each PE"),
    ("store_mab", "vpe/m64", MEM, ".pe({vm, cur_pe})", ".pe({4'd0, cur_pe})", "the memories of each MAB"),
    ("store_read_ch", "vpe/mab", STO, "assign rsp_valid = b_rsp_valid ? (4'd1 << q_ch) : 4'd0;",
     "assign rsp_valid = b_rsp_valid ? (4'd1 << g) : 4'd0;", "a read answer to its channel"),
    ("ctx_no_t_load", "vpe/mab", CTX, "wire [4:0]  grp_l = {(MAU != 0) & cx[8], cx[6], cx[0], cx[2], cx[4]};",
     "wire [4:0]  grp_l = {(MAU != 0) & cx[8], cx[6], 1'b0, cx[2], cx[4]};", "T loaded for a word that reads it"),
    ("ctx_no_aluf_save", "vpe/mab", CTX, "wire [4:0]  grp_s = {(MAU != 0) & cx[9], cx[7], cx[1], cx[3], cx[5]};",
     "wire [4:0]  grp_s = {(MAU != 0) & cx[9], 1'b0, cx[1], cx[3], cx[5]};", "$aluf saved after a word"),
    ("ctx_no_bar_save", "vpe/mab", CTX, "wire [4:0]  grp_s = {(MAU != 0) & cx[9], cx[7], cx[1], cx[3], cx[5]};",
     "wire [4:0]  grp_s = {(MAU != 0) & cx[9], cx[7], cx[1], cx[3], 1'b0};", "$mb / $nb saved"),
    ("ctx_no_omr_save", "vpe/mab", CTX, "wire [4:0]  grp_s = {(MAU != 0) & cx[9], cx[7], cx[1], cx[3], cx[5]};",
     "wire [4:0]  grp_s = {(MAU != 0) & cx[9], cx[7], cx[1], 1'b0, cx[5]};", "$omr saved"),
    ("ctx_omr_entry", "vpe/mab", CTX, "oe     <= save ? omr_e : imr_e;", "oe     <= omr_e;",
     "the $omr entry a word reads"),
    ("ctx_hold", "vpe/mab", CTX, "hold_d <= hp_rsp_rdata;", "hold_d <= 64'd0;",
     "a saved item when the bus waits"),
    ("cx_t_write_load", "vpe/mab", PE, "c_act & (src_t | (jw[425-90] & c_lm0) | d_t_wr)};",
     "c_act & (src_t | (jw[425-90] & c_lm0))};", "T loaded before a (masked) T write"),
    ("cx_tind_load", "vpe/mab", PE, "c_act & (src_t | (jw[425-90] & c_lm0) | d_t_wr)};",
     "c_act & (src_t | d_t_wr)};", "T loaded for T-indirect"),
    ("vpe_nochk_mab0", "vpe/mab", VPE, "wire        nochk = gchk | (vm != 4'd0) | ((LM_AW >= 11) & ~x_act);",
     "wire        nochk = 1'b1;", "the check-only pass of MAB 0 (E_RANGE before any write)"),
    ("vpe_no_gchk", "vpe/m64r", VPE, "wire        gchk_n  = (N_MAB > 1) && (LM_AW < 11) && cx_use[4];",
     "wire        gchk_n  = 1'b0;", "the check of all MABs before any writes (LM_AW < 11)"),
    ("vpe_ugo_every_mab", "vpe/m64", VPE, "assign ugo      = m_ugo & ~gpass & (vm == 4'd0);",
     "assign ugo      = m_ugo & ~gpass;", "the units start once a word"),
    ("vpe_cur_mab0", "vpe/m64", VPE, "assign cur_mab  = vm;", "assign cur_mab  = 4'd0;",
     "the MAB of the L1BM transfers"),
    ("pe_mabid_vm", "vpe/m64", PE, "wire [3:0] v_mab  = V_MAB4[5:2] + vm;", "wire [3:0] v_mab  = V_MAB4[5:2];",
     "$peid / $mabid of the virtual MABs"),
    ("l1bm_bs_read_ahead", "vpe/m64", L1, "((k_dir & (~BSB | kp)) | k_zero | (krun & rr_done & k_lane_last));",
     "((k_dir & (~BSB | 1'b1)) | k_zero | (krun & rr_done & k_lane_last));",
     "BS: a direct item after its source buffer read"),
    ("l1bm_bs_stage", "vpe/m64", L1, "& ~krun & ~rr_busy & (~BSB | stg_hit);", "& ~krun & ~rr_busy & (~BSB | 1'b1);",
     "BS: a reduction after its inputs are staged"),
    ("l1bm_bs_stage_half", "vpe/m64", L1, "wire         stg_hit = stg_ok & (stg_lo == in_lo);",
     "wire         stg_hit = stg_ok;", "BS: restaging when a rounded reduction reads the other long word"),
    ("pe_lbs_wait", "vpe/m64", PE, "wire lb_ok = (LBS == 0) | ~BX | (gcode != 4'd13) | (lb_v & (lb_c == iss_c));",
     "wire lb_ok = 1'b1;", "LBS: the $lbf read a clock after its address"),
    ("arb_route", "vpe", ARB, "assign m0_rsp_valid = s_rsp_valid & ~q_m;", "assign m0_rsp_valid = s_rsp_valid;",
     "the SDRAM answers to their master (MV / virtual PEs)"),
]


def unit_cfg(unit: str):
    files, cfg = simrun.parse_files(unit)
    return files, cfg


def run_mutation(m):
    name, unit, path, old, new, what = m
    src = (ROOT / path).read_text(encoding="utf-8")
    if src.count(old) != 1:
        return name, what, f"BAD MUTATION (the text occurs {src.count(old)} times)"
    mdir = HERE / "build" / "mut" / name
    mdir.mkdir(parents=True, exist_ok=True)
    (mdir / Path(path).name).write_text(src.replace(old, new), encoding="utf-8", newline="\n")
    files, cfg = unit_cfg(unit)
    files = [(mdir / Path(path).name).as_posix() if f == path else f for f in files]
    vvp = mdir / "sim.vvp"
    cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", str(vvp)]
    cmd += [f"-I{d}" for d in cfg["incdir"]] + [f"-D{d}" for d in cfg["define"]] + ["-s", cfg["top"]] + files
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        return name, what, "COMPILE ERROR " + (r.stdout + r.stderr)[-300:]
    try:
        r = subprocess.run(["vvp", "-n", str(vvp), "+quiet", "+maxclk=3000000"], cwd=ROOT, capture_output=True,
                           text=True, timeout=14400)
        out = r.stdout
    except subprocess.TimeoutExpired:
        return name, what, "detected (timeout)"
    verdicts = [ln for ln in out.splitlines() if ln.startswith(("PASS", "FAIL"))]
    v = verdicts[-1] if verdicts else "no verdict"
    errs = [ln for ln in out.splitlines() if "ERROR" in ln]
    if v.startswith("PASS") and not errs:
        return name, what, "NOT DETECTED"
    return name, what, "detected: " + (v if not v.startswith("PASS") else errs[0])[:120]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="comma separated mutation names")
    ap.add_argument("-j", "--jobs", type=int, default=4)
    a = ap.parse_args(argv)
    only = set(a.only.split(",")) if a.only else None
    muts = [m for m in MUTATIONS if not only or m[0] in only]
    ok = True
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for name, what, res in ex.map(run_mutation, muts):
            print(f"{name:<22} {res}   ({what})", flush=True)
            ok &= res.startswith("detected")
    print(f"{len(muts)} mutations: {'all detected' if ok else 'NOT ALL DETECTED'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

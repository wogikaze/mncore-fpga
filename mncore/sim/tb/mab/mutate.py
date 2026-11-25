#!/usr/bin/env python3
"""Mutation check of the WP30 tests: each mutation must make the mab unit test fail.

    python mncore/sim/tb/mab/mutate.py [--only NAME,...] [-j 6]

Every mutation changes one line of the 4-PE RTL (mn_mab.v, mn_mab_mem.v, mn_pe_core.v,
mn_pe_store.v; a copy in build/mut/<name>/), recompiles tb_core with N_PE = 4 and runs
mncore/sim/tb/mab/fixed/all.scr. Prints one line per mutation: detected (with the verdict) or
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

MAB = "mncore/rtl/mab/mn_mab.v"
MEM = "mncore/rtl/mab/mn_mab_mem.v"
PE = "mncore/rtl/pe/mn_pe_core.v"
ST = "mncore/rtl/pe/mn_pe_store.v"

# (name, file, old text, new text, what it breaks)
MUTATIONS = [
    ("msl_direction", MAB, "wire [1:0] src = (op_q == 2'd1) ? p - 2'd1 : (op_q == 2'd2) ? p + 2'd1 : p;",
     "wire [1:0] src = (op_q == 2'd1) ? p + 2'd1 : (op_q == 2'd2) ? p - 2'd1 : p;", "msl / msr direction"),
    ("msl_lsb_kept", MAB, "assign xz_z = (op_q == 2'd3) ? xb_rd : {xb_rd[127:64], 64'd0};",
     "assign xz_z = xb_rd;", "msl / msr LSB long word = 0"),
    ("x_cycle", MAB, "assign xb_wa = bf_we ? bf_wa : {p, xg_cycle};", "assign xb_wa = bf_we ? bf_wa : {p, 2'd0};",
     "exchange buffer entry per cycle"),
    ("bfn_pe_order", MAB, ".x({xb_rd, stg})", ".x({stg, xb_rd})", "bfn / bfe input of PE p at x[128p]"),
    ("bfn_result_pe", MAB, "assign bf_wd  = bf_z[128*bk +: 128];", "assign bf_wd  = bf_z[127:0];",
     "bfn / bfe result of PE p"),
    ("no_prechk", PE, "assign prechk = MP & (xpe | mat_act | rd_use[2] | rd_use[3] | d_lm0_wr | d_lm1_wr);",
     "assign prechk = MP & (xpe | mat_act);", "E_RANGE of any PE before any write"),
    ("xpe_no_aluf", PE, ".clk(clk), .we(fwd_on & (alu_act | xpe)), .waddr(f_wa), .wdata(aluf_wd),",
     ".clk(clk), .we(fwd_on & alu_act), .waddr(f_wa), .wdata(aluf_wd),", "$aluf after msl / msr / bfn"),
    ("fwd_shared", PE, "assign f_wa = {pe_q, coll_c};", "assign f_wa = {2'b00, coll_c};",
     "forwarding registers per PE"),
    ("peid_pe0", PE, "wire [5:0] v_peid = {V_MAB4[5:2], pos_p};", "wire [5:0] v_peid = {V_MAB4[5:2], 2'd0};",
     "$peid of each PE"),
    ("mau_pe_sub", PE, ".exta(mau_exta), .extb(mau_extb), .extc(mau_extc), .pe_sub(pos_p),",
     ".exta(mau_exta), .extb(mau_extb), .extc(mau_extc), .pe_sub(2'd0),", "dvfma u / d PE pair"),
    ("subpe_madpe", MEM, ".clk(clk), .rst(rst), .subpe(pe_q),", ".clk(clk), .rst(rst), .subpe(2'd0),",
     "j<madpe> per PE"),
    ("store_shared", ST, "assign ra = {pq, a[AW-1:0]};", "assign ra = {2'b00, a[AW-1:0]};",
     "memories per PE"),
    ("no_t_restore", MEM, "r_t   <= ctx_t | (w_m0_tr & ~w_imm) | (~nul & w_t_wr & w_tgt_t & w_mask);",
     "r_t   <= 1'b0;", "T of the PE loaded before its step"),
    ("no_t_restore_src", MEM, "r_t   <= ctx_t | (w_m0_tr & ~w_imm) | (~nul & w_t_wr & w_tgt_t & w_mask);",
     "r_t   <= (w_m0_tr & ~w_imm) | (~nul & w_t_wr & w_tgt_t & w_mask);", "T loaded for a T operand"),
    ("no_o_restore", MEM, "r_o   <= ~nul & w_mask & ~w_imr[4] & (w_imr[3:0] != 4'd0);", "r_o   <= 1'b0;",
     "$omr<imr> of the PE loaded before its step"),
    ("no_t_save", MEM, "s_t   <= ~nul & w_t_wr;", "s_t   <= 1'b0;", "T saved after a T write"),
    ("no_o_save", MEM, "s_o   <= ~nul & (w_omr != 4'd0);", "s_o   <= 1'b0;", "$omr saved after an $omr write"),
    ("no_b_save", MEM, "s_b   <= ~nul & w_barw;", "s_b   <= 1'b0;", "$mb / $nb saved after a write"),
    ("bar_slot", MEM, "it_ce = (i <= 4'd1) ? {4'b0100, i[0]} :", "it_ce = (i <= 4'd1) ? {4'b0100, 1'b0} :",
     "$nb restored from its own slot"),
    ("check_pass_writes", MEM, "wire [425:0] l_jw   = (q == Q_GO) ? jw_chk : (nul_q ? jw_nul : jw);",
     "wire [425:0] l_jw   = (q == Q_GO) ? jw_chk : jw;", "the check-only pass writes nothing"),
    ("host_t_lanes", MEM, "c_we = {|hp_req_wmask[7:4], |hp_req_wmask[3:0]};", "c_we = 2'b01;",
     "host writes of T (both halves)"),
]


def run_mutation(m):
    name, path, old, new, what = m
    src = (ROOT / path).read_text(encoding="utf-8")
    if src.count(old) != 1:
        return name, what, f"BAD MUTATION (the text occurs {src.count(old)} times)"
    mdir = HERE / "build" / "mut" / name
    mdir.mkdir(parents=True, exist_ok=True)
    (mdir / Path(path).name).write_text(src.replace(old, new), encoding="utf-8", newline="\n")
    files, cfg = simrun.parse_files("mab")
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
            print(f"{name:<18} {what:<44} {res}", flush=True)
            bad += not res.startswith("detected")
    print(f"{len(muts) - bad}/{len(muts)} mutations detected")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Mutation check of the WP10 testbench: every mutant of the generated RTL must make tb_dec FAIL.

    python mncore/sim/tb/dec/mutate.py        (after gen_vectors.py; uses mncore/sim/vectors/dec)

Each mutant replaces one exact line fragment of a generated file in a temporary copy, compiles it
with iverilog against tb_dec.v and runs vvp from the repository root. Exit 0 iff the unmodified
copy passes and every mutant fails. A fragment that is not found (generator output changed) counts
as a failure of this script, so the list has to be kept in step with gen_dec.py.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
if shutil.which("iverilog") is None:
    _oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
    os.environ["PATH"] = os.pathsep.join([str(_oss / "bin"), str(_oss / "lib"), os.environ.get("PATH", "")])
DEC = ROOT / "mncore" / "rtl" / "dec"
SRC = {"j": DEC / "mn_dec_j.v", "m": DEC / "mn_dec_m.v", "jvh": DEC / "mn_jfields.vh", "mvh": DEC / "mn_mfields.vh"}
TB = ROOT / "mncore" / "sim" / "tb" / "dec" / "tb_dec.v"

MUTANTS = [
    ("aluop slice off by one", "jvh", "`define MN_J_PE_ALUC_ALUOP(w) w[278:274]", "`define MN_J_PE_ALUC_ALUOP(w) w[279:275]"),
    ("lm1_adr_c3 bits rotated", "jvh", "`define MN_J_PE_LM1_ADR_C3(w) w[11:0]", "`define MN_J_PE_LM1_ADR_C3(w) {w[10:0], w[11]}"),
    ("cyc_lm0 c1/c2 swapped", "j", "assign cyc_lm0 = {pe_lm0_adr_c3, pe_lm0_adr_c2, pe_lm0_adr_c1, pe_lm0_adr};",
     "assign cyc_lm0 = {pe_lm0_adr_c3, pe_lm0_adr_c1, pe_lm0_adr_c2, pe_lm0_adr};"),
    ("imm 17:12 from wrong pos", "j", "assign imm32[17:12] = jw[335:330];", "assign imm32[17:12] = jw[336:331];"),
    ("imm 11:0 from replica", "j", "assign imm32[11:0] = jw[347:336];", "assign imm32[11:0] = jw[143:132];"),
    ("WAIT gated by exec", "j", "assign grp[MN_J_GRP_WAIT] = word_ok &", "assign grp[MN_J_GRP_WAIT] = exec &"),
    ("L1BM misses wl", "j", "                    l1bm_wl |\n", ""),
    ("WR_MB ignores imm", "j", "assign grp[MN_J_GRP_WR_MB] = exec & (pe_lm0_write & !is_imm & lm0_base);",
     "assign grp[MN_J_GRP_WR_MB] = exec & (pe_lm0_write & lm0_base);"),
    ("ALU-none test ignores dmode", "j", "!(pe_aluc_dmode == 2'b11 && pe_aluc_aluop == 5'b00000)", "!(pe_aluc_aluop == 5'b00000)"),
    ("lm0_wl check ignores imm", "j", "exec & (!is_imm) & (pe_lm0_wl == 2'b11)", "exec & (pe_lm0_wl == 2'b11)"),
    ("l1bm_opcode check ignores rmode", "j", "exec & (l1bm_rmode == 1'b1) & ", "exec & "),
    ("rsv_162 checked in ll=00", "j", "assign unsup_vec[66] = exec & (rsv_162 != 2'd0);", "assign unsup_vec[66] = (rsv_162 != 2'd0);"),
    ("noforward wrong", "j", "assign noforward = (ll == MN_J_LL_NOFORWARD);", "assign noforward = ll[1];"),
    ("err priority: rsv_164 before rsv_162", "j", "        unsup_vec[66] ? 7'd66 :\n        unsup_vec[67] ? 7'd67 :",
     "        unsup_vec[67] ? 7'd67 :\n        unsup_vec[66] ? 7'd66 :"),
    ("m dmode check without valid", "m", "assign mv_unsup_vec[5] = mv_valid & (", "assign mv_unsup_vec[5] = ("),
    ("m adra off by one", "mvh", "`define MN_M_ADRA(w) w[57:28]", "`define MN_M_ADRA(w) w[58:29]"),
]


def run(d: Path) -> str:
    vvp = d / "sim.vvp"
    cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", str(vvp), f"-I{d}", "-s", "tb_dec",
           str(d / "mn_dec_j.v"), str(d / "mn_dec_m.v"), str(TB)]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        return "COMPILE-ERROR " + (r.stdout + r.stderr)[:300]
    r = subprocess.run(["vvp", "-n", str(vvp)], capture_output=True, text=True, cwd=ROOT)
    v = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
    return v[-1] if v else "NO-VERDICT"


def main() -> int:
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        def fresh():
            for p in SRC.values():
                shutil.copy(p, tmp / p.name)

        fresh()
        base = run(tmp)
        print(f"baseline: {base}")
        ok &= base.startswith("PASS")
        for name, key, old, new in MUTANTS:
            fresh()
            p = tmp / SRC[key].name
            text = p.read_text(encoding="utf-8")
            if text.count(old) != 1:
                print(f"[stale] {name}: fragment found {text.count(old)} times")
                ok = False
                continue
            p.write_text(text.replace(old, new), encoding="utf-8")
            v = run(tmp)
            killed = v.startswith("FAIL")
            ok &= killed
            print(f"[{'killed' if killed else 'SURVIVED'}] {name}: {v}")
    print("PASS all mutants killed" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

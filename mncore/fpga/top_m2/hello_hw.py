#!/usr/bin/env python3
"""hello_world on the board across two function-specific bitstreams (WP37).

usage: python mncore/fpga/top_m2/hello_hw.py --mau-fs <top_mab .fs> --m2-fs <top_m2 .fs> [--split 4]
           [--program problems/challenge/21.hello-world/main.vsm] [--port COMx] [--log FILE] [--no-lock-check]

The M2 units (L1BM, L2BM, MV) and the vector MAU do not fit in one bitstream (WP37 report: with the MAU
the M2 design is LUT_eq 95 % of the GW2AR-18). hello_world needs both: its words 0..3 use the integer ALU
and the MAU (imm, idec, dvpassar, fvadd), its words 4..8 the L1BM, L2BM and MV units (l1bmrhfadd,
l2bmrhfadd, mvp). This runs the program on the board in two parts, with the architectural state handed
over by the host (mncore/wp/WP-3x.md: function-specific bitstreams):

  1. load the MAU bitstream (mn_top_mab, design 0x03, MAU = 1) into the SRAM; RESET; the words
     [0, split) into the instruction memory; RUN; read the state of PEs p0..p3 (GRF0, GRF1, LM0, LM1, T,
     OMR 1..15, BAR);
  2. load the M2 bitstream (mn_top_m2, design 0x04; its RESET clears the PEs, L1BM, L2BM and the
     DRAM / PDM); write that PE state back; the words [split, n) into the instruction memory; RUN; the
     program's d gets (and the M2 probe of the regression) -> ndmp records;
  3. compare like run.py --m2: with the official emulator (4096 PEs, cut to the implemented units) and
     with the Rust simulator on the reduced topology (the zero rule); a REPLICA bitstream (INFO flags bit
     7) is compared with the official only.

The hand-over carries what the host can read and write. It is exact when the words after the split read
no forwarding register ($aluf, $mauf, $lbf, $mreadf), $lbi, MV tag or DAR written before it; the script
checks the operand selectors of those words (ALU, MAU, L1BM) and stops otherwise.
The official run is the one of `python mncore/sim/regress/run.py --m2` (build/m2/<name>/official.asm).
Take the board lock first (contract 06 section 9).
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
import run as regress  # noqa: E402
import mnhost  # noqa: E402
import ndmp  # noqa: E402

regress.configure(4, m2=True)
LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")
PE_LOCS = [mnhost.loc_code(p=p) for p in range(4)]
PE_STATE = [("GRF0", 256), ("GRF1", 256), ("LM0", 256), ("LM1", 256), ("T", 8), ("BAR", 2)]


def field_pos() -> dict:
    text = (ROOT / "mncore" / "spec" / "isa" / "j_flat.yaml").read_text(encoding="utf-8")
    body = text.split("\nfields:", 1)[1]
    out = {}
    for m in re.finditer(r"^  - name: (\S+)\n    pos: (\d+)\n    width: (\d+)", body, flags=re.MULTILINE):
        out[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return out


def reads_forwarding(word: int, fp: dict) -> list[str]:
    """Operand selectors of a j word that read a forwarding register ($aluf $mauf $lbf $mreadf)."""
    def f(name):
        pos, w = fp[name]
        return regress.jfield(word, pos, w)
    if f("ll") & 1 == 0:
        return []
    out = []
    aluop = f("pe_aluc_aluop")
    if aluop != 0b11111 and f("pe_aluc_isela") in (11, 12, 13, 14):
        out.append(f"pe_aluc_isela {f('pe_aluc_isela')}")
    if aluop != 0b11111 and f("pe_aluc_iselb") >= 5:
        out.append(f"pe_aluc_iselb {f('pe_aluc_iselb')}")
    if f("pe_mauc_enfma") or f("pe_mauc_mw"):
        for k in ("pe_mauc_isela", "pe_mauc_iselb", "pe_mauc_iselc"):
            if f(k) >= 5:
                out.append(f"{k} {f(k)}")
    if f("l1bm_lwrite") and f("l1bm_isel") >= 5:
        out.append(f"l1bm_isel {f('l1bm_isel')}")
    return out


def program(fs: Path, log) -> None:
    r = subprocess.run(["openFPGALoader", "-b", "tangnano20k", str(fs)], capture_output=True, text=True)
    log(f"# openFPGALoader {fs.name}: rc {r.returncode}")
    if r.returncode:
        raise SystemExit(r.stdout + r.stderr)
    time.sleep(1.0)


def connect(port: str, baud: int, design: int):
    link = mnhost.Link.open(port, 1000000, timeout=0.2)
    dev = mnhost.Device(link)
    inf = dev.info()
    if inf.design_id != design:
        raise SystemExit(f"design 0x{inf.design_id:02x}, expected 0x{design:02x}")
    if baud and baud != 1000000:
        dev.set_baud(baud)
    return dev


def run_entries(dev, entries, log, what: str) -> mnhost.Status:
    dev.write_imem(0, entries)
    dev.run(0, len(entries))
    st = dev.wait_idle(60.0)
    log(f"# {what}: RUN {len(entries)} words: reason {st.reason_name} pc {st.pc} steps {st.steps} info {st.info}")
    return st


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mau-fs", required=True, help="the MAU bitstream (mncore/fpga/top_mab, MAU = 1)")
    ap.add_argument("--m2-fs", required=True, help="the M2 bitstream (mncore/fpga/top_m2)")
    ap.add_argument("--program", default="problems/challenge/21.hello-world/main.vsm")
    ap.add_argument("--split", type=int, default=4, help="first word of the M2 part")
    ap.add_argument("--port", default="auto")
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--log")
    ap.add_argument("--no-lock-check", action="store_true")
    a = ap.parse_args(argv)
    logf = open(a.log, "a", encoding="utf-8") if a.log else None

    def log(s=""):
        print(s, flush=True)
        if logf:
            logf.write(s + "\n")
            logf.flush()

    if not a.no_lock_check and not LOCK.exists():
        raise SystemExit(f"take the board lock first: {LOCK}")
    job = regress.BUILD / regress.prog_name(a.program)
    prog = mnhost.parse_asm((job / "official.asm").read_text(encoding="utf-8"))
    n = len(prog.entries)
    if any(pos < n for pos, _ in prog.events):
        raise SystemExit("the program has d / r lines before its end: not handled here")
    fp = field_pos()
    words = [(e >> 446, e & ((1 << 426) - 1)) for e in prog.entries]
    for i, (t, w) in enumerate(words[a.split:], a.split):
        if t == mnhost.IMEM_TYPE_J:
            bad = reads_forwarding(w, fp)
            if bad:
                raise SystemExit(f"word {i} reads state that is not handed over: {bad}")
    log(f"# hello_hw {time.strftime('%Y-%m-%d %H:%M:%S')}: {a.program}, {n} words, split at {a.split}")

    # ---- part 1: the MAU bitstream
    program(Path(a.mau_fs), log)
    dev = connect(a.port, a.baud, 0x03)
    inf = dev.info()
    log(f"# part 1: design 0x{inf.design_id:02x} flags 0x{inf.flags:02x} (MAU {(inf.flags >> 4) & 1})")
    dev.reset()
    st = run_entries(dev, prog.entries[:a.split], log, "part 1")
    if st.reason:
        raise SystemExit("part 1 stopped")
    state = {}
    for loc in PE_LOCS:
        for sp, depth in PE_STATE:
            state[(sp, loc)] = dev.read(mnhost.SPACES[sp], loc, 0, depth)
        state[("OMR", loc)] = dev.read(mnhost.SPACES["OMR"], loc, 1, 15)
    log(f"# part 1: read the state of p0..p3 ({sum(len(v) for v in state.values())} long words)")
    dev.set_baud(1000000)
    dev.link.ser.close()

    # ---- part 2: the M2 bitstream
    program(Path(a.m2_fs), log)
    dev = connect(a.port, a.baud, 0x04)
    inf = dev.info()
    replica = (inf.flags >> 7) & 1
    log(f"# part 2: design 0x{inf.design_id:02x} flags 0x{inf.flags:02x} (REPLICA {replica})")
    dev.reset()
    for (sp, loc), vals in state.items():
        dev.write(mnhost.SPACES[sp], loc, 1 if sp == "OMR" else 0, vals)
    st = run_entries(dev, prog.entries[a.split:], log, "part 2")
    if st.reason:
        raise SystemExit("part 2 stopped")
    # the d gets of the program (all at its end)
    rec = {}
    topo = mnhost.Topology(inf.topo)
    smap = mnhost.SpaceMap(inf)
    for _, d in prog.events:
        dep = smap.depth(d.space)
        for f in (topo.locations(d.space, d.loc) if dep else []):
            units = mnhost.get_units(d)
            vals = {}
            for run in mnhost._addr_runs(lw for _, _, lw, _ in units if lw is not None and lw < dep):
                sp, lc, a0 = smap.target(d.space, f, run[0])
                vals.update(zip(run, dev.read(sp, lc, a0, len(run))))
            lt = mnhost.loc_text(d.space, f)
            for space, addr, lw, how in units:
                if lw is None:
                    rec[(space, lt, addr)] = how
                elif lw in vals:
                    rec[(space, lt, addr)] = mnhost._unit_value(how, vals[lw])
    hw = ndmp.canonical((s, l, ad, v) for (s, l, ad), v in rec.items())
    (job / f"hw_hello{'_rep' if replica else ''}.ndmp").write_text(
        ndmp.dumps(hw, {"producer": "board mn_top_mab + mn_top_m2 (hello_hw.py)"}), encoding="utf-8")
    d0, d1 = hw.get(("DRAM", "n0", 0)), hw.get(("DRAM", "n0", 1))
    if d0 is not None and d1 is not None:
        text = (d0.to_bytes(8, "big") + d1.to_bytes(8, "big"))[:13]
        log(f"# DRAM n0 [0] {d0:016x} [1] {d1:016x}: {text!r}")
    off, _ = ndmp.read(str(job / "official.ndmp"))
    A = {k: v for k, v in off.items() if regress.keep_record(k)}
    B = {k: v for k, v in hw.items() if regress.keep_record(k)}
    m, oa, ob = regress.diff(A, B)
    log(f"# vs official (4096 PEs, cut): {len(A.keys() & B.keys())} compared, {len(m)} differ, {len(oa)} only "
        f"official, {len(ob)} only board")
    for k in (m + oa + ob)[:8]:
        log(f"#   {k[0]} {k[1]} {k[2]:#x} official={A.get(k, 0):016x} board={B.get(k, 0):016x}")
    rd, _ = ndmp.read(str(job / "rust.ndmp"))
    R = {k: v for k, v in rd.items() if regress.keep_record(k)}
    m2, oa2, ob2 = regress.diff(R, B)
    log(f"# vs Rust, reduced topology (zero rule): {len(R.keys() & B.keys())} compared, {len(m2)} differ, "
        f"{len(oa2)} only rust, {len(ob2)} only board")
    for k in (m2 + oa2 + ob2)[:8]:
        log(f"#   {k[0]} {k[1]} {k[2]:#x} rust={R.get(k, 0):016x} board={B.get(k, 0):016x}")
    ok = not (m or oa or ob) if replica else not (m2 or oa2 or ob2)
    log(f"# {'PASS' if ok else 'FAIL'}: the board equals the {'official emulator (replica rule)' if replica else 'reduced Rust simulator (zero rule)'}")
    try:
        dev.set_baud(1000000)
    except mnhost.ProtocolError:
        pass
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

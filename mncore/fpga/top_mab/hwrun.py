#!/usr/bin/env python3
"""Run corpus programs on the board (mn_top_mab, 4 PEs) and compare with the official emulator (WP30).

usage: python mncore/fpga/top_mab/hwrun.py [--all | --list FILE | PROGRAM ...] [--fpalu N] [--mau N]
           [--bfn N] [--baud 2000000] [--port COMx] [-o results.tsv] [--log FILE] [--no-lock-check]

Like mncore/fpga/top_1pe/hwrun.py (WP21), on the 4-PE design: for each program (a corpus path, as in
mncore/tools/golden/corpus.tsv) the official run of the 4-PE regression is used
(mncore/sim/regress/build/mab/<name>/: official.asm = the emulator's whole input with the probe of
PEs n0c0b0m0p0..p3, official.ndmp = its d get output; run `python mncore/sim/regress/run.py --pes 4`
first). official.asm is executed on the board with mnhost.execute_program (RESET, IMEM windows, RUN
split at the d lines, d set -> WR_MEM, d get -> RD_MEM of the 4 PEs of the INFO topology), and the
d get records are compared with official.ndmp on the 4 PEs like run.py --pes 4 does (LM0/LM1 up to 256
long words, GRF0/GRF1, the W forms, T, OMR).

Each program is classified pass / mismatch(...) / E_UNSUPPORTED <field> / E_RANGE / E_DECODE / error,
and checked against the RTL simulation of the same configuration (build/mab/results<tag>.tsv from
`run.py --pes 4 [--define TB_FPALU=<n>] [--define TB_MAU=<n>] [--define TB_BFN=<n>]`, defines in that
order, only those that differ from 1): "as rtl" when both agree. The units of the bitstream on the
board (FPALU / MAU / BFN of build.py) are read from the INFO flags (mn_top_mab: bits 3..2 FPALU, bit 4
MAU, bit 5 BFN); --fpalu / --mau / --bfn, when given, must agree with them. The board must be locked
first (contract 06 section 9): C:\\wgkz\\nano20k\\mncore\\.board.lock.
WP36: bit 6 of the flags is MAT (the matrix unit; the RTL table then has TB_MAT=1), and --matrix
takes the programs of `run.py --pes 4 --matrix` (table results<tag>_mat.tsv).
"""
from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
import run as regress  # noqa: E402  (also: goldenlib, ndmp, mnhost)
import mnhost  # noqa: E402
import ndmp  # noqa: E402

regress.configure(4)
LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")
DESIGN_ID = 0x03


def rtl_tag(fpalu: int, mau: int, bfn: int, mat: int = 0, matrix: bool = False) -> str:
    """the results<tag>.tsv of run.py for the configuration (defines in this order; WP36: TB_MAT=1
    for a bitstream with the matrix unit, and the suffix _mat for run.py --matrix)."""
    defs = []
    if fpalu != 1:
        defs.append(f"TB_FPALU={fpalu}")
    if mau != 1:
        defs.append(f"TB_MAU={mau}")
    if bfn != 1:
        defs.append(f"TB_BFN={bfn}")
    if mat:
        defs.append("TB_MAT=1")
    return "".join(f"_{d.replace('=', '')}" for d in defs) + ("_mat" if matrix else "")


def rtl_expectation(tag: str) -> dict:
    path = regress.BUILD / f"results{tag}.tsv"
    out = {}
    if path.exists():
        with open(path, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t"):
                out[r["path"]] = r
    return out


def corpus_rows(matrix: bool = False) -> dict:
    """pe1 = yes, or (matrix) the programs left out of pe1 only for the matrix group (run.py --matrix)."""
    rows = {}
    with open(ROOT / "mncore" / "tools" / "golden" / "corpus.tsv", encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            reasons = set(filter(None, r.get("pe1_reason", "").split(";")))
            if (reasons == {"groups:matrix"} and r.get("official") == "ok") if matrix else r.get("pe1") == "yes":
                rows[r["path"]] = r
    return rows


def run_one(dev, path: str, row: dict) -> dict:
    job = regress.BUILD / regress.prog_name(path)
    res = {"path": path, "groups": row.get("groups", ""), "words": "", "steps": 0, "compared": 0,
           "result": "", "detail": "", "seconds": 0.0}
    if regress.gl.read_status(job) != "ok":
        res["result"], res["detail"] = "official_fail", regress.gl.read_status(job)
        return res
    prog = mnhost.parse_asm((job / "official.asm").read_text(encoding="utf-8"))
    res["words"] = len(prog.entries)
    t0 = time.monotonic()
    r = mnhost.execute_program(dev, prog, mnhost.Topology(dev.info().topo), run_timeout=60.0)
    res["seconds"] = round(time.monotonic() - t0, 2)
    res["steps"] = r.stats["steps"]
    if r.stop is not None:
        st = r.stop
        entries = [("j" if (e >> 446) == mnhost.IMEM_TYPE_J else "m", e & ((1 << 426) - 1)) for e in prog.entries]
        idx = r.stop_entry if r.stop_entry is not None and r.stop_entry < len(entries) else None
        res["result"], what = regress.classify_stop(st.reason, st.info, entries[idx] if idx is not None else None)
        word = r.stats.get("e_range_word", idx)
        res["detail"] = (what + " " if what else "") + f"at word {word}"
        return res
    if r.stats["dropped"]:
        res["detail"] = f"{r.stats['dropped']} d set long words beyond the depth dropped; "
    hw = ndmp.canonical((s, l, a, v) for (s, l, a), v in r.records.items())
    off, _ = ndmp.read(str(job / "official.ndmp"))
    a = {k: v for k, v in off.items() if regress.keep_record(k)}
    b = {k: v for k, v in hw.items() if regress.keep_record(k)}
    mism = sorted(k for k in a.keys() & b.keys() if a[k] != b[k])
    only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))
    res["compared"] = len(a.keys() & b.keys())
    beyond = sum(1 for (s, l, ad), v in off.items()
                 if l in regress.PE_LOCS and s in ("LM0", "LM1") and ad >= regress.LM_LW and v)
    (job / "hw.ndmp").write_text(ndmp.dumps(hw, {"producer": "board mn_top_mab", "src": path}), encoding="utf-8")
    if mism or only_a or only_b:
        sp = sorted({k[0] for k in mism + only_a + only_b})
        res["result"] = "mismatch(" + ",".join(sp) + ")"
        res["detail"] += f"{len(mism)} differ, {len(only_a)} only official, {len(only_b)} only board"
        lines = [f"{k[0]} {k[1]} {k[2]:#06x} official={a.get(k, 0):016x} board={b.get(k, 0):016x}"
                 for k in (mism + only_a + only_b)[:20]]
        (job / "hw_cmp.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    elif beyond:
        res["result"] = "mismatch(LM beyond depth)"
        res["detail"] += f"{beyond} official LM long words beyond {regress.LM_LW} are not 0"
    else:
        res["result"] = "pass"
    return res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("programs", nargs="*")
    ap.add_argument("--all", action="store_true", help="every corpus program with pe1 = yes")
    ap.add_argument("--matrix", action="store_true",
                    help="WP36: --all means the programs of run.py --matrix (left out of pe1 only for the "
                         "matrix group); the RTL table is results<tag>_mat.tsv")
    ap.add_argument("--list", help="file with one corpus path per line ('#' comments)")
    ap.add_argument("--fpalu", type=int, help="FPALU of the loaded bitstream (default: from INFO)")
    ap.add_argument("--mau", type=int, help="MAU of the loaded bitstream (default: from INFO)")
    ap.add_argument("--bfn", type=int, help="BFN of the loaded bitstream (default: from INFO)")
    ap.add_argument("--port", default="auto")
    ap.add_argument("--baud", type=int, default=2000000, help="switch to this baud rate first (0: stay at 1M)")
    ap.add_argument("-o", "--output", help="results table (TSV)")
    ap.add_argument("--log", help="also append the console lines to this file")
    ap.add_argument("--no-lock-check", action="store_true")
    a = ap.parse_args(argv)

    logf = open(a.log, "a", encoding="utf-8") if a.log else None

    def log(s=""):
        print(s, flush=True)
        if logf:
            logf.write(s + "\n")
            logf.flush()

    if not a.no_lock_check and not LOCK.exists():
        raise SystemExit(f"take the board lock first: {LOCK} (WP number, start time)")
    rows = corpus_rows(a.matrix)
    paths = list(a.programs)
    if a.list:
        for line in Path(a.list).read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                paths.append(line)
    if a.all:
        paths += sorted(rows)
    if not paths:
        raise SystemExit("no programs (give paths, --list or --all)")

    link = mnhost.Link.open(a.port, 1000000, timeout=0.2)
    dev = mnhost.Device(link)
    inf = dev.info()
    if inf.design_id != DESIGN_ID:
        raise SystemExit(f"design id 0x{inf.design_id:02x}, expected 0x{DESIGN_ID:02x} (mn_top_mab)")
    units = {"fpalu": (inf.flags >> 2) & 3, "mau": (inf.flags >> 4) & 1, "bfn": (inf.flags >> 5) & 1}
    for k, v in units.items():
        given = getattr(a, k)
        if given is not None and given != v:
            raise SystemExit(f"--{k} {given}, but the bitstream has {k.upper()}={v} (INFO flags 0x{inf.flags:02x})")
        setattr(a, k, v)
    mat = (inf.flags >> 6) & 1   # WP36: the matrix unit
    tag = rtl_tag(a.fpalu, a.mau, a.bfn, mat, a.matrix)
    exp = rtl_expectation(tag)
    if a.baud and a.baud != 1000000:
        dev.set_baud(a.baud)
    inf = dev.info(refresh=True)
    log(f"# hwrun {time.strftime('%Y-%m-%d %H:%M:%S')}: design 0x{inf.design_id:02x}, {inf.clk_hz} Hz, "
        f"{inf.baud:.0f} baud, imem {inf.imem_depth}, topo {inf.topo}, FPALU={a.fpalu} MAU={a.mau} BFN={a.bfn} "
        f"MAT={mat}, "
        f"rtl table results{tag}.tsv ({len(exp)} rows), {len(paths)} programs")
    results = []
    t0 = time.monotonic()
    for i, p in enumerate(paths, 1):
        try:
            res = run_one(dev, p, rows.get(p, {}))
        except (mnhost.ProtocolError, mnhost.DeviceError) as e:
            res = {"path": p, "groups": rows.get(p, {}).get("groups", ""), "words": "", "steps": 0,
                   "compared": 0, "result": "error", "detail": str(e), "seconds": 0.0}
            dev.link.flush_input(0.1)
        e = exp.get(p)
        if e is None:
            res["vs_rtl"] = "no rtl result"
        else:
            same = (res["result"] == e["result"] and
                    (res["result"] == "pass" or res["detail"].split(" at word")[-1] == e["detail"].split(" at word")[-1]))
            res["vs_rtl"] = "as rtl" if same else f"rtl: {e['result']} {e['detail']}".strip()
        results.append(res)
        log(f"[{i}/{len(paths)}] {res['result']:<28} {res['vs_rtl']:<8} {res['words']!s:>4} words "
            f"{res['steps']:>4} steps {res['compared']:>5} lw {res['seconds']:>6.2f} s  {p} {res['detail']}")
    st = dev.status()
    log(f"# {len(paths)} programs in {time.monotonic() - t0:.0f} s; link: crc_err {st.crc_err} frame_err "
        f"{st.frame_err} overrun {st.overrun} timeout {st.timeout}, host retries {dev.link.stats['retries']}")
    npass = sum(1 for r in results if r["result"] == "pass")
    nas = sum(1 for r in results if r["vs_rtl"] == "as rtl")
    log(f"# pass {npass}/{len(results)} (board d get = official on PEs n0c0b0m0p0..p3); as the RTL simulation "
        f"{nas}/{len(results)}")
    if a.output:
        cols = ["path", "groups", "words", "steps", "compared", "result", "vs_rtl", "seconds", "detail"]
        with open(a.output, "w", encoding="utf-8", newline="\n") as f:
            f.write("\t".join(cols) + "\n")
            for r in results:
                f.write("\t".join(str(r[c]) for c in cols) + "\n")
    if a.baud and a.baud != 1000000:
        try:
            dev.set_baud(1000000)
        except mnhost.ProtocolError:
            pass
    return 0 if nas == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())

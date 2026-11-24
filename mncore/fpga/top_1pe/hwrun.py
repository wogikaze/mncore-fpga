#!/usr/bin/env python3
"""Run corpus programs on the board (mn_top_1pe) and compare with the official emulator (WP21).

usage: python mncore/fpga/top_1pe/hwrun.py [--all | --list FILE | PROGRAM ...] [--fpalu N]
           [--baud 2000000] [--port COMx] [-o results.tsv] [--log FILE] [--no-lock-check]

For each program (a corpus path, as in mncore/tools/golden/corpus.tsv) the official run of the WP20
regression is used (mncore/sim/regress/build/<name>/: official.asm = the emulator's whole input with the
probe of PE n0c0b0m0p0, official.ndmp = its d get output; run `python mncore/sim/regress/run.py` first).
official.asm is executed on the board with `mnhost.py run` (mnhost.execute_program: RESET, IMEM windows,
RUN split at the d lines, d set -> WR_MEM, d get -> RD_MEM of what the board implements), and the d get
records are compared with official.ndmp on PE n0c0b0m0p0 like run.py does (LM0/LM1 up to 512 long words,
GRF0/GRF1, the W forms, T, OMR; official LM data beyond 512 long words must be 0).

Each program is classified pass / mismatch(...) / E_UNSUPPORTED <field> / E_RANGE / E_DECODE / error, and
also checked against what the RTL simulation of the same configuration gave (build/results.tsv for
FPALU=1, build/results_TB_FPALU<N>.tsv otherwise): "as rtl" when both agree (a pass, or a stop at the same
word with the same reason). The board must be locked (contract 06 section 9):
C:\\wgkz\\nano20k\\mncore\\.board.lock must exist and name WP21.
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

LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")
DESIGN_ID = 0x02


def rtl_expectation(fpalu: int) -> dict:
    name = "results.tsv" if fpalu == 1 else f"results_TB_FPALU{fpalu}.tsv"
    path = regress.BUILD / name
    out = {}
    if path.exists():
        with open(path, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t"):
                out[r["path"]] = r
    return out


def corpus_rows() -> dict:
    rows = {}
    with open(ROOT / "mncore" / "tools" / "golden" / "corpus.tsv", encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if r.get("pe1") == "yes":
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
                 if l == regress.PE_LOC and s in ("LM0", "LM1") and ad >= regress.LM_LW and v)
    (job / "hw.ndmp").write_text(ndmp.dumps(hw, {"producer": "board mn_top_1pe", "src": path}), encoding="utf-8")
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
    ap.add_argument("--list", help="file with one corpus path per line ('#' comments)")
    ap.add_argument("--fpalu", type=int, default=0, help="FPALU of the loaded bitstream (for the RTL expectation)")
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

    if not a.no_lock_check:
        if not LOCK.exists() or "WP21" not in LOCK.read_text(encoding="utf-8", errors="replace"):
            raise SystemExit(f"take the board lock first: {LOCK} (WP21, start time)")
    rows = corpus_rows()
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
    exp = rtl_expectation(a.fpalu)

    link = mnhost.Link.open(a.port, 1000000, timeout=0.2)
    dev = mnhost.Device(link)
    inf = dev.info()
    if inf.design_id != DESIGN_ID:
        raise SystemExit(f"design id 0x{inf.design_id:02x}, expected 0x{DESIGN_ID:02x} (mn_top_1pe)")
    if a.baud and a.baud != 1000000:
        dev.set_baud(a.baud)
    inf = dev.info(refresh=True)
    log(f"# hwrun {time.strftime('%Y-%m-%d %H:%M:%S')}: design 0x{inf.design_id:02x}, {inf.clk_hz} Hz, "
        f"{inf.baud:.0f} baud, imem {inf.imem_depth}, topo {inf.topo}, FPALU={a.fpalu}, {len(paths)} programs")
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
    log(f"# pass {npass}/{len(results)} (board d get = official on PE n0c0b0m0p0); as the RTL simulation "
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

#!/usr/bin/env python3
"""Run corpus programs on the board (mn_top_m2, the M2 core) and compare them like run.py --m2 (WP37).

usage: python mncore/fpga/top_m2/hwrun.py [--all | --list FILE | PROGRAM ...] [--only TEXT] [--matrix]
           [--baud 2000000] [--port COMx] [-o results.tsv] [--log FILE] [--no-lock-check]

For each program (a corpus path, as in mncore/tools/golden/corpus.tsv) the runs of the M2 regression
are used (mncore/sim/regress/build/m2/<name>/: official.asm = the emulator's whole input with the M2
probe (PEs n0c0b0m0p0..p3, L1BM n0c0b0, L2BM n0c0, DRAM n0), official.ndmp = its d get output,
rust.ndmp = the Rust simulator on the reduced topology (the zero rule); run
`python mncore/sim/regress/run.py --m2` first). official.asm is executed on the board with
mnhost.execute_program (RESET: the core clears the PEs, L1BM, L2BM and the DRAM / PDM; IMEM windows,
RUN split at the d lines, d set / r lines -> WR_MEM, d get -> RD_MEM), and the d get records are compared
with the official (cut to the implemented units) and with the Rust run, like run.py --m2: pass b (the
official equals the reduced Rust run and the board equals both), pass c (they differ and the board
equals the Rust run: the zero rule), pass b (rust differs), mismatch, or the stop (E_UNSUPPORTED ...,
E_RANGE, "E_RANGE as rust"). With a REPLICA bitstream (INFO flags bit 7) the board is compared with the
official only (pass / mismatch).

The units of the bitstream are read from the INFO flags (design 0x04: bits 3..2 FPALU, bit 4 MAU, bit 5
BFN, bit 6 MAT, bit 7 REPLICA); "as rtl" compares with the RTL simulation of the same configuration
(build/m2/results<tag>.tsv of `run.py --m2 [--define TB_FPALU=<n>] [--define TB_MAU=0] [--define
TB_BFN=0] [--define TB_MAT=1] [--define TB_REPLICA=1]`, in that order, only those that differ from the
testbench defaults FPALU 1, MAU 1, BFN 1, MAT 0, REPLICA 0). The board must be locked first (contract
06 section 9): C:\\wgkz\\nano20k\\mncore\\.board.lock.
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

regress.configure(4, m2=True)
LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")
DESIGN_ID = 0x04


def rtl_tag(fpalu: int, mau: int, bfn: int, mat: int, replica: int) -> str:
    defs = []
    if fpalu != 1:
        defs.append(f"TB_FPALU={fpalu}")
    if mau != 1:
        defs.append(f"TB_MAU={mau}")
    if bfn != 1:
        defs.append(f"TB_BFN={bfn}")
    if mat:
        defs.append("TB_MAT=1")
    if replica:
        defs.append("TB_REPLICA=1")
    return "".join(f"_{d.replace('=', '')}" for d in defs)


def rtl_expectation(tag: str) -> dict:
    path = regress.BUILD / f"results{tag}.tsv"
    out = {}
    if path.exists():
        with open(path, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t"):
                out[r["path"]] = r
    return out


def corpus_rows(matrix: bool) -> dict:
    """The programs of run.py --m2 (left out of pe1 for the l1bm / l2bm / mv groups, also for their LM
    addresses; with matrix also those with the matrix group)."""
    rows = {}
    lm_only = {"lm_dyn", "lm_max>=256"}
    with open(ROOT / "mncore" / "tools" / "golden" / "corpus.tsv", encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            reasons = set(filter(None, r.get("pe1_reason", "").split(";")))
            groups, rest = set(), set()
            for x in reasons:
                if x.startswith("groups:"):
                    groups |= set(x.split(":", 1)[1].split("+"))
                else:
                    rest.add(x)
            allowed = {"l1bm", "l2bm", "mv"} | ({"matrix"} if matrix else set())
            if (r.get("official") == "ok" and groups and groups <= allowed and rest <= lm_only and
                    groups & {"l1bm", "l2bm", "mv"}):
                rows[r["path"]] = r
    return rows


def run_one(dev, path: str, row: dict, replica: bool) -> dict:
    job = regress.BUILD / regress.prog_name(path)
    res = {"path": path, "groups": row.get("groups", ""), "words": "", "steps": 0, "compared": 0,
           "result": "", "cls": "", "detail": "", "seconds": 0.0}
    if regress.gl.read_status(job) != "ok":
        res["result"] = res["cls"] = "official_fail"
        res["detail"] = regress.gl.read_status(job)
        return res
    prog = mnhost.parse_asm((job / "official.asm").read_text(encoding="utf-8"))
    res["words"] = len(prog.entries)
    t0 = time.monotonic()
    r = mnhost.execute_program(dev, prog, mnhost.Topology(dev.info().topo), run_timeout=120.0)
    res["seconds"] = round(time.monotonic() - t0, 2)
    res["steps"] = r.stats["steps"]
    rst = (job / "rust.status").read_text().strip() if (job / "rust.status").exists() else "missing"
    if r.stop is not None and r.stop.reason != 4:
        st = r.stop
        entries = [("j" if (e >> 446) == mnhost.IMEM_TYPE_J else "m", e & ((1 << 426) - 1)) for e in prog.entries]
        idx = r.stop_entry if r.stop_entry is not None and r.stop_entry < len(entries) else None
        res["result"], what = regress.classify_stop(st.reason, st.info, entries[idx] if idx is not None else None)
        word = r.stats.get("e_range_word", idx)
        res["detail"] = (what + " " if what else "") + f"at word {word}"
        res["cls"] = "E_RANGE as rust" if (st.reason == 1 and rst == f"range {word}" and not replica) else res["result"]
        return res
    if r.stop is not None:
        res["detail"] = f"WAIT at word {r.stats.get('wait_word')}; "
    hw = ndmp.canonical((s, l, a, v) for (s, l, a), v in r.records.items())
    off, _ = ndmp.read(str(job / "official.ndmp"))
    a = {k: v for k, v in off.items() if regress.keep_record(k)}
    b = {k: v for k, v in hw.items() if regress.keep_record(k)}
    (job / f"hw{'_rep' if replica else ''}.ndmp").write_text(
        ndmp.dumps(hw, {"producer": "board mn_top_m2", "src": path}), encoding="utf-8")
    mism, only_a, only_b = regress.diff(a, b)
    res["compared"] = len(a.keys() & b.keys())
    if mism or only_a or only_b:
        sp = sorted({k[0] for k in mism + only_a + only_b})
        res["result"] = "mismatch(" + ",".join(sp) + ")"
        res["detail"] += f"{len(mism)} differ, {len(only_a)} only official, {len(only_b)} only board"
    else:
        res["result"] = "pass"
    if replica:
        res["cls"] = res["result"]
        return res
    # the zero rule: also against the Rust simulator on the reduced topology (run.py m2_compare)
    tmp = {}
    regress.m2_compare(tmp, job, a, b, "_hw")
    res["cls"] = tmp.get("cls", res["result"])
    res["detail"] += f" rust {tmp.get('rust')} off_rust {tmp.get('off_rust')} vs_rust {tmp.get('vs_rust')}"
    return res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("programs", nargs="*")
    ap.add_argument("--all", action="store_true", help="every program of run.py --m2")
    ap.add_argument("--matrix", action="store_true", help="with --all: also the programs with the matrix group")
    ap.add_argument("--list", help="file with one corpus path per line ('#' comments)")
    ap.add_argument("--only", help="only paths that contain this text")
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
    if a.only:
        paths = [p for p in paths if a.only in p]
    if not paths:
        raise SystemExit("no programs (give paths, --list or --all)")

    link = mnhost.Link.open(a.port, 1000000, timeout=0.2)
    dev = mnhost.Device(link)
    inf = dev.info()
    if inf.design_id != DESIGN_ID:
        raise SystemExit(f"design id 0x{inf.design_id:02x}, expected 0x{DESIGN_ID:02x} (mn_top_m2)")
    fpalu, mau, bfn = (inf.flags >> 2) & 3, (inf.flags >> 4) & 1, (inf.flags >> 5) & 1
    mat, replica = (inf.flags >> 6) & 1, (inf.flags >> 7) & 1
    tag = rtl_tag(fpalu, mau, bfn, mat, replica)
    exp = rtl_expectation(tag)
    if a.baud and a.baud != 1000000:
        dev.set_baud(a.baud)
    inf = dev.info(refresh=True)
    log(f"# hwrun m2 {time.strftime('%Y-%m-%d %H:%M:%S')}: design 0x{inf.design_id:02x}, {inf.clk_hz} Hz, "
        f"{inf.baud:.0f} baud, imem {inf.imem_depth}, topo {inf.topo}, FPALU={fpalu} MAU={mau} BFN={bfn} "
        f"MAT={mat} REPLICA={replica}, rtl table results{tag}.tsv ({len(exp)} rows), {len(paths)} programs")
    results = []
    t0 = time.monotonic()
    for i, p in enumerate(paths, 1):
        try:
            res = run_one(dev, p, rows.get(p, {}), bool(replica))
        except (mnhost.ProtocolError, mnhost.DeviceError) as e:
            res = {"path": p, "groups": rows.get(p, {}).get("groups", ""), "words": "", "steps": 0,
                   "compared": 0, "result": "error", "cls": "error", "detail": str(e), "seconds": 0.0}
            dev.link.flush_input(0.1)
        e = exp.get(p)
        if e is None:
            res["vs_rtl"] = "no rtl result"
        else:
            ecls = e.get("cls", e["result"]) if not replica else e["result"]
            same = res["cls"] == ecls and (res["cls"].startswith("pass") or
                                           res["detail"].split(" at word")[-1][:12] == e["detail"].split(" at word")[-1][:12])
            res["vs_rtl"] = "as rtl" if same else f"rtl: {ecls} {e['detail']}".strip()
        results.append(res)
        log(f"[{i}/{len(paths)}] {res['cls']:<24} {res['vs_rtl']:<8} {res['words']!s:>4} words "
            f"{res['steps']:>5} steps {res['compared']:>5} lw {res['seconds']:>6.2f} s  {p} {res['detail']}")
    st = dev.status()
    log(f"# {len(paths)} programs in {time.monotonic() - t0:.0f} s; link: crc_err {st.crc_err} frame_err "
        f"{st.frame_err} overrun {st.overrun} timeout {st.timeout}, host retries {dev.link.stats['retries']}")
    npass = sum(1 for r in results if r["cls"].startswith("pass"))
    nas = sum(1 for r in results if r["vs_rtl"] == "as rtl")
    log(f"# pass {npass}/{len(results)} ({'official' if replica else 'official or the zero-rule Rust run'}); "
        f"as the RTL simulation {nas}/{len(results)}")
    if a.output:
        cols = ["path", "groups", "words", "steps", "compared", "result", "cls", "vs_rtl", "seconds", "detail"]
        with open(a.output, "w", encoding="utf-8", newline="\n") as f:
            f.write("\t".join(cols) + "\n")
            for r in results:
                f.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")
    if a.baud and a.baud != 1000000:
        try:
            dev.set_baud(1000000)
        except mnhost.ProtocolError:
            pass
    return 0 if nas == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())

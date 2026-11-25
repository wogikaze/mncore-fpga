#!/usr/bin/env python3
"""Run corpus programs on the board (mn_top_vpe, the virtual PEs) and compare them like run.py --vpe (WP34).

usage: python mncore/fpga/top_vpe/hwrun.py [--list FILE | PROGRAM ...] [--only TEXT] [--baud 2000000]
           [--port COMx] [-o results.tsv] [--log FILE] [--no-lock-check]

The configuration comes from INFO (design 0x06): the topology 1/1/1/N_MAB/4, the LM depth 2**LM_AW, the
units (the depths of the L1BM / L2BM spaces: all, the L1BM only, none) and the flags (bits 3..2 FPALU,
bit 4 MAU, bit 5 BFN, bit 7 REPLICA). For each program the runs of the regression `python mncore/sim/regress/run.py --vpe N_MAB
--lm-aw LM_AW` are used (mncore/sim/regress/build/vpe<N_MAB>_lm<LM_AW>/<name>/: official.asm = the
emulator's whole input with the 64-PE probe, official.ndmp, rust.ndmp = the Rust simulator on the reduced
topology). official.asm is executed on the board with mnhost.execute_program (RESET: the core clears the
VPE region, the DRAM / PDM and the units; IMEM windows, RUN split at the d lines, d set / r lines ->
WR_MEM, d get -> RD_MEM) and the d get records are compared with the official (cut to the implemented
units) and with the Rust run: pass b, pass c, mismatch or the stop, as run.py. "as rtl" compares with the
RTL simulation of the same configuration (build/vpe<N>_lm<A>/results<tag>.tsv of run.py --vpe N --lm-aw A
[--vpe-units 0|2] [--define TB_FPALU=<n>] [--define TB_MAU=0] [--define TB_BFN=0] [--define TB_REPLICA=1]).
The board must be locked first (contract 06 section 9): C:\\wgkz\\nano20k\\mncore\\.board.lock.
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
DESIGN_ID = 0x06


def rtl_tag(units: int, fpalu: int, mau: int, bfn: int, replica: int) -> str:
    """units: 1 all, 0 none, 2 the L1BM only (run.py --vpe-units)."""
    defs = []
    if fpalu != 1:
        defs.append(f"TB_FPALU={fpalu}")
    if mau != 1:
        defs.append(f"TB_MAU={mau}")
    if bfn != 1:
        defs.append(f"TB_BFN={bfn}")
    if replica:
        defs.append("TB_REPLICA=1")
    return {1: "", 0: "_TB_M20", 2: "_TB_L2MV0"}[units] + "".join(f"_{d.replace('=', '')}" for d in defs)


def rtl_expectation(tag: str) -> dict:
    path = regress.BUILD / f"results{tag}.tsv"
    out = {}
    if path.exists():
        with open(path, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t"):
                out[r["path"]] = r
    return out


def corpus_rows() -> dict:
    with open(ROOT / "mncore" / "tools" / "golden" / "corpus.tsv", encoding="utf-8") as f:
        return {r["path"]: r for r in csv.DictReader(f, delimiter="\t") if r.get("official") == "ok"}


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
    r = mnhost.execute_program(dev, prog, mnhost.Topology(dev.info().topo), run_timeout=600.0)
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
    tmp = {}
    regress.m2_compare(tmp, job, a, b, "_hw")
    res["cls"] = tmp.get("cls", res["result"])
    if not res["cls"].startswith("pass"):
        (job / "hw.ndmp").write_text(ndmp.dumps(hw, {"producer": "board mn_top_vpe", "src": path}),
                                     encoding="utf-8")
    res["detail"] += f" rust {tmp.get('rust')} off_rust {tmp.get('off_rust')} vs_rust {tmp.get('vs_rust')}"
    return res


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("programs", nargs="*")
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
    rows = corpus_rows()
    paths = list(a.programs)
    if a.list:
        for line in Path(a.list).read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                paths.append(line)
    if a.only:
        paths = [p for p in paths if a.only in p]
    if not paths:
        raise SystemExit("no programs (give paths or --list)")

    link = mnhost.Link.open(a.port, 1000000, timeout=0.2)
    dev = mnhost.Device(link)
    inf = dev.info()
    if inf.design_id != DESIGN_ID:
        raise SystemExit(f"design id 0x{inf.design_id:02x}, expected 0x{DESIGN_ID:02x} (mn_top_vpe)")
    n_mab = inf.topo[3]
    lm_lw = inf.space_depth.get(mnhost.SPACES["LM0"], 0)
    lm_aw = lm_lw.bit_length() - 1
    units = (1 if inf.space_depth.get(mnhost.SPACES["L2BM"], 0) > 0 else
             2 if inf.space_depth.get(mnhost.SPACES["L1BM"], 0) > 0 else 0)
    fpalu, mau, bfn, replica = (inf.flags >> 2) & 3, (inf.flags >> 4) & 1, (inf.flags >> 5) & 1, (inf.flags >> 7) & 1
    regress.configure_vpe(n_mab, lm_aw, units)
    tag = rtl_tag(units, fpalu, mau, bfn, replica)
    exp = rtl_expectation(tag)
    if a.baud and a.baud != 1000000:
        dev.set_baud(a.baud)
    inf = dev.info(refresh=True)
    log(f"# hwrun vpe {time.strftime('%Y-%m-%d %H:%M:%S')}: design 0x{inf.design_id:02x}, {inf.clk_hz} Hz, "
        f"{inf.baud:.0f} baud, imem {inf.imem_depth}, topo {inf.topo}, LM {lm_lw}, "
        f"units {['none', 'L1BM / L2BM / MV', 'L1BM'][units]}, "
        f"FPALU={fpalu} MAU={mau} BFN={bfn} REPLICA={replica}, rtl table {regress.BUILD.name}/results{tag}.tsv "
        f"({len(exp)} rows), {len(paths)} programs")
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
            f"{res['steps']:>5} steps {res['compared']:>6} lw {res['seconds']:>7.2f} s  {p} {res['detail']}")
    st = dev.status()
    log(f"# {len(paths)} programs in {time.monotonic() - t0:.0f} s; link: crc_err {st.crc_err} frame_err "
        f"{st.frame_err} overrun {st.overrun} timeout {st.timeout}, host retries {dev.link.stats['retries']}")
    npass = sum(1 for r in results if r["cls"].startswith("pass"))
    nas = sum(1 for r in results if r["vs_rtl"] == "as rtl")
    log(f"# pass {npass}/{len(results)} (official or the zero-rule Rust run); as the RTL simulation "
        f"{nas}/{len(results)}")
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

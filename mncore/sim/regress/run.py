#!/usr/bin/env python3
"""WP20 regression: the corpus programs comparable in the 1-PE mode, on the RTL core.

usage: python mncore/sim/regress/run.py [--only TEXT] [-j N] [--official-jobs N]
           [--skip-official] [--force-official] [--table FILE] [--keep]

1. official (WSL, cached in build/<name>/): every corpus.tsv row with pe1 = yes is composed like
   the golden tools do (goldenlib.load_program) with the probe "pe" (the whole state of PE
   n0c0b0m0p0 at the end) and run on the official assemble3 (flat, no packer) and emulator.
2. rtl: official.asm (the emulator's whole input) becomes a tb_core script with the steps of
   `mnhost.py run` (PROTOCOL.md section 6): load the instruction memory in windows of
   IMEM_DEPTH entries, RUN split at the d lines, d set -> WR_MEM, d get -> RD_MEM. Only
   PE n0c0b0m0p0 exists; d set / d get of other locations and spaces are skipped, `r` lines
   (DRAM data) too. The script runs on iverilog (tb_core, mn_core).
3. compare: the RTL's d get values become ndmp records like norm_gpfn3 makes them from the
   emulator's dump (word access -> LM0W.., T 2c+k, OMR entry*4+cycle), and are compared with
   official.ndmp on PE n0c0b0m0p0: LM0 LM1 GRF0 GRF1 (+ W forms) inside the implemented depth
   (LM 2**LM_AW, GRF 2**GRF_AW long words), T and OMR.

Each program is classified: pass, mismatch(<spaces>), E_UNSUPPORTED <field> (<what>),
E_RANGE, E_DECODE, timeout, error. Results: build/results.tsv (and --table FILE, a copy that
can be committed), and a summary by corpus group on stdout.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BUILD = HERE / "build"
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import goldenlib as gl  # noqa: E402
import ndmp  # noqa: E402
import mnhost  # noqa: E402
import simrun  # noqa: E402  (also puts OSS CAD Suite on PATH)

# must match tb_core / mn_core
IMEM_DEPTH = 512
LM_LW = 512      # 2**LM_AW long words
GRF_LW = 256     # 2**GRF_AW long words
PE_LOC = "n0c0b0m0p0"
PE_LOC_CODE = 0

SP_ID = {"LM0": 0x01, "LM1": 0x02, "GRF0": 0x03, "GRF1": 0x04, "T": 0x05, "OMR": 0x10}
WORD_SPACES = ("LM0", "LM1", "GRF0", "GRF1")
DEPTH_LW = {"LM0": LM_LW, "LM1": LM_LW, "GRF0": GRF_LW, "GRF1": GRF_LW, "T": 8}

D_RE = re.compile(r"^d\s+(set|get)([dfh]?)\s+(\S+)\s+(\d+)\s*(.*)$")
MEM_RE = re.compile(r"^\$(ll|l)?(omr|[rsmntbcpd])(\d*)((?:[ncbmp]\d+)*)$")


# --------------------------------------------------------------------------------------- fields
def field_names() -> list:
    """j field names by index (j_flat.yaml order)."""
    names = []
    text = (ROOT / "mncore" / "spec" / "isa" / "j_flat.yaml").read_text(encoding="utf-8")
    body = text.split("\nfields:", 1)[1]
    for m in re.finditer(r"^  - name: (\S+)", body, flags=re.MULTILINE):
        names.append(m.group(1))
    return names


FIELDS = field_names()
M_FIELDS = ["valid", "mmode", "tmode", "destid", "srcid", "dmode", "mvid", "indirect", "adra", "adrb",
            "nw", "priority"]


def jfield(word: int, pos: int, width: int) -> int:
    """Field at string position pos of a 426-bit j word (contract 06 section 2)."""
    return (word >> (426 - pos - width)) & ((1 << width) - 1)


# --------------------------------------------------------------------------------------- d lines
class DLine:
    def __init__(self, text: str):
        self.text = text.split("#", 1)[0].strip()
        m = D_RE.match(self.text)
        if not m:
            raise ValueError(f"cannot parse d line: {text}")
        self.op, self.dtype, mem, cnt, rest = m.groups()
        mm = MEM_RE.match(mem)
        if not mm:
            raise ValueError(f"cannot parse memory operand {mem!r}")
        pre, letter, addr, loc = mm.groups()
        self.count = int(cnt)
        self.addr = int(addr or 0)
        self.loc = {k: int(v) for k, v in re.findall(r"([ncbmp])(\d+)", loc)}
        if letter == "omr":
            self.space, self.width = "OMR", "w"
        else:
            self.space = mnhost.MEM_LETTER[letter]
            if letter in "rsmn":
                self.width = {None: "w", "l": "l", "ll": "ll"}[pre]
            elif letter in "tb":
                self.width = "ll" if pre == "ll" else "l"
            else:
                self.width = "l"
        self.payload = []
        if self.op == "set":
            self.payload = mnhost.parse_payload(rest)

    def on_pe(self) -> bool:
        """Whether this line touches PE n0c0b0m0p0 (the only PE of the 1-PE core)."""
        if self.space not in SP_ID:
            return False
        return bool(mnhost.Topology().locations(self.space if self.space != "OMR" else "T", self.loc))

    def mnhost_op(self) -> "mnhost.DOp":
        return mnhost.DOp(op=self.op, space=self.space, width=self.width, addr=self.addr, loc=self.loc,
                          count=self.count, payload=self.payload, text=self.text)


def parse_official_asm(text: str):
    entries, events, n_r = [], [], 0
    for ln, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        tag = line[0]
        if tag in "jm" and len(line) > 2 and line[1] == " ":
            bits = line[2:].strip()
            entries.append((tag, int(bits, 2)))
        elif tag == "d":
            events.append((len(entries), DLine(line)))
        elif tag == "r":
            n_r += 1    # DRAM data: there is no DRAM in the 1-PE core
        else:
            raise ValueError(f"line {ln}: unknown line {line[:30]!r}")
    return entries, events, n_r


# --------------------------------------------------------------------------------------- script
def get_reads(d: DLine):
    """(space id, first long word / entry, count) reads for a d get, inside the implemented depth."""
    if d.space == "OMR":
        ents = [e for e in range(d.addr, d.addr + d.count) if 1 <= e <= 15]
        return [(SP_ID["OMR"], e, 1) for e in ents]
    if d.space == "T":
        return [(SP_ID["T"], 0, 8)]
    if d.width == "w":
        lo, hi = d.addr >> 1, (d.addr + d.count - 1) >> 1
    else:
        per = 2 if d.width == "ll" else 1
        lo = d.addr >> 1
        hi = lo + d.count * per - 1
    hi = min(hi, DEPTH_LW[d.space] - 1)
    if hi < lo:
        return []
    return [(SP_ID[d.space], lo, hi - lo + 1)]


def set_writes(d: DLine):
    """(space id, long word, mask, value) writes for a d set on PE n0c0b0m0p0."""
    if d.space == "OMR":
        raise ValueError("d set of a mask register is not handled")
    out = []
    for lw, v, m in mnhost.long_words(d.mnhost_op()):
        if d.space in DEPTH_LW and lw >= DEPTH_LW[d.space]:
            raise ValueError(f"d set beyond the implemented depth: {d.text}")
        out.append((SP_ID[d.space], lw, m, v))
    return out


def make_script(entries, events):
    lines = ["C"]
    runs = []           # (first entry, count) of each X, in order
    gets = []           # (tag, DLine)
    win = {"base": None}

    def load_window(base):
        for k, (tag, word) in enumerate(entries[base:base + IMEM_DEPTH]):
            lines.append(f"I {k:x} {mnhost.imem_entry(tag, word):0112x}")
        win["base"] = base

    def run_range(a, b):
        while a < b:
            if win["base"] is None or not (win["base"] <= a < win["base"] + IMEM_DEPTH):
                load_window(a)
            n = min(b, win["base"] + IMEM_DEPTH) - a
            lines.append(f"X {a - win['base']:x} {n:x}")
            runs.append((a, n, win["base"]))
            a += n

    if entries:
        load_window(0)
    pc = 0
    for pos, d in events:
        if pos > pc:
            run_range(pc, pos)
            pc = pos
        if not d.on_pe():
            continue
        if d.op == "set":
            for sp, lw, m, v in set_writes(d):
                lines.append(f"W {sp:x} {PE_LOC_CODE:x} {lw:x} {m:x} {v:x}")
        else:
            tag = len(gets)
            gets.append((tag, d))
            for sp, lo, n in get_reads(d):
                lines.append(f"R {tag:x} {sp:x} {PE_LOC_CODE:x} {lo:x} {n:x}")
    if len(entries) > pc:
        run_range(pc, len(entries))
    lines.append("E")
    return "\n".join(lines) + "\n", runs, gets


def rtl_records(gets, reads):
    """ndmp records of the RTL's d gets, in program order (like norm_gpfn3 on the emulator dump)."""
    recs = []
    for tag, d in gets:
        sp = SP_ID[d.space]

        def lw_val(a):
            return reads.get((tag, sp, a))

        if d.space == "OMR":
            for e in range(d.addr, d.addr + d.count):
                for c in range(4):
                    if e == 0:
                        v = 15
                    elif e >= 16:
                        v = 15 if (e >> (3 - c)) & 1 else 0
                    else:
                        w = lw_val(e)
                        if w is None:
                            continue
                        v = (w >> (4 * c)) & 0xF
                    recs.append(("OMR", PE_LOC, e * 4 + c, v))
        elif d.space == "T":
            for i in range(d.count):
                c = (d.addr + i) % 4
                for k in range(2 if d.width == "ll" else 1):
                    w = lw_val(2 * c + k)
                    if w is not None:
                        recs.append(("T", PE_LOC, 2 * c + k, w))
        elif d.width == "w":
            for i in range(d.count):
                a = d.addr + i
                w = lw_val(a >> 1)
                if w is not None:
                    recs.append((d.space + "W", PE_LOC, a, (w >> 32) if a % 2 == 0 else w & 0xFFFFFFFF))
        else:
            per = 2 if d.width == "ll" else 1
            base = d.addr >> 1
            for i in range(d.count * per):
                w = lw_val(base + i)
                if w is not None:
                    recs.append((d.space, PE_LOC, base + i, w))
    return ndmp.canonical(recs)


def keep_record(key) -> bool:
    space, loc, addr = key
    if loc != PE_LOC:
        return False
    if space in DEPTH_LW:
        return addr < DEPTH_LW[space]
    if space.endswith("W") and space[:-1] in WORD_SPACES:
        return addr < 2 * DEPTH_LW[space[:-1]]
    return space == "OMR"


# --------------------------------------------------------------------------------------- official
def prog_name(path: str) -> str:
    return gl.safe_name(gl.MNCORE / path)


def official_stage(rows, jobs: int, force: bool, log):
    todo = []
    for r in rows:
        vsm = gl.MNCORE / r["path"]
        prog = gl.load_program(vsm, "auto", "pe")
        job = BUILD / prog_name(r["path"])
        key = hashlib.sha1("\0".join([prog.prefix, prog.main_vsm, prog.suffix_vsm, prog.output,
                                      prog.probe_text]).encode()).hexdigest()
        kf = job / "key.txt"
        if (not force and gl.read_status(job) == "ok" and kf.exists() and kf.read_text().strip() == key
                and (job / "official.asm").exists()):
            continue
        gl.write_official_job(prog, job)
        kf.write_text(key + "\n")
        todo.append(job)
    if todo:
        log(f"[official] {len(todo)} programs to run in WSL ({jobs} in parallel)")
        t = time.time()
        n = [0]

        def on_line(s):
            n[0] += 1
            if n[0] % 25 == 0 or not s.startswith("ok"):
                log(f"[official] {n[0]}/{len(todo)} {s}")
        gl.run_official_jobs(todo, parallel=jobs, keep=True, on_line=on_line)
        log(f"[official] done in {time.time() - t:.0f} s")


# --------------------------------------------------------------------------------------- rtl
def compile_tb(log, defines=()) -> Path:
    files, cfg = simrun.parse_files("core")
    vvp = BUILD / ("sim" + "".join(f"_{d.replace('=', '')}" for d in defines) + ".vvp")
    cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", str(vvp)]
    cmd += [f"-D{d}" for d in defines]
    cmd += [f"-I{d}" for d in cfg["incdir"]] + ["-s", cfg["top"]] + files
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("iverilog failed")
    log("[rtl] compiled tb_core")
    return vvp


def classify_stop(reason: int, info: int, entry_word):
    if reason == 1:
        return "E_RANGE", f"word {info}"
    if reason == 3:
        return "E_DECODE", f"info {info:#x}"
    if info & 0x80:
        name = M_FIELDS[info & 0x7F] if (info & 0x7F) < len(M_FIELDS) else str(info)
        return f"E_UNSUPPORTED m.{name}", "MV instruction"
    name = FIELDS[info] if info < len(FIELDS) else str(info)
    what = ""
    if entry_word is not None:
        tag, w = entry_word
        if tag == "j":
            aluop = jfield(w, 147, 5)
            iselb = jfield(w, 159, 3)
            if name == "pe_aluc_aluop":
                what = {0b10001: "msl", 0b10010: "msr"}.get(aluop, "")
                if aluop == 0b11101:
                    what = "bfe"
                elif aluop == 0b11110 and (iselb >> 1) != 0b11:
                    what = "bfn"
            elif name == "pe_mauc_mmode":
                what = "matrix MAU"
            elif name == "pe_mauc_mw":
                what = "?mwrite"
    return f"E_UNSUPPORTED {name}", what


def run_one(row, vvp: Path, timeout: int, keep: bool):
    name = prog_name(row["path"])
    job = BUILD / name
    res = {"path": row["path"], "groups": row["groups"], "kind": row["kind"], "result": "", "detail": "",
           "words": "", "steps": 0, "clocks": 0, "compared": 0, "seconds": 0.0}
    status = gl.read_status(job)
    if status != "ok":
        res["result"], res["detail"] = "official_fail", status
        return res
    t0 = time.time()
    try:
        entries, events, n_r = parse_official_asm((job / "official.asm").read_text(encoding="utf-8"))
        script, runs, gets = make_script(entries, events)
    except ValueError as e:
        res["result"], res["detail"] = "script_error", str(e)
        return res
    res["words"] = len(entries)
    (job / "rtl.scr").write_text(script, encoding="utf-8", newline="\n")
    try:
        r = subprocess.run(["vvp", "-n", str(vvp), f"+script={(job / 'rtl.scr').as_posix()}", "+quiet"],
                           cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        res["result"], res["detail"] = "timeout", f"{timeout} s"
        return res
    out = r.stdout
    if keep:
        (job / "rtl.out").write_text(out, encoding="utf-8", newline="\n")
    reads = {}
    stops = []
    for line in out.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "D":
            reads[(int(p[1], 16), int(p[2], 16), int(p[3], 16))] = int(p[4], 16)
        elif p[0] == "S":
            stops.append(p[1:])
        elif p[0] in ("ERR", "DERR") or line.startswith("mn_pe_core: ERROR") or line.startswith("FAIL"):
            res["detail"] += (" | " if res["detail"] else "") + line.strip()
    res["seconds"] = round(time.time() - t0, 2)
    # stop records, in RUN order
    for (first, n, base), st in zip(runs, stops):
        if st[0] == "TIMEOUT":
            res["result"] = "timeout"
            return res
        reason, info, pc, steps = (int(x, 16) for x in st[:4])
        res["steps"] += steps
        res["clocks"] += int(st[5])
        if reason != 0:
            # pc is the entry of the loaded window
            idx = base + pc if base + pc < len(entries) else None
            entry = entries[idx] if idx is not None else None
            res["result"], what = classify_stop(reason, info, entry)
            res["detail"] = (what + " " if what else "") + f"at word {idx}"
            return res
    if len(stops) < len(runs):
        res["result"] = "error"
        res["detail"] = (res["detail"] + " | " if res["detail"] else "") + "missing stop records"
        return res
    if r.returncode != 0 or res["detail"]:
        res["result"] = "error"
        return res
    rtl = rtl_records(gets, reads)
    off, _ = ndmp.read(str(job / "official.ndmp"))
    a = {k: v for k, v in off.items() if keep_record(k)}
    b = {k: v for k, v in rtl.items() if keep_record(k)}
    ndmp.write(str(job / "rtl.ndmp"), rtl, {"producer": "rtl tb_core", "src": row["path"]})
    mism = sorted(k for k in a.keys() & b.keys() if a[k] != b[k])
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    res["compared"] = len(a.keys() & b.keys())
    # the program must not use LM beyond the implemented depth (the RTL would trap)
    beyond = sum(1 for (s, l, ad), v in off.items() if l == PE_LOC and s in ("LM0", "LM1") and ad >= LM_LW and v)
    if mism or only_a or only_b:
        sp = Counter(k[0] for k in mism + only_a + only_b)
        res["result"] = "mismatch(" + ",".join(sorted(sp)) + ")"
        lines = [f"{k[0]} {k[1]} {k[2]:#06x} official={a.get(k, 0):016x} rtl={b.get(k, 0):016x}"
                 for k in (mism + only_a + only_b)[:20]]
        (job / "cmp.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        res["detail"] = f"{len(mism)} differ, {len(only_a)} only official, {len(only_b)} only rtl"
    elif beyond:
        res["result"] = "mismatch(LM beyond depth)"
        res["detail"] = f"{beyond} official LM long words beyond {LM_LW} are not 0"
    else:
        res["result"] = "pass"
    return res


# --------------------------------------------------------------------------------------- main
def group_of(row) -> str:
    g = row["groups"]
    if g in ("", "-"):
        return "d set/get only"
    return g


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="only programs whose path contains this text")
    ap.add_argument("-j", "--jobs", type=int, default=8, help="parallel RTL simulations")
    ap.add_argument("--official-jobs", type=int, default=12)
    ap.add_argument("--skip-official", action="store_true", help="use the cached official results only")
    ap.add_argument("--force-official", action="store_true")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds per RTL simulation")
    ap.add_argument("--table", help="also write the results table here (TSV)")
    ap.add_argument("--keep", action="store_true", help="keep the simulator output (build/<name>/rtl.out)")
    ap.add_argument("--vvp", help="use this compiled tb_core instead of compiling one (e.g. a mutated RTL)")
    ap.add_argument("--define", action="append", default=[],
                    help="iverilog define for tb_core, e.g. TB_FPALU=0 or TB_MAU=0 (reduced cores)")
    a = ap.parse_args(argv)

    def log(s):
        print(s, flush=True)

    BUILD.mkdir(parents=True, exist_ok=True)
    rows = []
    with open(ROOT / "mncore" / "tools" / "golden" / "corpus.tsv", encoding="utf-8") as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(head, line.rstrip("\n").split("\t")))
            if r.get("pe1") == "yes" and (not a.only or a.only in r["path"]):
                rows.append(r)
    log(f"[regress] {len(rows)} programs with pe1 = yes")
    if not a.skip_official:
        official_stage(rows, a.official_jobs, a.force_official, log)
    vvp = Path(a.vvp).resolve() if a.vvp else compile_tb(log, a.define)
    t0 = time.time()
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(run_one, r, vvp, a.timeout, a.keep): r for r in rows}
        for i, fu in enumerate(cf.as_completed(futs), 1):
            res = fu.result()
            results.append(res)
            if res["result"] != "pass" or i % 25 == 0:
                log(f"[rtl] {i}/{len(rows)} {res['result']:<24} {res['path']} {res['detail']}")
    log(f"[rtl] {len(rows)} programs in {time.time() - t0:.0f} s")
    results.sort(key=lambda r: r["path"])
    cols = ["path", "kind", "groups", "words", "steps", "clocks", "compared", "result", "detail"]
    text = "\t".join(cols) + "\n" + "".join("\t".join(str(r[c]) for c in cols) + "\n" for r in results)
    tag = "".join(f"_{d.replace('=', '')}" for d in a.define)
    (BUILD / f"results{tag}.tsv").write_text(text, encoding="utf-8", newline="\n")
    if a.table:
        Path(a.table).write_text(text, encoding="utf-8", newline="\n")

    # summary: result class by corpus group
    by = defaultdict(Counter)
    for r in results:
        res = r["result"]
        cls = res.split("(")[0] if res.startswith("mismatch") else res
        by[group_of(r)][cls] += 1
    classes = sorted({c for g in by.values() for c in g}, key=lambda c: (c != "pass", c))
    log("")
    log("group\t" + "\t".join(classes) + "\ttotal")
    for g in sorted(by):
        log(g + "\t" + "\t".join(str(by[g][c]) for c in classes) + f"\t{sum(by[g].values())}")
    tot = Counter(r["result"].split("(")[0] if r["result"].startswith("mismatch") else r["result"] for r in results)
    log("all\t" + "\t".join(str(tot[c]) for c in classes) + f"\t{len(results)}")
    reasons = Counter((r["result"], r["detail"].split(" at word")[0]) for r in results if r["result"] != "pass")
    if reasons:
        log("")
        for (res, det), n in sorted(reasons.items(), key=lambda x: -x[1]):
            log(f"{n:4d}  {res}  {det}")
    npass = tot["pass"]
    log(f"\nPASS {npass}/{len(results)}" if npass == len(results) else f"\n{npass}/{len(results)} pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())

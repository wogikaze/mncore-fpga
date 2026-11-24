#!/usr/bin/env python3
"""Runs the whole corpus on the official emulator and on the Rust simulator and compares the ndmps.

usage: python mncore/tools/golden/sweep.py [-j N] [--rust-jobs N] [--probe wide] [--filter REGEX]
           [--limit N] [--keep] [--timeout SEC] [-o conformance.tsv]

Each program is composed and run exactly as run_official.py / run_rust.py do (same goldenlib
functions, same default probe), in mncore/tools/golden/build/sweep/<name>/. The official runs go
to WSL in one batch (wsl_official.sh, N in parallel); the Rust runs go in parallel on this side.
A program whose two sides both succeed is compared with ndiff's comparison (all lines, nothing
filtered). The ndmps of matching programs are deleted unless --keep.

conformance.tsv columns:
  path kind testcase official rust words_official words_rust compared mismatches only_official
  only_rust diff_spaces result note
result is match, MISMATCH (values or line sets differ, or the word counts differ) or skip (one
side failed); diff_spaces lists the spaces with differences. Then run corpus.py to merge the
results into corpus.tsv. ``--recompare`` redoes only the comparison of the MISMATCH rows from the
kept ndmps.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, str(Path(__file__).resolve().parent))
import corpus  # noqa: E402
import goldenlib as gl  # noqa: E402
import ndiff  # noqa: E402
import ndmp  # noqa: E402

COLUMNS = ["path", "kind", "testcase", "official", "rust", "words_official", "words_rust", "compared",
           "mismatches", "only_official", "only_rust", "diff_spaces", "result", "note"]


class Sweep:
    def __init__(self, files: List[Path], probe: str, keep: bool, rust_jobs: int, timeout: int) -> None:
        self.files = files
        self.probe = probe
        self.keep = keep
        self.rust_jobs = rust_jobs
        self.timeout = timeout
        self.root = gl.BUILD / "sweep"
        self.jobs: Dict[Path, Path] = {}  # job dir -> vsm
        self.by_wsl: Dict[str, Path] = {}  # job dir as wsl_official.sh prints it -> job dir
        self.rows: Dict[Path, Dict[str, str]] = {}
        self.rust: Dict[Path, gl.RustResult] = {}
        self.off_done: Dict[Path, str] = {}
        self.lock = threading.Lock()
        self.finished = 0
        self.t0 = time.time()

    def prepare(self) -> None:
        for f in self.files:
            prog = gl.load_program(f, "auto", self.probe)
            job = self.root / gl.safe_name(f)
            gl.write_official_job(prog, job)
            (job / "rust.ndmp").unlink(missing_ok=True)
            self.jobs[job] = f
            self.by_wsl[gl.wsl_path_arg(job)] = job
            self.rows[job] = {
                "path": corpus.corpus_rel(f),
                "kind": prog.kind,
                "testcase": "-" if prog.kind == "testcase" else corpus.corpus_rel(prog.testcase),
            }

    def run_rust(self, job: Path) -> None:
        f = self.jobs[job]
        prog = gl.load_program(f, "auto", self.probe)
        res = gl.run_rust_program(prog, threads=1, timeout=self.timeout)
        if res.status == "ok":
            meta = dict(prog.meta)
            meta["producer"] = "rust"
            res.write(job / "rust.ndmp", meta)
            res.body = ""
        with self.lock:
            self.rust[job] = res
            ready = job in self.off_done
        if ready:
            self.finalize(job)

    def on_official(self, line: str) -> None:
        m = re.match(r"^(.*) (/\S+)$", line)
        if not m:
            if line.strip():
                print(f"[wsl] {line}", file=sys.stderr)
            return
        status, wjob = m.groups()
        job = self.by_wsl.get(wjob)
        if job is None:
            print(f"[wsl] unknown job {wjob}", file=sys.stderr)
            return
        with self.lock:
            self.off_done[job] = status
            ready = job in self.rust
        if ready:
            self.finalize(job)

    def finalize(self, job: Path) -> None:
        row = self.rows[job]
        off = gl.read_status(job)
        res = self.rust[job]
        row["official"] = off
        row["rust"] = res.status
        wo = job / "words.txt"
        row["words_official"] = wo.read_text().strip() if wo.exists() else "-"
        row["words_rust"] = "-" if res.words is None else str(res.words)
        row.update(compared="-", mismatches="-", only_official="-", only_rust="-", diff_spaces="-", note="")
        if off == "ok" and res.status == "ok":
            ok = compare_job(job, row)
            if ok and not self.keep:
                (job / "official.ndmp").unlink(missing_ok=True)
                (job / "rust.ndmp").unlink(missing_ok=True)
        else:
            row["result"] = "skip"
            if off != "ok":
                log = job / "official.log"
                msg = log.read_text(encoding="utf-8", errors="replace").strip() if log.exists() else ""
                row["note"] = "official: " + first_line(msg)
            if res.status != "ok":
                row["note"] = "; ".join(filter(None, [row["note"], "rust: " + first_line(res.message)]))
            if not self.keep:
                (job / "official.ndmp").unlink(missing_ok=True)
                (job / "rust.ndmp").unlink(missing_ok=True)
        with self.lock:
            self.finished += 1
            n = self.finished
        if row["result"] != "match" or n % 50 == 0:
            print(f"[{n}/{len(self.jobs)} {time.time() - self.t0:.0f}s] {row['result']:8} {row['path']}"
                  f"  off={off} rust={res.status} {row['note'][:160]}", file=sys.stderr)

    def run(self, parallel: int) -> None:
        jobs = list(self.jobs)
        pool = ThreadPoolExecutor(max_workers=self.rust_jobs)
        # Big programs first on both sides, so that the long ones do not end up last.
        order = sorted(jobs, key=lambda j: -self.size_hint(j))
        futs = [pool.submit(self.run_rust, j) for j in order]
        rc = gl.run_official_jobs(order, parallel=parallel, keep=False, timeout=self.timeout,
                                  on_line=self.on_official)
        for fu in futs:
            fu.result()
        pool.shutdown()
        if rc != 0:
            print(f"warning: wsl_official.sh exited with {rc}", file=sys.stderr)
        # Jobs whose progress line was lost still get a row.
        for j in jobs:
            if j not in self.off_done:
                with self.lock:
                    self.off_done[j] = gl.read_status(j)
                self.finalize(j)

    def size_hint(self, job: Path) -> int:
        f = self.jobs[job]
        tc = self.rows[job]["testcase"]
        size = f.stat().st_size
        if tc != "-":
            size += (gl.MNCORE / tc).stat().st_size
        return size


def compare_job(job: Path, row: Dict[str, str]) -> bool:
    """Compares job/official.ndmp with job/rust.ndmp and the word counts; fills the comparison
    columns of ``row``. True when everything agrees."""
    la, lb = body_lines(job / "official.ndmp"), body_lines(job / "rust.ndmp")
    if la == lb:  # both are canonical, so equal line lists mean equal dumps
        mism, only_a, only_b, n = [], [], [], len(la)
        a = b = {}
    else:
        a = ndmp.canonical(ndmp.parse_line(x) for x in la)
        b = ndmp.canonical(ndmp.parse_line(x) for x in lb)
        mism, only_a, only_b, n = ndiff.compare(a, b)
    del la, lb
    spaces = sorted({k[0] for k in mism + only_a + only_b})
    row.update(compared=str(n), mismatches=str(len(mism)), only_official=str(len(only_a)),
               only_rust=str(len(only_b)), diff_spaces=",".join(spaces) or "-")
    notes = []
    if spaces == ["PDM"]:
        notes.append("PDM only: the official `d get $p` prints DRAM (testdata/pdm_dget.vsm)")
    if mism:
        k = mism[0]
        notes.append(f"first {ndmp.format_line(*k, a[k]).rsplit(' ', 1)[0]} "
                     f"official={a[k]:016x} rust={b[k]:016x}")
    for tag, keys in (("only_official", only_a), ("only_rust", only_b)):
        if keys:
            notes.append(f"{tag} e.g. {ndmp.format_line(*keys[0], 0).rsplit(' ', 1)[0]}")
    words_ok = row["words_official"] == row["words_rust"]
    if not words_ok:
        notes.append(f"words differ official={row['words_official']} rust={row['words_rust']}")
    ok = not mism and not only_a and not only_b and words_ok
    row["result"] = "match" if ok else "MISMATCH"
    row["note"] = "; ".join(notes)
    return ok


def recompare(path: Path) -> None:
    """Re-runs the comparison of the MISMATCH rows of an existing conformance.tsv from the kept
    ndmps (after a change of the comparison or the notes), and rewrites the file."""
    rows = list(csv.DictReader(open(path, encoding="utf-8", newline=""), delimiter="\t"))
    for r in rows:
        r.setdefault("diff_spaces", "-")
        if r["result"] != "MISMATCH":
            continue
        job = gl.BUILD / "sweep" / gl.safe_name(gl.MNCORE / r["path"])
        if (job / "official.ndmp").exists() and (job / "rust.ndmp").exists():
            compare_job(job, r)
        else:
            print(f"recompare: ndmps of {r['path']} are gone, row kept", file=sys.stderr)
    write_rows(path, rows)


def write_rows(path: Path, rows: List[Dict[str, str]]) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\t".join(COLUMNS) + "\n")
        for r in sorted(rows, key=lambda r: r["path"]):
            f.write("\t".join(str(r.get(c, "-")).replace("\t", " ") for c in COLUMNS) + "\n")


def body_lines(path: Path) -> List[str]:
    with open(path, encoding="utf-8") as f:
        return [line.rstrip("\n") for line in f if line.strip() and not line.startswith("#")]


def first_line(s: str) -> str:
    for line in s.splitlines():
        line = line.strip()
        if line:
            return line[:200]
    return ""


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-j", "--jobs", type=int, default=10, help="parallel official runs in WSL (default 10)")
    ap.add_argument("--rust-jobs", type=int, default=6, help="parallel Rust runs (default 6)")
    ap.add_argument("--probe", default=gl.DEFAULT_PROBE, choices=gl.PROBES)
    ap.add_argument("--filter", help="regex on the path below third_party/mncore")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--keep", action="store_true", help="keep the ndmps of matching programs")
    ap.add_argument("--timeout", type=int, default=1800, help="per program and side, seconds")
    ap.add_argument("-o", "--out", default=str(gl.GOLDEN_DIR / "conformance.tsv"))
    ap.add_argument("--recompare", action="store_true",
                    help="only redo the comparison of the MISMATCH rows of --out from the kept ndmps")
    a = ap.parse_args(argv)

    if a.recompare:
        recompare(Path(a.out))
        return 0
    files = corpus.list_corpus()
    if a.filter:
        files = [f for f in files if re.search(a.filter, corpus.corpus_rel(f))]
    if a.limit:
        files = files[: a.limit]
    exe = gl.build_rust()
    print(f"sweep: {len(files)} programs, probe={a.probe}, golden_dump={exe}", file=sys.stderr)
    sw = Sweep(files, a.probe, a.keep, a.rust_jobs, a.timeout)
    sw.prepare()
    sw.run(a.jobs)

    rows = sorted(sw.rows.values(), key=lambda r: r["path"])
    write_rows(Path(a.out), rows)
    counts: Dict[str, int] = {}
    for r in rows:
        counts[r["result"]] = counts.get(r["result"], 0) + 1
    print(f"sweep: {len(rows)} programs in {time.time() - sw.t0:.0f}s: "
          + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + f" -> {a.out}")
    return 1 if counts.get("MISMATCH") else 0


if __name__ == "__main__":
    sys.exit(main())

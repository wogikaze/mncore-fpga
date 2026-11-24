#!/usr/bin/env python3
"""Round-trip check of mnisa against assemble3 over every .vsm of third_party/mncore.

    python mncore/tools/mnisa/verify_corpus.py                 assemble (first time) and verify
    python mncore/tools/mnisa/verify_corpus.py --reassemble    force a fresh assembly
    python mncore/tools/mnisa/verify_corpus.py --report out.json
    python mncore/tools/mnisa/verify_corpus.py --cross-check-auto-stride

For every source that assemble3 accepts (flat, packer disabled) and for every j / m word:
  1. the CSV columns concatenate to the .asm word (property of assemble3),
  2. the CSV columns have the schema widths, and decode(word)[field] == CSV value for every field,
  3. encode(decode(word)) == word,
  4. imm words: the payload replicas equal the primary segment,
  5. (--cross-check-auto-stride) for sources accepted in both modes, every j field with a csv_name
     equals the auto_stride column of that header name.
Sources that assemble3 rejects are excluded and counted. Exit status 0 iff there is no mismatch.

The assembled output is cached in mncore/tools/mnisa/build/corpus (git-ignored). Calling assemble3
needs WSL (Windows) or bash with assemble3 at $ASSEMBLE3 / ~/wgkz/mncore/judge/... (Linux).
"""
from __future__ import annotations

import argparse
import collections
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from mnisa import assembler, codec, csv_import, schema  # noqa: E402
from mnisa.asm_io import read_asm  # noqa: E402

REPO = HERE.parents[2]
DEFAULT_ROOT = REPO / "third_party" / "mncore"
DEFAULT_CACHE = HERE / "build" / "corpus"


def find_sources(root: Path) -> list[str]:
    return sorted(p.relative_to(root).as_posix() for p in root.rglob("*.vsm") if ".git" not in p.parts)


def assemble(root: Path, files: list[str], cache: Path, jobs: int | None, modes: str) -> None:
    cache.mkdir(parents=True, exist_ok=True)
    out = cache / "out"
    out.mkdir(exist_ok=True)
    for old in out.iterdir():
        old.unlink()
    lst = cache / "list.txt"
    with open(lst, "w", encoding="utf-8", newline="\n") as fh:
        for i, rel in enumerate(files):
            fh.write(f"{i:04d}\t{assembler.to_wsl_path(root / rel)}\n")
    t = time.time()
    r = assembler.run_script(lst, out, modes, jobs)
    if r.returncode:
        sys.exit(f"assemble_corpus.sh failed ({r.returncode}): {r.stderr.strip()[:1000]}")
    (cache / "files.tsv").write_text("".join(f"{i:04d}\t{rel}\n" for i, rel in enumerate(files)), encoding="utf-8")
    print(f"assembled {len(files)} sources ({modes}) in {time.time() - t:.0f} s", flush=True)


def cache_ok(cache: Path, files: list[str], tags=("flat",)) -> bool:
    tsv = cache / "files.tsv"
    if not tsv.exists():
        return False
    listed = [ln.split("\t", 1)[1] for ln in tsv.read_text(encoding="utf-8").splitlines() if ln]
    return listed == files and all((cache / "out" / f"{i:04d}.{t}.rc").exists()
                                   for i in range(len(files)) for t in tags)


def cross_check_auto_stride(flat_csv: Path, as_csv: Path, rel: str, st: "Stats") -> None:
    """Fields with a csv_name must equal the auto_stride column of that name (same source, both modes).

    This is how the flat columns got their names: the j row is not in the CSV header order.
    """
    fj = [r for r in csv_import.read_csv(flat_csv).words(("j",))]
    af = csv_import.read_csv(as_csv)
    ai = af.words(("i",))
    if len(fj) != len(ai):
        st.as_skipped += 1
        return
    named = [f for f in schema.load("j").fields if f.csv_name]
    for n, (j, i) in enumerate(zip(fj, ai)):
        dj = csv_import.to_fields(j)
        di = csv_import.to_fields(i, af.headers)
        st.as_words += 1
        for f in named:
            if dj[f.name] != di[f.csv_name]:
                st.field_mismatch[f"auto_stride:{f.name}"] += 1
                st.bad("auto_stride name", f"{rel} j#{n}", f"{f.name}={dj[f.name]} but {f.csv_name}={di[f.csv_name]}")


class Stats:
    def __init__(self):
        self.words = collections.Counter()
        self.mismatch = collections.Counter()  # kind of check -> count
        self.field_mismatch = collections.Counter()
        self.examples = []  # first few mismatches
        self.nonzero = {k: collections.Counter() for k in ("j", "m")}
        self.values = {k: collections.defaultdict(collections.Counter) for k in ("j", "m")}
        self.value_src = {k: collections.defaultdict(dict) for k in ("j", "m")}
        self.known = {k: {f.name: {int(e.val, 2) for e in f.enum} for f in schema.load(k).fields} for k in ("j", "m")}
        self.off_enum = collections.Counter()  # 'field=value' seen where the enum applies but lacks the value
        self.off_enum_src = {}
        self.imm = 0
        self.as_words = 0
        self.as_files = 0
        self.as_skipped = 0

    def bad(self, what: str, where: str, detail: str = ""):
        self.mismatch[what] += 1
        if len(self.examples) < 20:
            self.examples.append(f"{where}: {what} {detail}".rstrip())


def verify_file(asm_path: Path, csv_path: Path, rel: str, st: Stats) -> None:
    asm_words = [ln for ln in read_asm(asm_path) if ln.kind in ("j", "m")]
    cf = csv_import.read_csv(csv_path)
    csv_words = cf.words(("j", "m"))
    if [w.kind for w in asm_words] != [r.kind for r in csv_words]:
        st.bad("word count/kind", rel, f"asm {len(asm_words)} words, csv {len(csv_words)} rows")
        return
    for n, (aw, row) in enumerate(zip(asm_words, csv_words)):
        k, bits = aw.kind, aw.bits
        where = f"{rel} {k}#{n}"
        st.words[k] += 1
        if row.bits != bits:
            st.bad("csv concat != asm", where)
        try:
            ref = csv_import.to_fields(row)
        except ValueError as e:
            st.bad("csv width", where, str(e))
            continue
        dec = codec.decode(bits, k)
        for name, v in ref.items():
            if dec[name] != v:
                st.field_mismatch[name] += 1
                st.bad("field", where, f"{name}: decode {dec[name]} csv {v}")
        if codec.encode(dec, k) != bits:
            st.bad("encode(decode(w)) != w", where)
        imm = k == "j" and codec.is_imm(bits)
        if imm:
            st.imm += 1
            if not codec.imm_replicas_ok(bits):
                st.bad("imm replica", where)
        s = schema.load(k)
        for f in s.fields:
            v = dec[f.name]
            if v:
                st.nonzero[k][f.name] += 1
            if f.width <= 8 or f.enum:
                st.values[k][f.name][v] += 1
                st.value_src[k][f.name].setdefault(v, where)
            if f.enum and s.enum_applies(f, dec, imm) and v not in st.known[k][f.name]:
                key = f"{f.name}={v:0{f.width}b}"
                st.off_enum[key] += 1
                st.off_enum_src.setdefault(key, where)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="corpus root (default third_party/mncore)")
    ap.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    ap.add_argument("--reassemble", action="store_true")
    ap.add_argument("--jobs", type=int)
    ap.add_argument("--report", type=Path, help="write a JSON report (stats, exclusions, field usage)")
    ap.add_argument("--cross-check-auto-stride", action="store_true",
                    help="also assemble in auto_stride mode and check every named j field against the CSV header names")
    a = ap.parse_args(argv)

    root = a.root.resolve()
    files = find_sources(root)
    if not files:
        sys.exit(f"no .vsm under {root} (run: git submodule update --init third_party/mncore)")
    tags = ("flat", "as") if a.cross_check_auto_stride else ("flat",)
    if a.reassemble or not cache_ok(a.cache, files, tags):
        assemble(root, files, a.cache, a.jobs, "flat auto_stride" if a.cross_check_auto_stride else "flat")
    out = a.cache / "out"
    version = (a.cache / "out" / "VERSION").read_text().strip() if (out / "VERSION").exists() else "?"

    st = Stats()
    excluded = {}
    for i, rel in enumerate(files):
        rc = (out / f"{i:04d}.flat.rc").read_text().strip()
        if rc != "0":
            err = (out / f"{i:04d}.flat.err").read_text(encoding="utf-8", errors="replace").strip().splitlines()
            excluded[rel] = f"rc={rc} " + (err[0] if err else "")
            continue
        verify_file(out / f"{i:04d}.flat.asm", out / f"{i:04d}.flat.csv", rel, st)
        if a.cross_check_auto_stride and (out / f"{i:04d}.as.rc").read_text().strip() == "0":
            st.as_files += 1
            cross_check_auto_stride(out / f"{i:04d}.flat.csv", out / f"{i:04d}.as.csv", rel, st)

    ok = len(files) - len(excluded)
    total_mis = sum(st.mismatch.values())
    print(f"assembler revision {version}")
    print(f"sources {len(files)}: assembled {ok}, excluded {len(excluded)} (assemble3 rejected)")
    print(f"words: j {st.words['j']}, m {st.words['m']} (imm {st.imm})")
    if a.cross_check_auto_stride:
        print(f"auto_stride cross-check: {st.as_files} sources accepted in both modes, {st.as_words} j words compared"
              f" ({st.as_skipped} sources skipped: different word counts)")
    print(f"mismatches: {total_mis}" + ("" if not total_mis else f" {dict(st.mismatch)}"))
    for e in st.examples:
        print("  ", e)
    unseen = {k: [f.name for f in schema.load(k).fields if not st.nonzero[k][f.name]] for k in ("j", "m")}
    print(f"fields never non-zero: j {unseen['j']} m {unseen['m']}")
    off_enum = [f"{key} x{n} ({st.off_enum_src[key]})" for key, n in sorted(st.off_enum.items())]
    print(f"values outside the enum tables (where the enum applies): {len(off_enum)}")
    for x in off_enum:
        print("  ", x)

    if a.report:
        rep = {
            "assembler_revision": version, "sources": len(files), "assembled": ok, "excluded": excluded,
            "words": dict(st.words), "imm_words": st.imm, "mismatches": dict(st.mismatch),
            "field_mismatches": dict(st.field_mismatch), "mismatch_examples": st.examples,
            "nonzero": {k: dict(v) for k, v in st.nonzero.items()},
            "values": {k: {n: {str(v): c for v, c in sorted(h.items())} for n, h in d.items()} for k, d in st.values.items()},
            "value_first_seen": {k: {n: {str(v): s for v, s in sorted(h.items())} for n, h in d.items()}
                                 for k, d in st.value_src.items()},
            "off_enum": off_enum,
            "auto_stride_cross_check": {"sources": st.as_files, "words": st.as_words, "skipped": st.as_skipped}
            if a.cross_check_auto_stride else None,
        }
        a.report.parent.mkdir(parents=True, exist_ok=True)
        a.report.write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"report: {a.report}")
    print("PASS" if total_mis == 0 else "FAIL")
    return 0 if total_mis == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

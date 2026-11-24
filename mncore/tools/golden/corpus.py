#!/usr/bin/env python3
"""Classifies every .vsm of the corpus (third_party/mncore) into mncore/tools/golden/corpus.tsv.

usage: python mncore/tools/golden/corpus.py [-o corpus.tsv] [--conformance conformance.tsv]

Columns (static analysis of the program as composed by goldenlib.load_program, i.e. the
solution plus the testcase suffix code; testcase `d set` / `d get` lines count for LM and dget):

  path        file, relative to third_party/mncore
  kind        testcase | solution | standalone (see goldenlib.py)
  testcase    testcase used to run it ('-' if none), relative to third_party/mncore
  groups      instruction groups used: alu_int fp mau matrix l1bm l2bm mv (unknown: opcodes that
              the classifier does not know)
  cross_pe    yes if PEs exchange data: L1BM, L2BM, matrix (MAB) instructions, msl/msr
  lm_max      highest LM0/LM1 long word address of a literal operand or d set / d get ('-' none)
  lm_dyn      yes if LM addresses also depend on run time values (base register $mb/$nb written,
              T-indirect $mt)
  dget        d get lines: self (in the program), testcase (testcase output), both, no
  words       j + m words of the program (official, from the sweep)
  official    status of the official run in the sweep (ok, asm_fail <rc>, ...)
  rust        status of the Rust run in the sweep (ok, unsupported, ...)
  match       result of ndiff official vs Rust in the sweep (match, MISMATCH(<spaces>), skip, -)
  pe1         yes if the program can be compared in 1 PE mode: official ok, only alu_int / fp /
              mau groups, lm_max < LM_DEPTH (256 long words) and no lm_dyn
  pe1_reason  why not (empty when pe1 is yes)

The sweep columns come from conformance.tsv (written by sweep.py); they are '-' without it.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import goldenlib as gl  # noqa: E402

LM_DEPTH = 256  # long words, contract 06 section 3
GROUP_ORDER = ["alu_int", "fp", "mau", "matrix", "l1bm", "l2bm", "mv", "unknown"]
PE1_GROUPS = {"alu_int", "fp", "mau"}

# ALU opcodes (name, type) after the optional u prefix and precision letter; mirrors
# viz/core/src/vsm.rs ALU_OPS.
ALU_TYPES = {
    "msl": "untyped", "msr": "untyped", "passa": "both", "inc": "int", "dec": "int", "not": "int",
    "lnot": "int", "rsqrt": "float", "floor": "float", "ftoi": "float", "bfe": "bfe", "bfn": "bfn",
    "max": "both", "min": "both", "packbit": "both", "and": "int", "or": "int", "xor": "int",
    "add": "int", "sub": "int", "lsl": "int", "lsr": "int", "bsl": "int", "bsr": "int",
    "relu": "float", "relu0": "float", "relu1": "float", "relu2": "float", "relu3": "float",
    "lrelud": "float", "lreluo": "float", "ilrelud": "float",
}


def classify_opcode(op: str) -> Optional[str]:
    """Group of one expression opcode, 'ctl' for control, None if unknown."""
    m = re.match(r"^h(bfn|bfe)/\d+(/.*)?$", op)
    if m:
        op = "h" + m.group(1)
    if "/" in op and not op.startswith("mv") and not op.startswith("l2bm"):
        op = op.split("/", 1)[0]
    if op in ("nop", "wait", "noforward") or op.startswith("nop/"):
        return "ctl"
    if op.startswith("l1bm"):
        return "l1bm"
    if op.startswith("l2bm"):
        return "l2bm"
    if op in ("zero", "imm", "immu"):
        return "alu_int"
    if not op:
        return None
    if op[0] in "dfgh":
        rest = op[1:]
        if rest in ("mwrite", "mread"):
            return "matrix"
        for pre, grp in (("m", "matrix"), ("v", "mau")):
            if rest.startswith(pre):
                r = rest[1:]
                for k in ("fma", "mul", "add", "passa"):
                    if r.startswith(k):
                        tail = r[len(k):]
                        if tail[:1] in ("u", "d"):
                            tail = tail[1:]
                        if tail in ("", "r"):
                            return grp
    unsigned = op.startswith("u") and len(op) > 1
    s = op[1:] if unsigned else op
    for prec, name in ((None, s), (s[0], s[1:])):
        ty = ALU_TYPES.get(name)
        if ty is None:
            continue
        if ty == "untyped":
            if prec is None and not unsigned:
                return "matrix"  # msl / msr move data between the PEs of a MAB
            continue
        if prec is None:
            continue
        if ty == "int" and prec in "lis":
            return "alu_int"
        if ty == "float" and prec in "dfh":
            return "fp"
        if ty == "both" and prec in "dfhlis":
            return "fp" if prec in "dfh" else "alu_int"
        if ty == "bfn" and prec in "dfgh":
            return "fp"
        if ty == "bfe" and prec == "h":
            return "fp"
    return None


_LM_OP_RE = re.compile(
    r"^-?\$(ll|l)?([mn])(t)?(?:\[(\d+),(\d+),(\d+),(\d+)\]|(\d+)?(v(\d+)?)?)(j\d+)?[er]?$")
_DEBUG_LM_RE = re.compile(r"^\s*d\s+(set|get[dfh]?)\s+\$(ll|l)?([mn])(\d+)\S*\s+(\d+)", re.MULTILINE)
_BAR_RE = re.compile(r"\$l{0,2}[mn]b\b")
_OPERAND_RE = re.compile(r"-?\$[A-Za-z0-9_\[\],.@]+")


def wl_words(prefix: Optional[str]) -> int:
    return {None: 1, "": 1, "l": 2, "ll": 4}[prefix]


def lm_operand_max(tok: str) -> Tuple[Optional[int], bool]:
    """(highest word address, T-indirect) of an LM operand token, (None, False) otherwise."""
    tok = tok.split("/", 1)[0]
    m = _LM_OP_RE.match(tok)
    if not m:
        return None, False
    ll, _, t, c0, c1, c2, c3, base, vec, inc, j = m.groups()
    wl = wl_words(ll)
    if c0 is not None:
        cyc = [int(c0), int(c1), int(c2), int(c3)]
    else:
        b = int(base) if base else 0
        step = (int(inc) if inc else wl) if vec else 0
        cyc = [b + i * step for i in range(4)]
    hi = max(cyc) + wl - 1 + (wl if j else 0)
    return hi, bool(t)


class Info:
    def __init__(self) -> None:
        self.groups: Set[str] = set()
        self.unknown: Set[str] = set()
        self.lm_max: Optional[int] = None  # word address
        self.lm_dyn = False
        self.dget_self = False
        self.dget_tc = False

    def lm(self, word: int) -> None:
        self.lm_max = word if self.lm_max is None else max(self.lm_max, word)


def scan_debug(text: str, info: Info) -> None:
    for m in _DEBUG_LM_RE.finditer(text):
        _, ll, _, addr, count = m.groups()
        info.lm(int(addr) + int(count) * wl_words(ll) - 1)


def scan_code(code: str, info: Info) -> None:
    for raw in code.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("d "):
            if re.match(r"d\s+get", line):
                info.dget_self = True
            continue
        if line.startswith("r "):
            continue
        if line.startswith("mv"):
            info.groups.add("mv")
            continue
        if re.match(r"^mask[a-z]*\s+\S+$", line):
            continue
        if _BAR_RE.search(line):
            info.lm_dyn = True
        for part in line.split(";"):
            part = part.strip()
            if not part:
                continue
            op = part.split()[0]
            g = "mv" if op.startswith("mv") else classify_opcode(op)
            if g is None:
                info.groups.add("unknown")
                info.unknown.add(op)
            elif g != "ctl":
                info.groups.add(g)
            for tok in _OPERAND_RE.findall(part[len(op):]):
                hi, t = lm_operand_max(tok)
                if hi is not None:
                    info.lm(hi)
                if t:
                    info.lm_dyn = True
    scan_debug(code, info)


_tc_cache: Dict[Path, Tuple[Info, str, str]] = {}


def testcase_info(tc: Path) -> Tuple[Info, str, str]:
    """(info of the testcase's d set / d get lines and suffix code, suffix, output)."""
    if tc not in _tc_cache:
        prefix, suffix, output = gl.split_testcase(tc.read_text(encoding="utf-8", errors="replace"))
        info = Info()
        scan_debug(prefix, info)
        scan_debug(output, info)
        # Most testcases have no "Output" marker; their d get lines then sit in the suffix.
        info.dget_tc = bool(re.search(r"^\s*d\s+get", output + "\n" + suffix, re.MULTILINE))
        _tc_cache[tc] = (info, gl.sanitize_vsm(suffix), output)
    return _tc_cache[tc]


def list_corpus() -> List[Path]:
    files = [p for p in gl.MNCORE.rglob("*.vsm") if "target" not in p.relative_to(gl.MNCORE).parts]
    return sorted(files, key=lambda p: p.relative_to(gl.MNCORE).as_posix())


def corpus_rel(p: Optional[Path]) -> str:
    if p is None:
        return "-"
    return Path(p).resolve().relative_to(gl.MNCORE.resolve()).as_posix()


def classify(path: Path) -> Dict[str, str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    info = Info()
    if gl.is_testcase_text(text):
        kind, tc = "testcase", path.resolve()
        main = ""
    else:
        tc = gl.resolve_testcase(path, "auto", text)
        kind = "solution" if tc else "standalone"
        main = gl.sanitize_vsm(text)
    if tc is not None:
        tinfo, suffix, _ = testcase_info(tc)
        if tinfo.lm_max is not None:
            info.lm(tinfo.lm_max)
        info.dget_tc = tinfo.dget_tc
        scan_code(suffix, info)
        info.dget_self = False  # d get lines of the testcase suffix belong to the testcase
    scan_code(main, info)
    dget = {(True, True): "both", (True, False): "self", (False, True): "testcase", (False, False): "no"}[
        (info.dget_self, info.dget_tc)]
    groups = [g for g in GROUP_ORDER if g in info.groups]
    return {
        "path": corpus_rel(path),
        "kind": kind,
        "testcase": "-" if kind == "testcase" else corpus_rel(tc),
        "groups": ",".join(groups) or "-",
        "cross_pe": "yes" if info.groups & {"l1bm", "l2bm", "matrix"} else "no",
        "lm_max": "-" if info.lm_max is None else str(info.lm_max // 2),
        "lm_dyn": "yes" if info.lm_dyn else "no",
        "dget": dget,
        "unknown_ops": ",".join(sorted(info.unknown)),
    }


def pe1(row: Dict[str, str]) -> Tuple[str, str]:
    reasons = []
    if row.get("official", "-") != "ok":
        reasons.append(f"official:{row.get('official', '-')}")
    groups = set(row["groups"].split(",")) - {"-"}
    bad = [g for g in GROUP_ORDER if g in groups - PE1_GROUPS]
    if bad:
        reasons.append("groups:" + "+".join(bad))
    if row["lm_max"] != "-" and int(row["lm_max"]) >= LM_DEPTH:
        reasons.append(f"lm_max>={LM_DEPTH}")
    if row["lm_dyn"] == "yes":
        reasons.append("lm_dyn")
    return ("no" if reasons else "yes"), ";".join(reasons)


COLUMNS = ["path", "kind", "testcase", "groups", "cross_pe", "lm_max", "lm_dyn", "dget", "words", "official",
           "rust", "match", "pe1", "pe1_reason"]


def read_conformance(path: Path) -> Dict[str, Dict[str, str]]:
    if not path.exists():
        return {}
    with open(path, encoding="utf-8", newline="") as f:
        return {r["path"]: r for r in csv.DictReader(f, delimiter="\t")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default=str(gl.GOLDEN_DIR / "corpus.tsv"))
    ap.add_argument("--conformance", default=str(gl.GOLDEN_DIR / "conformance.tsv"))
    a = ap.parse_args(argv)

    conf = read_conformance(Path(a.conformance))
    rows = []
    for p in list_corpus():
        row = classify(p)
        c = conf.get(row["path"], {})
        row["words"] = c.get("words_official", "-") or "-"
        row["official"] = c.get("official", "-") or "-"
        row["rust"] = c.get("rust", "-") or "-"
        row["match"] = c.get("result", "-") or "-"
        if row["match"] == "MISMATCH" and c.get("diff_spaces", "-") not in ("", "-"):
            row["match"] += f"({c['diff_spaces']})"
        row["pe1"], row["pe1_reason"] = pe1(row)
        if row["unknown_ops"]:
            row["pe1_reason"] = ";".join(filter(None, [row["pe1_reason"], "unknown_ops:" + row["unknown_ops"]]))
        rows.append(row)

    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\t".join(COLUMNS) + "\n")
        for r in rows:
            f.write("\t".join(r[c] for c in COLUMNS) + "\n")

    n = len(rows)
    by_kind: Dict[str, int] = {}
    for r in rows:
        by_kind[r["kind"]] = by_kind.get(r["kind"], 0) + 1
    n_pe1 = sum(r["pe1"] == "yes" for r in rows)
    print(f"corpus: {n} files ({', '.join(f'{k} {v}' for k, v in sorted(by_kind.items()))}), "
          f"pe1 comparable: {n_pe1} -> {a.out}")
    if not conf:
        print("note: no conformance.tsv yet; run sweep.py for the official / rust / match columns")
    return 0


if __name__ == "__main__":
    sys.exit(main())

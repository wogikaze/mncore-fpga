#!/usr/bin/env python3
"""Makes the tb_top_1pe script (WP21) from the corpus regression of WP20.

usage: python mncore/sim/tb/top_1pe/gen_top.py [-o FILE] [--max-read N] [PROGRAM ...]

Needs `python mncore/sim/regress/run.py --keep` to have run (with FPALU=1): for each program, the
request sequence of `mnhost.py run` (build/<name>/rtl.scr: RESET, WR_IMEM, WR_MEM, RUN, RD_MEM) and
what tb_core read back (build/<name>/rtl.out), which run.py compared with the official emulator
(result pass in build/results.tsv). The script repeats the requests as UART frames and checks every
read value (Q) and stop record (K / P). The first program keeps its reads whole (256 long words per
frame); the others keep the first --max-read long words of every read (default 64) to keep the
simulation short. Hand-made checks are added at the end: INFO, an m word (E_UNSUPPORTED 0x80), an
ll = 10 word (E_DECODE 0), and RD_MEM requests the core rejects (E_RANGE).
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REG = ROOT / "mncore" / "sim" / "regress"
sys.path.insert(0, str(REG))
import run as regress  # noqa: E402

# Welcome (integer ALU) and a MAU program; both pass with every FPALU setting. (A program longer than
# the instruction memory, e.g. problems/16.onehot/main.vsm with 560 words, also works but its IMEM
# upload through the UART model takes about 10 minutes of simulation; the board run covers it.)
DEFAULT = ["problems/challenge/1.plus-one/main.vsm", "problems/6.subrow-vec/main.vsm"]


def program_lines(path: str, max_read: int | None) -> list[str]:
    job = regress.BUILD / regress.prog_name(path)
    scr = (job / "rtl.scr").read_text(encoding="utf-8").split("\n")
    out_lines = (job / "rtl.out").read_text(encoding="utf-8").split("\n")
    reads, stops = {}, []
    for line in out_lines:
        p = line.split()
        if p and p[0] == "D":
            reads[(int(p[1], 16), int(p[2], 16), int(p[3], 16))] = int(p[4], 16)
        elif p and p[0] == "S":
            stops.append(p[1:])
    out = [f"# {path}"]
    si = 0
    for line in scr:
        p = line.split()
        if not p or p[0] == "E":
            continue
        if p[0] in ("C", "I", "W"):
            out.append(line)
        elif p[0] == "X":
            out.append(line)
            reason, info, pc, steps = stops[si][:4]
            si += 1
            out.append(f"K {reason} {info}")
            out.append(f"P {pc} {steps}")
        elif p[0] == "R":
            tag, sp, loc, lo, n = (int(x, 16) for x in p[1:])
            if max_read is not None:
                n = min(n, max_read)
            for a in range(lo, lo + n, 256):
                k = min(256, lo + n - a)
                vals = [reads[(tag, sp, a + i)] for i in range(k)]
                out.append(f"Q {sp:x} {loc:x} {a:x} {k:x} " + " ".join(f"{v:x}" for v in vals))
        else:
            raise ValueError(f"{path}: unexpected script line {line!r}")
    return out


def extras() -> list[str]:
    m_word = (2 << 446) | (1 << 81)          # m word, valid = 1 -> E_UNSUPPORTED, info 0x80 (MV)
    j_ll10 = (1 << 446) | (0b10 << 424)      # j word, ll = 10 -> E_DECODE, info 0 (MN_J_LL_IDX)
    return [
        "# hand-made: stops and rejected reads",
        "C",
        f"I 0 {m_word:0112x}",
        "X 0 1", "K 2 80", "P 0 0",
        f"I 1 {j_ll10:0112x}",
        "X 1 1", "K 3 0", "P 1 0",
        "G 6 0 0 5",        # L1BM: not implemented -> E_RANGE
        "G 1 1 0 5",        # LM0 of PE p1: not implemented
        "G 1 0 200 5",      # LM0 long word 512: beyond the depth
        "G 10 0 10 5",      # OMR entry 16: beyond
    ]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("programs", nargs="*", default=DEFAULT)
    ap.add_argument("-o", "--output", default=str(HERE / "fixed" / "top.scr"))
    ap.add_argument("--max-read", type=int, default=64)
    a = ap.parse_args(argv)
    res = {}
    with open(REG / "build" / "results.tsv", encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            res[r["path"]] = r["result"]
    lines = ["# tb_top_1pe script, made by gen_top.py from the WP20 regression (official emulator results)", "N"]
    for i, p in enumerate(a.programs):
        if res.get(p) != "pass":
            raise SystemExit(f"{p}: regression result {res.get(p)!r}, not pass")
        lines += program_lines(p, None if i == 0 else a.max_read)
    lines += extras()
    lines.append("E")
    Path(a.output).parent.mkdir(parents=True, exist_ok=True)
    Path(a.output).write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {a.output}: {len(lines)} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())

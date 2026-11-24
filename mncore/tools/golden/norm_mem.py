#!/usr/bin/env python3
"""RTL simulation / FPGA dumps -> ndmp.

usage: python mncore/tools/golden/norm_mem.py -o OUT.ndmp
           [--lines FILE ...] [--memh SPACE:LOC:WIDTH:FILE ...] [--meta KEY=VALUE ...]

Two input forms, both can be given several times and mixed:

--lines FILE   one record per line, ``<space> <loc> <addr> <value>``; addr and value may be
               decimal or 0x-hex (value without 0x is read as hex, like ndmp). ``#`` and ``//``
               start comments. This is what a host tool can print while it reads memories back.
--memh SPEC    a ``$writememh`` style image (one hex value per line, optional ``@<hex addr>``
               lines, ``//`` comments) of one memory, ``SPACE:LOC:WIDTH:FILE``:
                 WIDTH 64  one long word per entry; entry i is long word address i
                 WIDTH 32  one 32-bit word per entry (word address); words 2i (MSB) and 2i + 1
                           (LSB) make long word i. For T, entry 4c + 2k + {0,1} make T long word
                           2c + k, the same pairing.
               e.g. ``--memh LM0:n0c0b0m0p0:32:lm0.hex``

Records are deduplicated (the last one wins) and written in the canonical ndmp order, so the
result can be compared with ndiff.py against run_official.py / run_rust.py output.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ndmp  # noqa: E402


def strip_comment(line: str) -> str:
    for mark in ("//", "#"):
        i = line.find(mark)
        if i >= 0:
            line = line[:i]
    return line.strip()


def read_lines(path: str) -> List[ndmp.Record]:
    out = []
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = strip_comment(raw)
            if not line:
                continue
            parts = line.split()
            if len(parts) != 4:
                raise ValueError(f"{path}:{n}: need 4 columns: {raw.strip()!r}")
            space, loc, addr, val = parts
            v = int(val, 0) if val.lower().startswith("0x") else int(val, 16)
            out.append((space, loc, int(addr, 0), v))
    return out


def read_memh(path: str) -> Dict[int, int]:
    """Entry index -> value of a $readmemh/$writememh image."""
    mem: Dict[int, int] = {}
    addr = 0
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = strip_comment(raw)
            for tok in line.split():
                if tok.startswith("@"):
                    addr = int(tok[1:], 16)
                    continue
                if any(c in tok.lower() for c in "xz"):
                    raise ValueError(f"{path}: undefined value {tok!r} at entry {addr}")
                mem[addr] = int(tok.replace("_", ""), 16)
                addr += 1
    return mem


def memh_records(spec: str) -> List[ndmp.Record]:
    try:
        space, loc, width, path = spec.split(":", 3)
    except ValueError:
        raise ValueError(f"--memh needs SPACE:LOC:WIDTH:FILE, got {spec!r}")
    mem = read_memh(path)
    if width == "64":
        return [(space, loc, a, v) for a, v in sorted(mem.items())]
    if width != "32":
        raise ValueError(f"--memh width must be 32 or 64, got {width}")
    out = []
    for lw in sorted({a >> 1 for a in mem}):
        hi, lo = mem.get(2 * lw), mem.get(2 * lw + 1)
        if hi is None or lo is None:
            raise ValueError(f"{path}: long word {lw} has only one of its two words")
        out.append((space, loc, lw, (hi << 32) | lo))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default="-")
    ap.add_argument("--lines", action="append", default=[])
    ap.add_argument("--memh", action="append", default=[])
    ap.add_argument("--meta", action="append", default=[], help="KEY=VALUE header comment")
    a = ap.parse_args(argv)
    if not a.lines and not a.memh:
        ap.error("give at least one --lines or --memh input")
    recs: List[ndmp.Record] = []
    try:
        for p in a.lines:
            recs += read_lines(p)
        for s in a.memh:
            recs += memh_records(s)
    except (OSError, ValueError) as e:
        print(f"norm_mem: {e}", file=sys.stderr)
        return 1
    meta = {"producer": "norm_mem"}
    for kv in a.meta:
        k, _, v = kv.partition("=")
        meta[k] = v
    ndmp.write(a.out, ndmp.canonical(recs), meta)
    return 0


if __name__ == "__main__":
    sys.exit(main())

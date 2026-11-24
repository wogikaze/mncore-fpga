"""Assemble small sources with assemble3 and show how the fields change.

    python -m mnisa.probe 'lpassa $lr0 $lr32' 'lpassa $lr0 $t/0101' 'nop; wait i01'
    python -m mnisa.probe --file probes.txt          one source per line ('\\n' splits lines)

The first word of the first source is the baseline: for every other j word only the fields that
differ from it are printed (m words are printed in full, non-zero fields only). Needs WSL + assemble3.
"""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from .asm_io import read_asm
from .assembler import assemble_sources
from .codec import decode_bits
from .dump import describe


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python -m mnisa.probe", description=__doc__.split("\n\n")[0])
    ap.add_argument("source", nargs="*")
    ap.add_argument("--file", type=Path)
    ap.add_argument("--full", action="store_true", help="print all non-zero fields instead of the diff")
    a = ap.parse_args(argv)
    srcs = list(a.source)
    if a.file:
        srcs += [ln for ln in a.file.read_text(encoding="utf-8").splitlines() if ln.strip() and not ln.startswith("//")]
    if not srcs:
        ap.error("no source")
    with tempfile.TemporaryDirectory() as tmp:
        out = assemble_sources({f"p{i:03d}": s.replace("\\n", "\n") for i, s in enumerate(srcs)}, tmp)
        base = None
        for i, s in enumerate(srcs):
            print(f"[{i}] {s}")
            if (out / f"p{i:03d}.flat.rc").read_text().strip() != "0":
                err = (out / f"p{i:03d}.flat.err").read_text(errors="replace").strip().splitlines()
                print(f"    rejected: {err[0] if err else '?'}")
                continue
            for n, ln in enumerate(w for w in read_asm(out / f"p{i:03d}.flat.asm") if w.kind in ("j", "m")):
                if ln.kind == "j" and base is None:
                    base = decode_bits(ln.bits, "j")
                if ln.kind == "m" or a.full:
                    print(f"    {ln.kind}{n}: " + " ".join(describe(ln.kind, ln.bits)))
                    continue
                cur = decode_bits(ln.bits, "j")
                print(f"    j{n}: " + " ".join(f"{k}={v}" for k, v in cur.items() if v != base[k]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

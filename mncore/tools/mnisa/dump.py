"""List the non-zero fields of every instruction word of an assemble3 .asm file.

    python -m mnisa.dump prog.asm            (run from mncore/tools, or with it on PYTHONPATH)
    python -m mnisa.dump prog.asm --all      every field, including zeros
    python -m mnisa.dump - < prog.asm        read stdin

Values are printed in binary (field width); enum names follow in parentheses. For imm words the
32-bit payload (imm_layout) is printed as well. 'd' lines are echoed as comments.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .asm_io import parse_asm
from .codec import decode_bits, imm_payload, is_imm
from .schema import load


def describe(kind: str, bits: str, show_all: bool = False) -> list[str]:
    s = load(kind)
    vals = decode_bits(bits, kind)
    ints = {k: int(v, 2) for k, v in vals.items()}
    imm = kind == "j" and is_imm(bits)
    out = []
    for f in s.fields:
        v = vals[f.name]
        if not show_all and "1" not in v:
            continue
        name = f.enum_name(ints[f.name]) if f.enum and s.enum_applies(f, ints, imm) else None
        out.append(f"{f.name}={v}" + (f"({name})" if name else ""))
    if imm:
        out.append(f"imm_payload=0x{imm_payload(bits):08x}")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python -m mnisa.dump", description=__doc__.split("\n\n")[0])
    ap.add_argument("asm", help=".asm file ('-' for stdin)")
    ap.add_argument("--all", action="store_true", help="print zero fields too")
    ap.add_argument("--no-d", action="store_true", help="do not echo 'd' lines")
    a = ap.parse_args(argv)
    text = sys.stdin.read() if a.asm == "-" else Path(a.asm).read_text(encoding="utf-8")
    n = {"j": 0, "m": 0}
    for ln in parse_asm(text, a.asm):
        if ln.kind == "d":
            if not a.no_d:
                print(f"# d {ln.text}")
            continue
        if ln.kind not in n:
            continue
        fields = describe(ln.kind, ln.bits, a.all)
        print(f"{ln.kind}{n[ln.kind]} (line {ln.lineno}): " + " ".join(fields))
        n[ln.kind] += 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

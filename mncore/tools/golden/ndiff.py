#!/usr/bin/env python3
"""Compares two ndmp files.

usage: python mncore/tools/golden/ndiff.py A.ndmp B.ndmp [--only-pes n0c0b0m0p0,...]
           [--spaces LM0,LM1] [--max-addr N] [--allow-missing] [--show N] [-q]

- ``--only-pes``: keep lines whose location agrees with one of the given paths on every level
  both name. ``n0c0b0m0p0`` keeps that PE plus its L1BM (n0c0b0), L2BM (n0c0) and DRAM/PDM (n0);
  ``n0c0b0m0`` keeps the four PEs of MAB 0. Combine with ``--spaces`` to drop block memories.
- ``--spaces``: keep only these spaces.
- ``--max-addr N``: keep only addresses below N (in each space's own unit), e.g. the reduced
  LM_DEPTH of 256 long words.
- ``--allow-missing``: lines present in only one file are counted but do not fail the check.

Prints the differing lines (``MISMATCH``, ``ONLY-A``, ``ONLY-B``) and a summary line, and exits
0 when the files agree, 1 when they differ, 2 on a usage or input error.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ndmp  # noqa: E402


def select(data: Dict[ndmp.Key, int], pes: Optional[List[str]], spaces: Optional[set],
           max_addr: Optional[int]) -> Dict[ndmp.Key, int]:
    out = {}
    for k, v in data.items():
        space, loc, addr = k
        if spaces is not None and space not in spaces:
            continue
        if max_addr is not None and addr >= max_addr:
            continue
        if pes is not None and not any(ndmp.loc_matches(loc, p) for p in pes):
            continue
        out[k] = v
    return out


def compare(a: Dict[ndmp.Key, int], b: Dict[ndmp.Key, int]):
    """(mismatched keys, keys only in a, keys only in b), each sorted."""
    ka, kb = set(a), set(b)
    both = ka & kb
    mism = sorted(k for k in both if a[k] != b[k])
    return mism, sorted(ka - kb), sorted(kb - ka), len(both)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--only-pes", help="comma separated location paths")
    ap.add_argument("--spaces", help="comma separated space names")
    ap.add_argument("--max-addr", type=lambda s: int(s, 0))
    ap.add_argument("--allow-missing", action="store_true")
    ap.add_argument("--show", type=int, default=20, help="differences to print per kind (default 20)")
    ap.add_argument("-q", "--quiet", action="store_true", help="print only the summary line")
    a = ap.parse_args(argv)

    try:
        da, _ = ndmp.read(a.a)
        db, _ = ndmp.read(a.b)
    except (OSError, ValueError) as e:
        print(f"ndiff: {e}", file=sys.stderr)
        return 2
    pes = [p.strip() for p in a.only_pes.split(",") if p.strip()] if a.only_pes else None
    spaces = {s.strip() for s in a.spaces.split(",") if s.strip()} if a.spaces else None
    da = select(da, pes, spaces, a.max_addr)
    db = select(db, pes, spaces, a.max_addr)
    mism, only_a, only_b, n_both = compare(da, db)

    if not a.quiet:
        for k in mism[: a.show]:
            s, l, ad = k
            print(f"MISMATCH {ndmp.format_line(s, l, ad, da[k]).rsplit(' ', 1)[0]} a={da[k]:016x} b={db[k]:016x}")
        if len(mism) > a.show:
            print(f"... {len(mism) - a.show} more mismatches")
        for tag, keys, src in (("ONLY-A", only_a, da), ("ONLY-B", only_b, db)):
            for k in keys[: a.show]:
                print(f"{tag} {ndmp.format_line(*k, src[k])}")
            if len(keys) > a.show:
                print(f"... {len(keys) - a.show} more {tag}")

    failed = bool(mism) or (not a.allow_missing and (only_a or only_b))
    print(f"ndiff: {n_both} compared, {len(mism)} mismatches, {len(only_a)} only in a, {len(only_b)} only in b"
          f" -> {'FAIL' if failed else 'PASS'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

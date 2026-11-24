#!/usr/bin/env python3
"""Official emulator debug dump (gpfn3_package_main -d) -> ndmp.

usage: norm_gpfn3.py IN.dmp [-o OUT.ndmp] [--meta KEY=VALUE ...] [--meta-file FILE]

Every `d get` form of SDM 3.4.3 is handled: all spaces (LM0 LM1 GRF0 GRF1 T OMR L1BM L2BM
PDM DRAM), access lengths (word, long word, two long words) and dtypes (none, d, f, h).
The emulator prints one line per access unit:

  DEBUG-LM0(n0c0b0m0p0,2):(f:0, i:{{..}}, v:0x100000002) #d get $lm0n0c0b0m0p0 2
  DEBUG-LM0(n0c0b0m0p0,0):{(..v:0x..), (..v:0x..)} #d get $llm0n0c0b0m0p0 1
  DEBUG-LM0(n0c0b0m0p0,3):(-inf) (0xffffffff) #d getf $m3n0c0b0m0p0 1
  DEBUG-OMR(n0c0b0m0p0,1):Mask{0} #d get $omr1n0c0b0m0p0 1      (4 lines: cycles 0..3)

Mapping to ndmp (see ndmp.py for the address units):

- the address printed for LM/GRF is the word address; a long word unit goes to long word
  ``addr >> 1`` (the emulator reads the aligned long word), the second long word of a two long
  word access to ``(addr >> 1) + 1``; a 32-bit unit (word access) goes to ``LM0W`` etc.
- TREG prints the cycle; long word k of cycle c goes to ``T`` address ``2 * (c % 4) + k``.
- L1BM two long word access prints long word a and a + 4 on one line.
- PIU is the emulator's name for ``$p``; it becomes ``PDM``. Note that the emulator's ``$p``
  shows DRAM contents (observed, also noted in viz/core/src/run.rs).
- OMR prints each (PE, entry) four times, cycle 0 first; the value goes to ``entry * 4 + cycle``.

The last read of a location wins. Pure standard library (runs under WSL python3 too).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Dict, Iterable, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ndmp  # noqa: E402

SPACE_MAP = {
    "LM0": "LM0",
    "LM1": "LM1",
    "GREG0": "GRF0",
    "GREG1": "GRF1",
    "TREG": "T",
    "OMR": "OMR",
    "L1BM": "L1BM",
    "L2BM": "L2BM",
    "PIU": "PDM",
    "DRAM": "DRAM",
}
WORD_SPACES = {"LM0", "LM1", "GRF0", "GRF1"}

_V_RE = re.compile(r"v:\s*0x([0-9A-Fa-f]+)")
_GROUP_RE = re.compile(r"\(([^()]*)\)")
_HEX_RE = re.compile(r"0x([0-9A-Fa-f]+)")
_MASK_RE = re.compile(r"Mask\{(\d+)\}")


class NormError(Exception):
    pass


def units(payload: str) -> List[Tuple[int, int]]:
    """Splits a payload into its access units as (value, bits).

    Without a dtype every unit is ``(f:.., i:{..}, v:0x..)`` and the long word is ``v``.
    With a dtype a unit is ``(floats) (hexes)``; the hex fields are zero padded, so their
    digit count gives the width and concatenating them gives the unit value.
    """
    vs = _V_RE.findall(payload)
    if vs:
        return [(int(v, 16), 64) for v in vs]
    out = []
    for group in _GROUP_RE.findall(payload):
        hexes = _HEX_RE.findall(group)
        if not hexes:
            continue  # the float interpretation
        digits = "".join(hexes)
        out.append((int(digits, 16), 4 * len(digits)))
    return out


def split_line(line: str) -> Optional[Tuple[str, str, int, str, str]]:
    """``DEBUG-<space>(<loc>,<addr>):<payload> #<command>`` -> its five parts, None otherwise.
    String operations instead of one regex: dumps have ~10^5 lines."""
    if not line.startswith("DEBUG-"):
        return None
    head, sep, rest = line.partition("):")
    if not sep:
        return None
    space, sep, locaddr = head[6:].partition("(")
    loc, sep2, addr_s = locaddr.partition(",")
    if not sep or not sep2 or not addr_s.isdigit():
        return None
    payload, _, cmd = rest.partition(" #")
    return space, loc, int(addr_s), payload, cmd


def records_from_lines(lines: Iterable[str]) -> Tuple[List[ndmp.Record], Dict[str, int]]:
    recs: List[ndmp.Record] = []
    stats = {"lines": 0, "skipped": 0, "unknown_space": 0}
    omr_seen: Dict[Tuple[str, int], int] = {}
    last_cmd: Optional[str] = None
    for raw in lines:
        line = raw.rstrip("\r\n")
        parts = split_line(line)
        if parts is None:
            if line.strip():
                stats["skipped"] += 1
            continue
        stats["lines"] += 1
        emu_space, loc, addr, payload, cmd = parts
        space = SPACE_MAP.get(emu_space)
        if space is None:
            stats["unknown_space"] += 1
            space = emu_space
        if cmd != last_cmd:
            omr_seen.clear()
            last_cmd = cmd
        if space == "OMR":
            mm = _MASK_RE.search(payload)
            if not mm:
                raise NormError(f"cannot parse mask value: {line}")
            k = (loc, addr)
            cycle = omr_seen.get(k, 0)
            omr_seen[k] = cycle + 1
            recs.append(("OMR", loc, addr * 4 + cycle % 4, int(mm.group(1))))
            continue
        us = units(payload)
        if not us:
            raise NormError(f"no value in dump line: {line}")
        if space in WORD_SPACES:
            if len(us) == 1 and us[0][1] == 32:
                recs.append((space + "W", loc, addr, us[0][0]))
                continue
            for k, (v, bits) in enumerate(us):
                if bits != 64:
                    raise NormError(f"unexpected {bits}-bit unit: {line}")
                recs.append((space, loc, (addr >> 1) + k, v))
        elif space == "T":
            for k, (v, bits) in enumerate(us):
                recs.append(("T", loc, 2 * (addr % 4) + k, v))
        elif space == "L1BM":
            for k, (v, bits) in enumerate(us):
                recs.append((space, loc, addr + 4 * k, v))
        else:
            for k, (v, bits) in enumerate(us):
                recs.append((space, loc, addr + k, v))
    return recs, stats


def normalize_file(path: str) -> Tuple[Dict[ndmp.Key, int], Dict[str, int]]:
    with open(path, encoding="utf-8", errors="replace") as f:
        recs, stats = records_from_lines(f)
    return ndmp.canonical(recs), stats


def read_meta_file(path: Optional[str]) -> Dict[str, str]:
    meta: Dict[str, str] = {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    meta[k.strip()] = v.strip()
    return meta


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="official emulator dump -> ndmp")
    ap.add_argument("dmp")
    ap.add_argument("-o", "--out", default="-")
    ap.add_argument("--meta", action="append", default=[], help="KEY=VALUE header comment")
    ap.add_argument("--meta-file", help="file of 'key: value' lines for the header")
    a = ap.parse_args(argv)
    try:
        data, stats = normalize_file(a.dmp)
    except NormError as e:
        print(f"norm_gpfn3: {e}", file=sys.stderr)
        return 1
    meta = read_meta_file(a.meta_file)
    for kv in a.meta:
        k, _, v = kv.partition("=")
        meta[k] = v
    meta.setdefault("producer", "official")
    ndmp.write(a.out, data, meta)
    if stats["skipped"] or stats["unknown_space"]:
        print(f"norm_gpfn3: skipped {stats['skipped']} lines, {stats['unknown_space']} with unknown space",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

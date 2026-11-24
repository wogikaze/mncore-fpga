"""Normalized dump (.ndmp) reading and writing (contract 06 section 4).

One line per long word: ``<space> <loc> 0x<addr> <value>``, value as 16 lower-case hex digits.
Lines are sorted as strings. Lines starting with ``#`` are comments; ``# key: value`` comments
after the ``# ndmp v1`` header carry metadata (source file, probe, ...), which comparisons ignore.

Spaces and their address units:

- ``LM0 LM1 GRF0 GRF1``: long word address (word address >> 1).
- ``LM0W LM1W GRF0W GRF1W``: word address; the value is the 32-bit word. Only word access
  ``d get`` (``d getf $m0 ...``) produces these.
- ``T``: ``2 * cycle + k``; k = 0 is the MSB long word of the cycle, k = 1 the LSB one.
- ``OMR``: ``entry * 4 + cycle``; the value is the 4-bit flag nibble.
- ``L1BM L2BM PDM DRAM``: long word address.

Locations follow SDM 3.4.3 / the emulator output: ``n0c0b0m0p0`` for PE spaces, ``n0c0b0`` for
L1BM, ``n0c0`` for L2BM, ``n0`` for PDM and DRAM.

Pure standard library: it also runs under the WSL python3 next to the official emulator.
"""

from __future__ import annotations

import re
import sys
from typing import Dict, Iterable, Iterator, Optional, TextIO, Tuple

HEADER = "# ndmp v1"

Key = Tuple[str, str, int]
Record = Tuple[str, str, int, int]

# Spaces whose addresses can exceed 16 bits get a wider field, so that sorting the lines as
# strings also sorts them by address.
WIDE_SPACES = {"PDM", "DRAM"}

PE_SPACES = {"LM0", "LM1", "GRF0", "GRF1", "LM0W", "LM1W", "GRF0W", "GRF1W", "T", "OMR"}

_LOC_RE = re.compile(r"([ncbmp])(\d+)")


def format_line(space: str, loc: str, addr: int, val: int) -> str:
    width = 8 if space in WIDE_SPACES else 4
    return f"{space} {loc} 0x{addr:0{width}x} {val & 0xFFFFFFFFFFFFFFFF:016x}"


def canonical(records: Iterable[Record]) -> Dict[Key, int]:
    """Deduplicates records; a later record for the same location wins (the last `d get`)."""
    out: Dict[Key, int] = {}
    for space, loc, addr, val in records:
        out[(space, loc, addr)] = val
    return out


def dumps(data: Dict[Key, int], meta: Optional[Dict[str, str]] = None) -> str:
    lines = sorted(format_line(s, l, a, v) for (s, l, a), v in data.items())
    head = [HEADER]
    for k, v in (meta or {}).items():
        head.append(f"# {k}: {v}")
    return "\n".join(head + lines) + "\n"


def write(path: str, data: Dict[Key, int], meta: Optional[Dict[str, str]] = None) -> None:
    text = dumps(data, meta)
    if path == "-":
        sys.stdout.write(text)
        return
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def parse_line(line: str) -> Record:
    parts = line.split()
    if len(parts) != 4:
        raise ValueError(f"ndmp line needs 4 columns: {line!r}")
    space, loc, addr, val = parts
    return space, loc, int(addr, 0), int(val, 16)


def iter_records(f: TextIO) -> Iterator[Record]:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        yield parse_line(line)


def read(path: str) -> Tuple[Dict[Key, int], Dict[str, str]]:
    """Returns (records, metadata). Duplicate locations keep the last value."""
    meta: Dict[str, str] = {}
    data: Dict[Key, int] = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#"):
                body = line[1:].strip()
                if ":" in body and not body.startswith("ndmp"):
                    k, v = body.split(":", 1)
                    meta[k.strip()] = v.strip()
                continue
            s, l, a, v = parse_line(line)
            data[(s, l, a)] = v
    return data, meta


def loc_parts(loc: str) -> Dict[str, int]:
    """``n0c1b2m3p0`` -> {'n': 0, 'c': 1, 'b': 2, 'm': 3, 'p': 0}."""
    return {k: int(v) for k, v in _LOC_RE.findall(loc)}


def loc_matches(loc: str, selector: str) -> bool:
    """True when the two paths agree on every level both name.

    A PE selector ``n0c0b0m0p0`` keeps that PE, its L1BM ``n0c0b0``, its L2BM ``n0c0`` and its
    DRAM ``n0``; ``n0c0b0m0`` keeps the four PEs of MAB 0.
    """
    a, b = loc_parts(loc), loc_parts(selector)
    return all(a[k] == b[k] for k in a.keys() & b.keys())

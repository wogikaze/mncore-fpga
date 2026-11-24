"""Import the output of `assemble3 --print-csv`.

The CSV starts with two header lines:
  i,ll,pe.mrc.imr,...,wd          names of the auto_stride 'i' word (95 fields)
  m,valid,mmode,...,priority      names of the 'm' word (12 fields)
followed by one row per output line. Instruction rows hold one cell per field written as ="0101"
(and end with a comma); 'd' rows hold the debug statement split at commas. Other statements that
assemble3 passes through (e.g. 'r 0 000000000 001 3E80...') appear as the raw line; they are kept
with kind = their leading token and cols = [the raw line].

Note: a flat 'j' row has 110 cells whose order is NOT the 'i' header order. Its columns map to the
fields of spec/isa/j_flat.yaml by csv_col.
"""
from __future__ import annotations

import csv
import io
from dataclasses import dataclass
from pathlib import Path

from . import schema as _schema


WORD_KINDS = ("j", "m", "i")


@dataclass
class CsvRow:
    kind: str  # 'j', 'm', 'i', 'd', or the leading token of a passed-through statement
    cols: list[str]  # binary strings for j/m/i; the raw cells for d; [raw line] otherwise
    lineno: int = 0

    @property
    def bits(self) -> str:
        """Concatenation of the columns: equals the word of the normal (.asm) output."""
        if self.kind not in WORD_KINDS:
            raise ValueError(f"'{self.kind}' row has no instruction bits")
        return "".join(self.cols)


@dataclass
class CsvFile:
    headers: dict  # {'i': [names...], 'm': [names...]}
    rows: list[CsvRow]

    def words(self, kinds=("j", "m")) -> list[CsvRow]:
        return [r for r in self.rows if r.kind in kinds]


def _cell(c: str) -> str:
    if c.startswith('="') and c.endswith('"'):
        return c[2:-1]
    raise ValueError(f"unexpected cell {c!r}")


def parse_csv(text: str, source: str = "<csv>") -> CsvFile:
    headers, rows = {}, []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        head = line.split(",", 1)[0]
        if head not in WORD_KINDS + ("d",):
            rows.append(CsvRow(line.split()[0], [line], n))
            continue
        rec = next(csv.reader(io.StringIO(line)))
        kind = rec[0]
        if len(rec) > 1 and not rec[1].startswith('="') and kind in ("i", "m") and kind not in headers:
            headers[kind] = [c for c in rec[1:] if c]
            continue
        if kind in WORD_KINDS:
            try:
                cols = [_cell(c) for c in rec[1:] if c != ""]
            except ValueError as e:
                raise ValueError(f"{source}:{n}: {e}") from None
            rows.append(CsvRow(kind, cols, n))
        else:
            rows.append(CsvRow("d", rec[1:], n))
    return CsvFile(headers, rows)


def read_csv(path) -> CsvFile:
    p = Path(path)
    return parse_csv(p.read_text(encoding="utf-8"), str(p))


def to_fields(row: CsvRow, headers: dict | None = None) -> dict[str, int]:
    """{field name: value} of one instruction row.

    j / m rows use the schema (column k is the field with csv_col k; widths are checked).
    i rows (auto_stride) use the CSV header names as they are (no schema).
    """
    if row.kind == "i":
        if not headers or "i" not in headers:
            raise ValueError("an 'i' row needs the CSV headers")
        names = headers["i"]
        if len(names) != len(row.cols):
            raise ValueError(f"line {row.lineno}: {len(row.cols)} cells for {len(names)} header names")
        return {n: int(c, 2) for n, c in zip(names, row.cols)}
    s = _schema.load(row.kind)
    by_col = sorted(s.fields, key=lambda f: f.csv_col)
    if len(row.cols) != len(by_col):
        raise ValueError(f"line {row.lineno}: {row.kind} row has {len(row.cols)} cells, schema has {len(by_col)} fields")
    out = {}
    for f, c in zip(by_col, row.cols):
        if len(c) != f.width:
            raise ValueError(f"line {row.lineno}: column {f.csv_col} ({f.name}) is {len(c)} bits, schema says {f.width}")
        out[f.name] = int(c, 2)
    return out

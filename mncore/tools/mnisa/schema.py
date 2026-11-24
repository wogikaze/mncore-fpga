"""Load and check the instruction-word schemas in mncore/spec/isa/*.yaml."""
from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import yaml

SPEC_DIR = Path(__file__).resolve().parents[2] / "spec" / "isa"
SCHEMA_FILES = {"j": "j_flat.yaml", "m": "m.yaml"}
NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")


@dataclass(frozen=True)
class EnumVal:
    val: str  # binary string, width digits
    name: str
    desc: str = ""


@dataclass(frozen=True)
class Field:
    name: str
    pos: int  # leftmost bit of the field (MSB), counted from the left of the word string
    width: int
    group: str
    csv_col: int
    csv_name: str | None = None
    desc: str = ""
    enum: tuple[EnumVal, ...] = ()
    addr: tuple[tuple[str, object], ...] = ()  # (("cycle", 0), ("port", "w"), ("unit", "rfc0"))
    notes: str = ""
    ref: tuple[str, ...] = ()
    enum_when: tuple[str, str] | None = None  # (field, binary value): the enum applies only when it holds

    @property
    def end(self) -> int:
        """One past the rightmost bit (pos of the LSB + 1)."""
        return self.pos + self.width

    def enum_name(self, value: int) -> str | None:
        key = format(value, f"0{self.width}b")
        for e in self.enum:
            if e.val == key:
                return e.name
        return None

    def addr_info(self) -> dict:
        return dict(self.addr)


class Schema:
    def __init__(self, data: dict, path: Path | None = None):
        self.path = path
        self.raw = data
        self.kind: str = data["kind"]
        self.width: int = int(data["width"])
        self.groups: dict = dict(data.get("groups") or {})
        fields = []
        for d in data["fields"]:
            enum = tuple(EnumVal(str(e["val"]), str(e["name"]), str(e.get("desc", ""))) for e in d.get("enum") or ())
            addr = tuple(sorted((d.get("addr") or {}).items()))
            ew = d.get("enum_when")
            fields.append(Field(
                name=d["name"], pos=int(d["pos"]), width=int(d["width"]), group=d["group"], csv_col=int(d["csv_col"]),
                csv_name=d.get("csv_name"), desc=d.get("desc", ""), enum=enum, addr=addr, notes=d.get("notes", ""),
                ref=tuple(d.get("ref") or ()), enum_when=(ew["field"], str(ew["val"])) if ew else None))
        self.fields: list[Field] = sorted(fields, key=lambda f: f.pos)
        self.by_name: dict[str, Field] = {f.name: f for f in self.fields}
        self.cycle_addr: dict = {k: v for k, v in (data.get("cycle_addr") or {}).items() if isinstance(v, list) and k != "ref"}
        self.imm_layout: dict | None = data.get("imm_layout")
        self._imm_fields: frozenset[str] | None = None

    def __getitem__(self, name: str) -> Field:
        return self.by_name[name]

    def imm_fields(self) -> frozenset[str]:
        """Names of the fields that carry the immediate payload (or its replicas) in an imm word."""
        if self._imm_fields is None:
            names = set()
            for s in (self.imm_layout or {}).get("segments", ()):
                names |= set(s["fields"])
                names |= {f.name for r in s.get("replicas", ()) for f in self.fields if f.pos == r[0]}
            self._imm_fields = frozenset(names)
        return self._imm_fields

    def enum_applies(self, f: Field, values: dict[str, int], imm: bool = False) -> bool:
        """Whether f's enum table describes its value in a word with the given decoded values."""
        if imm and f.name in self.imm_fields():
            return False
        if f.enum_when:
            g = self.by_name[f.enum_when[0]]
            return values[g.name] == int(f.enum_when[1], 2)
        return True

    def __iter__(self):
        return iter(self.fields)

    def __len__(self):
        return len(self.fields)

    def check(self) -> list[str]:
        """Return a list of problems (empty when the schema is consistent)."""
        p = []
        if len(self.by_name) != len(self.fields):
            seen = set()
            p += [f"duplicate field name {f.name}" for f in self.fields if f.name in seen or seen.add(f.name)]
        owner = [None] * self.width
        for f in self.fields:
            if not NAME_RE.match(f.name):
                p.append(f"bad field name {f.name!r}")
            if f.width <= 0:
                p.append(f"{f.name}: width {f.width}")
            if f.pos < 0 or f.end > self.width:
                p.append(f"{f.name}: [{f.pos},{f.end}) outside 0..{self.width}")
                continue
            for b in range(f.pos, f.end):
                if owner[b] is not None:
                    p.append(f"bit {b} overlaps: {owner[b]} and {f.name}")
                owner[b] = f.name
            for e in f.enum:
                if len(e.val) != f.width or set(e.val) - {"0", "1"}:
                    p.append(f"{f.name}: enum value {e.val!r} is not a {f.width}-bit binary string")
            if len({e.val for e in f.enum}) != len(f.enum):
                p.append(f"{f.name}: duplicate enum value")
            if f.group not in self.groups:
                p.append(f"{f.name}: group {f.group!r} not declared")
            if f.enum_when:
                g = self.by_name.get(f.enum_when[0])
                if g is None or len(f.enum_when[1]) != g.width:
                    p.append(f"{f.name}: bad enum_when {f.enum_when}")
        p += [f"bit {b} not covered by any field" for b in range(self.width) if owner[b] is None]
        cols = [f.csv_col for f in sorted(self.fields, key=lambda f: f.csv_col)]
        if cols != list(range(len(self.fields))):
            p.append("csv_col is not 0..n-1")
        if [f.csv_col for f in self.fields] != cols:
            p.append("csv_col order differs from bit order (CSV columns concatenate to the word)")
        for key, names in self.cycle_addr.items():
            if len(names) != 4:
                p.append(f"cycle_addr.{key}: expected 4 entries")
            ws = set()
            for c, n in enumerate(names):
                if n not in self.by_name:
                    p.append(f"cycle_addr.{key}: unknown field {n}")
                    continue
                f = self.by_name[n]
                ws.add(f.width)
                if f.addr_info().get("cycle") != c:
                    p.append(f"cycle_addr.{key}[{c}]: {n} is not marked cycle {c}")
            if len(ws) > 1:
                p.append(f"cycle_addr.{key}: mixed widths {sorted(ws)}")
        if self.imm_layout:
            p += self._check_imm()
        return p

    def _check_imm(self) -> list[str]:
        p = []
        seen = []
        for s in self.imm_layout["segments"]:
            hi, lo = s["bits"]
            a, b = s["pos"]
            n = hi - lo + 1
            if b - a + 1 != n:
                p.append(f"imm segment {s}: bit count and pos range differ")
            seen += range(lo, hi + 1)
            span = set(range(a, b + 1))
            covered = set()
            for name in s["fields"]:
                f = self.by_name.get(name)
                if f is None:
                    p.append(f"imm segment {s}: unknown field {name}")
                    continue
                covered |= set(range(f.pos, f.end))
            if covered != span:
                p.append(f"imm segment bits {hi}..{lo}: fields {s['fields']} do not cover pos {a}..{b} exactly")
            for r in s.get("replicas", ()):
                if r[1] - r[0] != b - a:
                    p.append(f"imm segment {s}: replica {r} has a different width")
        if sorted(seen) != list(range(32)):
            p.append("imm_layout does not cover payload bits 0..31 exactly once")
        return p


@lru_cache(maxsize=None)
def load(kind: str = "j", path: str | None = None) -> Schema:
    """Load the schema for 'j' (flat PE word, 426 bit) or 'm' (MV word, 82 bit)."""
    p = Path(path) if path else SPEC_DIR / SCHEMA_FILES[kind]
    with open(p, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    s = Schema(data, p)
    if s.kind != kind and path is None:
        raise ValueError(f"{p}: kind {s.kind!r}, expected {kind!r}")
    return s


def kind_of_width(width: int) -> str:
    for k in SCHEMA_FILES:
        if load(k).width == width:
            return k
    raise ValueError(f"no schema for a {width}-bit word (auto_stride 'i' words are not supported)")

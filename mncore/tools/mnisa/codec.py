"""decode / encode of flat 'j' (426 bit) and 'm' (82 bit) instruction words.

A word is handled as the bit string printed by assemble3 after 'j ' / 'm ' (pos 0 = leftmost
character = MSB). An int is also accepted (the string read as a binary number).
"""
from __future__ import annotations

from . import schema as _schema


def _as_bits(word, kind: str | None) -> tuple[str, str]:
    if isinstance(word, str):
        bits = "".join(word.split())
        if set(bits) - {"0", "1"}:
            raise ValueError("word must be a string of 0/1")
        k = kind or _schema.kind_of_width(len(bits))
        w = _schema.load(k).width
        if len(bits) != w:
            raise ValueError(f"{k} word must be {w} bits, got {len(bits)}")
        return bits, k
    if isinstance(word, int):
        if kind is None:
            raise ValueError("kind is required for an int word")
        w = _schema.load(kind).width
        if word < 0 or word >> w:
            raise ValueError(f"int does not fit in {w} bits")
        return format(word, f"0{w}b"), kind
    raise TypeError(f"unsupported word type {type(word).__name__}")


def decode(word, kind: str | None = None) -> dict[str, int]:
    """Return {field name: value} for every field, in bit order. kind is inferred from the length of a string."""
    bits, k = _as_bits(word, kind)
    return {f.name: int(bits[f.pos:f.end], 2) for f in _schema.load(k).fields}


def decode_bits(word, kind: str | None = None) -> dict[str, str]:
    """Like decode() but the values are the binary strings of each field (as in the CSV)."""
    bits, k = _as_bits(word, kind)
    return {f.name: bits[f.pos:f.end] for f in _schema.load(k).fields}


def encode(values: dict, kind: str = "j", strict: bool = True) -> str:
    """Build the bit string from {field name: int or binary string}. Missing fields are 0.

    strict=True rejects unknown names and values that do not fit in the field.
    """
    s = _schema.load(kind)
    out = ["0"] * s.width
    for name, v in values.items():
        f = s.by_name.get(name)
        if f is None:
            if strict:
                raise KeyError(f"unknown {kind} field {name!r}")
            continue
        if isinstance(v, str):
            if len(v) != f.width or set(v) - {"0", "1"}:
                raise ValueError(f"{name}: {v!r} is not a {f.width}-bit binary string")
            b = v
        else:
            v = int(v)
            if v < 0 or v >> f.width:
                if strict:
                    raise ValueError(f"{name}: {v} does not fit in {f.width} bits")
                v &= (1 << f.width) - 1
            b = format(v, f"0{f.width}b")
        out[f.pos:f.end] = b
    return "".join(out)


def to_int(bits: str) -> int:
    return int(bits, 2)


def from_int(value: int, kind: str = "j") -> str:
    return _as_bits(value, kind)[0]


def nonzero(fields: dict[str, int]) -> dict[str, int]:
    return {k: v for k, v in fields.items() if v}


# ---- derived views -------------------------------------------------------

def is_imm(word) -> bool:
    lay = _schema.load("j").imm_layout
    f = _schema.load("j")[lay["when"]["field"]]
    bits, _ = _as_bits(word, "j")
    return bits[f.pos:f.end] == lay["when"]["val"]


def imm_payload(word) -> int:
    """32-bit immediate payload laid out by imm_layout (meaningful only when is_imm(word))."""
    bits, _ = _as_bits(word, "j")
    v = 0
    for s in _schema.load("j").imm_layout["segments"]:
        hi, lo = s["bits"]
        a, b = s["pos"]
        v |= int(bits[a:b + 1], 2) << lo
    return v


def imm_insert(word, payload: int, replicate: bool = True) -> str:
    """Write a 32-bit payload into a j word (and its replicas, as assemble3 does)."""
    if payload < 0 or payload >> 32:
        raise ValueError("payload must be a 32-bit unsigned value")
    out = list(_as_bits(word, "j")[0])
    for s in _schema.load("j").imm_layout["segments"]:
        hi, lo = s["bits"]
        a, b = s["pos"]
        seg = format((payload >> lo) & ((1 << (hi - lo + 1)) - 1), f"0{hi - lo + 1}b")
        out[a:b + 1] = seg
        if replicate:
            for ra, rb in s.get("replicas", ()):
                out[ra:rb + 1] = seg
    return "".join(out)


def imm_replicas_ok(word) -> bool:
    """True when every replica of the imm payload equals its primary segment."""
    bits, _ = _as_bits(word, "j")
    for s in _schema.load("j").imm_layout["segments"]:
        a, b = s["pos"]
        for ra, rb in s.get("replicas", ()):
            if bits[ra:rb + 1] != bits[a:b + 1]:
                return False
    return True


def cycle_addrs(fields: dict[str, int]) -> dict[str, list[int]]:
    """{'rfc0_w': [c0, c1, c2, c3], 'rfc0_r': [...], ..., 'lm1': [...]} from decoded j fields."""
    return {k: [fields[n] for n in names] for k, names in _schema.load("j").cycle_addr.items()}

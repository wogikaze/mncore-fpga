"""Read and write assemble3 '.asm' text (flat, packer disabled).

Line kinds:
  j <426 bits>   flat PE instruction word
  m <82 bits>    MV instruction word
  i <292 bits>   auto_stride PE word (kept as text; not decoded)
  d <args>       debug statement (d set / d get ...), kept verbatim
  r <args>       data line written in the .vsm (e.g. 'r 0 000000000 001 3E80...'); assemble3 passes it
                 through unchanged. Any other leading token is kept the same way (kind = that token).
  # ...          comment (e.g. '# ! assembler version : ...')
Blank lines are dropped. CRLF is accepted.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

WORD_WIDTH = {"j": 426, "m": 82, "i": 292}


@dataclass
class AsmLine:
    kind: str  # 'j', 'm', 'i', '#', or the leading token of a statement ('d', 'r', ...)
    text: str  # bits for j/m/i, the arguments of a statement, the whole line for '#'
    lineno: int = 0

    @property
    def bits(self) -> str:
        if self.kind not in WORD_WIDTH:
            raise ValueError(f"line {self.lineno}: '{self.kind}' line has no instruction bits")
        return self.text

    @property
    def args(self) -> list[str]:
        return self.text.split()

    def __str__(self) -> str:
        if self.kind == "#":
            return self.text
        return f"{self.kind} {self.text}" if self.text else self.kind


def parse_asm(text: str, source: str = "<asm>") -> list[AsmLine]:
    out = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            out.append(AsmLine("#", line, n))
            continue
        kind, _, rest = line.partition(" ")
        rest = rest.strip()
        if kind in WORD_WIDTH:
            if len(rest) != WORD_WIDTH[kind] or set(rest) - {"0", "1"}:
                raise ValueError(f"{source}:{n}: '{kind}' line must have {WORD_WIDTH[kind]} bits of 0/1")
            out.append(AsmLine(kind, rest, n))
        else:
            out.append(AsmLine(kind, rest, n))
    return out


def read_asm(path) -> list[AsmLine]:
    p = Path(path)
    return parse_asm(p.read_text(encoding="utf-8", errors="strict"), str(p))


def format_asm(lines) -> str:
    return "".join(f"{ln}\n" for ln in lines)


def write_asm(path, lines) -> None:
    Path(path).write_text(format_asm(lines), encoding="utf-8", newline="\n")


def words(lines, kinds=("j", "m")) -> list[AsmLine]:
    """Only the instruction-word lines of the given kinds, in order."""
    return [ln for ln in lines if ln.kind in kinds]

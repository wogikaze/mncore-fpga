#!/usr/bin/env python3
"""WP33: run MV programs on the official assembler and emulator (WSL) and read the results.

    from mvemu import run, mfields, set_mfields
    res = run({"name": Prog or vsm text, ...}, workdir)

Programs are .vsm texts; words can be edited after the assembly (j and m words, by index among
the words of their kind) to pin the emulator's semantics of fields the assembler never sets.
The official binaries are only called (WP31's emu_batch.sh through l1emu.run_programs), never
copied (contract section 9).
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE.parent / "l1bm"))           # WP31 tools (used, not changed)
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
from l1emu import Result, fields, run_programs, set_fields  # noqa: E402,F401
from mnisa.codec import decode  # noqa: E402

M64 = (1 << 64) - 1


def mfields(bits: str) -> Dict[str, int]:
    return decode(bits, "m")


_MSCHEMA = None


def set_mfields(bits: str, changes: Dict[str, int]) -> str:
    """Returns the m word with the given fields replaced (pos 0 = leftmost character)."""
    global _MSCHEMA
    if _MSCHEMA is None:
        from mnisa.schema import load
        _MSCHEMA = {f.name: f for f in load("m").fields}
    b = list(bits)
    for name, v in changes.items():
        fd = _MSCHEMA[name]
        s = format(v, f"0{fd.width}b")
        assert len(s) == fd.width, (name, v)
        b[fd.pos:fd.pos + fd.width] = list(s)
    return "".join(b)


def words_of(res: Result) -> List[Tuple[str, str]]:
    """The j / m words of the program in order (kind, bits)."""
    return [(k, b) for k, b in res.seq if k in "jm"]


def run(texts: Dict[str, str], workdir, jobs: int = 8, reuse: bool = False,
        edits: Optional[Dict[str, List[Tuple[str, int, Dict[str, int]]]]] = None) -> Dict[str, Result]:
    """texts: name -> .vsm text. edits: name -> [(kind 'j' | 'm', index among the words of that
    kind, {field: value})]; those programs are assembled, edited and run from the edited
    assembler output. Returns name -> Result (Result.seq holds the words actually run)."""
    edits = edits or {}
    plain = {n: t for n, t in texts.items() if n not in edits}
    res = run_programs(plain, workdir, jobs=jobs, reuse=reuse) if plain else {}
    ed = {n: t for n, t in texts.items() if n in edits}
    if ed:
        res0 = run_programs(ed, str(workdir) + "_a", jobs=jobs, reuse=reuse)
        asm = {}
        for n in ed:
            r = res0[n]
            if r.asm_err:
                res[n] = r
                continue
            seq = list(r.seq)
            idx = {"j": [i for i, (k, _) in enumerate(seq) if k == "j"],
                   "m": [i for i, (k, _) in enumerate(seq) if k == "m"]}
            for kind, k, ch in edits[n]:
                i = idx[kind][k]
                bits = seq[i][1]
                bits = set_fields(bits, ch) if kind == "j" else set_mfields(bits, ch)
                seq[i] = (kind, bits)
            lines = [f"{k} {t}" if k in "jm" else t for k, t in seq]
            asm[n] = "\n".join(lines) + "\n"
        res.update(run_programs({}, str(workdir) + "_b", jobs=jobs, asm=asm, reuse=reuse))
    return res


def rline(group: int, addr: int, vals: List[int]) -> List[str]:
    """DRAM initial data lines of the emulator ('r <group> <addr> <count> <long words>'), at most
    4095 long words per line."""
    out = []
    for o in range(0, len(vals), 4095):
        part = vals[o:o + 4095]
        out.append(f"r {group} {addr + o:09x} {len(part):03x} " + "".join(f"{v:016X}" for v in part))
    return out

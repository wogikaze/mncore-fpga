#!/usr/bin/env python3
"""WP31: L1BM test programs: initial data, body, d get of the L1B n0c0b0 (official and model).

A program initialises the L1BM (long words 0..LB-1) and, for the PEs of MABs 0..init_mabs-1
of L1B n0c0b0, GRF0 / GRF1 long words 0..31, LM0 / LM1 long words 0..63 and T (d set). Then
the body runs, and the same regions of all 64 PEs of the L1B and the L1BM are read (d get).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import l1model as L
import pemodel as P
from l1emu import fields, run_programs, set_fields

LB = 1024          # L1BM long words initialised and read
GRF_LONGS = 32
LM_LONGS = 64


@dataclass
class Prog:
    name: str
    body: List[str]
    init_mabs: int = 16
    data: str = "tag"          # bits (= tag) | f64 | f32 | f16 | int: styled() of splitmix64
    seed: int = 1
    edits: List[Tuple[int, Dict[str, int]]] = field(default_factory=list)  # (j word index, fields)
    note: str = ""
    lb_zero: bool = False      # leave the L1BM zero
    stop: Optional[Tuple[int, int, int]] = None     # gen_tests: (word, 1 E_RANGE / 2 E_UNSUPPORTED, field)


M64 = (1 << 64) - 1
STYLES = {"bits": 0, "f64": 1, "f32": 2, "f16": 3, "int": 4, "tag": 0}


class SplitMix64:
    """The data generator of the tests; tb_l1bm_env.v has the same (sm_next, styled)."""

    def __init__(self, seed: int):
        self.s = seed & M64

    def next(self) -> int:
        self.s = (self.s + 0x9E3779B97F4A7C15) & M64
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & M64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M64
        return z ^ (z >> 31)


def styled(r: int, style: int) -> int:
    """Turns a random long word into test data (tb_l1bm.v: function styled)."""
    if style == 1:      # double: exponent 0, 2047 or 1000..1063
        sel = (r >> 4) & 15
        e = 0 if sel == 0 else 2047 if sel == 1 else 1000 + ((r >> 56) & 63)
        return (r & (1 << 63)) | (e << 52) | (r & ((1 << 52) - 1))
    if style == 2:      # two singles: exponent 0, 255 or 110..141
        out = 0
        for h in ((r >> 32) & 0xFFFFFFFF, r & 0xFFFFFFFF):
            sel = h & 15
            e = 0 if sel == 0 else 255 if sel == 1 else 110 + ((h >> 25) & 31)
            out = (out << 32) | (h & 0x80000000) | (e << 23) | (h & 0x7FFFFF)
        return out
    if style == 3:      # four halves: exponent 0, 63 or 24..39
        out = 0
        for k in range(4):
            q = (r >> (48 - 16 * k)) & 0xFFFF
            sel = q & 7
            e = 0 if sel == 0 else 63 if sel == 1 else 24 + ((q >> 9) & 15)
            out = (out << 16) | (q & 0x8000) | (e << 9) | (q & 0x1FF)
        return out
    if style == 4:      # integers: 0, 1, all ones, a byte, two halves, or any
        sel = r & 7
        return [0, 1, M64, r & 0xFF, r & 0x0000FFFF0000FFFF, r, r, r][sel]
    return r


def name_seed(name: str) -> int:
    h = 0xCBF29CE484222325
    for ch in name.encode():
        h = ((h ^ ch) * 0x100000001B3) & M64
    return h


class Init:
    """Initial data of a program (also loaded into the model and the testbench).
    Order: L1BM long words 0..LB-1, then for every PE of MABs 0..init_mabs-1 (in PE order)
    GRF0 0..31, GRF1 0..31, LM0 0..63, LM1 0..63, T 0..7 (long words), from SplitMix64(seed)."""

    def __init__(self, p: Prog):
        self.seed = name_seed(f"{p.name}:{p.seed}")
        self.style = STYLES[p.data]
        g = SplitMix64(self.seed)
        self.lb = [0 if p.lb_zero else styled(g.next(), self.style) for a in range(LB)]
        self.pe = {}   # (space, pe) -> list of long words; space r s m n t
        for m in range(p.init_mabs):
            for q in range(4):
                i = m * 4 + q
                for sp, n in (("r", GRF_LONGS), ("s", GRF_LONGS), ("m", LM_LONGS), ("n", LM_LONGS), ("t", 8)):
                    self.pe[(sp, i)] = [styled(g.next(), self.style) for _ in range(n)]


def vsm_of(p: Prog, ini: Init) -> str:
    out = []
    if not p.lb_zero:
        out.append(f"d set $lb0n0c0b0 {LB} " + "".join(f"{v:016x}" for v in ini.lb))
    for (sp, i), vals in sorted(ini.pe.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        loc = P.loc(i)
        if sp == "t":
            out.append(f"d set $llt{loc} 4 " + "".join(f"{v:016x}" for v in vals))
        else:
            out.append(f"d set $l{sp}0{loc} {len(vals)} " + "".join(f"{v:016x}" for v in vals))
    out += p.body
    out.append(f"d get $lb0n0c0b0 {LB}")
    out.append(f"d get $lr0n0c0b0 {GRF_LONGS}")
    out.append(f"d get $ls0n0c0b0 {GRF_LONGS}")
    out.append(f"d get $lm0n0c0b0 {LM_LONGS}")
    out.append(f"d get $ln0n0c0b0 {LM_LONGS}")
    out.append("d get $lltn0c0b0 4")
    return "\n".join(out) + "\n"


def load_model(p: Prog, ini: Init, n_mab: int) -> Tuple[P.PeState, L.L1State]:
    l1 = L.L1State(n_mab=n_mab)
    for a, v in enumerate(ini.lb):
        l1.mem[a] = v
    pe = P.PeState(n_mab * 4)
    for (sp, i), vals in ini.pe.items():
        if i >= n_mab * 4:
            continue
        if sp == "t":
            for k, v in enumerate(vals):
                pe.t[i][2 * k] = v >> 32
                pe.t[i][2 * k + 1] = v & 0xFFFFFFFF
        else:
            mem = pe.mem[sp][i]
            for k, v in enumerate(vals):
                mem[2 * k] = v >> 32
                mem[2 * k + 1] = v & 0xFFFFFFFF
    return pe, l1


def jwords(res) -> List[str]:
    return [b for k, b in res.words if k == "j"]


def run(progs: List[Prog], workdir, jobs=8, reuse=False):
    """Runs the programs on the official tools (edited words where the program says so).
    Returns name -> (Result, Init, [j words actually run]). reuse: read an earlier run."""
    inits = {p.name: Init(p) for p in progs}
    texts = {p.name: vsm_of(p, inits[p.name]) for p in progs}
    plain = {p.name: texts[p.name] for p in progs if not p.edits}
    res = run_programs(plain, workdir, jobs=jobs, reuse=reuse) if plain else {}
    edited = [p for p in progs if p.edits]
    if edited:
        res0 = run_programs({p.name: texts[p.name] for p in edited}, str(workdir) + "_a", jobs=jobs, reuse=reuse)
        asm = {}
        for p in edited:
            r = res0[p.name]
            if r.asm_err:
                res[p.name] = r
                continue
            js = jwords(r)
            for idx, ch in p.edits:
                ch = dict(ch)
                if "__copy__" in ch:        # replace the word by a copy of another one first
                    js[idx] = js[ch.pop("__copy__")]
                js[idx] = set_fields(js[idx], ch)
            lines, k = [], 0
            for kind, txt in r.seq:
                if kind == "j":
                    lines.append("j " + js[k])
                    k += 1
                elif kind in ("m",):
                    lines.append("m " + txt)
                else:
                    lines.append(txt)
            asm[p.name] = "\n".join(lines) + "\n"
        res.update(run_programs({}, str(workdir) + "_b", jobs=jobs, asm=asm, reuse=reuse))
    return {p.name: (res[p.name], inits[p.name], jwords(res[p.name]) if not res[p.name].asm_err else [])
            for p in progs}


def model_run(p: Prog, ini: Init, words: List[str], n_mab: int = 16):
    pe, l1 = load_model(p, ini, n_mab)
    for w in words:
        P.step(pe, l1, fields(w))
    return pe, l1


def compare(p: Prog, r, ini, words, n_mab=16, verbose=5):
    """Model vs official on the dumped keys (PEs of MABs < n_mab and the L1BM)."""
    pe, l1 = model_run(p, ini, words, n_mab)
    got = P.dump(pe, l1, r.dump.keys())
    bad = [(k, r.dump[k], got[k]) for k in sorted(got) if got[k] != r.dump[k]]
    lines = [f"  {k[0]} {k[1]} {k[2]:#x}: official {e:016x} model {g:016x}" for k, e, g in bad[:verbose]]
    return bad, lines

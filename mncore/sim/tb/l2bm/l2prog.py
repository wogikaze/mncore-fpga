#!/usr/bin/env python3
"""WP32: L2BM test programs: initial data, body, d get of L2B n0c0 (official tools).

A program initialises (d set, splitmix64 data, see Init) the L2BM of L2B n0c0 (long words
0..L2-1), the L1BM of L1Bs n0c0b0 .. n0c0b<l1bs-1> (long words 0..L1-1) and, with pes, GRF0 /
GRF1 / LM0 / LM1 / T of the 4 PEs of MAB n0c0b0m0. Then the body runs, and the L2BM, the L1BMs
of the 8 L1Bs of n0c0 and (with pes) the PE regions are read back (d get).

The reduced topology of the RTL tests (1 L2B, 1 L1B, 1 MAB) is the official full chip with
data only in the units that exist (contract section 3 (b)): l1bs = 1 for tests of N_L1B = 1.
The official binaries are only called (WP31's emu_batch.sh through l1emu), never copied.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "l1bm"))     # WP31 tools (used, not changed)
from l1emu import fields, run_programs, set_fields  # noqa: E402,F401
from l1prog import SplitMix64, name_seed  # noqa: E402
from l1prog import styled as styled_l1  # noqa: E402

L2 = 2048          # L2BM long words initialised and read (contract L2BM_DEPTH)
L1 = 1024          # L1BM long words per L1B (contract L1BM_DEPTH)
GRF_LONGS = 32
LM_LONGS = 64
M64 = (1 << 64) - 1

# data styles: those of WP31 (0 bits, 1 f64, 2 f32, 3 f16, 4 int) and 5 dar: every 32-bit half
# is a small DRAM chunk number (0..63), for DAR tests (the official DAR is seen through the DRAM
# chunks an indirect MV reads, which must be inside the marked DRAM region)
STYLES = {"bits": 0, "f64": 1, "f32": 2, "f16": 3, "int": 4, "dar": 5}


def styled(r: int, style: int) -> int:
    """Turns a random long word into test data (tb_l2bm_env.v: function styled)."""
    if style == 5:
        return (((r >> 40) & 63) << 32) | ((r >> 8) & 63)
    return styled_l1(r, style)


@dataclass
class Prog:
    name: str
    body: List[str]
    l1bs: int = 1              # L1Bs of n0c0 (b0 ..) whose L1BM is initialised
    pes: bool = False          # initialise (and read) the PEs of MAB n0c0b0m0
    data: str = "bits"
    seed: int = 1
    edits: List[Tuple[int, Dict[str, int]]] = field(default_factory=list)  # (j word index, fields)
    l2_zero: bool = False      # leave the L2BM zero
    l1_zero: bool = False      # leave the L1BMs zero
    stop: Optional[Tuple[int, int, int]] = None    # (word, 1 E_RANGE / 2 E_UNSUPPORTED, field)
    dar: Optional[Tuple[int, int]] = None          # observe DAR entries [a, a + n) after the body
    note: str = ""


class Init:
    """Initial data of a program (also made by the testbench). Order: L2BM long words 0..L2-1,
    then for every initialised L1B (b0 ..) its L1BM long words 0..L1-1, then with pes for the
    PEs n0c0b0m0p0..p3 (in order) GRF0 0..31, GRF1 0..31, LM0 0..63, LM1 0..63, T 0..7 (long
    words), all from SplitMix64(seed) through styled()."""

    def __init__(self, p: Prog):
        self.seed = name_seed(f"{p.name}:{p.seed}")
        self.style = STYLES[p.data]
        g = SplitMix64(self.seed)
        self.l2 = [0 if p.l2_zero else styled(g.next(), self.style) for _ in range(L2)]
        self.l1 = [[0 if p.l1_zero else styled(g.next(), self.style) for _ in range(L1)] for _ in range(p.l1bs)]
        self.pe = {}   # (space, pe) -> long words; space r s m n t
        if p.pes:
            for i in range(4):
                for sp, n in (("r", GRF_LONGS), ("s", GRF_LONGS), ("m", LM_LONGS), ("n", LM_LONGS), ("t", 8)):
                    self.pe[(sp, i)] = [styled(g.next(), self.style) for _ in range(n)]


def pe_loc(i: int) -> str:
    return f"n0c0b0m{i // 4}p{i % 4}"


def init_lines(p: Prog, ini: Init) -> List[str]:
    out = []
    if not p.l2_zero:
        out.append(f"d set $lc0n0c0 {L2} " + "".join(f"{v:016x}" for v in ini.l2))
    if not p.l1_zero:
        for b, vals in enumerate(ini.l1):
            out.append(f"d set $lb0n0c0b{b} {L1} " + "".join(f"{v:016x}" for v in vals))
    for (sp, i), vals in sorted(ini.pe.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        if sp == "t":
            out.append(f"d set $llt{pe_loc(i)} 4 " + "".join(f"{v:016x}" for v in vals))
        else:
            out.append(f"d set $l{sp}0{pe_loc(i)} {len(vals)} " + "".join(f"{v:016x}" for v in vals))
    return out


def get_lines(p: Prog) -> List[str]:
    out = [f"d get $lc0n0c0 {L2}"]
    for b in range(8):
        out.append(f"d get $lb0n0c0b{b} {L1}")
    if p.pes:
        out += [f"d get $lr0n0c0b0m0 {GRF_LONGS}", f"d get $ls0n0c0b0m0 {GRF_LONGS}",
                f"d get $lm0n0c0b0m0 {LM_LONGS}", f"d get $ln0n0c0b0m0 {LM_LONGS}", "d get $lltn0c0b0m0 4"]
    return out


# DAR observer (only in the program that observes DAR): DRAM of group 0 gets markers (long word
# a = MARK | a) through L2BM long words OBS_SRC.. (above the reduced L2BM, the official has 32768),
# then an indirect MV reads chunk i of 16 long words from DRAM 16 * DAR[a + i] (nd1) into L2BM
# OBS_DST + 16 i; DAR[a + i] is the chunk number of the marker found there (0 outside the marks).
MARK = 0xDA00000000000000
OBS_SRC = 16384
OBS_DST = 20480
OBS_CHUNKS = 64


def dar_lines(a: int, n: int) -> List[str]:
    assert n % 4 == 0 and 16 * n <= 8192
    out = [f"d set $lc{OBS_SRC}n0c0 {16 * OBS_CHUNKS} " +
           "".join(f"{MARK | k:016x}" for k in range(16 * OBS_CHUNKS)),
           f"mvp/n{16 * OBS_CHUNKS} $lc{OBS_SRC}@0.0 $d0@0", "nop", "nop", "nop",
           f"mvp/n{16 * n}nd1 $di{a}@0 $lc{OBS_DST}@0.0", "nop", "nop", "nop"]
    for i in range(n):
        out.append(f"d get $lc{OBS_DST + 16 * i}n0c0 1")
    return out


def dar_of(dump: Dict, a: int, n: int) -> List[Optional[int]]:
    """DAR entries a .. a + n - 1 from the observer's dump (None: outside the marked chunks)."""
    out = []
    for i in range(n):
        v = dump.get(("L2BM", "n0c0", OBS_DST + 16 * i), 0)
        if (v & ~0xFFFF) == MARK and (v & 15) == 0:
            out.append((v & 0xFFFF) >> 4)
        else:
            out.append(None)
    return out


def vsm_of(p: Prog, ini: Init, observe_dar: bool = False) -> str:
    out = init_lines(p, ini) + list(p.body)
    if observe_dar:
        out += dar_lines(*p.dar)
    else:
        out += get_lines(p)
    return "\n".join(out) + "\n"


def jwords(res) -> List[str]:
    return [b for k, b in res.words if k == "j"]


def run(progs: List[Prog], workdir, jobs=8, reuse=False, observe_dar=False, extra=None):
    """Runs the programs on the official tools (words edited where the program says so).
    Returns name -> (Result, Init, [j words of the body]). With observe_dar the DAR observer
    replaces the d get. extra: name -> text appended after the body (before the d get)."""
    inits = {p.name: Init(p) for p in progs}
    texts = {}
    for p in progs:
        q = p
        if extra and p.name in extra:
            q = Prog(**{**p.__dict__, "body": list(p.body) + extra[p.name]})
        texts[p.name] = vsm_of(q, inits[p.name], observe_dar)
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
                elif kind == "m":
                    lines.append("m " + txt)
                else:
                    lines.append(txt)
            asm[p.name] = "\n".join(lines) + "\n"
        res.update(run_programs({}, str(workdir) + "_b", jobs=jobs, asm=asm, reuse=reuse))
    return {p.name: (res[p.name], inits[p.name], jwords(res[p.name]) if not res[p.name].asm_err else [])
            for p in progs}

#!/usr/bin/env python3
"""WP33: reference model of the MV unit at the machine-code level (m word fields, 82 bits).

This documents the semantics the RTL (mncore/rtl/mv) follows, written while probing the official
emulator (probe.py). The expected values of the tests always come from the emulator; the model is
a development aid (gen_tests.py compares it with every official run).

Chip: 4 groups, each with a PDM, a DRAM and a DAR (1024 x 32 bit), and 2 L2Bs (8 L2BMs; L2B
g*2+c is n<g>c<c>). The model runs on the whole chip or on the reduced topology of the RTL
(contract section 3: only group 0 and its L2B 0 exist; PDM / DRAM / L2BM capacities reduced):
units that do not exist read as zero and drop writes; an access beyond a reduced capacity is
RangeError, raised before anything is written.

Semantics of the m word (official emulator, probe.py; mncore/rtl/mv/README.md has the tables):
  - mmode: the direction, tmode: the form; (mmode, tmode) pairs outside FORMS: mmode 111 or
    tmode 110 / 111 do nothing (the MV still completes: its tag counts), the others abort.
  - destid / srcid = group * 2 + L2B. Reductions: {destid[0], srcid} is the opcode, destid[2:1]
    the PDM group. Which of them a form reads: plan().
  - adra: the DRAM address / 16 (forms with DRAM), the PDM address / 16 (PDM <-> L2BM, the source
    of PDM -> PDM); indirect: nd << 10 | M (nd: 5 bits, adra[14:10]).
    adrb: the L2BM address / 16 (bits 1..0 not used: 64-long-word aligned) or the PDM address / 16
    (PDM <-> DRAM, the destination of PDM -> PDM).
  - Addresses wrap at the chip's sizes: L2BM 2**15, PDM 2**19, DRAM 2**29 long words.
  - nw: chunks of 16 long words; 0 aborts; the forms b2 / b4 / b and DRAM -> PDM mvd abort when
    nw % 4 != 0; the others run nw chunks.
  - The DRAM side of a group is walked chunk by chunk: chunk i of group g is at adra*16 + 16 i,
    or with indirect at 16 * (DAR_g[(M + i / N) % 1024] + i % N), N = nd; nd = 0 is N infinite:
    16 * (DAR_g[M] + i).
  - All reads of an MV come before its writes (PDM -> PDM with overlapping ranges is a copy).
  - priority: no effect. mvid: the tag (wait).
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "l2bm"))
sys.path.insert(0, str(HERE.parent / "l1bm"))
import l2model as L2  # noqa: E402  (WP32: L2BM instructions, DAR, reductions)

GROUPS = 4
L2BM_CHIP = 1 << 15
PDM_CHIP = 1 << 19
DRAM_CHIP = 1 << 29          # the emulator wraps MV DRAM addresses here (probe: wrap)
DAR_ENTRIES = 1024
OPS = L2.OPS                 # {opcode: name}
M64 = (1 << 64) - 1

# (mmode, tmode) of the forms the emulator runs (SDM 3.5.8.2 .. 3.5.8.25, and four more that the
# assembler does not make: p2d / d2p / p2p parallel and p2c b2)
P2D, P2C, D2C, P2P, D2P, C2P, C2D = range(7)
SINGLE, PAR, TB2, TB4, TB, TD = range(6)
FORMS = {
    (P2D, SINGLE): "mvp $p@g $d@g", (D2P, SINGLE): "mvp $d@g $p@g", (P2C, SINGLE): "mvp $p@g $lc@g.l",
    (C2P, SINGLE): "mvp $lc@g.l $p@g", (D2C, SINGLE): "mvp $d@g $lc@g.l", (C2D, SINGLE): "mvp $lc@g.l $d@g",
    (P2P, SINGLE): "mvp $p@g $p@g",
    (P2C, PAR): "mvp $p $lc@.l", (C2P, PAR): "mvp $lc@.l $p", (D2C, PAR): "mvp $d $lc@.l",
    (C2D, PAR): "mvp $lc@.l $d",
    (P2D, PAR): "(p2d parallel)", (D2P, PAR): "(d2p parallel)", (P2P, PAR): "(p2p parallel)",
    (D2C, TB2): "mvb2 $d $lc", (C2D, TB2): "mvr2 $lc $d", (C2P, TB2): "mvr2 $lc@g $p@g",
    (P2C, TB2): "(p2c b2: PDM of group g to both L2BMs of g)",
    (D2C, TB4): "mvb4 $d $lc", (C2D, TB4): "mvr4 $lc $d",
    (P2C, TB): "mvb $p@g $lc", (C2P, TB): "mvr $lc $p@g", (D2C, TB): "mvb $d $lc", (C2D, TB): "mvr $lc $d",
    (P2C, TD): "mvd $p@g $lc", (C2P, TD): "mvd $lc $p@g", (P2D, TD): "mvd $p@g $d", (D2P, TD): "mvd $d $p@g",
}
REDUCE = {(C2D, TB2), (C2P, TB2), (C2D, TB4), (C2P, TB), (C2D, TB)}
NW4 = {(m, t) for (m, t) in FORMS if t in (TB2, TB4, TB)} | {(D2P, TD)}   # nw % 4 != 0 aborts


class RangeError(Exception):
    pass


class Unsupported(Exception):
    def __init__(self, field_name: str, msg: str = ""):
        super().__init__(f"{field_name}: {msg}")
        self.field = field_name


@dataclass
class Topo:
    """Which units exist and the capacities (long words). full(): the chip."""
    groups: int = 1          # groups 0 .. groups-1 have their L2B 0 (and the PDM / DRAM / DAR)
    l2b1: bool = False       # L2B 1 of those groups exists too
    l2_cap: int = 2048
    pdm_cap: int = 1 << 17
    dram_cap: int = 1 << 19

    @staticmethod
    def full() -> "Topo":
        return Topo(groups=4, l2b1=True, l2_cap=L2BM_CHIP, pdm_cap=PDM_CHIP, dram_cap=DRAM_CHIP)

    def has(self, kind: str, g: int, c: int = 0) -> bool:
        if g >= self.groups:
            return False
        return kind != "C" or c == 0 or self.l2b1


class Sparse(dict):
    def __missing__(self, k):
        return 0


@dataclass
class State:
    topo: Topo = field(default_factory=Topo)
    l2: List[L2.L2State] = field(default_factory=list)      # per L2B (index g*2+c): L2BM; DAR of g in g*2
    pdm: List[Sparse] = field(default_factory=lambda: [Sparse() for _ in range(GROUPS)])
    dram: List[Sparse] = field(default_factory=lambda: [Sparse() for _ in range(GROUPS)])
    tags: List[int] = field(default_factory=lambda: [0] * 256)   # completed MVs not yet waited for (max 2)
    halted: bool = False     # a wait for a tag that is not there: nothing after it runs (official)
    touched: set = field(default_factory=set)   # (kind, g, chunk address // 16) of the PDM / DRAM chunks used

    def __post_init__(self):
        if not self.l2:
            self.l2 = [L2.L2State(n_l1b=1, l2_cap=L2BM_CHIP) for _ in range(8)]

    def l2bm(self, g: int, c: int) -> List[int]:
        return self.l2[2 * g + c].l2bm

    def dar(self, g: int) -> List[int]:
        return self.l2[2 * g].dar


def lane_bits(dmode: int) -> int:
    return {0: 64, 1: 32, 2: 16}[dmode]


def plan(f: Dict[str, int]):
    """The chunks of an m word on the whole chip, in the order of the transfer: a list of
    (dst, srcs, reduce) with dst / src = (kind, group, l2b, address) for the L2BM ('C') and the
    PDM ('P') and ('D', group, 0, chunk index) for the DRAM (address: dram_chunk()). srcs: one
    location (copy) or several (reduction)."""
    mm, tm, nw = f["mmode"], f["tmode"], f["nw"]
    pa = (f["adra"] & 0x7FFF) * 16          # PDM address in adra
    pb = f["adrb"] * 16                      # PDM address in adrb
    cb = (f["adrb"] >> 2) * 64               # L2BM address in adrb (bits 1..0 unused)
    sid, did = f["srcid"], f["destid"]
    gs, ls, gd, ld = sid >> 1, sid & 1, did >> 1, did & 1
    form = (mm, tm)
    out = []
    allc = [(g, c) for g in range(GROUPS) for c in range(2)]

    def P(g, a):
        return ("P", g, 0, a)

    def C(g, c, a):
        return ("C", g, c, a)

    def Dr(g, ci):
        return ("D", g, 0, ci)

    n = nw // 4
    if form == (P2D, SINGLE):
        out = [(Dr(gd, u), [P(gs, pb + 16 * u)], False) for u in range(nw)]
    elif form == (D2P, SINGLE):
        out = [(P(gd, pb + 16 * u), [Dr(gs, u)], False) for u in range(nw)]
    elif form == (P2C, SINGLE):
        out = [(C(gd, ld, cb + 16 * u), [P(gs, pa + 16 * u)], False) for u in range(nw)]
    elif form == (C2P, SINGLE):
        out = [(P(gd, pa + 16 * u), [C(gs, ls, cb + 16 * u)], False) for u in range(nw)]
    elif form == (D2C, SINGLE):
        out = [(C(gd, ld, cb + 16 * u), [Dr(gs, u)], False) for u in range(nw)]
    elif form == (C2D, SINGLE):
        out = [(Dr(gd, u), [C(gs, ls, cb + 16 * u)], False) for u in range(nw)]
    elif form == (P2P, SINGLE):
        out = [(P(gd, pb + 16 * u), [P(gs, pa + 16 * u)], False) for u in range(nw)]
    elif form == (P2C, PAR):
        out = [(C(g, ld, cb + 16 * u), [P(g, pa + 16 * u)], False) for u in range(nw) for g in range(GROUPS)]
    elif form == (C2P, PAR):
        out = [(P(g, pa + 16 * u), [C(g, ls, cb + 16 * u)], False) for u in range(nw) for g in range(GROUPS)]
    elif form == (D2C, PAR):
        out = [(C(g, ld, cb + 16 * u), [Dr(g, u)], False) for u in range(nw) for g in range(GROUPS)]
    elif form == (C2D, PAR):
        out = [(Dr(g, u), [C(g, ls, cb + 16 * u)], False) for u in range(nw) for g in range(GROUPS)]
    elif form == (P2D, PAR):
        out = [(Dr(g, u), [P(g, pb + 16 * u)], False) for u in range(nw) for g in range(GROUPS)]
    elif form == (D2P, PAR):
        out = [(P(g, pb + 16 * u), [Dr(g, u)], False) for u in range(nw) for g in range(GROUPS)]
    elif form == (P2P, PAR):
        out = [(P(g, pb + 16 * u), [P(g, pa + 16 * u)], False) for u in range(nw) for g in range(GROUPS)]
    elif form == (D2C, TB2):
        out = [(C(g, c, cb + 16 * u), [Dr(g, u)], False) for u in range(nw) for g, c in allc]
    elif form == (C2D, TB2):
        out = [(Dr(g, u), [C(g, 0, cb + 16 * u), C(g, 1, cb + 16 * u)], True) for u in range(nw) for g in range(GROUPS)]
    elif form == (C2P, TB2):
        out = [(P(gd, pa + 16 * u), [C(gd, 0, cb + 16 * u), C(gd, 1, cb + 16 * u)], True) for u in range(nw)]
    elif form == (P2C, TB2):
        out = [(C(gd, c, cb + 16 * u), [P(gd, pa + 16 * u)], False) for u in range(nw) for c in range(2)]
    elif form == (P2C, TB):
        out = [(C(g, c, cb + 16 * u), [P(gs, pa + 16 * u)], False) for u in range(nw) for g, c in allc]
    elif form == (C2P, TB):
        out = [(P(gd, pa + 16 * u), [C(g, c, cb + 16 * u) for g, c in allc], True) for u in range(nw)]
    elif form == (D2C, TB4):
        out = [(C(g, c, cb + 64 * u + 16 * s), [Dr(s, 2 * u + c)], False)
               for u in range(n) for c in range(2) for s in range(GROUPS) for g in range(GROUPS)]
    elif form == (C2D, TB4):
        out = [(Dr(g, 2 * u + c), [C(s, c, cb + 64 * u + 16 * g) for s in range(GROUPS)], True)
               for u in range(n) for c in range(2) for g in range(GROUPS)]
    elif form == (D2C, TB):
        out = [(C(g, c, cb + 64 * u + 16 * s), [Dr(s, u)], False)
               for u in range(n) for s in range(GROUPS) for g, c in allc]
    elif form == (C2D, TB):
        out = [(Dr(g, u), [C(s, c, cb + 64 * u + 16 * g) for s, c in allc], True)
               for u in range(n) for g in range(GROUPS)]
    elif form == (P2C, TD):
        # L2BM chunk q (16 q = 64 i + 16 j) of every L2BM (g, c) <- PDM 512 i + 16 (8 j + 2 g + c)
        out = [(C(g, c, cb + 16 * q), [P(gs, pa + 128 * q + 16 * (2 * g + c))], False)
               for q in range(nw) for g, c in allc]
    elif form == (C2P, TD):
        out = [(P(gd, pa + 128 * q + 16 * (2 * g + c)), [C(g, c, cb + 16 * q)], False)
               for q in range(nw) for g, c in allc]
    elif form == (P2D, TD):
        # chunk q = 4 i + g: DRAM chunk i of group g <- PDM 64 i + 16 g
        out = [(Dr(q % 4, q // 4), [P(gs, pb + 16 * q)], False) for q in range(nw)]
    elif form == (D2P, TD):
        out = [(P(gd, pb + 64 * u + 16 * g), [Dr(g, u)], False) for u in range(n) for g in range(GROUPS)]
    return out


def dram_chunk(st: State, f: Dict[str, int], g: int, ci: int) -> int:
    """Long word address of DRAM chunk ci of group g (direct or indirect, before wrapping)."""
    if not f["indirect"]:
        return f["adra"] * 16 + 16 * ci
    m, nd = f["adra"] & 1023, (f["adra"] >> 10) & 31
    if nd:
        e, o = (m + ci // nd) % DAR_ENTRIES, ci % nd
    else:
        e, o = m, ci
    return 16 * ((st.dar(g)[e] + o) & 0xFFFFFFFF)


def check(f: Dict[str, int]):
    """Raises Unsupported for the words the emulator aborts on; returns 'nop' / 'run'."""
    if not f["valid"]:
        return "nop"
    form = (f["mmode"], f["tmode"])
    if form not in FORMS:
        if f["mmode"] == 7 or f["tmode"] >= 6:
            return "nop"
        raise Unsupported("tmode", f"mmode {f['mmode']:03b} tmode {f['tmode']:03b} (the emulator aborts)")
    if form in REDUCE:
        if (((f["destid"] & 1) << 3) | f["srcid"]) not in OPS:
            raise Unsupported("srcid", "reduction opcode (the emulator aborts)")
        if f["dmode"] == 3:
            raise Unsupported("dmode", "reduction precision (the emulator aborts)")
    if f["nw"] == 0:
        raise Unsupported("nw", "no chunk (the emulator aborts)")
    if form in NW4 and f["nw"] % 4:
        raise Unsupported("nw", "not a multiple of 64 long words (the emulator aborts)")
    return "run"


def mv_step(st: State, f: Dict[str, int]):
    """Executes one m word (the official completes an MV when it is issued)."""
    what = check(f)
    if not f["valid"]:
        return
    if what == "run":
        form = (f["mmode"], f["tmode"])
        t = st.topo
        caps = {"P": (t.pdm_cap, PDM_CHIP), "D": (t.dram_cap, DRAM_CHIP), "C": (t.l2_cap, L2BM_CHIP)}

        def where(loc) -> Optional[int]:
            kind, g, c, a = loc
            if not t.has(kind, g, c):
                return None
            if kind == "D":
                a = dram_chunk(st, f, g, a)
            cap, chip = caps[kind]
            a %= chip
            if a + 15 >= cap:
                raise RangeError(f"{kind} n{g}c{c} {a}")
            if kind != "C":
                st.touched.add((kind, g, a // 16))
            return a

        def mem(kind, g, c):
            return st.pdm[g] if kind == "P" else st.dram[g] if kind == "D" else st.l2bm(g, c)

        op = OPS.get(((f["destid"] & 1) << 3) | f["srcid"])
        writes = []
        for dst, srcs, r in plan(f):
            da = where(dst)
            if da is None:
                continue      # an absent destination: nothing is read either
            vals = []
            for s in srcs:
                sa = where(s)
                m = mem(s[0], s[1], s[2]) if sa is not None else None
                vals.append([m[sa + k] if m is not None else 0 for k in range(16)])
            if r:
                bits = lane_bits(f["dmode"])
                v = [L2.reduce_longs(op, bits, [x[k] for x in vals]) for k in range(16)]
            else:
                v = vals[0]
            writes.append((dst[0], dst[1], dst[2], da, v))
        for kind, g, c, a, v in writes:
            m = mem(kind, g, c)
            for k in range(16):
                m[a + k] = v[k]
        del form
    if f["mvid"]:
        st.tags[f["mvid"]] = min(st.tags[f["mvid"]] + 1, 2)


def j_step(st: State, f: Dict[str, int]):
    """A j word: its wait, then its L2BM part (every L2B that exists runs it, each with its L1B 0
    (the other L1Bs are absent); the DAR of group g is the one of L2B g*2). Only the L2BM part is
    modelled (the PEs and the L1BMs beyond L1B 0 are not)."""
    wd = f["wd"]
    if wd:
        if st.tags[wd] == 0:
            st.halted = True
            return
        if st.tags[wd] >= 2:
            raise Unsupported("wd", "a wait for a tag whose MV completed twice (the emulator aborts)")
        st.tags[wd] = 0
    for g in range(GROUPS):
        if not st.topo.has("C", g, 0):
            continue
        s0 = st.l2[2 * g]
        if f["ll"] != 0 and f["l2bm_darsend"] and (f["l2bm_opcode"] & 1) and st.topo.has("C", g, 1):
            # l2bmdars of L2B 1 on the chip: the DAR of the group from n<g>c1 (l2model reads 0
            # for L2B 1, its N_L2B = 1 view)
            saved = s0.l2bm
            s0.l2bm = st.l2bm(g, 1)
            f2 = dict(f)
            f2["l2bm_opcode"] = f["l2bm_opcode"] & 2
            L2.l2_step(s0, f2)
            s0.l2bm = saved
        else:
            L2.l2_step(s0, f)
        if st.topo.has("C", g, 1):
            # L2B 1 runs the same L2BM instruction on its own L2BM and L1Bs (its DAR is not used)
            L2.l2_step(st.l2[2 * g + 1], f)


def step(st: State, kind: str, f: Dict[str, int]):
    if st.halted:
        return
    if kind == "m":
        mv_step(st, f)
    else:
        j_step(st, f)

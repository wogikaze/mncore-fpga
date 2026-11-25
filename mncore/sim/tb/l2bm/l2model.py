#!/usr/bin/env python3
"""WP32: reference model of the L2BM unit at the machine-code level (flat j word fields).

This documents the semantics the RTL (mncore/rtl/l2bm) follows, written while probing the
official emulator. The expected values of the tests always come from the emulator itself; the
model is a development aid (gen_tests.py compares it with every official run).

One L2B (n0c0) is modelled: its L2BM, the L1BMs of its 8 L1Bs, the DAR buffer and the DAR of
group 0. A topology with n_l1b < 8 has L1Bs 0..n_l1b-1; the others are absent: they receive
nothing and send zero, except that L1Bs outside the set of an l2bmr send the identity
(contract section 3).
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "l1bm"))
import l1model as L  # noqa: E402

L2BM_LONGS = 32768
L1BM_LONGS = 8192
DAR_ENTRIES = 1024
DARBUF_ENTRIES = 512

OPS = {0b0000: "fadd", 0b0001: "max", 0b0010: "min", 0b1000: "iadd", 0b1001: "band", 0b1010: "and",
       0b1100: "bor", 0b1101: "or"}
L2_FIELDS_DEFAULT = {"l1bm_gwrite": 0, "l1bm_gadr": 0, "l2bm_lwrite": 0, "l2bm_bdmode": 0, "l2bm_ladr": 0,
                     "l2bm_l1adr": 0, "l2bm_immode": 0, "l2bm_dmode": 3, "l2bm_opcode": 0,
                     "l2bm_darsend": 0, "l2bm_darwrite": 0}


class RangeError(Exception):
    pass


class Unsupported(Exception):
    pass


@dataclass
class L2State:
    n_l1b: int = 8
    l2bm: List[int] = field(default_factory=lambda: [0] * L2BM_LONGS)
    l1bm: List[List[int]] = field(default_factory=lambda: [[0] * L1BM_LONGS for _ in range(8)])
    darbuf: List[int] = field(default_factory=lambda: [0] * DARBUF_ENTRIES)
    dar: List[int] = field(default_factory=lambda: [0] * DAR_ENTRIES)
    darw_addr: int = 0
    darbuf_rd: int = 0
    dars_prev: bool = False    # the previous j word had l2bmdars (m words do not count)
    dars_l2b: int = 0          # the L2B of the first l2bmdars of a run of consecutive ones
    l2_cap: int = L2BM_LONGS
    l1_cap: int = L1BM_LONGS


def lane_bits(dmode: int) -> int:
    return {0: 64, 1: 32, 2: 16}[dmode]


def identity(op: str, bits: int) -> int:
    m = (1 << bits) - 1
    return {"fadd": 0, "iadd": 0, "bor": 0, "or": 0, "band": m, "and": 1, "max": m, "min": m >> 1}[op]


def reduce_longs(op: str, bits: int, vals: List[int]) -> int:
    f = L.fmt_of_bits(bits) if op == "fadd" else None
    out = []
    for i in range(64 // bits):
        col = [L.lanes(v, bits)[i] for v in vals]
        out.append(L.reduce_lane(op, bits, col, f, f))
    return L.from_lanes(out, bits)


def in_set(b: int, l1adr: int, immode: int) -> bool:
    keep = 7 ^ immode
    return (b & keep) == (l1adr & keep)


def l2_any(f: Dict[str, int]) -> bool:
    return any(f[k] != v for k, v in L2_FIELDS_DEFAULT.items())


def l2_step(st: L2State, f: Dict[str, int]):
    """Executes the L2BM part of one j word (L2BM <-> L1BM transfers, DAR)."""
    w1, w2 = l2_compute(st, f)
    l2_apply(st, w1, w2)


def l2_apply(st: L2State, w1, w2):
    for b, a, v, _c in w1:
        st.l1bm[b][a] = v
    for a, v in w2:
        st.l2bm[a] = v


def l2_compute(st: L2State, f: Dict[str, int]):
    """The L2BM part of one j word: reads the state and returns the writes (w1: (l1b, address,
    value, cycle) to the L1BMs, w2: (address, value) to the L2BM); DAR / DARBUF are updated here."""
    if f["ll"] == 0:
        st.dars_prev = False
        return [], []
    gw, lw, bd = f["l1bm_gwrite"], f["l2bm_lwrite"], f["l2bm_bdmode"]
    ab8 = f["l1bm_gadr"] * 8          # L1BM address of the 8-per-cycle forms (l2bmd)
    ab = (f["l1bm_gadr"] >> 1) * 16   # L1BM address of the 16-per-cycle forms: gadr[0] unused (probed)
    ac = f["l2bm_ladr"] * 16          # L2BM address (long words)
    l1adr, immode = f["l2bm_l1adr"], f["l2bm_immode"]
    dmode, opcode = f["l2bm_dmode"], f["l2bm_opcode"]
    ds, dw = f["l2bm_darsend"], f["l2bm_darwrite"]
    present = lambda b: b < st.n_l1b  # noqa: E731

    def a1(a):
        a %= L1BM_LONGS
        if a >= st.l1_cap:
            raise RangeError(f"L1BM {a}")
        return a

    def a2(a):
        a %= L2BM_LONGS
        if a >= st.l2_cap:
            raise RangeError(f"L2BM {a}")
        return a

    def rd1(b, a):
        return st.l1bm[b][a1(a)] if present(b) else 0

    w1: List = []     # (l1b, addr, value, cycle)
    w2: List = []     # (addr, value)
    if ds:
        # l2bmdars: DAR address and L2B number in l1adr..opcode (12 bits: dar[9:0], l2b[1:0])
        v12 = (l1adr << 9) | (immode << 6) | (dmode << 4) | opcode
        dar_a, l2b = v12 >> 2, v12 & 3
        # a run of l2bmdars in consecutive j words keeps the DAR write address, the DAR buffer read
        # address and the L2B of its first word; the later ones only refresh the buffer (probed)
        if st.dars_prev:
            l2b = st.dars_l2b
        for c in range(4):
            for i in range(64):
                long = st.l2bm[a2(ac + 64 * c + i)] if (l2b & 1) == 0 else 0   # bit 1 unused (probed)
                st.darbuf[128 * c + 2 * i] = long >> 32
                st.darbuf[128 * c + 2 * i + 1] = long & 0xFFFFFFFF
        # the addresses are set only by an l2bmdars whose previous j word had none (probed: in
        # consecutive l2bmdars words the later ones refresh the buffer but keep both addresses)
        if not st.dars_prev:
            st.darw_addr = dar_a
            st.darbuf_rd = 0
            st.dars_l2b = l2b
    elif gw and not lw:
        S = [b for b in range(8) if in_set(b, l1adr, immode)]
        for c in range(4):
            for b in S:
                if not present(b):
                    continue
                if bd == 1:      # l2bmb
                    for k in range(16):
                        w1.append((b, a1(ab + 16 * c + k), st.l2bm[a2(ac + 16 * c + k)], c))
                elif bd == 2:    # l2bmb2
                    for k in range(16):
                        w1.append((b, a1(ab + 16 * c + k), st.l2bm[a2(ac + 64 * c + 16 * (b // 2) + k)], c))
                elif bd == 0:    # l2bmd
                    for k in range(8):
                        w1.append((b, a1(ab8 + 8 * c + k), st.l2bm[a2(ac + 64 * c + 8 * b + k)], c))
                # bdmode 11: nothing (probed: no error, nothing written)
    elif (lw and not gw) or (lw and gw and immode == 7):
        # (l2bmi with immode 7 is the gather, probed)
        if gw:
            if bd != 0:
                raise Unsupported("l2bmi bdmode")
        op = OPS.get(opcode)
        if bd == 3:
            raise Unsupported("lwrite bdmode 11 (the emulator aborts)")
        if bd in (1, 2) and (op is None or dmode == 3):
            raise Unsupported("reduction opcode / dmode (the emulator aborts)")
        def rin(b, a, bits):
            # reduction input: L1Bs outside the set send the identity, absent ones zero
            if in_set(b, l1adr, immode):
                return rd1(b, a)
            return L.from_lanes([identity(op, bits)] * (64 // bits), bits)

        for c in range(4):
            if bd == 1:          # l2bmr (l2bm@n: bor over the set {n})
                bits = lane_bits(dmode)
                for k in range(16):
                    vals = [rin(b, ab + 16 * c + k, bits) for b in range(8)]
                    w2.append((a2(ac + 16 * c + k), reduce_longs(op, bits, vals)))
            elif bd == 2:        # l2bmr2 (the set applies too, probed; the assembler always sets all)
                bits = lane_bits(dmode)
                for g in range(4):
                    for k in range(16):
                        vals = [rin(2 * g, ab + 16 * c + k, bits), rin(2 * g + 1, ab + 16 * c + k, bits)]
                        w2.append((a2(ac + 64 * c + 16 * g + k), reduce_longs(op, bits, vals)))
            elif bd == 0 and immode == 7:   # l2bmd (gather); other sets: nothing (probed)
                for b in range(8):
                    for k in range(8):
                        w2.append((a2(ac + 64 * c + 8 * b + k), rd1(b, ab8 + 8 * c + k)))
    elif gw and lw:
        # l2bmi: the source address is in gadr (x 8), the destination address in ladr (x 16)
        if bd != 0:
            raise Unsupported("l2bmi bdmode")
        keep = 7 ^ immode
        for c in range(4):
            for d in range(8):
                if not present(d) or in_set(d, l1adr, immode):
                    continue     # sources are not written
                s = (l1adr & keep) | (d & immode)
                for k in range(16):
                    # the destination does not wrap at the chip's 8192 (probed: ladr = 520 writes
                    # nothing below 1024); beyond the capacity it is E_RANGE
                    if ac + 16 * c + k >= st.l1_cap:
                        raise RangeError(f"L1BM {ac + 16 * c + k}")
                    w1.append((d, ac + 16 * c + k, rd1(s, ab + 16 * c + k), c))
    st.dars_prev = bool(ds)
    if dw:
        for _ in range(4):
            st.dar[st.darw_addr] = st.darbuf[st.darbuf_rd]
            st.darw_addr = (st.darw_addr + 1) % DAR_ENTRIES
            st.darbuf_rd = (st.darbuf_rd + 1) % DARBUF_ENTRIES
    return w1, w2

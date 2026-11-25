#!/usr/bin/env python3
"""WP32: the model of a whole word for the tests: L2BM part (l2model.py) and L1BM / PE part
(WP31's l1model.py / pemodel.py on L1B 0, MAB 0), in the order the official emulator uses.

Order within one j word (probed with words that hold an L1BM and an L2BM expression on the same
L1BM addresses, which the assembler accepts): see ORDER and rtl/l2bm/README.md.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Dict, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "l1bm"))
import l1model as L1  # noqa: E402
import l2model as M  # noqa: E402
import l2prog as LP  # noqa: E402
import pemodel as P  # noqa: E402

# reads: the L2BM part reads the L1BM before the step (pre), or after the L1BM part (post)
# writes: the L2BM part writes the L1BM after the L1BM part (last) or before its reads (first)
ORDERS = {
    "pre_cycle": ("pre", "cycle"),
    "pre_last": ("pre", "last"),
    "pre_first": ("pre", "first"),
    "post_last": ("post", "last"),
}
ORDER = "pre_cycle"


def pe_wcycle(f: Dict[str, int], a: int):
    """The cycle in which the L1BM part of the word writes L1BM long word a of its L1B, or None
    (WP31: PE -> L1BM with me = 1 writes, per cycle c, the block base + c * blk .. + blk - 1)."""
    if not (f["ll"] & 1) or not f["l1bm_lwrite"] or not f["l1bm_me"]:
        return None
    bm = 1 if f["l1bm_bmode"] == 0 else f["l1bm_bmode"]
    wl = f["l1bm_wl"]
    blk = 64 if bm == 3 else (32 if wl else 16) if bm == 2 else (8 if wl else 4)
    base = (f["l1bm_ladr"] & ~63) if bm == 3 else f["l1bm_ladr"]
    o = a - base
    if 0 <= o < 4 * blk:
        return o // blk
    return None


class State:
    def __init__(self, p: LP.Prog, ini: LP.Init, n_l1b: int = 1, l2_cap=M.L2BM_LONGS, l1_cap=M.L1BM_LONGS):
        self.l2 = M.L2State(n_l1b=n_l1b, l2_cap=l2_cap, l1_cap=l1_cap)
        for a, v in enumerate(ini.l2):
            self.l2.l2bm[a] = v
        for b, vals in enumerate(ini.l1):
            if b < n_l1b:
                for a, v in enumerate(vals):
                    self.l2.l1bm[b][a] = v
        self.l1 = L1.L1State(n_mab=1)
        self.l1.mem = self.l2.l1bm[0]          # the L1BM of L1B 0 is shared
        self.pe = P.PeState(4)
        for (sp, i), vals in ini.pe.items():
            if sp == "t":
                for k, v in enumerate(vals):
                    self.pe.t[i][2 * k] = v >> 32
                    self.pe.t[i][2 * k + 1] = v & 0xFFFFFFFF
            else:
                mem = self.pe.mem[sp][i]
                for k, v in enumerate(vals):
                    mem[2 * k] = v >> 32
                    mem[2 * k + 1] = v & 0xFFFFFFFF

    def step(self, f: Dict[str, int], order: str = None):
        rd, wr = ORDERS[order or ORDER]
        pe_part = f["ll"] != 0 and (L1.lbf_update(f) or f["l1bm_lwrite"] or any(
            f[w] and f[i] == 2 for w, i in (("pe_rfc0_write", "pe_rfc0_isel"), ("pe_rfc1_write", "pe_rfc1_isel"),
                                             ("pe_lm1_write", "pe_lm1_isel"), ("pe_trc_write", "pe_trc_isel"))) or
            (f["pe_lm0_write"] and f["pe_lm0_isel"] == 2 and f["pe_aluc_aluop"] != 0b11111) or
            f["pe_aluc_aluop"] == 0b01010)
        if rd == "pre":
            w1, w2 = M.l2_compute(self.l2, f)
            if wr == "first":
                M.l2_apply(self.l2, w1, w2)
            if pe_part:
                P.step(self.pe, self.l1, f, cap=self.l2.l1_cap)
            if wr == "last":
                M.l2_apply(self.l2, w1, w2)
            if wr == "cycle":
                # per cycle c: the PE -> L1BM writes of c, then the L2BM -> L1BM writes of c; an
                # L2BM write loses to a PE write of the same address in a later cycle
                w1 = [w for w in w1 if not (w[0] == 0 and (pe_wcycle(f, w[1]) or -1) > w[3])]
                M.l2_apply(self.l2, w1, w2)
        else:
            if pe_part:
                P.step(self.pe, self.l1, f, cap=self.l2.l1_cap)
            M.l2_step(self.l2, f)

    def dump(self, want) -> Dict[Tuple[str, str, int], int]:
        out = {}
        for key in want:
            space, loc, a = key
            if space == "L2BM" and loc == "n0c0" and a < LP.L2:
                out[key] = self.l2.l2bm[a]
            elif space == "L1BM" and loc.startswith("n0c0b"):
                b = int(loc[5:])
                if b < self.l2.n_l1b:
                    out[key] = self.l2.l1bm[b][a]
            elif loc.startswith("n0c0b0m0p"):
                got = P.dump(self.pe, self.l1, [key])
                out.update(got)
        return out


def compare(p: LP.Prog, dump, ini, words, n_l1b=1, order=None, show=6):
    st = State(p, ini, n_l1b)
    for w in words:
        st.step(LP.fields(w), order)
    got = st.dump(dump.keys())
    bad = [(k, dump[k], got[k]) for k in sorted(got) if got[k] != dump[k]]
    lines = [f"    {k[0]} {k[1]} {k[2]:#x}: official {e:016x} model {g:016x}" for k, e, g in bad[:show]]
    return bad, lines

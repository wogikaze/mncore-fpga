#!/usr/bin/env python3
"""WP31: the PE side that the L1BM tests need (a stub of the PE core, for the model only).

Reads the PE operand of a PE -> L1BM transfer (l1bm_isel: $lr $ls $t $lm $ln) and writes the
L1BM -> PE data to the destinations whose isel is 10 (GRF0 GRF1 LM0 LM1 T), with the cycle
addresses of the word and the word lengths. Zero flush (pe_mrc_zero, zero_sel = 10) with a
literal pattern ($imr >= 16) is applied to the L1BM data. `?passa` copies its x operand
(also $lbf) so that tests can store $lbf. No write masks, no base registers, no T indirect:
the generator only makes words without them (checked here).
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple

import l1model as L

GRF_WORDS = 512
LM_WORDS = 4096


class PeState:
    def __init__(self, npe: int = 64):
        self.npe = npe
        self.mem = {k: [[0] * (GRF_WORDS if k in ("r", "s") else LM_WORDS) for _ in range(npe)]
                    for k in ("r", "s", "m", "n")}
        self.t = [[0] * 16 for _ in range(npe)]
        self.lbf = [[[0] * 4 for _ in range(4)] for _ in range(npe)]


SRC = {0: "r", 1: "s", 2: "t", 3: "m", 4: "n"}
RD = {"r": ("pe_rfc0_rwl", "pe_rfc0_radr"), "s": ("pe_rfc1_rwl", "pe_rfc1_radr"),
      "m": ("pe_lm0_wl", "pe_lm0_adr"), "n": ("pe_lm1_wl", "pe_lm1_adr")}
WR = {"r": ("pe_rfc0_write", "pe_rfc0_isel", "pe_rfc0_wwl", "pe_rfc0_wadr"),
      "s": ("pe_rfc1_write", "pe_rfc1_isel", "pe_rfc1_wwl", "pe_rfc1_wadr"),
      "m": ("pe_lm0_write", "pe_lm0_isel", "pe_lm0_wl", "pe_lm0_adr"),
      "n": ("pe_lm1_write", "pe_lm1_isel", "pe_lm1_wl", "pe_lm1_adr")}
NWORDS = {0: 1, 1: 2, 2: 4}


def cyc_addr(f, name, c):
    return f[name] if c == 0 else f[f"{name}_c{c}"]


def read_bus(pe: PeState, i: int, f: Dict[str, int], space: str, c: int) -> List[int]:
    if space == "t":
        return pe.t[i][4 * c:4 * c + 4]
    wlf, af = RD[space]
    n = NWORDS[f[wlf]]
    a = cyc_addr(f, af, c) & ~(n - 1)
    mem = pe.mem[space][i]
    return [mem[(a + k) % len(mem)] if k < n else 0 for k in range(4)]


def write_bus(pe: PeState, i: int, f: Dict[str, int], space: str, c: int, b: List[int]):
    if space == "t":
        pe.t[i][4 * c:4 * c + 4] = list(b)
        return
    _w, _isel, wlf, af = WR[space]
    n = NWORDS[f[wlf]]
    a = cyc_addr(f, af, c) & ~(n - 1)
    mem = pe.mem[space][i]
    for k in range(n):
        mem[(a + k) % len(mem)] = b[k]


def flush_flags(f, c):
    """Zero flush flags of the L1BM data in cycle c, or None (no flush / not L1BM)."""
    if not (f["pe_mrc_zero"] and f["pe_mrc_zero_sel"] == 2):
        return None
    imr = f["pe_mrc_imr"]
    if imr < 16:
        raise ValueError("zero flush with a mask register entry is not modelled")
    return 0xF if (imr >> (3 - c)) & 1 else 0


def apply_flush(b, flags, two):
    """Long-word mask: the 4 half words of the MSB long word; 2-long-word mask: the 4 words."""
    if flags is None:
        return list(b)
    out = list(b)
    if two:
        for k in range(4):
            if not (flags >> (3 - k)) & 1:
                out[k] = 0
    else:
        for k in range(4):
            if not (flags >> (3 - k)) & 1:
                w = k // 2
                out[w] &= 0x0000FFFF if k % 2 == 0 else 0xFFFF0000
    return out


def check_simple(f):
    for k in ("pe_lm0_maadj", "pe_lm0_madpe", "pe_lm1_maadj", "pe_lm1_madpe"):
        if f.get(k, 0):
            raise ValueError(f"{k} is not modelled")
    if f["pe_mrc_imr"] and not f["pe_mrc_zero"]:
        raise ValueError("write masks are not modelled")


def step(pe: PeState, l1: L.L1State, f: Dict[str, int], cap: int = 8192):
    ll = f["ll"]
    if ll == 0:
        return
    check_simple(f)
    nofwd = ll == 3
    npe = l1.n_mab * 4
    # PE -> L1BM source values (read before anything is written)
    src = {}
    isel = f["l1bm_isel"]
    if f["l1bm_lwrite"] and isel != 7:
        if isel not in SRC:
            raise ValueError(f"l1bm_isel {isel} ($mauf / $aluf) is not modelled")
        for i in range(npe):
            src[i] = [read_bus(pe, i, f, SRC[isel], c) for c in range(4)]
    # ALU ?passa of a PE operand ($lbf included), read before the writes
    alu_out = None
    if f["pe_aluc_aluop"] == 0b01010 and not (f["pe_aluc_dmode"] == 3):
        xs = f["pe_aluc_isela"]
        alu_out = {}
        for i in range(npe):
            alu_out[i] = []
            for c in range(4):
                if xs == 13:
                    alu_out[i].append(list(pe.lbf[i][c]))
                elif xs in SRC:
                    alu_out[i].append(read_bus(pe, i, f, SRC[xs], c))
                else:
                    raise ValueError(f"passa source {xs} is not modelled")
    to_pe, _writes = L.l1_step(l1, f, src, cap)
    # writes
    dsts = []
    for sp, (w, isel_f, _wl, _a) in WR.items():
        if f[w] and not (sp == "m" and f["pe_aluc_aluop"] == 0b11111):
            dsts.append((sp, f[isel_f]))
    if f["pe_trc_write"]:
        dsts.append(("t", f["pe_trc_isel"]))
    for i in range(npe):
        for c in range(4):
            fl = flush_flags(f, c)
            for sp, s in dsts:
                if s == 2:
                    if to_pe is None:
                        raise ValueError("isel 10 without an L1BM -> PE transfer")
                    write_bus(pe, i, f, sp, c, apply_flush(to_pe[i][c], fl, f["pe_mrc_wl"]))
                elif s == 1:
                    if alu_out is None:
                        raise ValueError("ALU output without a modelled ALU instruction")
                    write_bus(pe, i, f, sp, c, alu_out[i][c])
                else:
                    raise ValueError(f"isel {s} is not modelled")
    if to_pe is not None and not nofwd and L.lbf_update(f):
        for i in range(npe):
            for c in range(4):
                pe.lbf[i][c] = apply_flush(to_pe[i][c], flush_flags(f, c), f["pe_mrc_wl"])


def loc(i):
    return f"n0c0b0m{i // 4}p{i % 4}"


def dump(pe: PeState, l1: L.L1State, want) -> Dict[Tuple[str, str, int], int]:
    """Values of the model for the keys of an official ndmp dump (L1B n0c0b0 only)."""
    out = {}
    names = {"GRF0": "r", "GRF1": "s", "LM0": "m", "LM1": "n"}
    for (space, lc, a) in want:
        if space == "L1BM":
            if lc == "n0c0b0":
                out[(space, lc, a)] = l1.mem[a]
            continue
        if not lc.startswith("n0c0b0m"):
            continue
        m, p = lc[len("n0c0b0m"):].split("p")
        i = int(m) * 4 + int(p)
        if i >= pe.npe:
            continue
        if space in names:
            mem = pe.mem[names[space]][i]
            out[(space, lc, a)] = (mem[2 * a] << 32) | mem[2 * a + 1]
        elif space == "T":
            c, k = divmod(a, 2)
            w = pe.t[i][4 * c + 2 * k:4 * c + 2 * k + 2]
            out[(space, lc, a)] = (w[0] << 32) | w[1]
    return out

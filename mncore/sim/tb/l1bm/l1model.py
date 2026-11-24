#!/usr/bin/env python3
"""WP31: reference model of the L1BM unit at the machine-code level (flat j word fields).

This is the specification the RTL (mncore/rtl/l1bm) follows, written while probing the
official emulator (the expected values of the tests always come from the emulator itself;
the model is a development aid and documents the semantics, see rtl/l1bm/README.md).

One L1B is modelled: its L1BM, the turnaround register $lbi, and the PEs of its MABs.
PE (m, p) has dense index 4 m + p. A topology with n_mab < 16 has MABs 0..n_mab-1; the others
send zero to PE -> L1BM transfers and receive nothing (contract section 3).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

M64 = (1 << 64) - 1


# ----------------------------------------------------------------------------------- floats
@dataclass(frozen=True)
class Fmt:
    exp_bits: int
    man_bits: int

    @property
    def width(self):
        return 1 + self.exp_bits + self.man_bits

    @property
    def emax(self):
        return (1 << self.exp_bits) - 1

    @property
    def bias(self):
        return (1 << (self.exp_bits - 1)) - 1

    def inf(self, neg):
        return (int(neg) << (self.width - 1)) | (self.emax << self.man_bits)


HALF = Fmt(6, 9)
SINGLE = Fmt(8, 23)
DOUBLE = Fmt(11, 52)


def round_pack(f: Fmt, neg: bool, sig: int, exp: int) -> int:
    """sig * 2^exp rounded to nearest even into f; overflow -> inf, underflow -> +0."""
    if sig == 0:
        return 0
    m = f.man_bits
    p = sig.bit_length() - 1
    if p > m:
        sh = p - m
        k = sig >> sh
        rem = sig & ((1 << sh) - 1)
        half = 1 << (sh - 1)
        if rem > half or (rem == half and (k & 1)):
            k += 1
        keep = k
    else:
        keep = sig << (m - p)
    if keep >> (m + 1):
        keep >>= 1
        p += 1
    biased = exp + p + f.bias
    if biased >= f.emax:
        return f.inf(neg)
    if biased <= 0:
        return 0
    return (int(neg) << (f.width - 1)) | (biased << m) | (keep & ((1 << m) - 1))


def round_shift(v: int, sh: int) -> int:
    if sh == 0:
        return v
    if sh >= 128:
        return 0
    k = v >> sh
    rem = v & ((1 << sh) - 1)
    half = 1 << (sh - 1)
    return k + (1 if (rem > half or (rem == half and (k & 1))) else 0)


def fadd(f: Fmt, vals: List[int], out: Fmt) -> int:
    """RRN floating-point addition (SDM 4.2.1, viz/core rrn.rs; checked by the rrn vectors)."""
    mb = f.man_bits
    exp = lambda v: (v >> mb) & f.emax  # noqa: E731
    max_e = max(exp(v) for v in vals)
    if max_e == 0:
        return 0
    if max_e == f.emax:
        negs = [(v >> (f.width - 1)) & 1 for v in vals if exp(v) == f.emax]
        return out.inf(all(negs))
    s = 0
    for v in vals:
        e = exp(v)
        if e == 0:
            continue
        sig = ((1 << mb) | (v & ((1 << mb) - 1))) << 3
        a = round_shift(sig, max_e - e)
        s += -a if (v >> (f.width - 1)) & 1 else a
    if s == 0:
        return 0
    e = max_e - f.bias - mb - 3
    return round_pack(out, s < 0, abs(s), e)


OPS = {0: "fadd", 1: "max", 2: "min", 8: "iadd", 9: "band", 10: "and", 12: "bor", 13: "or"}


def reduce_lane(op: str, bits: int, vals: List[int], f: Optional[Fmt], out: Optional[Fmt]) -> int:
    m = (1 << bits) - 1
    if op == "fadd":
        return fadd(f, vals, out)
    if op in ("max", "min"):
        def key(v):
            neg = (v >> (bits - 1)) & 1
            mag = v & (m >> 1)
            return -mag - 1 if neg else mag
        if op == "max":
            best = vals[0]
            for v in vals[1:]:
                if key(v) >= key(best):
                    best = v
            return best
        best = vals[0]
        for v in vals[1:]:
            if key(v) < key(best):
                best = v
        return best
    if op == "iadd":
        return sum(vals) & m
    if op == "band":
        r = m
        for v in vals:
            r &= v
        return r
    if op == "bor":
        r = 0
        for v in vals:
            r |= v
        return r
    if op == "and":
        return int(all(v != 0 for v in vals))
    if op == "or":
        return int(any(v != 0 for v in vals))
    raise ValueError(op)


def fmt_of_bits(bits: int) -> Fmt:
    return {64: DOUBLE, 32: SINGLE, 16: HALF}[bits]


def half_to_single(h: int) -> int:
    """Precision extension of one half (decode HALF, encode SINGLE; exp 0 -> +0, inf -> inf)."""
    neg = (h >> 15) & 1
    e = (h >> 9) & 63
    m = h & 0x1FF
    if e == 0:
        return 0
    if e == 63:
        return SINGLE.inf(neg)
    return (neg << 31) | ((e - 31 + 127) << 23) | (m << 14)


def half_to_single_raw(h: int) -> int:
    """The L1BM reduction's input extension (e): exponent 0 -> 0, 63 -> 255, else + 96; the sign
    and the 9 mantissa bits are kept (probed with max / min: an infinity keeps its mantissa).
    For fadd it is the same as half_to_single (fadd does not look at those mantissas)."""
    neg = (h >> 15) & 1
    e = (h >> 9) & 63
    m = h & 0x1FF
    es = 0 if e == 0 else 255 if e == 63 else e + 96
    return (neg << 31) | (es << 23) | (m << 14)


def r_round(s: int) -> int:
    """The ALU `r` rounding single -> half (WP03 r_round, the official emulator's): the sign
    stays, exponent = clamp(E - 96 + carry, 0, 63), mantissa = RNE(23 -> 9 bits) kept as is
    (no flush to zero, no infinity). Used by the max / min reductions with round_out."""
    sign = (s >> 31) & 1
    e = (s >> 23) & 255
    m = s & 0x7FFFFF
    k = m >> 14
    rem = m & 0x3FFF
    if rem > 0x2000 or (rem == 0x2000 and (k & 1)):
        k += 1
    c = k >> 9
    k &= 0x1FF
    eh = max(0, min(63, e - 96 + c))
    return (sign << 15) | (eh << 9) | k


# ----------------------------------------------------------------------------- reductions
@dataclass
class Rrn:
    op: str
    bits: int          # lane width of the reduction
    ext: bool          # inputs: 4 halves of the MSB long word extended to 4 singles
    rnd: bool          # outputs: rounded to halves (4 halves per PE in one long word)
    two_in: bool       # two long words of input per PE
    two_out: bool      # two long words of output per PE (the L1BM layout: wl)


def decode_rrn(opcode: int, dmode: int, ext: int, rnd: int, wl: int) -> Optional[Rrn]:
    """Machine fields -> reduction; None for combinations the emulator rejects (E_UNSUPPORTED).
    The L1BM layout always follows wl (probed): an extended result (4 singles) written with
    wl = 0 keeps its first long word, a rounded one (4 halves) written with wl = 1 gets a zero
    second long word."""
    op = OPS.get(opcode)
    if op is None:
        return None
    two = bool(wl)
    if opcode & 8:  # integer and bitwise
        if rnd:
            return None
        bits = 64 if dmode == 0 else (16 if ext else 32)
        if dmode == 0 and ext:
            return None
        return Rrn(op, bits, False, False, two, two)
    if dmode == 0:
        if ext or rnd:
            return None  # the emulator aborts (InvalidArgument) on d with e / r
        return Rrn(op, 64, False, False, two, two)
    if op != "fadd" and ext and rnd:
        return Rrn(op, 16, False, False, two, two)            # hmax / hmin: 16-bit lanes
    if ext:
        return Rrn(op, 32, True, bool(rnd), False, two)       # ffadd e / hfadd / fmax e
    if rnd:
        return Rrn(op, 32, False, True, True, two)            # ffaddr / fmaxr: 4 singles -> 4 halves
    return Rrn(op, 32, False, False, two, two)


def lanes(v: int, bits: int) -> List[int]:
    n = 64 // bits
    m = (1 << bits) - 1
    return [(v >> (64 - bits * (i + 1))) & m for i in range(n)]


def from_lanes(ls: List[int], bits: int) -> int:
    v = 0
    for x in ls:
        v = (v << bits) | x
    return v


def reduce_pe(r: Rrn, vals: List[Tuple[int, int]], sixteen: bool) -> Tuple[int, int]:
    """Reduces the (hi, lo) long words of one PE position over 16 (two stages of 4) or 4 MABs.
    Returns the output (hi, lo); lo is 0 for one-long-word outputs."""
    if r.ext:
        ins = []
        for hi, _lo in vals:
            hs = lanes(hi, 16)
            s = [half_to_single_raw(h) for h in hs]
            ins.append(((s[0] << 32) | s[1], (s[2] << 32) | s[3]))
        vals = ins
    two = r.two_in or r.ext or r.rnd
    f = fmt_of_bits(r.bits) if r.op == "fadd" else None
    out = HALF if (r.rnd and r.op == "fadd") else f
    res = []
    for k in range(2 if two else 1):
        ls = [lanes(v[k], r.bits) for v in vals]
        o = []
        for i in range(64 // r.bits):
            col = [x[i] for x in ls]
            if sixteen:
                st = [reduce_lane(r.op, r.bits, col[g * 4:g * 4 + 4], f, f) for g in range(4)]
                o.append(reduce_lane(r.op, r.bits, st, f, out))
            else:
                o.append(reduce_lane(r.op, r.bits, col, f, out))
        res.append(o)
    if r.rnd:
        # 4 singles (two long words) -> 4 halves in one long word, PE order kept; fadd rounds
        # inside the reduction, max / min round the result with the ALU `r` rounding
        hs = []
        for k in range(2):
            for i in range(2):
                v = res[k][i]
                hs.append(v & 0xFFFF if r.op == "fadd" else r_round(v))
        return from_lanes(hs, 16), 0
    hi = from_lanes(res[0], r.bits)
    lo = from_lanes(res[1], r.bits) if two else 0
    return hi, lo


# ---------------------------------------------------------------------------------- state
@dataclass
class L1State:
    n_mab: int = 16
    mem: List[int] = field(default_factory=lambda: [0] * 8192)
    lbi: List[List[int]] = field(default_factory=lambda: [[0] * 128 for _ in range(4)])
    lbi_mode: Tuple[int, int, int] = (0, 0, 0)   # (bmode, wl, ladr & 63) of the last $lbi writer
    lbf: Dict[int, List[List[int]]] = field(default_factory=dict)  # pe -> 4 cycles x 4 words


def bus(hi: int, lo: int) -> List[int]:
    return [(hi >> 32) & 0xFFFFFFFF, hi & 0xFFFFFFFF, (lo >> 32) & 0xFFFFFFFF, lo & 0xFFFFFFFF]


def longs(b: List[int]) -> Tuple[int, int]:
    return (b[0] << 32) | b[1], (b[2] << 32) | b[3]


class RangeError(Exception):
    pass


class Unsupported(Exception):
    pass


def l1_step(st: L1State, f: Dict[str, int], src: Dict[int, List[List[int]]], cap: int = 8192):
    """Executes the L1BM part of one j word.

    src[pe][c] is the 4-word bus the PE reads for a PE -> L1BM transfer (l1bm_isel source).
    Returns (to_pe, writes): to_pe[pe][c] the 4-word bus of an L1BM -> PE transfer (None when
    the word has none), writes the list of (address, value) written to L1BM. st is updated
    ($lbi, its mode; L1BM memory). Raises RangeError when an access is beyond cap long words.
    """
    ll = f["ll"]
    if ll == 0:
        return None, []
    nofwd = ll == 3
    bmode, lwrite, rmode, me = f["l1bm_bmode"], f["l1bm_lwrite"], f["l1bm_rmode"], f["l1bm_me"]
    ladr, wl, isel = f["l1bm_ladr"], f["l1bm_wl"], f["l1bm_isel"]
    mab_sel = f["l1bm_mabadr"]
    nmab = st.n_mab
    pes = [m * 4 + p for m in range(nmab) for p in range(4)]

    def addr_of(a):
        a &= 8191
        if a >= cap:
            raise RangeError(a)
        return a

    to_pe = None
    writes: List[Tuple[int, int]] = []
    lsh = ladr & 60          # l1bmd: the MAB shift (ladr[1:0] are not used)
    if bmode == 0 and lwrite == 1:
        bmode = 1            # a PE -> L1BM transfer in the l1bmp mode behaves as 16x1 (probed)
    # ---------------------------------------------------------------- L1BM -> PE
    if lwrite == 0:          # every word with lwrite = 0 reads (me only enables writes; probed)
        to_pe = {}
        reads = {}
        for pe in pes:
            m, p = divmod(pe, 4)
            to_pe[pe] = []
            for c in range(4):
                if bmode == 0:      # l1bmp
                    a_hi = ladr + c
                    a_lo = ladr + c + 4 if wl else None
                elif bmode == 1:    # l1bmm
                    a_hi = ladr + (8 if wl else 4) * c + p
                    a_lo = a_hi + 4 if wl else None
                elif bmode == 2:    # l1bmm4
                    a_hi = ladr + (32 if wl else 16) * c + (m >> 2) * (8 if wl else 4) + p
                    a_lo = a_hi + 4 if wl else None
                else:               # l1bmd (distribution)
                    a_hi = (ladr & ~63) + 64 * c + ((lsh + 4 * m + p) & 63)
                    a_lo = None
                hi = st.mem[addr_of(a_hi)]
                lo = st.mem[addr_of(a_lo)] if a_lo is not None else 0
                reads[(pe, c)] = (a_hi, a_lo)
                to_pe[pe].append(bus(hi, lo))
    else:
        # turnaround read from $lbi, in the mode of the transfer that wrote $lbi
        tb, twl, tadr = st.lbi_mode
        to_pe = {}
        for pe in pes:
            m, p = divmod(pe, 4)
            to_pe[pe] = []
            for c in range(4):
                if tb == 2:
                    o = (m >> 2) * (8 if twl else 4) + p
                elif tb == 3:
                    o = (tadr + 4 * m + p) & 63
                else:
                    o = p
                to_pe[pe].append(bus(st.lbi[c][o], st.lbi[c][64 + o]))
    # ---------------------------------------------------------------- PE -> L1BM
    # every word with lwrite = 1 transfers (isel 111: zero data); the L1BM is written when me = 1
    if lwrite == 1:
        def srcv(mab, p, c):
            if mab >= nmab or isel == 7:
                return (0, 0)
            return longs(src[mab * 4 + p][c])
        new_lbi = [row[:] for row in st.lbi]
        mem_items = []   # (address, value)
        for c in range(4):
            items = []   # (block offset, value)
            turn = []    # ($lbi position, value)
            if rmode == 0:
                if bmode == 1:      # l1bmm@
                    for p in range(4):
                        hi, lo = srcv(mab_sel, p, c)
                        items.append((p, hi))
                        turn.append((p, hi))
                        if wl:
                            items.append((4 + p, lo))
                            turn.append((64 + p, lo))
                    step = 8 if wl else 4
                elif bmode == 2:    # l1bmm4@
                    for mo in range(4):
                        for p in range(4):
                            hi, lo = srcv(mo * 4 + (mab_sel & 3), p, c)
                            if wl:
                                items += [(mo * 8 + p, hi), (mo * 8 + 4 + p, lo)]
                                turn += [(mo * 8 + p, hi), (64 + mo * 8 + p, lo)]
                            else:
                                items.append((mo * 4 + p, hi))
                                turn.append((mo * 4 + p, hi))
                    step = 32 if wl else 16
                elif bmode == 3:    # l1bmd (gather)
                    for mab in range(16):
                        for p in range(4):
                            hi, _ = srcv(mab, p, c)
                            items.append((((4 * mab + p) - lsh) & 63, hi))
                            turn.append((4 * mab + p, hi))
                    step = 64
                else:
                    raise Unsupported("bmode 0 with lwrite")
            else:
                r = decode_rrn(f["l1bm_opcode"], f["l1bm_dmode"], f["l1bm_ext"], f["l1bm_round_out"], wl)
                if r is None or bmode not in (1, 2):
                    raise Unsupported("reduction")
                four = bmode == 2
                for g in range(4 if four else 1):
                    mabs = list(range(g * 4, g * 4 + 4)) if four else list(range(16))
                    for p in range(4):
                        hi, lo = reduce_pe(r, [srcv(mb, p, c) for mb in mabs], not four)
                        if r.two_out:
                            o = g * 8 + p if four else p
                            items += [(o, hi), (o + 4, lo)]
                            turn += [(o, hi), (64 + o, lo)]
                        else:
                            o = g * 4 + p if four else p
                            items.append((o, hi))
                            turn.append((o, hi))
                step = (32 if r.two_out else 16) if four else (8 if r.two_out else 4)
            for o, v in turn:
                new_lbi[c][o] = v
            if me:
                base = ladr & ~63 if (bmode == 3 and rmode == 0) else ladr
                for o, v in items:
                    mem_items.append((addr_of(base + c * step + o), v))
        if me:
            for a, v in mem_items:
                st.mem[a] = v
                writes.append((a, v))
        if not nofwd:
            st.lbi = new_lbi
            st.lbi_mode = (bmode, wl, lsh)
    return to_pe, writes


L1_FIELDS_DEFAULT = {"l1bm_bmode": 0, "l1bm_lwrite": 0, "l1bm_rmode": 0, "l1bm_me": 0, "l1bm_ladr": 0,
                     "l1bm_dmode": 0, "l1bm_ext": 0, "l1bm_round_out": 0, "l1bm_mabadr": 0,
                     "l1bm_opcode": 0, "l1bm_isel": 7, "l1bm_wl": 0}


def lbf_update(f: Dict[str, int]) -> bool:
    """Whether the word updates $lbf (besides ll): the RTL rule, a word with an L1BM expression
    (some L1BM field not at its default value).

    The official emulator updates $lbf with every executed word (a word without L1BM fields
    loads it with its implicit l1bmp read of L1BM[0..3]; probe p7, words edited by hand). The
    assembler rejects a $lbf read after such a word (`ialu_op->a()` check), so the difference
    never shows in an assembled program; the RTL does not pay for it (rtl/l1bm/README.md)."""
    return any(f[k] != v for k, v in L1_FIELDS_DEFAULT.items())

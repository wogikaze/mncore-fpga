"""Reference model of the MAB matrix register and the matrix MAU, as measured on the official
emulator (WP36; mncore/status/WP-36.md). Used by probe_mat.py to compare with the emulator.

Matrix register: faces X (0) and Y (1) of 16 physical rows x 16 halves (8 words); the precisions
share it (viz/core machine.rs layout): d element (row i, col j) = halves 4j..4j+3 of physical row
4i; f / g (i, j) = halves 2j, 2j+1 of physical row 2i; h (i, j) = half j of physical row i.

Matrix MAU (?mfma / ?mmul), one output element: the exact dot product of the block-float row and x
(SDM 4.5), c aligned to the adder grid 2^(Ep - K) and the dot product dropped when c is far above
it, then one rounding:
    Ep = (ca - bias) + (cb - bias)  (common exponents = the largest exponent field of each block)
    K  = d 86, f 39, g 34, h 26     T (drop when lead(c) - Ep >= T) = d 57, h 30, f / g none
    ca or cb = 0: dot = 0 and c is not aligned; else ca or cb all ones: +inf
Extended half elements (exponent field 0) are common - 6; their product is shifted right by 6 or
12 bits and rounded to the product's grid. The emulator's rounding there is not round-to-nearest-
even in every case (it depends on the operands, SDM 4.5 leaves it out); `ext="rne"` is the
approximation the RTL implements (about 92 % of single products agree, WP36 report).
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "fpu_tools"))
import mnfp_ref as R  # noqa: E402

# prec: (element format, mantissa bits used, partial-product truncation of SDM 4.3 / 4.5)
BF = {"d": (R.DOUBLE, 52, True), "f": (R.SINGLE, 23, True), "g": (R.SINGLE, 18, False), "h": (R.HALF, 9, False)}
ROWS = {"d": 4, "f": 8, "g": 8, "h": 16}
GRID_K = {"d": 86, "f": 39, "g": 34, "h": 26}
DROP_T = {"d": 57, "h": 30}


# ---------------------------------------------------------------------------- the register
class Mat:
    def __init__(self):
        self.f = [[[0] * 16 for _ in range(16)] for _ in range(2)]

    def copy(self):
        m = Mat()
        m.f = [[list(r) for r in fa] for fa in self.f]
        return m

    def get(self, fa, prec, row, col):
        if prec == "d":
            h = self.f[fa][4 * row][4 * col:4 * col + 4]
            return (h[0] << 48) | (h[1] << 32) | (h[2] << 16) | h[3]
        if prec == "h":
            return self.f[fa][row][col]
        h = self.f[fa][2 * row][2 * col:2 * col + 2]
        return (h[0] << 16) | h[1]

    def read(self, fa, prec, addr):
        """transposed read: bus[p][c] (128 bits); h: the column address is even."""
        rows = ROWS[prec]
        if prec == "h":
            addr &= ~1
        bus = [[0] * 4 for _ in range(4)]
        for c in range(4):
            for p in range(4):
                if prec == "d":
                    bus[p][c] = self.get(fa, "d", p, (addr + c) % 4) << 64
                elif prec == "h":
                    c0 = (addr + 2 * c) % 16
                    x = 0
                    for v in [self.get(fa, "h", 4 * p + k, c0) for k in range(4)] + \
                             [self.get(fa, "h", 4 * p + k, (c0 + 1) % 16) for k in range(4)]:
                        x = (x << 16) | v
                    bus[p][c] = x
                else:
                    col = (addr + c) % rows
                    bus[p][c] = ((self.get(fa, prec, 2 * p, col) << 32) | self.get(fa, prec, 2 * p + 1, col)) << 64
        return bus

    def write(self, fa, prec, addr, two_rows, src):
        """?mwrite: src[p][c] = the 128-bit bus of PE p in cycle c after e / r / sign."""
        rows = ROWS[prec]
        step = {"d": 4, "h": 1}.get(prec, 2)
        for c in range(4):
            def halves(lw):
                return [(lw >> 48) & 0xffff, (lw >> 32) & 0xffff, (lw >> 16) & 0xffff, lw & 0xffff]
            if prec == "h" and two_rows:
                a = ((addr & ~1) + 2 * c) % 16
                for k in range(2):
                    self.f[fa][a + k] = sum((halves((src[p][c] >> (64 * (1 - k))) & ((1 << 64) - 1))
                                             for p in range(4)), [])
            else:
                row = (addr + c) % rows
                self.f[fa][row * step] = sum((halves(src[p][c] >> 64) for p in range(4)), [])


def faces(readh: int, mw: int):
    """(write face, transposed-read face, matrix-MAU face), X = 0, Y = 1."""
    return (0 if readh else 1), (0 if (readh ^ mw) else 1), (1 if readh else 0)


# ---------------------------------------------------------------------------- the matrix MAU
def fields(prec, v):
    f, m, _ = BF[prec]
    return (v >> (f.width - 1)) & 1, (v >> f.man_bits) & f.emax, (v & ((1 << f.man_bits) - 1)) >> (f.man_bits - m)


def _shift_round(p, s):
    if s == 0:
        return p
    q, r = divmod(p, 1 << s)
    h = 1 << (s - 1)
    return q + (1 if (r > h or (r == h and q & 1)) else 0)


def bf_dot(prec, arow, xs, ext="rne"):
    """(value, grid exponent, Ep); value as an mnfp_ref tuple."""
    f, m, drop = BF[prec]
    ca = max(fields(prec, v)[1] for v in arow)
    cb = max(fields(prec, v)[1] for v in xs)
    if ca == 0 or cb == 0:
        return ("z", False), None, None
    if ca == f.emax or cb == f.emax:
        return ("i", False), None, None
    ep = (ca - f.bias) + (cb - f.bias)
    base = ca + cb - 2 * f.bias - 2 * (m - 1)       # exponent of a product's LSB
    total = 0
    for a, x in zip(arow, xs):
        na, ea, ma = fields(prec, a)
        nb, eb, mb = fields(prec, x)
        p = ma * mb
        if drop:
            lo = f.man_bits - f.full
            d = (ma & ((1 << lo) - 1)) * (mb & ((1 << lo) - 1))
            if d:
                p = p - d + (1 << (2 * lo - 2))
        sh = (6 if ea == 0 else 0) + (6 if eb == 0 else 0) if prec == "h" else 0
        v = (p << (12 - sh)) if ext == "exact" else (_shift_round(p, sh) << 12)
        total += -v if (na ^ nb) else v
    if total == 0:
        return ("z", False), ep - GRID_K[prec], ep
    return ("f", total < 0, abs(total), base - 12), ep - GRID_K[prec], ep


def mat_fma(prec, fout, dot, c):
    val, grid, ep = dot
    if grid is not None:
        t = DROP_T.get(prec)
        if t is not None and c[0] == "f" and R.lead(c) - ep >= t:
            val = ("z", False)
        c = R.align_c(c, grid)
    return R.encode(fout, R.add_exact(val, c))


def mfma(prec, rows, xs, cs, half=None, rnd=False, ext="rne"):
    """rows: logical matrix rows (raw elements), xs: x (raw, signs applied), cs: c per output row
    (mnfp_ref tuples, e / sign / zeroc applied). Returns (raw outputs, output format)."""
    if prec == "d":
        fout = R.SINGLE if rnd else R.DOUBLE
    elif prec == "h":
        fout = R.HALF if rnd else R.SINGLE
    else:
        fout = R.SINGLE
    out = []
    for i in range(ROWS[prec]):
        active = not ((half == "u" and i >= 2) or (half == "d" and i < 2))
        if active:
            arow = [rows[i][2 * j] for j in range(4)] if prec == "f" else rows[i]
            d = bf_dot(prec, arow, xs, ext)
        else:
            d = (("z", False), None, None)
        out.append(mat_fma(prec, fout, d, cs[i]))
    return out, fout

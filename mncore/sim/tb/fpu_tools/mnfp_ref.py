"""Bit-exact reference model of the MN-Core 2 MAU vector FMA (WP12).

The model follows the Rust simulator (`third_party/mncore/viz/core/src/float.rs` and
`compute_vec_pe` in `machine.rs`) and the official emulator where the two disagree
(`mncore/status/WP-03.md`, `mncore/rtl/fpu/SPEC.md`):

- ext_mul: an extended operand (`e`) is converted exactly to the operation format before
  the multiplication, so the partial-product truncation of SDM 4.3 sees its zero low bits.
- adder alignment (what WP03 called round_twice): the product is dropped when
  Uc - Ep >= DROP_T (55 d, 26 f and h), and h aligns c to the grid 2^(Ep - 28) like d (88)
  and f (41) do. Ep is the sum of the unbiased exponents of a and b.
- fvr_flags: `fv*r` flags are one bit per half result (bits 3 and 2).

Python integers make every sum exact, so the model needs no sticky logic of its own.
`official=False` gives the simulator's behaviour (for files without expect=official, whose
disputed rows hold simulator values).
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Fmt:
    name: str
    exp_bits: int
    man_bits: int
    full: int | None  # high mantissa bits that take part in every partial product

    @property
    def bias(self):
        return (1 << (self.exp_bits - 1)) - 1

    @property
    def emax(self):
        return (1 << self.exp_bits) - 1

    @property
    def width(self):
        return 1 + self.exp_bits + self.man_bits

    def inf(self, neg):
        return (int(neg) << (self.width - 1)) | (self.emax << self.man_bits)

    def one(self):
        return self.bias << self.man_bits


HALF = Fmt("h", 6, 9, None)
SINGLE = Fmt("s", 8, 23, 18)
DOUBLE = Fmt("d", 11, 52, 36)

# value: ("z", neg) | ("i", neg) | ("f", neg, sig, exp) with value = sig * 2**exp


def decode(f, bits):
    neg = (bits >> (f.width - 1)) & 1 == 1
    e = (bits >> f.man_bits) & f.emax
    m = bits & ((1 << f.man_bits) - 1)
    if e == 0:
        return ("z", neg)
    if e == f.emax:
        return ("i", neg)
    return ("f", neg, (1 << f.man_bits) | m, e - f.bias - f.man_bits)


def negate(v):
    return (v[0], not v[1]) + tuple(v[2:])


def round_pack(f, neg, sig, exp):
    """Round sig * 2**exp to f (nearest even), overflow to inf, underflow to +0."""
    if sig == 0:
        return 0
    m = f.man_bits
    p = sig.bit_length() - 1
    if p > m:
        sh = p - m
        k = sig >> sh
        rem = sig & ((1 << sh) - 1)
        half = 1 << (sh - 1)
        if rem > half or (rem == half and k & 1):
            k += 1
    else:
        k = sig << (m - p)
    if k >> (m + 1):
        k >>= 1
        p += 1
    biased = exp + p + f.bias
    if biased >= f.emax:
        return f.inf(neg)
    if biased <= 0:
        return 0
    return (int(neg) << (f.width - 1)) | (biased << m) | (k & ((1 << m) - 1))


def encode(f, v):
    if v[0] == "z":
        return 0
    if v[0] == "i":
        return f.inf(v[1])
    return round_pack(f, v[1], v[2], v[3])


def mul_exact(f, a, b):
    neg = a[1] != b[1]
    if a[0] == "z" or b[0] == "z":
        return ("z", neg)
    if a[0] == "i" or b[0] == "i":
        return ("i", neg)
    sa, sb = a[2], b[2]
    prod = sa * sb
    if f.full is not None:
        low = f.man_bits - f.full
        mask = (1 << low) - 1
        dropped = (sa & mask) * (sb & mask)
        if dropped:
            prod = prod - dropped + (1 << (2 * low - 2))
    return ("f", neg, prod, a[3] + b[3])


def add_exact(a, b):
    if a[0] == "i" and b[0] == "i":
        return ("i", a[1] and b[1])
    if a[0] == "i":
        return a
    if b[0] == "i":
        return b
    if a[0] == "z" and b[0] == "z":
        return ("z", a[1] and b[1])
    if a[0] == "z":
        return b
    if b[0] == "z":
        return a
    e = min(a[3], b[3])
    va = a[2] << (a[3] - e)
    vb = b[2] << (b[3] - e)
    v = (-va if a[1] else va) + (-vb if b[1] else vb)
    if v == 0:
        return ("z", False)
    return ("f", v < 0, abs(v), e)


def align_c(c, grid):
    if c[0] != "f":
        return c
    _, neg, sig, exp = c
    if exp >= grid:
        return c
    lead = exp + sig.bit_length() - 1
    if lead - grid <= -2:
        return ("z", False)
    s = grid - exp
    kept = sig >> s
    sticky = (sig & ((1 << s) - 1)) != 0
    return ("f", neg, kept | int(sticky), grid)


def lead(v):
    """Exponent of the leading bit of a finite value."""
    return v[3] + v[2].bit_length() - 1


# Adder alignment of the official emulator (see the module docstring and SPEC.md):
#   GRID_K: c is aligned to the grid 2^(Ep - K), Ep = the sum of the unbiased exponents of a
#           and b (bits of c below the grid are jammed into it, c is dropped when its leading
#           bit is two or more places below it). d and f are the simulator's values; h has a
#           grid too, which only shows with output rounding.
#   DROP_T: the product is dropped when Ep is T or more below the unbiased exponent of c.
GRID_K = {"d": 88, "s": 41, "h": 28}
DROP_T = {"d": 55, "s": 26, "h": 26}


def vfma(fa, fo, a, b, c, official=True):
    """a * b + c for operands already decoded in the operation format fa (c in its own)."""
    p = mul_exact(fa, a, b)
    if a[0] == "f" and b[0] == "f":
        m = fa.man_bits
        ep = (a[3] + m) + (b[3] + m)
        if official:
            if c[0] == "f" and lead(c) - ep >= DROP_T[fa.name]:
                p = ("z", False)
            else:
                c = align_c(c, ep - GRID_K[fa.name])
        elif fa.full is not None:
            c = align_c(c, ep - fa.full - m)
    return encode(fo, add_exact(p, c))


# ---------------------------------------------------------------------------
# MAU vector instructions (unit `mau`) and basic functions (unit `fp`)

FORMATS = {
    # prec: (fa, fc, fz, fz_round, lanes)
    "d": (DOUBLE, DOUBLE, DOUBLE, SINGLE, 1),
    "f": (SINGLE, SINGLE, SINGLE, HALF, 2),
    "h": (HALF, SINGLE, SINGLE, HALF, 4),
}


def lower(f):
    return SINGLE if f is DOUBLE else HALF


def unpack(bus, w, n):
    return [(bus >> (128 - w * (i + 1))) & ((1 << w) - 1) for i in range(n)]


def pack(vals, w):
    b = 0
    for i, v in enumerate(vals):
        b |= (v & ((1 << w) - 1)) << (128 - w * (i + 1))
    return b


def fp_row(prec, rnd, a, b, c, official=True):
    """unit fp: z = round(a * b + c) for raw a, b (format fa) and c (format fc)."""
    fa, fc, fz, fzr, _ = FORMATS[prec]
    fo = fzr if rnd else fz
    return vfma(fa, fo, decode(fa, a), decode(fa, b), decode(fc, c), official)


def flags_of(prec, rnd, outs, fo, official=True):
    pos = [((v >> (fo.width - 1)) & 1) == 0 for v in outs]
    if prec == "d":
        return (0xC if pos[0] else 0) if rnd else (0xF if pos[0] else 0)
    if prec == "f":
        if rnd and official:
            return (8 if pos[0] else 0) | (4 if pos[1] else 0)
        return (0xC if pos[0] else 0) | (0x3 if pos[1] else 0)
    return sum((1 << (3 - i)) for i in range(4) if pos[i])


def mau_row(prec, kind, side, rnd, pe, signs, exts, a_bus, b_bus, c_bus, official=True):
    """unit mau: one (PE, cycle) slot. kind in fma/mul/add/passa, side None/'u'/'d'.

    signs, exts: (signa, signb, signc), (exta, extb, extc). Buses are 128-bit ints.
    Returns (z_bus, flags).
    """
    fa, fc, fz, fzr, n = FORMATS[prec]
    fo = fzr if rnd else fz
    uses = {"fma": (1, 1, 1), "mul": (1, 1, 0), "add": (1, 0, 1), "passa": (1, 0, 0)}[kind]

    def read(k, f, bus):
        if not uses[k]:
            return None
        ext = exts[k]
        if prec == "h" and k < 2 and ext:
            raw = SINGLE  # `r`: rounded from single
        elif ext:
            raw = lower(f)
        else:
            raw = f
        vals = []
        for r in unpack(bus, raw.width, n):
            v = decode(raw, r)
            if prec == "h" and k < 2 and ext:
                v = decode(f, encode(f, v))
            elif ext and official:
                v = decode(f, encode(f, v))  # exact widening
            if signs[k]:
                v = negate(v)
            vals.append(v)
        return vals

    av = read(0, fa, a_bus)
    bv = read(1, fa, b_bus)
    cv = read(2, fc, c_bus)
    mul_here = {None: True, "u": pe % 4 < 2, "d": pe % 4 >= 2}[side]
    one = decode(fa, fa.one())
    zero = ("z", False)
    outs = []
    for l in range(n):
        x, y = (av[l], bv[l] if bv else one) if mul_here else (zero, zero)
        z = cv[l] if cv else zero
        outs.append(vfma(fa, fo, x, y, z, official))
    return pack(outs, fo.width), flags_of(prec, rnd, outs, fo, official)

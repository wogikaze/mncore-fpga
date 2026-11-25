#!/usr/bin/env python3
"""WP36 directed tests for the matrix register of the MAB (unit `mat`), expectations from the
official emulator.

    python mncore/sim/tb/mat/gen_mat.py [--only NAME,...] [--jobs 12] [--keep-going]

Every test is a small program on the 4 PEs of MAB n0c0b0m0 (deterministic data per PE, the body,
d get of GRF0/GRF1/LM0/LM1 long words 0..127, T and $omr1..15 of the 4 PEs), assembled with the
official assemble3 (flat, no packer) and run on the official emulator (WSL; only called, contract
section 9), which executes all 4096 PEs; the 4 PEs of MAB 0 are compared (contract 06 section 3
(b)). The result is a tb_core script (mnhost.py run steps):
    fixed/all.scr   all tests (committed, the simrun default of the unit `mat`),
    build/fixed/<name>.scr   one per test.
The machinery (scripts, stop records) is WP30's gen_mab.py.

Tests:
  mat_rw_d / _f / _h   ?mwrite of every precision (rows, faces, e / - / h `r`, h two rows, odd
                        addresses) and ?mread in every precision, also of rows written in another
                        precision (the physical layout), into GRF / LM
  mat_rw_mix           ?mwrite and ?mread in one word (the read column in signa/signc/passa/zeroc,
                        the other face), $mreadf after it
  mat_mreadf           $mreadf: every step updates it (also words without ?mread: dmread $ly0,
                        a vector MAU word), nop and noforward keep it, zero flush, as the ALU input
                        x of lpassa / hbfn, as the x of a msl
  mfma_g / _f / _h / _hr   ?mfma / ?mmul with block-float data made here (valid blocks, edge
                        exponents: c around the adder grid, c far above (h: the product drop),
                        common exponent 0 / all ones, c = inf / 0, overflow), - on x / y, e on y
  mfma_f0 / _g0 / _h0  the low bits of the dot: the residual dot - round(dot) (?mmul, then ?mfma
                        with y = -$mauf; f: the partial-product correction) and c on the grid of a
                        dot that is exactly 0 (x in pairs v, -v; the jam below the grid)
  mfma_mix             ?mfma with ?mwrite / ?mread / an ALU instruction reading $mreadf in the same
                        word, x from $aluf / T, the result through $mauf, masks and zero flush
  mfma_mauf            $mauf of the matrix MAU as the ALU x (also through a nop), zero-flushed, and
                        as the y of the next ?mfma (no vector MAU instruction)
The tests without vector MAU / FP ALU instructions also go to fixed/mau0.scr (unit mat_m0: the core
without the vector MAU, where the matrix unit keeps the MAU result and $mauf).
  e_unsup_dmfma        dmfmau: E_UNSUPPORTED pe_mauc_dmode (d is not implemented)
  e_range_mwrite       ?mwrite whose LM source is out of range on PE 2 only: E_RANGE, nothing written
  e_range_mfma_x       ?mfma whose x is out of range on PE 1 only (T-indirect): E_RANGE
"""
from __future__ import annotations

import argparse
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BUILD = HERE / "build" / "fixed"
FIXED = HERE / "fixed"
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "mab"))
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "core"))
import run as rg  # noqa: E402
import goldenlib as gl  # noqa: E402
import gen_mab as g30  # noqa: E402  (configures run.py for 4 PEs; make_fixed, GET_LINES)

LOCS = rg.PE_LOCS
F = {name: i for i, name in enumerate(rg.FIELDS)}
UNSUP, RANGE = 2, 1


def T(name, body, init=None, status=None, note=""):
    return dict(name=name, body=body, init=init, status=status, note=note)


def last_word(entries):
    return len(entries) - 1


def lw_hex(vals):
    return "".join(f"{v & ((1 << 64) - 1):016x}" for v in vals)


# ---------------------------------------------------------------------------------- data
def rand_init(seed, mems=(("lr", 32), ("ls", 32), ("lm", 64), ("ln", 64)), small_t=True):
    """random long words per PE (bit patterns that are also valid floats now and then)."""
    out = []
    for p, loc in enumerate(LOCS):
        rng = random.Random(f"wp36-{seed}-p{p}")
        for mem, n in mems:
            out.append(f"d set ${mem}0{loc} {n} " + lw_hex(g30.g20.lw_data(rng) for _ in range(n)))
        tv = []
        for c in range(4):
            tv.append((rng.getrandbits(32) << 32) | (8 * c + 2 * rng.randint(0, 3)) if small_t else rng.getrandbits(64))
            tv.append(g30.g20.lw_data(rng))
        out.append(f"d set $llt{loc} 4 " + lw_hex(tv))
    return out


def init_seq(name):
    """long words whose 16-bit halves tell where they came from: 0x<p><mem><lw>, so that
    every element of a matrix read can be traced (no float meaning)."""
    out = []
    for p, loc in enumerate(LOCS):
        for k, mem in enumerate(("lr", "ls", "lm", "ln")):
            vals = []
            for lw in range(32):
                v = 0
                for h in range(4):
                    v = (v << 16) | (0x8000 * (h == 0)) | (p << 12) | (k << 10) | (lw << 2) | h
                vals.append(v)
            out.append(f"d set ${mem}0{loc} 32 " + lw_hex(vals))
        rng = random.Random(f"wp36-seq-{name}-{p}")
        tv = []
        for c in range(4):
            tv.append((rng.getrandbits(32) << 32) | (8 * c))
            tv.append(rng.getrandbits(64))
        out.append(f"d set $llt{loc} 4 " + lw_hex(tv))
    return out


def init_floats(name):
    """normal single / half / double values per PE (for e / r conversions in ?mwrite)."""
    out = []
    for p, loc in enumerate(LOCS):
        rng = random.Random(f"wp36-fl-{name}-{p}")
        # GRF0: singles (pairs), GRF1: halves (quads), LM0: doubles, LM1: singles near the half range
        def sgl():
            return (rng.getrandbits(1) << 31) | (rng.randint(100, 150) << 23) | rng.getrandbits(23)

        def hlf():
            return (rng.getrandbits(1) << 15) | (rng.randint(1, 62) << 9) | rng.getrandbits(9)

        def dbl():
            return (rng.getrandbits(1) << 63) | (rng.randint(900, 1100) << 52) | rng.getrandbits(52)

        out.append(f"d set $lr0{loc} 32 " + lw_hex((sgl() << 32) | sgl() for _ in range(32)))
        out.append(f"d set $ls0{loc} 32 " + lw_hex((hlf() << 48) | (hlf() << 32) | (hlf() << 16) | hlf()
                                                    for _ in range(32)))
        out.append(f"d set $lm0{loc} 32 " + lw_hex(dbl() for _ in range(32)))
        out.append(f"d set $ln0{loc} 32 " + lw_hex((sgl() << 32) | sgl() for _ in range(32)))
        tv = []
        for c in range(4):
            tv.append((rng.getrandbits(32) << 32) | (8 * c))
            tv.append(dbl())
        out.append(f"d set $llt{loc} 4 " + lw_hex(tv))
    return out


# ---------------------------------------------------------------------------------- ?mwrite / ?mread
RW_D = [
    "dmwrite $lr0v $lx0", "dmwrite $ls0v $ly1", "nop",
    "dmread $lx0 $lr64v", "dmread $ly2 $ls64v", "dmread $lx3 $lm64v", "dmread $ly1 $ln64v", "nop/2",
    "dmwrite -$lm0v $lx2", "dmwrite $r16ve $ly0", "nop",               # sign, single -> double
    "dmread $lx0 $lr72v", "dmread $ly0 $ls72v",
    "fmread $lx0 $lr80v", "fmread $ly5 $ls80v", "gmread $lx2 $lm80v",   # rows written as d
    "hmread $llx0 $llr88v", "hmread $lly6 $lls88v",
    "dmwrite $t $lx1", "nop", "dmread $lx1 $ln72v", "nop/2",
    "dmwrite $lm8 $ly3", "nop", "dmread $ly0 $ln80v",                   # word source
]
RW_F = [
    "fmwrite $lr0v $lx0", "fmwrite $lr8v $lx4", "gmwrite $ls0v $ly1", "gmwrite $ls8v $ly5", "nop",
    "fmread $lx0 $lr64v", "fmread $lx4 $ls64v", "gmread $ly1 $lm64v", "gmread $ly6 $ln64v", "nop/2",
    "fmwrite -$lm0v $lx2", "fmwrite $s16ve $ly0", "gmwrite $r40v $lx6", "nop",    # sign, e, word
    "fmread $lx2 $lr72v", "gmread $ly0 $ls72v", "fmread $lx7 $lm72v",
    "dmread $lx1 $ln72v", "hmread $llx4 $llr80v", "hmread $lly10 $lls80v",
]
RW_H = [
    "hmwrite $llr0v $llx0", "hmwrite $llr16v $llx8", "hmwrite $lls0v $ly3", "hmwrite $lls8v $ly13", "nop",
    "hmread $llx0 $llr64v", "hmread $llx8 $lls64v", "hmread $lly2 $llm64v", "hmread $lly12 $lln64v", "nop/2",
    "hmwrite -$lm0v $lx5", "hmwrite $lln0vr $ly7", "hmwrite $lln16vr $ly12", "nop",       # sign, r
    "hmread $llx4 $llr72v", "hmread $lly6 $lls72v", "hmread $lly0 $llm72v",
    "dmread $lx1 $ln64v", "fmread $ly3 $ln72v", "gmread $lx7 $ln80v",
]
RW_MIX = [
    "hmwrite $llr0v $llx0", "hmwrite $llr16v $llx8", "hmwrite $lls0v $lly0", "hmwrite $lls16v $lly8", "nop",
    "dmwrite $lm0v $lx1 ; dmread $ly2 $lr64v",            # write X, read Y at column 2
    "dmwrite $ln0v $ly0 ; dmread $lx3 $ls64v",            # write Y, read X at column 3
    "fmwrite $lm8v $lx5 ; fmread $ly6 $ln64v",
    "hmwrite $lr8v $ly9 ; hmread $llx14 $llm64v",          # odd write row, read column 14
    "hmwrite $lls16v $lly4 ; hmread $llx6 $llr72v",
    "lpassa $mreadf $lls72v",                              # $mreadf of the word above
    "nop/2",
    "hmread $llx0 $llr80v", "hmread $lly0 $lls80v", "hmread $lly8 $lln80v",
    "hmwrite $llr40v $llx3", "nop", "hmread $llx2 $llr88v",   # two rows at an odd address
]
MREADF = [
    "dmwrite $lr0v $lx0", "dmwrite $ls0v $ly0", "nop",
    "dmread $lx1 $nowrite", "lpassa $mreadf $lls64v",       # the read of the previous word
    "zero $nowrite", "lpassa $mreadf $lls72v",              # no ?mread: dmread $ly0
    "dmread $lx2 $lr64v", "nop", "lpassa $mreadf $lls80v",    # nop keeps it
    "dmread $lx3 $lr72v", "noforward ; lpassa $lr0v $nowrite", "lpassa $mreadf $lls88v",
    "dmread/0101 $lx0 $lr80v", "lpassa $mreadf $lls96v",    # zero flush (sel 11)
    "hmwrite $llr16v $llx8", "nop",
    "hmread $llx8 $nowrite", "hbfn/9 $mreadf $lln64v",      # as the input of a bfn
    "fvpassa $lm0v $nowrite ; fmread $lx4 $nowrite", "lpassa $mreadf $lln72v",
    "dvfmau $lr8v $ls8v $lm8v $ln8v ; dmread $lx0 $lr88v", "lpassa $mreadf $lln80v",
    "gmread $ly3 $nowrite", "msl $mreadf $lln88v",
    "nop/2",
]


# ---------------------------------------------------------------------------------- matrix MAU
BF = {  # prec: (exp bits, man bits, width, bias)
    "f": (8, 23, 32, 127), "g": (8, 23, 32, 127), "h": (6, 9, 16, 31)}
ROWS = {"f": 8, "g": 8, "h": 16}
NX = {"f": 4, "g": 8, "h": 16}
LAY = {"f": (8, 2, 4, 4), "g": (8, 4, 4, 4), "h": (16, 4, 8, 8)}   # matrix, x, y, out long words
KGRID = {"f": 39, "g": 34, "h": 26}


def bf_block(rng, prec, n, ce, kind):
    eb, mb, w, bias = BF[prec]
    out = []
    for _ in range(n):
        s = rng.getrandbits(1)
        man = rng.getrandbits(mb)
        r = rng.random()
        if r < 0.08:
            man = 0
        elif r < 0.12:
            man = (1 << mb) - 1
        e = ce
        if prec == "h" and kind == "ext" and rng.random() < 0.3 and ce != 0:
            e = 0
            man &= ~0x3f    # extended element: the product's shifted-out bits are zero
        out.append((s << (w - 1)) | (e << mb) | man)
    return out


def rand_c(rng, fmt_bits, lead_e):
    eb, mb, w, bias = fmt_bits
    be = max(1, min((1 << eb) - 2, lead_e + bias))
    s = rng.getrandbits(1)
    man = rng.getrandbits(mb)
    return (s << (w - 1)) | (be << mb) | man


SINGLE = (8, 23, 32, 127)
HALF = (6, 9, 16, 31)


def tie_c(rng, out_m, lead_e):
    """a single exactly half way between two values with out_m mantissa bits."""
    k = 23 - out_m
    be = max(1, min(254, lead_e + 127))
    man = (rng.getrandbits(out_m) << k) | (1 << (k - 1))
    return (rng.getrandbits(1) << 31) | (be << 23) | man


def mf_case(rng, prec, kind, opts):
    eb, mb, w, bias = BF[prec]
    emax = (1 << eb) - 1
    rows = ROWS[prec]
    spread = 10 if kind != "wide" else 40
    mat = []
    for i in range(rows):
        ce = rng.randint(max(1, bias - spread), min(emax - 1, bias + spread))
        if kind == "special":
            r = rng.random()
            ce = 0 if r < 0.15 else emax if r < 0.25 else rng.choice([1, 2, emax - 1]) if r < 0.4 else ce
        mat.append(bf_block(rng, prec, rows, ce, kind))
    xs = []
    for c in range(4):
        ce = rng.randint(max(1, bias - spread), min(emax - 1, bias + spread))
        if kind == "special":
            r = rng.random()
            ce = 0 if r < 0.1 else emax if r < 0.2 else ce
        xs.append(bf_block(rng, prec, NX[prec], ce, kind))
    if kind == "zero":
        # x in pairs (v, -v) and the matrix elements that meet them equal: the dot is exactly 0 with
        # non-zero common exponents, so the result is c on the adder grid (jammed below it)
        for c in range(4):
            xs[c] = [xs[c][j & ~1] ^ ((j & 1) << (w - 1)) for j in range(len(xs[c]))]
        step = 2 if prec == "f" else 1      # f: x element j meets matrix element 2j
        for i in range(rows):
            r = mat[i]
            mat[i] = [r[(j // step & ~1) * step + (j % step)] for j in range(len(r))]
    yraw = HALF if opts["extc"] else SINGLE
    ys = []
    for c in range(4):
        yc = []
        cb = max((v >> mb) & emax for v in xs[c])
        for i in range(rows):
            ca = max((v >> mb) & emax for v in mat[i])
            ep = (ca - bias) + (cb - bias)
            g = ep - KGRID[prec]
            if kind == "grid":
                lead = g + rng.randint(-3, 26)
            elif kind == "zero":
                lead = g + rng.randint(-5, 24)
            elif kind == "drop":
                lead = ep + rng.randint(24, 40)
            else:
                lead = ep + rng.randint(-40, 30)
            v = rand_c(rng, yraw, lead)
            if kind == "drop" and not opts["extc"] and opts["rnd"]:
                v = tie_c(rng, 9, lead)     # on a half-precision tie: the product decides, unless dropped
            r = rng.random()
            if r < 0.04:
                v = 0
            elif r < 0.06 and kind == "special":
                v = ((rng.getrandbits(1) << (yraw[2] - 1)) | (((1 << yraw[0]) - 1) << yraw[1]))
            yc.append(v)
        ys.append(yc)
    return dict(mat=mat, xs=xs, ys=ys)


def pack_lw(elems, width):
    per = 64 // width
    out = []
    for k in range(0, len(elems), per):
        v = 0
        for e in elems[k:k + per]:
            v = (v << width) | e
        v <<= width * (per - len(elems[k:k + per]))
        out.append(v)
    return out


def case_data(prec, case, opts):
    """per PE: matrix source, x and y long words."""
    eb, mb, w, bias = BF[prec]
    per_pe = ROWS[prec] // 4
    pe = [dict(mat=[], x=[], y=[]) for _ in range(4)]
    if prec == "h":
        for blk in range(2):
            for c in range(4):
                for k in range(2):
                    row = case["mat"][8 * blk + 2 * c + k]
                    for p in range(4):
                        pe[p]["mat"] += pack_lw(row[4 * p:4 * p + 4], 16)
    else:
        for blk in range(2):
            for c in range(4):
                row = case["mat"][4 * blk + c]
                for p in range(4):
                    pe[p]["mat"] += pack_lw(row[2 * p:2 * p + 2], 32)
    xw = []
    for c in range(4):
        xs = case["xs"][c]
        for p in range(4):
            if prec == "f":
                pe[p]["x"].append(xs[p])
            elif prec == "g":
                pe[p]["x"] += pack_lw(xs[2 * p:2 * p + 2], 32)
            else:
                pe[p]["x"] += pack_lw(xs[4 * p:4 * p + 4], 16)
    del xw
    for p in range(4):
        if prec == "f":
            pe[p]["x"] = pack_lw(pe[p]["x"], 32)
    yw = 16 if opts["extc"] else 32
    for p in range(4):
        flat = []
        for c in range(4):
            flat += case["ys"][c][per_pe * p:per_pe * (p + 1)]
        pe[p]["y"] = pack_lw(flat, yw)
    return pe


def mf_test(prec, seed, ncase, kinds, rnd=None):
    """a test of ncase matrix FMA instructions (prec) with block-float data; per case: ?mwrite of
    the matrix (GRF), ?mfma with x (GRF) and y (LM1), result to LM0."""
    rng = random.Random(f"wp36-mf-{prec}-{seed}")
    lay = LAY[prec]
    body, regs = [], []
    data = [{"lr": {}, "ls": {}, "ln": {}} for _ in range(4)]
    for k in range(ncase):
        kind = kinds[k % len(kinds)]
        opts = dict(rnd=(prec == "h") and (rnd if rnd is not None else rng.random() < 0.3),
                    zeroc=rng.random() < 0.2, signa=rng.random() < 0.25, signc=rng.random() < 0.25)
        opts["extc"] = (not opts["zeroc"]) and rng.random() < 0.2 and kind != "drop"
        if kind == "resid":
            # dot - round(dot): a ?mmul to $mauf, then ?mfma with y = -$mauf (random data)
            opts.update(rnd=False, zeroc=False, extc=False, signc=False)
        case = mf_case(rng, prec, kind, opts)
        reg = "lr" if k % 2 == 0 else "ls"
        R = "r" if reg == "lr" else "s"
        mbase = (k // 2) * (lay[0] + lay[1])
        xbase = mbase + lay[0]
        ybase = k * lay[2]
        obase = k * lay[3]
        pd = case_data(prec, case, opts)
        for p in range(4):
            for i, v in enumerate(pd[p]["mat"]):
                data[p][reg][mbase + i] = v
            for i, v in enumerate(pd[p]["x"]):
                data[p][reg][xbase + i] = v
            for i, v in enumerate(pd[p]["y"]):
                data[p]["ln"][ybase + i] = v
        if prec == "h":
            body += [f"hmwrite $ll{R}{2 * mbase}v $llx0", f"hmwrite $ll{R}{2 * mbase + 16}v $llx8"]
        else:
            body += [f"{prec}mwrite $l{R}{2 * mbase}v $lx0", f"{prec}mwrite $l{R}{2 * mbase + 8}v $lx4"]
        sa = "-" if opts["signa"] else ""
        sc = "-" if opts["signc"] else ""
        xop = f"{sa}${R}{2 * xbase}v" if prec == "f" else f"{sa}$l{R}{2 * xbase}v"
        if opts["extc"]:
            yop = f"{sc}$ln{2 * ybase}ve" if prec == "h" else f"{sc}$n{2 * ybase}ve"
        else:
            yop = f"{sc}$lln{2 * ybase}v" if prec == "h" else f"{sc}$ln{2 * ybase}v"
        if prec == "h":
            dst = f"$lm{2 * obase}v" if opts["rnd"] else f"$llm{2 * obase}v"
        else:
            dst = f"$lm{2 * obase}v"
        op = {"f": "fm", "g": "gm", "h": "hm"}[prec] + ("mul" if opts["zeroc"] else "fma") + ("r" if opts["rnd"] else "")
        if kind == "resid":
            body += [f"{prec}mmul $lx {xop} $nowrite", f"{prec}mfma $lx {xop} -$mauf {dst}"]
        else:
            body.append(f"{op} $lx {xop} {dst}" if opts["zeroc"] else f"{op} $lx {xop} {yop} {dst}")
        regs.append(obase)
    body.append("nop/3")

    def init(name):
        out = []
        for p, loc in enumerate(LOCS):
            for reg, n in (("lr", 256), ("ls", 256), ("ln", 128)):
                vals = [data[p][reg].get(i, 0) for i in range(n)]
                top = max((i + 1 for i, v in enumerate(vals) if v), default=0)
                if top:
                    out.append(f"d set ${reg}0{loc} {top} " + lw_hex(vals[:top]))
        return out
    return body, init


MF_MIX = [
    # data: gbfn of random singles to make valid blocks, then the matrix operations
    "gbfn $lr0v $nowrite", "gmwrite $aluf $lx0",
    "gbfn $lr8v $nowrite", "gmwrite $aluf $lx4",
    "gbfn $ls0v $nowrite", "gmwrite $aluf $ly0",
    "gbfn $ls8v $nowrite", "gmwrite $aluf $ly4",
    "gbfn $lm0v $nowrite",
    "gmmul $lx $aluf $ln64v",                              # x from $aluf
    "gbfn $lm0v $nowrite",
    "gmfma $ly $aluf $lr16v $ln72v ; gmread $lx3 $lm64v",   # mfma + mread (X, column 3)
    "nop/2",
    "gbfn $lm8v $t", "nop/2",
    "gmfma $lx $t $ls16v $ln80v ; gmwrite $lr24v $ly0",     # mfma (X) + mwrite (Y, not a block)
    "gmmul $lx $t $nowrite", "fvpassa $mauf $lm72v",       # the result through $mauf
    "gmread $ly1 $nowrite",
    "gmfma $lx $t $lr16v $ln88v/1010 ; lpassa $mreadf $lm80v",   # ALU reading $mreadf, mask
    "gmfma/0110 $lx $t $lr16v $ln96v", "fvpassa $mauf $lm88v",  # zero flush of the MAU result
    "nop/3",
]


# $mauf of the matrix MAU: as the ALU's x after a matrix step (also through a nop), zero-flushed,
# as the y (port c) of the next ?mfma. Without vector MAU instructions, so that it also runs on a
# core without the vector MAU (MAU = 0: the matrix unit keeps $mauf; fixed/mau0.scr)
MF_MAUF = [
    "gbfn $lr0v $nowrite", "gmwrite $aluf $lx0",
    "gbfn $lr8v $nowrite", "gmwrite $aluf $lx4",
    "gbfn $ls0v $t", "nop/2",
    "gmmul $lx $t $nowrite", "lpassa $mauf $lm64v",
    "gmmul $lx $t $ln64v", "nop", "lpassa $mauf $lm72v",
    "gmmul/1010 $lx $t $nowrite", "lpassa $mauf $lm80v",
    "gmmul $lx $t $nowrite", "gmfma $lx $t $mauf $lm88v",
    "gmfma $lx $t -$mauf $ln72v/0110", "lpassa $mauf $lm96v",
    "nop/3",
]


def mf_mix_init(name):
    out = []
    for p, loc in enumerate(LOCS):
        rng = random.Random(f"wp36-mix-{name}-{p}")

        def sgl():
            return (rng.getrandbits(1) << 31) | (rng.randint(115, 135) << 23) | rng.getrandbits(23)
        for mem in ("lr", "ls", "lm", "ln"):
            out.append(f"d set ${mem}0{loc} 32 " + lw_hex((sgl() << 32) | sgl() for _ in range(32)))
        tv = []
        for c in range(4):
            tv.append((rng.getrandbits(32) << 32) | (8 * c))
            tv.append((sgl() << 32) | sgl())
        out.append(f"d set $llt{loc} 4 " + lw_hex(tv))
    return out


def t_init(t_word1):
    def init(name):
        out = rand_init(name)
        out = [ln for ln in out if not ln.startswith("d set $llt")]
        rng = random.Random(f"wp36-t-{name}")
        for p, loc in enumerate(LOCS):
            tv = []
            for c in range(4):
                tv.append((rng.getrandbits(32) << 32) | t_word1[p][c])
                tv.append(rng.getrandbits(64))
            out.append(f"d set $llt{loc} 4 " + lw_hex(tv))
        return out
    return init


TIND_PE2 = [[8 * c for c in range(4)] for _ in range(4)]
TIND_PE2[2][2] = 0x400
TIND_PE1 = [[8 * c for c in range(4)] for _ in range(4)]
TIND_PE1[1][0] = 0x3f8

ERR_PRE = ["dmwrite $lr0v $lx0", "nop"]

MF_G, MF_G_INIT = mf_test("g", 1, 14, ["rand", "grid", "special", "wide", "rand"])
MF_F, MF_F_INIT = mf_test("f", 1, 16, ["rand", "grid", "special", "wide"])
MF_H, MF_H_INIT = mf_test("h", 1, 14, ["rand", "grid", "ext", "special", "drop"], rnd=False)
MF_HR, MF_HR_INIT = mf_test("h", 2, 14, ["rand", "grid", "drop", "special", "ext"], rnd=True)
# the low bits of the dot: the residual dot - round(dot), and c on the grid of a dot that is exactly 0
MF_F0, MF_F0_INIT = mf_test("f", 3, 12, ["resid", "zero"])
MF_G0, MF_G0_INIT = mf_test("g", 3, 12, ["resid", "zero"])
MF_H0, MF_H0_INIT = mf_test("h", 3, 8, ["zero"], rnd=False)

TESTS = [
    T("mat_rw_d", RW_D, init=init_seq),
    T("mat_rw_f", RW_F, init=init_floats),
    T("mat_rw_h", RW_H, init=init_floats),
    T("mat_rw_mix", RW_MIX, init=init_seq),
    T("mat_mreadf", MREADF, init=init_floats),
    T("mfma_g", MF_G, init=MF_G_INIT),
    T("mfma_f", MF_F, init=MF_F_INIT),
    T("mfma_h", MF_H, init=MF_H_INIT),
    T("mfma_hr", MF_HR, init=MF_HR_INIT),
    T("mfma_f0", MF_F0, init=MF_F0_INIT),
    T("mfma_g0", MF_G0, init=MF_G0_INIT),
    T("mfma_h0", MF_H0, init=MF_H0_INIT),
    T("mfma_mix", MF_MIX, init=mf_mix_init),
    T("mfma_mauf", MF_MAUF, init=mf_mix_init),
    T("e_unsup_dmfma", ERR_PRE + ["dmfmau $lx $lr0v $ls0v $nowrite"], status=(UNSUP, F["pe_mauc_dmode"])),
    T("e_range_mwrite", ERR_PRE + ["hmwrite $lmt0v $ly0"], init=t_init(TIND_PE2), status=(RANGE, last_word),
      note="the LM source of ?mwrite is out of range on PE 2 only (cycle 2): no PE writes"),
    T("e_range_mfma_x", ERR_PRE + ["gmmul $lx $lmt0v $nowrite"], init=t_init(TIND_PE1), status=(RANGE, last_word),
      note="the x of ?mmul is out of range on PE 1 only: E_RANGE before any write"),
]


# the tests without vector MAU or FP ALU instructions: fixed/mau0.scr, run by the unit mat_m0 on the
# core of the matrix bitstream (FPALU = 0, MAU = 0, BFN = 1, MAT = 1: the matrix unit keeps the MAU
# result and $mauf)
MAU0_TESTS = {"mat_rw_d", "mat_rw_f", "mat_rw_h", "mat_rw_mix", "mfma_g", "mfma_f", "mfma_h", "mfma_hr",
              "mfma_f0", "mfma_g0", "mfma_h0", "mfma_mauf", "e_unsup_dmfma", "e_range_mwrite",
              "e_range_mfma_x"}


def program(t) -> str:
    body = list(t["body"])
    init = (t["init"] or rand_init)(t["name"])
    if t["status"] is not None:
        lines = init + body[:-1] + ["nop/3"] + g30.GET_LINES + body[-1:]
    else:
        lines = init + body + ["nop/3"] + g30.GET_LINES
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="comma separated test names")
    ap.add_argument("--jobs", type=int, default=12)
    ap.add_argument("--keep-going", action="store_true", help="write the tests that worked")
    a = ap.parse_args(argv)
    only = set(a.only.split(",")) if a.only else None
    tests = [t for t in TESTS if not only or t["name"] in only]
    BUILD.mkdir(parents=True, exist_ok=True)
    for f in BUILD.iterdir():
        f.unlink()
    for t in tests:
        (BUILD / f"{t['name']}.vsm").write_text(program(t), encoding="utf-8", newline="\n")
    cmd = gl.wsl_cmd(g30.CORE / "emu_batch.sh", [gl.wsl_path_arg(BUILD), str(a.jobs)])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
    ok = True
    scripts = []
    for t in tests:
        n = t["name"]
        arc = (BUILD / f"{n}.arc").read_text().strip() if (BUILD / f"{n}.arc").exists() else "?"
        if arc != "0":
            print(f"{n}: assemble3 failed ({arc}): {(BUILD / f'{n}.aerr').read_text(errors='replace')[-400:]}")
            ok = False
            continue
        erc = (BUILD / f"{n}.erc").read_text().strip() if (BUILD / f"{n}.erc").exists() else "?"
        if erc != "0":
            print(f"{n}: emulator failed ({erc}): {(BUILD / f'{n}.eout').read_text(errors='replace')[-400:]}")
            ok = False
            continue
        try:
            scr, n_q, n_w = g30.make_fixed(t, (BUILD / f"{n}.asm").read_text(encoding="utf-8"), BUILD / f"{n}.dmp")
        except ValueError as e:
            print(f"{n}: {e}")
            ok = False
            continue
        print(f"{n}: {n_w} words, {n_q} checks" + (f", stop {t['status'][0]}" if t["status"] else ""))
        scripts.append((n, scr))
    if not ok and not a.keep_going:
        print("FAIL: nothing written")
        return 1
    FIXED.mkdir(exist_ok=True)
    for n, scr in scripts:
        (BUILD / f"{n}.scr").write_text(scr + "E\n", encoding="utf-8", newline="\n")
    if not only:
        allscr = "".join(scr for _, scr in scripts) + "E\n"
        (FIXED / "all.scr").write_text(allscr, encoding="utf-8", newline="\n")
        m0 = "".join(scr for n, scr in scripts if n in MAU0_TESTS) + "E\n"
        (FIXED / "mau0.scr").write_text(m0, encoding="utf-8", newline="\n")
        print(f"wrote {len(scripts)} tests to {FIXED.relative_to(ROOT)}/ (all.scr; mau0.scr: "
              f"{len([n for n, _ in scripts if n in MAU0_TESTS])} of them for the unit mat_m0)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

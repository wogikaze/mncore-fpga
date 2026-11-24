#!/usr/bin/env python3
"""WP20 directed tests for the core unit, with the official emulator's results as expectations.

    python mncore/sim/tb/core/gen_fixed.py [--only NAME,...] [--jobs 12] [--keep-going]

Every test in TESTS is a small program: deterministic initial data (d set of GRF0/GRF1 long
words 0..31, LM0/LM1 0..63 and T), the body, and d get of the regions the tests use (GRF and LM
long words 0..127, T, $omr1..15). It is assembled with the official assemble3 (flat, no
packer) and run on the official emulator (WSL, emu_batch.sh; only called, contract section 9).
The result is a tb_core script (the same steps as `mnhost.py run`) whose Q lines check the
final state against the emulator's dump and whose K lines check the stop record of each RUN:
    fixed/all.scr   all tests (committed, the simrun default),
    build/fixed/<name>.scr   one per test (vvp sim.vvp +script=...)
The scripts are committed: `python mncore/tools/simrun.py core` needs neither WSL nor the
official tools.

The tests cover what the corpus regression (mncore/sim/regress) exercises little or not at all
(mncore/sim/regress/coverage.py): all ALU operations and precisions with `u`, the FP ALU
operations, the MAU vector operations with signs / e / r / round_out / u-d, fixed operands,
forwarding through nop and noforward, zero flush of either unit, words with both units,
$omr from the MAU, T, $mb / $nb and T-indirect, and the stop records of the 1-PE core:
E_UNSUPPORTED (msl, bfn, L1BM, ?mwrite, matrix MAU, MV, `r` with dmode != 10),
E_RANGE (also a write stopped by the mask, contract 06 section 3) and E_DECODE (ll = 10).
Error tests end with the failing word and read the state before it: the core must stop
without writing anything. Their expected stop record is the contract's, not the emulator's.
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
import run as rg  # noqa: E402
import norm_gpfn3  # noqa: E402
import goldenlib as gl  # noqa: E402

LOC = "n0c0b0m0p0"
N_LW = 128            # long words of GRF0/GRF1/LM0/LM1 checked (words 0..255)

# field indices for the expected E_UNSUPPORTED records (mncore/rtl/dec/mn_jfields.vh _IDX)
F = {name: i for i, name in enumerate(rg.FIELDS)}
UNSUP, RANGE, DECODE = 2, 1, 3


def T(name, body, status=None, patch=None, official=True, note=""):
    """status: (reason, info) of the last RUN, info may be a callable(entries) -> int.
    patch: callable(entries) changing the assembled words (E_DECODE).
    official = False: the emulator is not run (it stops on the word); only the stop record and
    the state before the word are checked, from the emulator run of the body without it."""
    return dict(name=name, body=body, status=status, patch=patch, official=official, note=note)


def last_word(entries):
    return len(entries) - 1


def ll10(entries):
    tag, w = entries[-1]
    entries[-1] = (tag, (w & ~(3 << 424)) | (2 << 424))


# ---------------------------------------------------------------------------------- tests
def alu_int(prec):
    ops2 = ["add", "sub", "and", "or", "xor", "max", "min", "lsl", "lsr", "bsl", "bsr", "packbit"]
    ops1 = ["inc", "dec", "not", "lnot", "passa"]
    srcs = ["$lr{a}v", "$ls{a}v", "$lm{a}v", "$ln{a}v"]
    dsts = ["$lr{a}v", "$ls{a}v", "$lm{a}v", "$ln{a}v"]
    body, n = [], 0
    nxt = {"lr": 64, "ls": 64, "lm": 64, "ln": 64}

    def dst(i, used):
        # LM has one address per cycle for reading and writing: no LM destination that is read
        for j in range(4):
            d = dsts[(i + j) % 4]
            k = d[1:3]
            if k in ("lm", "ln") and k in used:
                continue
            a = nxt[k]
            nxt[k] += 8
            return d.format(a=a)
        raise AssertionError

    def src(i, k):
        # x and y come from different memories (one read address per memory and cycle)
        return srcs[(i + k) % 4].format(a=(8 * ((i + 3 * k) % 6)))

    for u in ("", "u"):
        for op in ops2 + ops1:
            if u and op in ("not", "lnot", "passa", "and", "or", "xor", "bsl", "bsr", "lsl", "packbit"):
                continue
            s0, s1 = src(n, 0), src(n, 1)
            used = {s0[1:3]} | ({s1[1:3]} if op in ops2 else set())
            ins = f"{u}{prec}{op} {s0}"
            if op in ops2:
                ins += f" {s1}"
            ins += f" {dst(n, used)}"
            if n % 3 == 0:
                ins += f" $omr{1 + (n // 3) % 15}"
            body += [ins, "nop/2"]
            n += 1
    # T as a source, 2 long word destinations
    body += [f"{prec}add $t $lr0v $llr{nxt['lr']}v", "nop/2", f"{prec}xor $ls8v $t $t", "nop/2"]
    return body


def alu_fp(prec):
    ops2 = ["max", "min", "relu", "relu1", "relu2", "relu3", "lrelud", "lreluo", "ilrelud"]
    ops1 = ["rsqrt", "floor", "ftoi", "passa", "packbit"]
    body, n = [], 0
    nxt = {"lr": 64, "ls": 64, "lm": 64, "ln": 64}
    order = ["lr", "ls", "lm", "ln"]
    for op in ops2 + ops1 + ["uftoi"]:
        name = f"u{prec}ftoi" if op == "uftoi" else f"{prec}{op}"
        if op == "packbit":
            srcs = f"$lm{8 * (n % 6)}v $ln{8 * ((n + 1) % 6)}v"
            used = {"lm", "ln"}
        elif op in ops2:
            a, b = order[n % 4], order[(n + 1) % 4]
            srcs = f"${a}{8 * (n % 6)}v ${b}{8 * ((n + 2) % 6)}v"
            used = {a, b}
        else:
            a = order[(n + 1) % 4]
            srcs = f"${a}{8 * (n % 6)}v"
            used = {a}
        # no LM destination that is also read (one LM address per cycle)
        k = next(order[(n + j) % 4] for j in range(4)
                 if not (order[(n + j) % 4] in ("lm", "ln") and order[(n + j) % 4] in used))
        d = f"${k}{nxt[k]}v"
        nxt[k] += 8
        ins = f"{name} {srcs} {d}"
        if n % 2 == 0:
            ins += f" $omr{1 + n % 15}"
        body += [ins, "nop/2"]
        n += 1
    if prec == "h":
        # `r`: single -> half rounding of the inputs (h only)
        body += ["hmax $lr0vr $ls0vr $lr200v $omr14", "nop/2",
                 "hrelu $lm8vr $ln8v $ls200v", "nop/2",
                 "hrsqrt $ln16vr $lm200v", "nop/2",
                 "hpassa $lr16vr $ln200v $omr15", "nop/2"]
    return body


MAU_BODIES = {
    # (no LM destination that is also read; x / y / z from different memories or the same address)
    "d": ["dvfmau $lr0v $ls0v $lm0v $lr64v $omr1", "nop/2",
          "dvfmad $lr8v $ls8v $lm8v $ls64v", "nop/2",
          "dvfmau $lr16v $ls16v $ln16v $lm64v $omr2", "nop/2",
          "dvmulu $lr24v $ls24v $ln64v", "nop/2",
          "dvmuld -$lr32v $ls32v $lr72v", "nop/2",
          "dvmulu $lr40v -$ls40v $ls72v", "nop/2",
          "dvadd $lm24v -$ln24v $lr80v $omr3", "nop/2",
          "dvpassa -$ln32v $lm72v", "nop/2",
          "dvfmaur $lr0v $ls8v $lm16v $r160v $omr4", "nop/2",
          "dvmuldr $lr8v $ls16v $s160v", "nop/2",
          "dvfmau $lr0ve $ls0ve $lm0v $ls80v", "nop/2",
          "dvadd $lm8ve $ln8v $lr88v", "nop/2",
          "dvfmau -$lr8v -$ls16v -$lm24v $ln72v", "nop/2",
          "dvpassa $t $ls88v", "nop/2",
          "dvfmau $t $lr24v $t $lm80v", "nop/2"],
    "f": ["fvfma $lr0v $ls0v $lm0v $lr64v $omr1", "nop/2",
          "fvfmar $lr8v $ls8v $lm8v $ls64v $omr2", "nop/2",
          "fvmul $lr16v -$ls16v $ln64v", "nop/2",
          "fvmulr $lr24v $ls24v $lm64v", "nop/2",
          "fvadd -$lm24v $ln24v $lr72v $omr3", "nop/2",
          "fvaddr $lm32v $ln32v $ls72v", "nop/2",
          "fvpassa -$ln40v $lm72v", "nop/2",
          "fvpassar $ln48v $lr80v $omr4", "nop/2",
          "fvfma $lr0ve $ls8ve $lm16ve $ls80v", "nop/2",
          "fvfma -$lr32v $ls40v -$lm40v $ln72v", "nop/2",
          "fvmul $lr40ve $ls48v $ln80v", "nop/2",
          "fvfma $t $lr48v $ln48v $lm80v", "nop/2"],
    "h": ["hvfma $lr0v $ls0v $lm0v $lr64v $omr1", "nop/2",
          "hvfmar $lr8v $ls8v $lm8v $ls64v $omr2", "nop/2",
          "hvmul $lr16v $ls16v $ln64v", "nop/2",
          "hvmulr $lr24v -$ls24v $lm64v", "nop/2",
          "hvadd $lm24v $ln24v $lr72v $omr3", "nop/2",
          "hvaddr -$lm32v $ln32v $ls72v", "nop/2",
          "hvpassa $ln40v $lm72v", "nop/2",
          "hvpassar -$ln48v $lr80v $omr4", "nop/2",
          "hvfma $lr0vr $ls8vr $lm16v $ls80v", "nop/2",
          "hvfma $lr8vr $ls16vr $lm24ve $ln72v", "nop/2",
          "hvfma $llr0vr $lls32vr -$llm40v $llr96v", "nop/2",
          "hvadd $lm8v $ln16ve $lr88v", "nop/2",
          "hvfma $t $lr48v $ln48v $lm80v", "nop/2"],
}

FIXED_BODY = [
    # fixed operands: chip coordinates of n0c0b0m0p0 (all 0) and $msb1, per lane width
    "lpassa $peid $lr64v", "ipassa $peid $lr72v", "spassa $subpeid $lr80v",
    "ipassa $l1bid $ls64v", "lpassa $l2bid $ls72v", "spassa $mabid $ls80v",
    "lpassa $msb1 $lr88v", "ipassa $msb1 $lr96v", "spassa $msb1 $lr104v",
    "ladd $msb1 $lr0v $ls88v", "iadd $peid $lr8v $ls96v", "sxor $msb1 $ls16v $ls104v $omr1",
    "lor $subpeid $lm0v $lr112v", "iand $msb1 $ln0v $ls112v",
]

FWD_BODY = [
    # $aluf / $mauf as every operand, through nop and noforward, with zero flush. The emulator
    # stops when $aluf / $mauf is read after a step without that unit ("IALU is disabled"), so
    # every read follows a step of the producer (nop / noforward steps in between keep it).
    # Destinations are GRF words 64.. (never read here, so no hazard rule applies).
    "iadd $lr0v $ls0v $nowrite",
    "ipassa $aluf $lr64v",                                   # x = aluf
    "isub $lm0v $aluf $lr72v",                               # y = aluf
    "fvfma $lr8v $ls8v $lm8v $nowrite ; ipassa $aluf $ls64v",
    "fvpassa $mauf $lr80v ; ipassa $aluf $ls72v",            # a = mauf
    "fvfma $lm16v $mauf $aluf $lr88v ; iadd $ln16v $aluf $ls80v",   # b = mauf, c = aluf
    "fvfma $aluf $ls16v $mauf $lr96v ; ipassa $mauf $ls88v", # a = aluf, c = mauf, ALU x = mauf
    "iadd $lm8v $mauf $lr104v",                              # ALU y = mauf
    "nop",
    "ipassa $aluf $lr112v",                                  # aluf kept over a nop
    "noforward ; iadd $ls24v $lm32v $ls96v",                 # writes, but aluf is not updated
    "ipassa $aluf $ls104v",                                  # aluf of the step before it
    "lpassa/0101 $lr24v $lr120v",                            # zero flush of the ALU output
    "lpassa $aluf $ls112v",                                  # aluf holds the flushed value
    "fvpassa/1010 $ls24v $lr128v ; ipassa $aluf $ls120v",    # zero flush of the MAU output
    "fvpassa $mauf $lr136v ; ipassa $aluf $ls128v",
    "lpassa/ll0110 $lr32v $lr144v",                          # 2 long word zero flush
    "lpassa $aluf $ls136v ; fvpassa $lr40v $nowrite",
    "noforward ; fvfma $lr0v $ls0v $lm0v $nowrite",          # mauf is not updated
    "fvpassa $mauf $lr152v",                                 # mauf of the step before it
    "ipassa $mreadf $ls144v",                                # no ?mwrite: the matrix register is 0
    "dvpassa $lr0v $nowrite",
    "nop/3",
    "lpassa $mauf $lr160v",                                  # mauf kept over 3 nops
]

DUAL_BODY = [
    # both units in one word (each memory read at one address), flags to $omr from either unit,
    # masks from $omr
    "fvadd $lr0v $ls0v $lr64v $omr1 ; iadd $lm0v $ln0v $ls64v", "nop/2",
    "fvmul $lr8v $lm8v $ls96v ; ixor $ls16v $ln16v $lr96v $omr2", "nop/2",
    "fvfma $lr16v $ls16v $lm16v $omr3 ; lpassa $ln16v $lr72v", "nop/2",
    "ipassa/$imr1 $lm24v $lr80v", "nop/2",
    "fvpassa $ln24v $ls72v/$imr2", "nop/2",
    "lpassa $lm32v $ls80v/$imr3 $omr4", "nop/2",
    "fvadd $lr32v $ls32v $lm72v/$imr4 ; ipassa $t $ln72v", "nop/2",
    "fvpassa/$imr3 $lr40v $ls88v", "nop/2",               # MAU zero flush from a mask register
    "lpassa $lr40v $llr96v/$llimr1", "nop/2",              # 2 long word mask from $omr
    "iadd $ls40v $lm40v $ln80v/1001 $omr5", "nop/2",
    "fvadd $lr48v $ls48v $t/0110", "nop/2",                # T with a pattern mask
    "lpassa $t $lr104v", "nop/2",
    "fvmul $ln40v $ls48v $omr6/$imr2", "nop/2",            # $omr write under a mask
]

TB_BODY = [
    # T, $mb / $nb and T indirect (also the same-step T write, measured on the emulator).
    # T-indirect and base addresses are kept small so that they stay inside the reduced LM.
    "dvpassa $lr0v $t", "nop/2",
    "lpassa $t $lr64v", "nop/2",
    'imm i"0x10" $t', "nop/2",                             # word 1 of every T entry = 0x10
    "fvpassa $lmt0v $lr72v", "nop/2",                      # T-indirect read
    "dvpassa $ls0v $lmt16v", "nop/2",                      # T-indirect write from the MAU
    "lpassa $lr16v $t ; fvpassa $lmt8v $ls64v", "nop/2",   # same step: address from the old T
    "lpassa $t $lr80v", "nop/2",
    'imm i"0x20" $lr120', "nop/2",
    "lpassa $lr120 $lmb", "nop/2",                         # $mb from the ALU (long: word 1)
    "lpassa $lm0v $ls72v", "nop/2",
    'imm i"0x3f800018" $ls120', "nop/2",
    "fvpassa $ls120 $nb", "nop/2",                         # $nb from the MAU (word: word 0)
    "lpassa $ln0v $ls80v", "nop/2",
    "lpassa $lm8vj1 $ls88v", "nop/2",                      # madpe: p0 <= 1 adds the length
    "lpassa $lr0v $ln16vj0", "nop/2",
    "ipassa $m3vj2 $s200v", "nop/2",
]

ERR_PRE = ["iadd $lr0v $ls0v $lr64v $omr1", "nop/2", "fvfma $lr8v $ls8v $lm8v $ls64v", "nop/2"]

TESTS = [
    T("alu_int_l", alu_int("l")),
    T("alu_int_i", alu_int("i")),
    T("alu_int_s", alu_int("s")),
    T("alu_fp_d", alu_fp("d")),
    T("alu_fp_f", alu_fp("f")),
    T("alu_fp_h", alu_fp("h")),
    T("mau_d", MAU_BODIES["d"]),
    T("mau_f", MAU_BODIES["f"]),
    T("mau_h", MAU_BODIES["h"]),
    T("fixed_operands", [x for i in FIXED_BODY for x in (i, "nop/2")]),
    T("forwarding", FWD_BODY),
    T("dual_unit_masks", DUAL_BODY),
    T("t_bar_tind", TB_BODY),
    T("wait_nop", ERR_PRE + ["nop ; wait i01"], note="the emulator blocks at the wait; nothing follows it"),
    # stop records (E_UNSUPPORTED / E_RANGE / E_DECODE): the last word fails
    T("e_msl", ERR_PRE + ["msl $lr0v $lr96v"], status=(UNSUP, F["pe_aluc_aluop"])),
    T("e_bfn", ERR_PRE + ["fbfn $lr0v $lr96v"], status=(UNSUP, F["pe_aluc_aluop"])),
    T("e_l1bm", ERR_PRE + ["l1bmp $lb0 $lr96v"], status=(UNSUP, F["l1bm_bmode"])),
    T("e_mwrite", ERR_PRE + ["dmwrite $lr0v $lx0"], status=(UNSUP, F["pe_mauc_mw"])),
    T("e_matrix", ERR_PRE + ["fmmul $lx $lm0v $ln64v"], status=(UNSUP, F["pe_mauc_mmode"]),
      official=False, note="the emulator rejects the random (not block-float) operands"),
    T("e_mv", ERR_PRE + ["mvp/n64i01 $lc0@.0 $d0"], status=(UNSUP, 0x80)),
    T("e_round", ERR_PRE + ["fmax $lr0vr $ls0v $lr96v"], status=(UNSUP, F["pe_aluc_rounda"]),
      official=False),
    T("e_range_read", ERR_PRE + ["lpassa $lm1024v $lr96v"], status=(RANGE, last_word)),
    T("e_range_write", ERR_PRE + ["lpassa $lr0v $ln1020v"], status=(RANGE, last_word)),
    T("e_range_masked", ERR_PRE + ["lpassa $lr0v $ln1020v/0000"], status=(RANGE, last_word),
      note="a write stopped by the mask is range checked too (contract 06 section 3)"),
    T("e_range_tind", ERR_PRE + ['imm i"0x800" $t', "nop/2", "lpassa $lmt0v $lr96v"],
      status=(RANGE, last_word), note="T-indirect address 2048 words"),
    T("e_decode", ERR_PRE + ["lpassa $lr0v $lr96v"], status=(DECODE, 0), patch=ll10),
]


# ---------------------------------------------------------------------------------- data
def lw_data(rng: random.Random) -> int:
    """A long word that is interesting for integer and for d / f / h interpretations."""
    r = rng.random()
    if r < 0.25:
        return rng.getrandbits(64)
    if r < 0.45:   # double, normal
        return (rng.getrandbits(1) << 63) | ((1023 + rng.randint(-12, 12)) << 52) | rng.getrandbits(52)
    if r < 0.70:   # two singles, normal
        v = 0
        for _ in range(2):
            v = (v << 32) | (rng.getrandbits(1) << 31) | ((127 + rng.randint(-8, 8)) << 23) | rng.getrandbits(23)
        return v
    if r < 0.90:   # four halves, normal
        v = 0
        for _ in range(4):
            v = (v << 16) | (rng.getrandbits(1) << 15) | ((15 + rng.randint(-6, 6)) << 10) | rng.getrandbits(10)
        return v
    special = [0, 1 << 63, 0x7FF0000000000000, 0xFFF8000000000001, 0x000FFFFFFFFFFFFF,
               0x7F8000003F800000, 0x80000000FF800000, 0x007FFFFF00000001, 0x7C00FC0003FF8001,
               0x3C003C003C003C00, 0x0000000100000002, 0xFFFFFFFFFFFFFFFF, 0x8000000080000000]
    return rng.choice(special)


def init_lines(name: str):
    rng = random.Random(f"wp20-{name}")
    out = []
    for mem, n in (("lr", 32), ("ls", 32), ("lm", 64), ("ln", 64)):
        vals = "".join(f"{lw_data(rng):016x}" for _ in range(n))
        out.append(f"d set ${mem}0{LOC} {n} {vals}")
    # T: word 1 of each entry is small (T-indirect addresses), the rest is data
    tv = []
    for c in range(4):
        tv.append((rng.getrandbits(32) << 32) | (8 * c + 2 * rng.randint(0, 3)))
        tv.append(lw_data(rng))
    out.append(f"d set $llt{LOC} 4 " + "".join(f"{v:016x}" for v in tv))
    return out


GET_LINES = [f"d get $lr0{LOC} {N_LW}", f"d get $ls0{LOC} {N_LW}", f"d get $lm0{LOC} {N_LW}",
             f"d get $ln0{LOC} {N_LW}", f"d get $llt{LOC} 4", f"d get $omr1{LOC} 15"]


def program(t) -> str:
    body = list(t["body"])
    if t["status"] is not None or t["name"] == "wait_nop":
        # the state before the last word is the expected one
        lines = init_lines(t["name"]) + body[:-1] + ["nop/3"] + GET_LINES + body[-1:]
    else:
        lines = init_lines(t["name"]) + body + ["nop/3"] + GET_LINES
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------------- script
def make_fixed(t, asm_text: str, dmp_path: Path):
    entries, events, _ = rg.parse_official_asm(asm_text)
    if t["patch"]:
        t["patch"](entries)
    if len(entries) > rg.IMEM_DEPTH:
        raise ValueError("test longer than the instruction memory")
    lines = [f"# test {t['name']}" + (f": {t['note']}" if t["note"] else ""), "C"]
    for k, (tag, word) in enumerate(entries):
        lines.append(f"I {k:x} {rg.mnhost.imem_entry(tag, word):0112x}")
    # stop record of the last RUN (the others must stop with OK)
    reason, info = (0, 0) if t["status"] is None else t["status"]
    if callable(info):
        info = info(entries)
    pc = 0
    for pos, d in events:
        if pos > pc:
            lines.append(f"X {pc:x} {pos - pc:x}")
            lines.append("K 0 0" if pos < len(entries) else f"K {reason:x} {info:x}")
            pc = pos
        if d.op == "set" and d.on_pe():
            for sp, lw, m, v in rg.set_writes(d):
                lines.append(f"W {sp:x} 0 {lw:x} {m:x} {v:x}")
    if len(entries) > pc:
        lines.append(f"X {pc:x} {len(entries) - pc:x}")
        lines.append(f"K {reason:x} {info:x}")
    # expected final state (the emulator's d get), PE n0c0b0m0p0
    with open(dmp_path, encoding="utf-8", errors="replace") as fh:
        recs, _ = norm_gpfn3.records_from_lines(fh)
    data = rg.ndmp.canonical(recs)
    omr = {}
    n_q = 0
    for (space, loc, addr), v in sorted(data.items()):
        if loc != LOC:
            continue
        if space == "OMR":
            e, c = divmod(addr, 4)
            if 1 <= e <= 15:
                omr[e] = omr.get(e, 0) | (v << (4 * c))
            continue
        if space not in rg.SP_ID or (space in rg.DEPTH_LW and addr >= rg.DEPTH_LW[space]):
            continue
        lines.append(f"Q {rg.SP_ID[space]:x} 0 {addr:x} {v:016x}")
        n_q += 1
    for e, v in sorted(omr.items()):
        lines.append(f"Q {rg.SP_ID['OMR']:x} 0 {e:x} {v:016x}")
        n_q += 1
    return "\n".join(lines) + "\n", n_q, len(entries)


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
        prog = program(t)
        if not t["official"]:
            # the emulator stops on the last word: take the expectations from the body without it
            (BUILD / f"{t['name']}.vsm").write_text(prog, encoding="utf-8", newline="\n")
            (BUILD / f"{t['name']}.noemu").write_text("", encoding="utf-8")
            pre = prog.rsplit("\n", 2)[0] + "\n"
            (BUILD / f"{t['name']}__pre.vsm").write_text(pre, encoding="utf-8", newline="\n")
        else:
            (BUILD / f"{t['name']}.vsm").write_text(prog, encoding="utf-8", newline="\n")
    cmd = gl.wsl_cmd(HERE / "emu_batch.sh", [gl.wsl_path_arg(BUILD), str(a.jobs)])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
    ok = True
    scripts = []
    for t in tests:
        n = t["name"]
        arc = (BUILD / f"{n}.arc").read_text().strip() if (BUILD / f"{n}.arc").exists() else "?"
        if arc != "0":
            print(f"{n}: assemble3 failed ({arc}): {(BUILD / f'{n}.aerr').read_text(errors='replace')[:400]}")
            ok = False
            continue
        dmp_src = n if t["official"] else f"{n}__pre"
        erc = (BUILD / f"{dmp_src}.erc").read_text().strip() if (BUILD / f"{dmp_src}.erc").exists() else "?"
        if erc != "0":
            print(f"{n}: emulator failed ({erc}): "
                  f"{(BUILD / f'{dmp_src}.eout').read_text(errors='replace')[-400:]}")
            ok = False
            continue
        try:
            scr, n_q, n_w = make_fixed(t, (BUILD / f"{n}.asm").read_text(encoding="utf-8"),
                                       BUILD / f"{dmp_src}.dmp")
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
        # one script per test for debugging (not committed): vvp sim.vvp +script=<this>
        (BUILD / f"{n}.scr").write_text(scr + "E\n", encoding="utf-8", newline="\n")
    if not only:
        allscr = "".join(scr for _, scr in scripts) + "E\n"
        (FIXED / "all.scr").write_text(allscr, encoding="utf-8", newline="\n")
        print(f"wrote {len(scripts)} tests to {FIXED.relative_to(ROOT)}/ (all.scr)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

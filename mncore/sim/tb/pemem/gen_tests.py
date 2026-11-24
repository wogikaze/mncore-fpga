#!/usr/bin/env python3
"""WP14 test generator: PE local memory programs checked against the official emulator.

    python mncore/sim/tb/pemem/gen_tests.py [--only NAME,...] [--jobs 8]

For every program in TESTS:
  1. write a .vsm: 'd set' of random initial data (per PE), the body (one instruction per
     step, two nops between steps so that the assembler's hazard rules always hold), then
     'd get' of every region the tests use;
  2. assemble it with the official assemble3 (flat, no packer) and run the official emulator
     gpfn3_package_main (both in WSL, only called: contract section 9; emu_batch.sh);
  3. turn the assembler output and the emulator dump into records for tb_pemem
     (build/tests.hex, one 512-bit record per line, see tb_pemem_drv.v):
       BEGIN(test, pe) CLEAR WR... EXEC... CHK... [EXPECT_TRAP before the trapping EXEC]
The expected values are the emulator's (contract section 1). E_RANGE tests (reduced LM, the
emulator has the full 2048 long words) take their expected trap from the test definition, and
check that the state before the trapping word is unchanged.

The testbench models PE p of MAB 0 with subpe = p. Tests that depend on the PE number
(j<madpe>) run for p0..p3, the others for p0 only.
"""
from __future__ import annotations

import argparse
import os
import random
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
EMU_DIR = BUILD / "emu"
LM_AW = 9  # must match tb_pemem (LM depth 512 long words = 1024 words)

# host port spaces (rtl/board/PROTOCOL.md v1)
SP = {"m": 0x01, "n": 0x02, "r": 0x03, "s": 0x04, "t": 0x05}
DMP_SP = {"LM0": 0x01, "LM1": 0x02, "GREG0": 0x03, "GREG1": 0x04, "TREG": 0x05}
OP_END, OP_CLEAR, OP_WR, OP_EXEC, OP_CHK, OP_BEGIN, OP_XTRAP = 0, 1, 2, 3, 4, 5, 6

# regions initialised and dumped (word address, long words)
REGIONS = [("r", 0, 32), ("s", 0, 32), ("m", 0, 64), ("m", 960, 32), ("n", 0, 64), ("n", 960, 32)]

M_GRF0, M_GRF1, M_LM0, M_LM1 = 0, 1, 2, 3


def T(name, body, allpe=False, init=None, trap=None, note=""):
    """body: instruction lines (mask directives allowed). init: extra 'd set' lines
    (without the position; '{p}' is replaced by the PE position). trap: (body index of the
    trapping word, mem, cycle, wr, word address)."""
    return dict(name=name, body=body, allpe=allpe, init=init or [], trap=trap, note=note)


def small_lr(vals):
    """d set of GRF0 $lr0.. with the given long words."""
    return [("lr0", len(vals), "".join(f"{v:016x}" for v in vals))]


def flags_lw(p):
    """Long word whose ?passa zero flags (16-bit lanes) are the 4-bit pattern p (bit 3 first)."""
    v = 0
    for i in range(4):
        v = (v << 16) | (0 if (p >> (3 - i)) & 1 else 0x1111 * (i + 1))
    return v


TESTS = [
    # ---- plain copies: word / long / 2 long words, strides, flat addresses
    T("grf0_grf1_long", ["lpassa $lr0v $ls8v"]),
    T("grf1_grf0_long_stride", ["lpassa $ls4v4 $lr40v6"]),
    T("grf_word_odd", ["ipassa $r1v $s9v"]),
    T("grf_word_stride", ["ipassa $r3v2 $r33v3"]),
    T("grf_dlong", ["lpassa $llr0v $lls16v"]),
    T("lm0_lm1_long", ["lpassa $lm0v $ln32v"]),
    T("lm1_lm0_long", ["lpassa $ln10v $lm100v"]),
    T("lm_word", ["ipassa $m5v $n77v"]),
    T("lm_dlong_to_grf", ["lpassa $llm8v $llr20v"]),
    T("grf_dlong_to_lm", ["lpassa $llr4v $llm40v"]),
    T("flat_long", ["lpassa $lm[0,10,4,30] $lr[2,8,60,14]"]),
    T("flat_word", ["ipassa $m[1,3,99,7] $n[100,5,6,7]"]),
    T("flat_dlong", ["lpassa $lln[8,0,24,4] $lls[4,0,12,8]"]),
    T("same_src_all_cycles", ["lpassa $lr0 $lm64v"]),
    T("same_dst_last_wins", ["lpassa $lr8v $lr8"]),
    T("read_old_grf", ["lpassa $lr0v $lr2v"]),
    T("read_old_lm", ["lpassa $lm8v $lm8v"]),
    T("lm_high_region", ["lpassa $lm960v $ln1000v", "lpassa $ln960v4 $lm1016v"]),
    T("chain", ["lpassa $lr0v $lm16v", "lpassa $lm16v $ln16v", "lpassa $ln16v $ls16v"]),
    # ---- several outputs of one unit
    T("multi_out_long", ["lpassa $lr0v $lr40v $ls40v $lm40v $ln40v $t"]),
    T("multi_out_word", ["ipassa $r0v $r16v $m16v $n33v"]),
    T("multi_out_dlong", ["lpassa $llm0v $llr32v $lln64v"]),
    # ---- T register
    T("t_from_grf", ["lpassa $lr0v $t"]),
    T("t_to_grf", ["lpassa $t $lr20v"]),
    T("t_to_dlong", ["lpassa $t $llr40v"]),
    T("t_roundtrip", ["lpassa $llm0v $t", "lpassa $t $lls0v", "lpassa $t $llr40v"]),
    T("t_word_src", ["ipassa $r1v $t", "lpassa $t $ln40v"]),
    # ---- immediates and zero
    T("imm_multi", ['imm i"0x12345678" $lr0v $ls0v $t']),
    T("immu_word_dlong", ['immu i"0x9abc" $r8v $lln0v']),
    T("imm_to_lm1", ['imm i"-1" $ln[2,4,8,16]', 'imm f"1.5" $r3v']),
    T("zero_out", ["zero $lr0v $lm0v $t"]),
    # ---- base address registers $mb / $nb
    T("bar0_long", ["lpassa $lr0 $lmb", "lpassa $lm0v $lr40v", "lpassa $lr8v $lm32v"],
      init=small_lr([0x0000000000000011])),
    T("bar0_word", ["ipassa $r1 $mb", "ipassa $m0v $r40v", "lpassa $lm0v $lr44v"],
      init=small_lr([0x0000000500000000])),
    T("bar0_word_hi", ["ipassa $r0 $mb", "lpassa $lm2v $ls40v"],
      init=small_lr([0x0000002200000000])),
    T("bar1_long", ["lpassa $ls0 $lnb", "lpassa $ln0v $lr40v", "lpassa $lr0v $ln16v"],
      init=[("ls0", 1, "0000000000000020")]),
    T("bar_wrap", ["lpassa $lr0 $lmb", "lpassa $lm200v $lr40v", "lpassa $lr0v $lm212v"],
      init=small_lr([0x0000000000000fa0])),
    T("bar_both", ["lpassa $lr0 $lmb", "lpassa $lr2 $lnb", "lpassa $lm0v $ln0v"],
      init=small_lr([0x0000000000000004, 0x0000000000000106])),
    T("bar_masked", ["lpassa $lr0v $lmb/0010", "lpassa $lm0v $lr40v"],
      init=small_lr([0x8, 0x10, 0x18, 0x20])),
    # ---- T indirect ($lmt)
    T("tind_read", ["lpassa $lr0v $t", "lpassa $lmt0v $lr40v"],
      init=small_lr([5, 6, 7, 8])),
    T("tind_word", ["lpassa $lr0v $t", "ipassa $mt1v $s40v"],
      init=small_lr([3, 0x10, 0x21, 0x7])),
    T("tind_write", ["lpassa $lr0v $t", "lpassa $ls0v $lmt8v"],
      init=small_lr([0x20, 0x2, 0x41, 0x6])),
    T("tind_bar", ["lpassa $lr8 $lmb", "lpassa $lr0v $t", "lpassa $lmt4v $lr40v"],
      init=small_lr([0x10, 0x20, 0x30, 0x40, 0x3])),
    T("tind_dlong", ["lpassa $lr0v $t", "lpassa $llmt0v $llr40v"],
      init=small_lr([0x8, 0x0, 0x13, 0x22])),
    # ---- MAB address adjust j<madpe> (depends on the PE number)
    T("madpe_j0", ["lpassa $lm0vj0 $lr40v"], allpe=True),
    T("madpe_j1", ["lpassa $lm0vj1 $lr40v"], allpe=True),
    T("madpe_j2_lm1", ["lpassa $ln0vj2 $ls40v"], allpe=True),
    T("madpe_j3_word", ["ipassa $m1vj3 $r40v"], allpe=True),
    T("madpe_write", ["lpassa $lr0v $lm64vj1"], allpe=True),
    T("madpe_dlong", ["lpassa $llm0vj2 $llr40v"], allpe=True),
    T("madpe_lm1_write", ["lpassa $ls0v $ln32vj0", "lpassa $ls8v $ln64vj2"], allpe=True),
    # ---- write masks: fixed patterns, single line
    T("mask_grf_pat", ["lpassa $lr0v $ls0v/1010"]),
    T("mask_lm_pat", ["lpassa $lm0v $ln0v/0110"]),
    T("mask_word_pat", ["ipassa $r0v $r40v/0011"]),
    T("mask_t_pat", ["lpassa $lr0v $t/1001"]),
    T("mask_dlong_ll", ["lpassa $llr0v $llr40v/ll1010"]),
    T("mask_multi_dst", ["lpassa $lm0v $lr40v/0101 $ls40v/0101"]),
    # ---- multi-line mask directives
    T("maskdir_r", ["maskr 17", "lpassa $lm0v $lr40v", "lpassa $lm8v $lr48v", "mask 0", "lpassa $lm16v $lr56v"]),
    T("maskdir_mn", ["maskmn 26", "lpassa $lr0v $lm40v $ln40v", "mask 0"]),
    T("maskdir_ll", ["masklls 25", "lpassa $llr0v $lls32v", "mask 0"]),
    T("maskdir_cancel", ["maskr 17", "lpassa $lm0v $lr40v $ls40v/1100", "mask 0"]),
    # ---- mask register $omr / $imr
    T("omr_long", ["lpassa $lr0v $omr1", "lpassa $ls0v $lr40v/$imr1"]),
    T("omr_int", ["ipassa $lr0v $omr2", "lpassa $lm0v $ln0v/$imr2"]),
    T("omr_half_rmw", ["spassa $lr0v $omr3", "lpassa $ls0v $lr40v/$imr3"]),
    T("omr_half_lm_word", ["spassa $lr0v $omr3", "ipassa $s1v $m41v/$imr3", "ipassa $s9v $n40v/$imr3"]),
    T("omr_half_t", ["spassa $lr0v $omr4", "lpassa $ls0v $t/$imr4", "lpassa $t $lls40v"]),
    T("omr_ll", ["spassa $lr0v $omr5", "lpassa $llm0v $llr40v/$llimr5"]),
    T("omr_dir", ["spassa $lr0v $omr6", "maskrs 6", "lpassa $lm0v $lr40v $ls40v", "mask 0"]),
    T("omr_masked_write", ["spassa $lr0v $omr7", "spassa $ls0v $omr8/$imr7",
                           "lpassa $lm0v $ln0v/$imr8"]),
    T("omr_same_step", ["spassa $lr0v $omr9", "spassa $ls0v $omr9 $lr40v/$imr9",
                        "lpassa $lm0v $ln0v/$imr9"]),
    T("omr_bar_mask", ["spassa $lr8v $omr10", "lpassa $lr0v $lmb/$imr10", "lpassa $lm0v $lr40v"],
      init=small_lr([0x12, 0x22, 0x32, 0x42])),
    # $mb / $lmb under a mask: only the flag of the half word holding the 12 bits counts
    # (official emulator; viz/core writes whenever a flag is 1)
    T("bar_imr_lmb_hi", ["spassa $lr0 $omr1", "lpassa $lr8 $lmb/$imr1", "lpassa $lm0v $lr40v"],
      init=small_lr([flags_lw(0b0010), 0, 0, 0, 0x0000002000000012])),
    T("bar_imr_lmb_lo", ["spassa $lr0 $omr1", "lpassa $lr8 $lmb/$imr1", "lpassa $lm0v $lr40v"],
      init=small_lr([flags_lw(0b0001), 0, 0, 0, 0x0000002000000012])),
    T("bar_imr_mb", ["spassa $lr0 $omr1", "spassa $lr2 $omr2", "ipassa $r8 $mb/$imr1",
                     "lpassa $lm0v $lr40v", "ipassa $r8 $mb/$imr2", "lpassa $lm0v $ls40v"],
      init=small_lr([flags_lw(0b1000), flags_lw(0b0100), 0, 0, 0x0000002000000012])),
    # T under a long-word mask: a cycle with all flags 0 writes neither long word
    T("t_mask_zero_cycles", ["spassa $lr0v $omr1", "lpassa $ls0v $t/$imr1", "lpassa $lr8v $t/0110"],
      init=small_lr([flags_lw(0), flags_lw(0b0011), flags_lw(0), flags_lw(0b1000)])),
    # ---- zero flush
    T("flush_pat", ["lpassa/0101 $lr0v $ls40v"]),
    T("flush_imr_half", ["spassa $lr0v $omr3", "lpassa/$imr3 $ls0v $lm40v"]),
    T("flush_ll", ["lpassa/ll1010 $llr0v $llr40v"]),
    T("flush_t", ["spassa $lr0v $omr2", "spassa/$imr2 $ls0v $t", "lpassa $t $llr40v"]),
    T("flush_and_mask", ["spassa $lr0v $omr3", "lpassa/$imr3 $lm0v $ls40v/$imr3"]),
    T("flush_word", ["ipassa/0110 $m1v $r41v $n41v"]),
    # ---- E_RANGE (LM reduced to 2**9 long words = words 0..1023)
    T("range_read", ["lpassa $lr0v $lm0v", "lpassa $lm1100 $lr40"],
      trap=(1, M_LM0, 0, 0, 1100)),
    T("range_write_c2", ["lpassa $lr0v $ln[0,2,1030,6]"],
      trap=(0, M_LM1, 2, 1, 1030)),
    T("range_bar", ["lpassa $lr0 $lmb", "lpassa $lm8v $lr40v"],
      init=small_lr([0x3fc]), trap=(1, M_LM0, 0, 0, 0x3fc + 8)),
    T("range_tind", ["lpassa $lr0v $t", "lpassa $lmt0v $lr40v"],
      init=small_lr([0, 0, 0x500, 0]), trap=(1, M_LM0, 2, 0, 0x500 + 4)),
    T("range_masked_off", ["lpassa $lr0v $lm[2000,1500,0,6]/0011", "lpassa $lm0v $lr40v"]),
    T("range_c3_read", ["lpassa $ln[0,2,4,2046] $ls40v"],
      trap=(0, M_LM1, 3, 0, 2046)),
]


# ---------------------------------------------------------------- random initial data
def rnd64(rng):
    """Random long word whose 16-bit halves are zero one time in three (mask flags)."""
    v = 0
    for _ in range(4):
        v = (v << 16) | (0 if rng.random() < 1 / 3 else rng.getrandbits(16))
    return v


def pos(p):
    return f"n0c0b0m0p{p}"


def make_vsm(t):
    pes = range(4) if t["allpe"] else [0]
    lines = []
    for p in pes:
        rng = random.Random(f"{t['name']}/{p}")
        for k, w, n in REGIONS:
            data = "".join(f"{rnd64(rng):016x}" for _ in range(n))
            lines.append(f"d set $l{k}{w}{pos(p)} {n} {data}")
        data = "".join(f"{rnd64(rng):016x}" for _ in range(8))
        lines.append(f"d set $llt{pos(p)} 4 {data}")
        for opnd, n, data in t["init"]:
            lines.append(f"d set ${opnd}{pos(p)} {n} {data}")
    body = t["body"]
    trap_at = t["trap"][0] if t["trap"] else None
    for i, ins in enumerate(body):
        if i == trap_at:
            lines += ["nop", "nop"] + dget_lines(pes)
        lines.append(ins)
        if not ins.startswith("mask"):
            lines += ["nop", "nop"]
    if trap_at is None:
        lines += dget_lines(pes)
    return "\n".join(lines) + "\n"


def dget_lines(pes):
    out = []
    for p in pes:
        for k, w, n in REGIONS:
            out.append(f"d get $l{k}{w}{pos(p)} {n}")
        out.append(f"d get $llt{pos(p)} 4")
    return out


# ---------------------------------------------------------------- WSL batch
def to_wsl(p: Path) -> str:
    s = str(p.resolve()).replace("\\", "/")
    return f"/mnt/{s[0].lower()}{s[2:]}" if s[1] == ":" else s


def run_emulator(names, jobs):
    # run an LF copy: with core.autocrlf=true the checked-out script has CRLF line ends
    lf = BUILD / "emu_batch.sh"
    lf.write_bytes((HERE / "emu_batch.sh").read_bytes().replace(b"\r", b""))
    script = to_wsl(lf)
    if os.name == "nt":
        cmd = ["wsl", "-d", os.environ.get("MNISA_WSL_DISTRO", "Ubuntu"), "-e", "bash", script,
               to_wsl(EMU_DIR), str(jobs)]
    else:
        cmd = ["bash", script, str(EMU_DIR), str(jobs)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"emu_batch.sh failed: {r.stderr[-800:]}")


# ---------------------------------------------------------------- records
RE_SET = re.compile(r"^d set \$(l{1,2})([rsmnt])(\d*)n0c0b0m0p(\d) (\d+) ([0-9A-Fa-f]+)\s*$")
RE_GET = re.compile(r"^d get \$(l{1,2})([rsmnt])(\d*)n0c0b0m0p(\d) (\d+)\s*$")
RE_DMP = re.compile(r"^DEBUG-(\w+)\(n0c0b0m0p(\d),(\d+)\):(.*)$")


def rec(op, space=0, addr=0, mask=0, data=0, jw=0):
    v = (op << 504) | (space << 496) | (addr << 472) | (mask << 464)
    v |= jw if op == OP_EXEC else (data << 400)
    return f"{v:0128x}"


def parse_dmp(path):
    out = []
    for ln in path.read_text().splitlines():
        m = RE_DMP.match(ln)
        if not m:
            continue
        name, p, a, rest = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
        vals = [int(x, 16) for x in re.findall(r"v:0x([0-9A-Fa-f]+)", rest)]
        out.append((DMP_SP[name], p, a, vals))
    return out


def j_index_of(body, at):
    """Number of j words before body[at] (d set lines and mask directives make none)."""
    n = 0
    for i, ins in enumerate(body):
        if i == at:
            return n + (2 if at is not None else 0)  # the two nops before the d get block
        if not ins.startswith("mask"):
            n += 3  # the instruction and its two nops
    raise ValueError


def records_for(t, ti, asm_lines, dmp):
    pes = range(4) if t["allpe"] else [0]
    out = []
    jwords = [ln[2:].strip() for ln in asm_lines if ln.startswith("j ")]
    trap_j = j_index_of(t["body"], t["trap"][0]) if t["trap"] else None
    for p in pes:
        out.append(rec(OP_BEGIN, space=p, addr=ti))
        out.append(rec(OP_CLEAR))
        checks = []
        di = 0
        jn = 0
        for ln in asm_lines:
            if ln.startswith("d set"):
                m = RE_SET.match(ln)
                if not m:
                    sys.exit(f"{t['name']}: cannot parse {ln!r}")
                ll, k, a, pp, n, data = m.groups()
                if int(pp) != p:
                    continue
                n = int(n)
                words = [int(data[16 * i:16 * i + 16], 16) for i in range(len(data) // 16)]
                if k == "t":
                    base = 0
                    addrs = list(range(2 * n)) if ll == "ll" else [2 * c for c in range(n)]
                else:
                    base = int(a or 0) // 2
                    addrs = [base + i for i in range(len(words))]
                for ad, w in zip(addrs, words):
                    out.append(rec(OP_WR, space=SP[k], addr=ad, mask=0xFF, data=w))
            elif ln.startswith("d get"):
                m = RE_GET.match(ln)
                if not m:
                    sys.exit(f"{t['name']}: cannot parse {ln!r}")
                n = int(m.group(5))
                for _ in range(n):
                    sp, pp, a, vals = dmp[di]
                    di += 1
                    if pp != p:
                        continue
                    if sp == SP["t"]:
                        for i, v in enumerate(vals):
                            c = rec(OP_CHK, space=sp, addr=2 * a + i, data=v)
                            out.append(c)
                            checks.append(c)
                    else:
                        c = rec(OP_CHK, space=sp, addr=a // 2, data=vals[0])
                        out.append(c)
                        checks.append(c)
            elif ln.startswith("j "):
                if trap_j is not None and jn == trap_j:
                    _, mem, cyc, wr, addr = t["trap"]
                    out.append(rec(OP_XTRAP, mask=(wr << 4) | (mem << 2) | cyc, data=addr))
                out.append(rec(OP_EXEC, jw=int(ln[2:].strip(), 2)))
                jn += 1
        if di != len(dmp):
            sys.exit(f"{t['name']}: {len(dmp) - di} dump lines not consumed")
        if t["trap"]:
            out += checks  # the trapping word must not have changed anything
    assert len(jwords) == jn
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma separated test names")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--no-emu", action="store_true", help="reuse build/emu outputs")
    a = ap.parse_args()
    tests = TESTS
    if a.only:
        keep = set(a.only.split(","))
        tests = [t for t in TESTS if t["name"] in keep]
    names = [t["name"] for t in TESTS]
    assert len(names) == len(set(names)), "duplicate test names"
    EMU_DIR.mkdir(parents=True, exist_ok=True)
    if not a.no_emu:
        for f in EMU_DIR.glob("*"):
            f.unlink()
        for t in tests:
            (EMU_DIR / f"{t['name']}.vsm").write_text(make_vsm(t), encoding="utf-8", newline="\n")
        run_emulator([t["name"] for t in tests], a.jobs)
    recs, bad = [], []
    listing = []
    for t in tests:
        ti = TESTS.index(t)
        b = EMU_DIR / t["name"]
        arc = (EMU_DIR / f"{t['name']}.arc").read_text().strip()
        if arc != "0":
            bad.append(f"{t['name']}: assemble3 rc={arc}: {(EMU_DIR / (t['name'] + '.aerr')).read_text()[:200]!r}")
            continue
        erc = (EMU_DIR / f"{t['name']}.erc").read_text().strip()
        if erc != "0":
            bad.append(f"{t['name']}: emulator rc={erc}: {(EMU_DIR / (t['name'] + '.eout')).read_text()[:200]!r}")
            continue
        asm = b.with_suffix(".asm").read_text().splitlines()
        dmp = parse_dmp(b.with_suffix(".dmp"))
        r = records_for(t, ti, asm, dmp)
        recs += r
        nj = sum(1 for ln in asm if ln.startswith("j "))
        listing.append(f"{ti:3d} {t['name']:22s} pes={4 if t['allpe'] else 1} j={nj:3d} "
                       f"checks={sum(1 for x in r if x[:2] == '04')} trap={'yes' if t['trap'] else 'no'}")
    recs.append(rec(OP_END))
    BUILD.mkdir(exist_ok=True)
    (BUILD / "tests.hex").write_text("\n".join(recs) + "\n")
    (BUILD / "tests.txt").write_text("\n".join(f"{i:3d} {n}" for i, n in enumerate(names)) + "\n")
    print("\n".join(listing))
    print(f"programs {len(tests) - len(bad)} / {len(tests)}, records {len(recs)}")
    if bad:
        print("\n".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

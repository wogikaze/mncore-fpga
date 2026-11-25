#!/usr/bin/env python3
"""WP34 directed tests of the virtual PEs on the 64 PEs of one L1B (16 MABs), expectations from the
official emulator.

    python mncore/sim/tb/vpe/gen_vpe.py [--only NAME,...] [--jobs 12] [--keep-going]

Every test is a small program on the 64 PEs n0c0b0m0..15p0..3: deterministic initial data that differs per
PE (d set of GRF0 / GRF1 long words 0..31, LM0 / LM1 0..63 and T of every PE; T word 1 small, for
T-indirect addresses), the body, and d get of the state of the 64 PEs (GRF / LM long words 0..127, or the
whole LM for the LM tests, T, $omr1..15) and of the L1BM. It is assembled with the official assemble3 (flat,
no packer) and run on the official emulator (WSL, mncore/sim/tb/core/emu_batch.sh; only called, contract
06 section 9) on all 4096 PEs; the 64 PEs of L1B n0c0b0 and its L1BM are compared (contract 06 section 3
(b): the programs keep their data inside the L1B, so the 4096-PE result cut to it is the answer).
The result is a tb_core script (`mnhost.py run` steps; d set on the 64 locations) whose checks are FNV-1a
hashes of each region (tb_core H, so that the script stays small):
    fixed/m64.scr    the tests of the unit vpe/m64 (N_MAB = 16, LM_AW = 11),
    fixed/m64r.scr   the tests of the unit vpe/m64r (N_MAB = 16, LM_AW = 8: the E_RANGE of one PE of a
                     MAB after MAB 0 must stop the word before any of the 64 PEs writes),
    build/fixed/<name>.scr   one per test.

Tests: the WP20 / WP30 bodies (integer / FP ALU, MAU with the u / d PE pairs, fixed operands $peid /
$mabid / $subpeid of 64 PEs, forwarding registers, masks, T / $mb / $nb / T-indirect / j<madpe>, msl / msr,
bfn / bfe) on the 64 PEs with different data, so that the context of every PE (T, $omr, $mb / $nb, $aluf,
$mauf) goes through the context engine; the L1BM forms across the 16 MABs (l1bmm@m, l1bmm4@i, l1bmd with a
MAB shift, l1bmr / l1bmr4 reductions of 16 / 4 MABs, $lbi turnaround, $lbf); LM addresses up to the chip's
2048 long words ($mb / $nb = $peid, T-indirect); stop records: E_RANGE on PEs of later MABs only (m64r),
E_UNSUPPORTED (?mwrite) after the 64 PEs' range checks; MV transfers (DRAM -> PDM -> DRAM, DRAM n0 checked)
in flight while the 64 PEs use their LM / GRF (the SDRAM bus shared by the MV unit and the virtual PEs).
"""
from __future__ import annotations

import argparse
import random
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BUILD = HERE / "build" / "fixed"
FIXED = HERE / "fixed"
CORE = ROOT / "mncore" / "sim" / "tb" / "core"
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
sys.path.insert(0, str(CORE))
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "mab"))
import run as rg  # noqa: E402
import norm_gpfn3  # noqa: E402
import goldenlib as gl  # noqa: E402
import gen_fixed as g20  # noqa: E402  (the WP20 bodies and data)
import gen_mab as g30  # noqa: E402  (the WP30 bodies)

rg.configure_vpe(16, 11)
LOCS = rg.PE_LOCS              # n0c0b0m0p0 .. n0c0b0m15p3, loc code = index
N_LW = 128                     # long words of GRF0 / GRF1 / LM0 / LM1 checked (words 0..255)
F = {name: i for i, name in enumerate(rg.FIELDS)}
UNSUP, RANGE = 2, 1


def T(name, body, status=None, init=None, note="", lm_full=False, l1bm=False, cfg="m64", dram=0):
    """status: (reason, info) of the last RUN, info may be a callable(entries) -> int. lm_full: check the
    whole LM (2048 long words). l1bm: random L1BM data first and the L1BM checked. cfg: the unit. dram:
    check DRAM n0 long words 0 .. dram-1."""
    return dict(name=name, body=body, status=status, init=init, note=note, lm_full=lm_full, l1bm=l1bm, cfg=cfg,
                dram=dram)


def last_word(entries):
    return len(entries) - 1


# ---------------------------------------------------------------------------------- bodies
# the L1BM forms across the 16 MABs (the L1BM holds random data first)
L1_READ_BODY = [
    "l1bmp $lb3 $lr0v", "l1bmp $llb5 $llr8v", "l1bmm $lb16 $ls0v", "l1bmm $llb32 $llm8v",
    "l1bmm4 $lb64 $lm0v", "l1bmm4 $llb128 $llr16v", "l1bmd $lb256 $ln0v", "l1bmd+1 $lb320 $ls8v",
    "l1bmd-3 $lb384 $ln8v", "l1bmd $lb448 $t", "nop/2",
]
L1_WRITE_BODY = [
    "l1bmm@0 $lr0v $lb16", "l1bmm@5 $lr4v $lb32", "l1bmm@15 $llr8v $llb64", "l1bmm@9 $t $lb100",
    "l1bmm4@0 $lr0v $lb128", "l1bmm4@3 $ls2v $lb160", "l1bmm4@1 $llr0v $llb192", "l1bmd $lr0v $lb256",
    "l1bmd+1 $ls0v $lb320", "l1bmd-5 $ln4v $lb384", "l1bmd $t $lb448", "nop/2",
    "l1bmm $lb32 $lr24v", "l1bmm4 $llb192 $llr32v", "l1bmd $lb320 $ls24v", "nop/2",
]
L1_TURN_BODY = [
    "l1bmm@7 $lr0v $lb0", "l1bmm $lbi $lm0v;l1bmm@11 $lr8v $lb16", "l1bmm $lbi $lm8v",
    "l1bmd+1 $lr0v $lb64", "l1bmd-1 $lr0v $lb256;l1bmd+1 $lbi $ls0v", "l1bmd-1 $lbi $ls8v",
    "l1bmm4@2 $llr0v $llb320", "l1bmm4 $llbi $llm16v", "nop",
    "l1bmm $lb16 $lr16v", "lpassa $lbf $ls16v", "l1bmp $lb40 $nowrite", "lpassa $lbf $ls24v",
    "l1bmm@12 $lr4v $lbi", "lpassa $lbf $ls32v", "nop/2",
]
L1_RED_INT_BODY = [
    "l1bmrliadd $lr0v $lb64", "l1bmriiadd $ls0v $lb128", "l1bmrsiadd $lm0v $lb192",
    "l1bmrlbor $llr8v $llb256", "l1bmrlband $ln0v $lb320", "l1bmrior $t $lb384",
    "l1bmr4liadd $lr16v $lb448", "l1bmr4iband $ls16v $lb512", "l1bmr4sor $lm16v $lb576", "nop/2",
    "l1bmrliadd $lr24v $lbi", "l1bmm $lbi $lr32v", "nop/2",
]
L1_RED_F_BODY = [
    "l1bmrffadd $lr0v $lb64", "l1bmrfmax $ls0v $lb128", "l1bmrfmin $lm0v $lb192",
    "l1bmrffadd $llr8v $llb256", "l1bmr4ffadd $llm8v $llb320", "l1bmr4fmax $ln0v $lb384", "nop/2",
]
L1_RED_H_BODY = [
    "l1bmrhfadd $lr0v $lb64", "l1bmrhmax $ls0v $lb128", "l1bmrhmin $lm0v $lb192",
    "l1bmr4hfadd $ln0v $lb256", "l1bmrffadd $lr8ve $llb320", "l1bmrffaddr $llr16v $lb384", "nop/2",
]
# LM up to the chip's 2048 long words (4096 words): direct, through $mb / $nb = $peid and T-indirect
LM_HI_BODY = [
    "lpassa $lr0v $lm4000v", "lpassa $ls0v $ln3500v", "lpassa $llr8v $llm2048v", "nop/2",
    "lpassa $lm4000v $lr64v", "fvpassa $ln3500v $ls64v", "lpassa $llm2048v $llr72v", "nop/2",
    "ipassa $peid $lr120", "nop/2",
    "lpassa $lr120 $lmb", "nop/2",                 # long access: word 1 -> $mb = peid
    "lpassa $lr16v $lm3900v", "nop/2", "lpassa $lm3900v $ls80v", "nop/2",
    "spassa $peid $s100", "nop/2", "ipassa $s100 $nb", "nop/2",   # word access: $nb = peid
    "lpassa $ls16v $ln4000v", "nop/2", "lpassa $ln3990v $lr88v", "nop/2",
    "fvpassa $lmt0v $lr96v", "nop/2",              # T-indirect read
    "dvpassa $ls24v $lmt64v", "nop/2",             # T-indirect write
    "lpassa $lm4000vj2 $lr104v", "nop/2", "lpassa $lr24v $ln3000vj1", "nop/2",
]


def lm_init(name):
    """default data, with T word 1 large (T-indirect to high LM addresses: up to 3500 + 64)."""
    out = default_init(name)
    out = [ln for ln in out if not ln.startswith("d set $llt")]
    for p, loc in enumerate(LOCS):
        rng = random.Random(f"wp34-lmt-{name}-{p}")
        tv = []
        for c in range(4):
            tv.append((rng.getrandbits(32) << 32) | (3000 + 128 * c + 2 * p))
            tv.append(g20.lw_data(rng))
        out.append(f"d set $llt{loc} 4 " + "".join(f"{v:016x}" for v in tv))
    return out


def t_init(t_word1):
    """default data with T word 1 of PE i, cycle c = t_word1(i, c) (T-indirect addresses per PE)."""
    def init(name):
        out = default_init(name)
        out = [ln for ln in out if not ln.startswith("d set $llt")]
        for i, loc in enumerate(LOCS):
            rng = random.Random(f"wp34-t-{name}-{i}")
            tv = []
            for c in range(4):
                tv.append((rng.getrandbits(32) << 32) | t_word1(i, c))
                tv.append(g20.lw_data(rng))
            out.append(f"d set $llt{loc} 4 " + "".join(f"{v:016x}" for v in tv))
        return out
    return init


ERR_PRE = g20.ERR_PRE

# MV transfers (DRAM -> PDM -> DRAM) in flight while words of the 64 PEs read and write their LM / GRF: the
# MV unit and the virtual PEs share the SDRAM bus (mn_vpe_arb). The official emulator ends a transfer when it
# is issued, the RTL runs it beside the following words; the PE words do not touch the DRAM / PDM, so the
# results are the same.
MV_N = 4096
MV_PE1 = ["lpassa $lm0v $lr64v", "lpassa $ln0v $ls64v", "iadd $lm8v $ln8v $lr72v", "ixor $lr0v $ls0v $lm128v",
          "lpassa $ln16v $lm136v", "ior $lm16v $lr8v $ls72v"]
MV_PE2 = ["lpassa $lm24v $lr80v", "lpassa $ln24v $ls80v", "iadd $lm32v $ln32v $lr88v", "ixor $lr16v $ls16v $lm144v",
          "lpassa $ln40v $lm152v", "ior $lm40v $lr24v $ls88v"]
MV_BODY = ([f"mvp/n{MV_N} $d0@0 $p0@0"] + [x for w in MV_PE1 for x in (w, "nop/2")] +
           [f"mvp/n{MV_N} $p0@0 $d8192@0"] + [x for w in MV_PE2 for x in (w, "nop/2")])


def mv_init(name):
    """default data and DRAM n0 long words 0 .. MV_N-1 (r lines; the script fills them with F)."""
    out = default_init(name)
    vals = fill_block(name, "DRAM", 0, MV_N, "", "dram")
    return out + [f"r 0 {a:09x} 001 {v:016X}" for a, v in enumerate(vals)]


TESTS = [
    # the SDRAM bus shared by the MV unit and the virtual PEs (first: a mutation of the arbiter stops here)
    T("mv_overlap", MV_BODY, init=mv_init, dram=3 * MV_N,
      note="MV DRAM -> PDM -> DRAM in flight while the 64 PEs read / write their LM / GRF"),
    # the WP30 / WP20 bodies on 64 PEs (unit vpe/m64)
    T("msl_msr", g30.MSL_BODY),
    T("bfn_bfe", g30.BFN_BODY),
    T("bar_per_pe", g30.BAR_BODY),
    T("alu_int_i", g20.alu_int("i")),
    T("alu_fp_h", g20.alu_fp("h")),
    T("mau_d", g20.MAU_BODIES["d"]),
    T("fixed_operands", [x for i in g20.FIXED_BODY for x in (i, "nop/2")]),
    T("forwarding", g20.FWD_BODY),
    T("dual_unit_masks", g20.DUAL_BODY),
    T("t_bar_tind", g20.TB_BODY),
    # the L1BM across 16 MABs
    T("l1_read", L1_READ_BODY, l1bm=True),
    T("l1_write", L1_WRITE_BODY, l1bm=True),
    T("l1_turn_lbf", L1_TURN_BODY, l1bm=True),
    T("l1_red_int", L1_RED_INT_BODY, l1bm=True),
    T("l1_red_f", L1_RED_F_BODY, l1bm=True, init=lambda n: default_init(n, "f32")),
    T("l1_red_h", L1_RED_H_BODY, l1bm=True, init=lambda n: default_init(n, "f16")),
    # the chip's LM
    T("lm_hi", LM_HI_BODY, lm_full=True, init=lm_init),
    T("e_unsup_mwrite", ERR_PRE + ["dmwrite $lr0v $lx0"], status=(UNSUP, F["pe_mauc_mw"]),
      note="?mwrite (no matrix unit with 16 MABs) after the range checks: nothing written"),
    # unit vpe/m64r (LM_AW = 8, LM 256 long words): E_RANGE on later MABs only; nothing may be written
    T("r_alu_int_i", g20.alu_int("i"), cfg="m64r"),
    T("r_bar_per_pe", g30.BAR_BODY, cfg="m64r"),
    T("e_range_nb_peid", ERR_PRE + ["spassa $peid $s100", "nop/2", "ipassa $s100 $nb", "nop/2",
                                    "lpassa $lr0 $ln470"], status=(RANGE, last_word), cfg="m64r",
      note="$nb = $peid: PEs 42..63 (MAB 10 p2 and later) reach LM1 long word 256; MABs 0..10 must not write"),
    T("e_range_tind_m9", ERR_PRE + ["lpassa $lmt0v $lr96v"], status=(RANGE, last_word), cfg="m64r",
      init=t_init(lambda i, c: 0x400 if (i == 37 and c == 1) else 8 * c),
      note="T-indirect: only PE n0c0b0m9p1 is out of range (cycle 1)"),
    T("e_range_tind_write_m15", ERR_PRE + ["lpassa $lr0v $lmt0v"], status=(RANGE, last_word), cfg="m64r",
      init=t_init(lambda i, c: 0x3fe if (i == 63 and c == 3) else 8 * c),
      note="T-indirect write: only the last PE (m15 p3) is out of range"),
    T("e_range_all", ERR_PRE + ["lpassa $lm600v $lr96v"], status=(RANGE, last_word), cfg="m64r"),
    T("e_range_masked", ERR_PRE + ["spassa $peid $s100", "nop/2", "ipassa $s100 $nb", "nop/2",
                                   "lpassa $lr0v $ln500v/0000"], status=(RANGE, last_word), cfg="m64r",
      note="a write stopped by the mask is range checked too (PEs 6.. reach long word 256)"),
]


# ---------------------------------------------------------------------------------- data
# The blocks of initial data are splitmix64 sequences; the script fills them with tb_core's F command (the
# same generator) instead of one W line per long word. FILL[test] = [(space, loc code, addr, n, seed, kind)].
M64 = (1 << 64) - 1
KIND = {"": 0, "f32": 1, "f16": 2}
FILL: dict = {}


def f32k(w: int) -> int:     # a single with the exponent 104..135 (tb_core f32k)
    return (w & 0x80000000) | ((((w >> 23) & 0x1f) + 104) << 23) | (w & 0x7fffff)


def f16k(q: int) -> int:     # a half with the exponent 22..37 (tb_core f16k)
    return (q & 0x8000) | ((((q >> 9) & 0xf) + 22) << 9) | (q & 0x1ff)


def sm_vals(seed: int, n: int, kind: int) -> list:
    """n long words of splitmix64(seed), shaped by kind like tb_core's F."""
    s, out = seed, []
    for _ in range(n):
        s = (s + 0x9e3779b97f4a7c15) & M64
        z = s
        z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & M64
        z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & M64
        z ^= z >> 31
        if kind == 1:
            z = (f32k(z >> 32) << 32) | f32k(z & 0xffffffff)
        elif kind == 2:
            z = (f16k(z >> 48) << 48) | (f16k((z >> 32) & 0xffff) << 32) | (f16k((z >> 16) & 0xffff) << 16) | \
                f16k(z & 0xffff)
        out.append(z)
    return out


def fill_block(name: str, space: str, code: int, n: int, kind: str, tag: str) -> list:
    seed = zlib.crc32(f"wp34-{name}-{tag}".encode())
    FILL.setdefault(name, []).append((rg.SP_ID[space], code, 0, n, seed, KIND[kind]))
    return sm_vals(seed, n, KIND[kind])


def default_init(name: str, kind: str = ""):
    out = []
    FILL[name] = [f for f in FILL.get(name, []) if f[0] == rg.SP_ID["L1BM"]]
    for p, loc in enumerate(LOCS):
        for mem, space, n in (("lr", "GRF0", 32), ("ls", "GRF1", 32), ("lm", "LM0", 64), ("ln", "LM1", 64)):
            vals = "".join(f"{v:016x}" for v in fill_block(name, space, p, n, kind, f"{p}-{mem}"))
            out.append(f"d set ${mem}0{loc} {n} {vals}")
        rng = random.Random(f"wp34-{name}-{p}")
        tv = []
        for c in range(4):
            tv.append((rng.getrandbits(32) << 32) | (8 * c + 2 * rng.randint(0, 3)))
            tv.append(rng.getrandbits(64))
        out.append(f"d set $llt{loc} 4 " + "".join(f"{v:016x}" for v in tv))
    return out


def l1bm_init(name: str, kind: str = ""):
    FILL[name] = [f for f in FILL.get(name, []) if f[0] != rg.SP_ID["L1BM"]]
    vals = "".join(f"{v:016x}" for v in fill_block(name, "L1BM", 0, 1024, kind, "l1bm"))
    return [f"d set $lb0n0c0b0 1024 {vals}"]


def get_lines(t):
    n = 2048 if t["lm_full"] else N_LW
    out = [g for loc in LOCS for g in (f"d get $lr0{loc} {N_LW}", f"d get $ls0{loc} {N_LW}",
                                       f"d get $lm0{loc} {n}", f"d get $ln0{loc} {n}",
                                       f"d get $llt{loc} 4", f"d get $omr1{loc} 15")]
    if t["l1bm"]:
        out.append("d get $lb0n0c0b0 1024")
    if t["dram"]:
        out.append(f"d get $d0n0 {t['dram']}")
    return out


def program(t) -> str:
    body = list(t["body"])
    FILL[t["name"]] = []
    init = (t["init"] or default_init)(t["name"])
    if t["l1bm"]:
        kind = "f32" if "red_f" in t["name"] else "f16" if "red_h" in t["name"] else ""
        init = l1bm_init(t["name"], kind) + init
    gets = get_lines(t)
    if t["status"] is not None:
        lines = init + body[:-1] + ["nop/3"] + gets + body[-1:]
    else:
        lines = init + body + ["nop/3"] + gets
    return "\n".join(lines) + "\n"


def fnv(vals) -> int:
    h = 0xcbf29ce484222325
    for v in vals:
        for b in range(8):
            h ^= (v >> (8 * b)) & 0xff
            h = (h * 0x100000001b3) & 0xffffffffffffffff
    return h


# ---------------------------------------------------------------------------------- script
def make_fixed(t, asm_text: str, dmp_path: Path):
    entries, events, _ = rg.parse_official_asm(asm_text)
    if len(entries) > rg.IMEM_DEPTH:
        raise ValueError("test longer than the instruction memory")
    lines = [f"# test {t['name']}" + (f": {t['note']}" if t["note"] else ""), "C"]
    for k, (tag, word) in enumerate(entries):
        lines.append(f"I {k:x} {rg.mnhost.imem_entry(tag, word):0112x}")
    reason, info = (0, 0) if t["status"] is None else t["status"]
    if callable(info):
        info = info(entries)
    # the splitmix64 blocks of the initial data (all before the first word): F lines
    fills = FILL.get(t["name"], [])
    covered = {(sp, code) for sp, code, _, _, _, _ in fills}
    for sp, code, a0, n, seed, kind in fills:
        lines.append(f"F {sp:x} {code:x} {a0:x} {n:x} {seed:x} {kind:x}")
    pc = 0
    for pos, d in events:
        if pos > pc:
            lines.append(f"X {pc:x} {pos - pc:x}")
            lines.append("K 0 0" if pos < len(entries) else f"K {reason:x} {info:x}")
            pc = pos
        if isinstance(d, rg.RLine):
            # DRAM data (group 0): an F block, or one W line per long word
            if (rg.SP_ID["DRAM"], 0) in covered:
                if pos != 0:
                    raise ValueError("an F block after the first word")
                continue
            for i, v in enumerate(d.payload):
                lines.append(f"W {rg.SP_ID['DRAM']:x} 0 {d.addr + i:x} ff {v:x}")
            continue
        if d.op == "set":
            for code, _ in d.pe_locs():
                if (rg.SP_ID[d.space], code) in covered:
                    if pos != 0:
                        raise ValueError("an F block after the first word")
                    continue
                for sp, lw, m, v in rg.set_writes(d):
                    lines.append(f"W {sp:x} {code:x} {lw:x} {m:x} {v:x}")
    if len(entries) > pc:
        lines.append(f"X {pc:x} {len(entries) - pc:x}")
        lines.append(f"K {reason:x} {info:x}")
    # expected final state (the emulator's d get) of the 64 PEs and the L1BM, as region hashes
    with open(dmp_path, encoding="utf-8", errors="replace") as fh:
        recs, _ = norm_gpfn3.records_from_lines(fh)
    data = rg.ndmp.canonical(recs)
    n_lm = 2048 if t["lm_full"] else N_LW
    n_h = 0
    for code, loc in enumerate(LOCS):
        for space, n in (("GRF0", N_LW), ("GRF1", N_LW), ("LM0", n_lm), ("LM1", n_lm), ("T", 8)):
            vals = [data[(space, loc, a)] for a in range(n)]
            lines.append(f"H {rg.SP_ID[space]:x} {code:x} 0 {n:x} {fnv(vals):016x}")
            n_h += 1
        omr = []
        for e in range(1, 16):
            omr.append(sum(data[("OMR", loc, 4 * e + c)] << (4 * c) for c in range(4)))
        lines.append(f"H {rg.SP_ID['OMR']:x} {code:x} 1 f {fnv(omr):016x}")
        n_h += 1
    if t["l1bm"]:
        vals = [data[("L1BM", "n0c0b0", a)] for a in range(1024)]
        lines.append(f"H {rg.SP_ID['L1BM']:x} 0 0 400 {fnv(vals):016x}")
        n_h += 1
    if t["dram"]:
        vals = [data[("DRAM", "n0", a)] for a in range(t["dram"])]
        lines.append(f"H {rg.SP_ID['DRAM']:x} 0 0 {t['dram']:x} {fnv(vals):016x}")
        n_h += 1
    return "\n".join(lines) + "\n", n_h, len(entries)


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
    cmd = gl.wsl_cmd(HERE / "emu_batch.sh", [gl.wsl_path_arg(BUILD), str(a.jobs), "1800"])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
    ok = True
    scripts = {}
    for t in tests:
        n = t["name"]
        arc = (BUILD / f"{n}.arc").read_text().strip() if (BUILD / f"{n}.arc").exists() else "?"
        if arc != "0":
            print(f"{n}: assemble3 failed ({arc}): {(BUILD / f'{n}.aerr').read_text(errors='replace')[:400]}")
            ok = False
            continue
        erc = (BUILD / f"{n}.erc").read_text().strip() if (BUILD / f"{n}.erc").exists() else "?"
        if erc != "0":
            print(f"{n}: emulator failed ({erc}): {(BUILD / f'{n}.eout').read_text(errors='replace')[-400:]}")
            ok = False
            continue
        try:
            scr, n_h, n_w = make_fixed(t, (BUILD / f"{n}.asm").read_text(encoding="utf-8"), BUILD / f"{n}.dmp")
        except (ValueError, KeyError) as e:
            print(f"{n}: {e!r}")
            ok = False
            continue
        print(f"{n} ({t['cfg']}): {n_w} words, {n_h} hash checks" + (f", stop {t['status'][0]}" if t["status"] else ""))
        scripts.setdefault(t["cfg"], []).append((n, scr))
        (BUILD / f"{n}.scr").write_text(scr + "E\n", encoding="utf-8", newline="\n")
    if not ok and not a.keep_going:
        print("FAIL: nothing written")
        return 1
    if not only:
        FIXED.mkdir(exist_ok=True)
        for cfg, lst in scripts.items():
            (FIXED / f"{cfg}.scr").write_text("".join(s for _, s in lst) + "E\n", encoding="utf-8", newline="\n")
            print(f"wrote {len(lst)} tests to {(FIXED / (cfg + '.scr')).relative_to(ROOT)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

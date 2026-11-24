#!/usr/bin/env python3
"""WP30 directed tests for the MAB unit (4 PEs, time-multiplexed), expectations from the official
emulator.

    python mncore/sim/tb/mab/gen_mab.py [--only NAME,...] [--jobs 12] [--keep-going]

Every test is a small program on the 4 PEs of MAB n0c0b0m0: deterministic initial data that
differs per PE (d set of GRF0/GRF1 long words 0..31, LM0/LM1 0..63 and T of p0..p3; T word 1
small, for T-indirect addresses), the body, and d get of GRF/LM long words 0..127, T and
$omr1..15 of the 4 PEs. It is assembled with the official assemble3 (flat, no packer) and run on
the official emulator (WSL, mncore/sim/tb/core/emu_batch.sh; only called, contract section 9),
which executes all 4096 PEs; the 4 PEs of MAB 0 are compared (contract 06 section 3 (b)).
The result is a tb_core script (`mnhost.py run` steps; d set / d get on the 4 locations):
    fixed/all.scr   all tests (committed, the simrun default of the unit `mab`),
    build/fixed/<name>.scr   one per test (vvp sim.vvp +script=...)

Tests: the WP20 bodies (mncore/sim/tb/core/gen_fixed.py: integer / FP ALU, MAU with u / d PE
pairs, fixed operands, forwarding, masks, T / $mb / $nb / T-indirect / j<madpe>) on 4 PEs with
different data, so that every piece of per-PE state is exercised; msl / msr (every source kind,
2 long words, $aluf both ways, zero flush, masks, noforward, with a MAU instruction in the same
word, T as the destination); bfn / bfe (d f g h, hbfn/6..9, hbfe/6..9, `r`, 2 long words, T and
$aluf as sources, $aluf of the result); $mb / $nb that differ per PE; stop records with 4 PEs:
E_RANGE on one PE only (T-indirect, $mb, msl) where no PE may write, E_RANGE on all PEs,
E_UNSUPPORTED (L1BM, ?mwrite, MV) after the range check of the 4 PEs.
Error tests end with the failing word and read the state before it: the core must stop without
writing anything on any PE. Their expected stop record is the contract's.
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
CORE = ROOT / "mncore" / "sim" / "tb" / "core"
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
sys.path.insert(0, str(CORE))
import run as rg  # noqa: E402
import norm_gpfn3  # noqa: E402
import goldenlib as gl  # noqa: E402
import gen_fixed as g20  # noqa: E402  (the WP20 bodies and data)

rg.configure(4)
LOCS = rg.PE_LOCS              # n0c0b0m0p0..p3
N_LW = 128                     # long words of GRF0/GRF1/LM0/LM1 checked (words 0..255)
F = {name: i for i, name in enumerate(rg.FIELDS)}
UNSUP, RANGE, DECODE = 2, 1, 3


def T(name, body, status=None, init=None, note=""):
    """status: (reason, info) of the last RUN, info may be a callable(entries) -> int.
    init: callable(name) -> d set lines (default: random data per PE)."""
    return dict(name=name, body=body, status=status, init=init, note=note)


def last_word(entries):
    return len(entries) - 1


# ---------------------------------------------------------------------------------- bodies
MSL_BODY = [
    # source kinds: GRF0 / GRF1 / LM0 / LM1, 2 long words, T, fixed operands, $aluf, $mauf
    "msl $lr0v $lr64v $omr1", "nop/2",
    "msr $ls0v $ls64v", "nop/2",
    "msl $llm0v $llr72v", "nop/2",                 # 2 long words: the MSB long word moves, LSB = 0
    "msr $ln8v $lm64v $omr2", "nop/2",
    "msl $t $lr88v", "nop/2",                      # T of the neighbour
    "msr $peid $ls72v", "nop/2",                   # fixed operand of the neighbour
    "msl $subpeid $ls80v", "nop/2",
    "lpassa $lr8v $nowrite", "msl $aluf $lr96v", "nop/2",   # $aluf of the neighbour
    "msr $lr16v $nowrite", "lpassa $aluf $lr104v", "nop/2", # msr result in $aluf
    "fvfma $lr24v $ls24v $lm24v $lr112v ; msl $ln8v $ls112v", "nop/2",   # with a MAU instruction
    "fvpassa $lr32v $nowrite", "msr $mauf $ls88v", "nop/2",
    "msl/1010 $lr40v $ls96v", "nop/2",             # zero flush
    "msr $lr48v $ls104v/$imr1", "nop/2",           # mask from $omr1 (per PE)
    "msl $lm16v $llr120v/$llimr2", "nop/2",        # 2 long word destination under a mask
    "noforward ; msr $lr56v $ls120v", "lpassa $aluf $ls128v", "nop/2",   # aluf of the msl above
    "msl $ls16v $t", "nop/2", "lpassa $t $ln80v", "nop/2",   # T written by msl
    "msr $ln16v $lr136v ; fvpassa $lm24v $ls136v", "nop/2",
]

BFN_BODY = [
    "dbfn $lr0v $lr64v $omr1", "nop/2",
    "fbfn $ls0v $ls64v", "nop/2",
    "gbfn $lm0v $lr72v", "nop/2",
    "hbfn/9 $ln0v $ls72v", "nop/2",
    "hbfn/6 $lr8v $lr80v", "nop/2",
    "hbfn/7 $llr16v $llr88v", "nop/2",            # 2 long words: both blocks
    "hbfn/8 $lls16v $lls96v", "nop/2",
    "hbfe/9 $lm8v $ls80v", "nop/2",
    "hbfe/6 $llm16v $llr104v", "nop/2",
    "hbfe/7 $ln8v $lm72v", "nop/2",
    "hbfe/8 $lln16v $llm80v", "nop/2",
    "hbfn/9 $lr24vr $ls88v", "nop/2",              # `r`: single -> half rounding of the input
    "hbfe/9 $llm32vr $lls112v", "nop/2",
    "dbfn $t $ln88v", "nop/2",
    "lpassa $lr32v $nowrite", "gbfn $aluf $lr120v", "nop/2",
    "fbfn $ls32v $nowrite", "lpassa $aluf $lr128v", "nop/2",
    "fvadd $lr40v $ls40v $lm96v ; hbfn/9 $ln40v $ls128v", "nop/2",
    "hbfn/9 $lr48v $t", "nop/2", "lpassa $t $ln96v", "nop/2",
]

BAR_BODY = [
    # $mb / $nb that differ per PE ($peid, $subpeid), LM through them, T-indirect per PE
    "ipassa $peid $lr120", "nop/2",
    "lpassa $lr120 $lmb", "nop/2",                 # long access: word 1 -> $mb = peid
    "lpassa $lm0v $ls72v", "nop/2",
    "lpassa $lr0v $lm64v", "nop/2",
    "spassa $subpeid $ls120", "nop/2",
    "ipassa $ls120 $nb", "nop/2",                  # word access: word 0 -> $nb = subpeid
    "lpassa $ln8v $ls80v", "nop/2",
    "lpassa $ls0v $ln72v", "nop/2",
    "fvpassa $lmt0v $lr72v", "nop/2",              # T-indirect read (T word 1 differs per PE)
    "dvpassa $ls8v $lmt32v", "nop/2",              # T-indirect write
    "lpassa $lm8vj2 $lr80v", "nop/2",              # madpe j2 with $mb
    "lpassa $lr16v $ln16vj1", "nop/2",
]


def t_init(t_word1):
    """Init with T word 1 of cycle c = t_word1[p][c] (T-indirect addresses per PE)."""
    def init(name):
        out = default_init(name)
        out = [ln for ln in out if not ln.startswith("d set $llt")]
        rng = random.Random(f"wp30-t-{name}")
        for p, loc in enumerate(LOCS):
            tv = []
            for c in range(4):
                tv.append((rng.getrandbits(32) << 32) | t_word1[p][c])
                tv.append(g20.lw_data(rng))
            out.append(f"d set $llt{loc} 4 " + "".join(f"{v:016x}" for v in tv))
        return out
    return init


# T-indirect address 0x400 words (512 long words) is beyond LM_DEPTH 256 on PE 2 only
TIND_PE2 = [[8 * c for c in range(4)] for _ in range(4)]
TIND_PE2[2][1] = 0x400
TIND_PE3 = [[8 * c for c in range(4)] for _ in range(4)]
TIND_PE3[3][3] = 0x3fe

ERR_PRE = g20.ERR_PRE

TESTS = [
    T("msl_msr", MSL_BODY),
    T("bfn_bfe", BFN_BODY),
    T("bar_per_pe", BAR_BODY),
    T("alu_int_i", g20.alu_int("i")),
    T("alu_fp_h", g20.alu_fp("h")),
    T("mau_d", g20.MAU_BODIES["d"], note="dvfma u / d: the product is made on PE 0,1 or 2,3"),
    T("mau_h", g20.MAU_BODIES["h"]),
    T("fixed_operands", [x for i in g20.FIXED_BODY for x in (i, "nop/2")]),
    T("forwarding", g20.FWD_BODY),
    T("dual_unit_masks", g20.DUAL_BODY),
    T("t_bar_tind", g20.TB_BODY),
    # stop records: the last word fails; nothing may be written on any PE
    T("e_range_pe2_tind", ERR_PRE + ["lpassa $lmt0v $lr96v"], status=(RANGE, last_word), init=t_init(TIND_PE2),
      note="T-indirect: only PE 2 is out of range (cycle 1); PE 0 and 1 must not write"),
    T("e_range_pe3_tind_write", ERR_PRE + ["lpassa $lr0v $lmt0v"], status=(RANGE, last_word), init=t_init(TIND_PE3),
      note="T-indirect write: only PE 3 is out of range"),
    T("e_range_pe_mb", ERR_PRE + ["spassa $peid $s100", "nop/2", "ipassa $s100 $nb", "nop/2",
                                  "lpassa $lr0 $ln510"], status=(RANGE, last_word),
      note="$nb = PE number: PE 2 and 3 reach long word 256 (PE 0, 1 do not)"),
    T("e_range_pe1_msl", ERR_PRE + ["msl $lmt0v $lr96v"], status=(RANGE, last_word), init=t_init(
        [[0, 8, 16, 24], [0, 8, 0x200, 24], [0, 8, 16, 24], [0, 8, 16, 24]]),
      note="msl reading through T-indirect, PE 1 out of range: no PE writes"),
    T("e_range_all", ERR_PRE + ["lpassa $lm600v $lr96v"], status=(RANGE, last_word)),
    T("e_range_masked", ERR_PRE + ["lpassa $lr0v $ln510v/0000"], status=(RANGE, last_word),
      note="a write stopped by the mask is range checked too (contract 06 section 3)"),
    T("e_unsup_l1bm", ERR_PRE + ["l1bmp $lb0 $lr96v"], status=(UNSUP, F["l1bm_bmode"])),
    T("e_unsup_mwrite", ERR_PRE + ["dmwrite $lr0v $lx0"], status=(UNSUP, F["pe_mauc_mw"])),
    T("e_unsup_mv", ERR_PRE + ["mvp/n64i01 $lc0@.0 $d0"], status=(UNSUP, 0x80)),
    T("e_range_before_unsup", ERR_PRE + ["l1bmp $lb0 $lmt0v"], status=(RANGE, last_word), init=t_init(TIND_PE2),
      note="an unsupported word that is out of range on PE 2 stops with E_RANGE"),
]


# ---------------------------------------------------------------------------------- data
def default_init(name: str):
    out = []
    for p, loc in enumerate(LOCS):
        rng = random.Random(f"wp30-{name}-p{p}")
        for mem, n in (("lr", 32), ("ls", 32), ("lm", 64), ("ln", 64)):
            vals = "".join(f"{g20.lw_data(rng):016x}" for _ in range(n))
            out.append(f"d set ${mem}0{loc} {n} {vals}")
        tv = []
        for c in range(4):
            tv.append((rng.getrandbits(32) << 32) | (8 * c + 2 * rng.randint(0, 3)))
            tv.append(g20.lw_data(rng))
        out.append(f"d set $llt{loc} 4 " + "".join(f"{v:016x}" for v in tv))
    return out


GET_LINES = [g for loc in LOCS for g in (f"d get $lr0{loc} {N_LW}", f"d get $ls0{loc} {N_LW}",
                                         f"d get $lm0{loc} {N_LW}", f"d get $ln0{loc} {N_LW}",
                                         f"d get $llt{loc} 4", f"d get $omr1{loc} 15")]


def program(t) -> str:
    body = list(t["body"])
    init = (t["init"] or default_init)(t["name"])
    if t["status"] is not None:
        lines = init + body[:-1] + ["nop/3"] + GET_LINES + body[-1:]
    else:
        lines = init + body + ["nop/3"] + GET_LINES
    return "\n".join(lines) + "\n"


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
    pc = 0
    for pos, d in events:
        if pos > pc:
            lines.append(f"X {pc:x} {pos - pc:x}")
            lines.append("K 0 0" if pos < len(entries) else f"K {reason:x} {info:x}")
            pc = pos
        if d.op == "set":
            for code, _ in d.pe_locs():
                for sp, lw, m, v in rg.set_writes(d):
                    lines.append(f"W {sp:x} {code:x} {lw:x} {m:x} {v:x}")
    if len(entries) > pc:
        lines.append(f"X {pc:x} {len(entries) - pc:x}")
        lines.append(f"K {reason:x} {info:x}")
    # expected final state (the emulator's d get) of the 4 PEs
    with open(dmp_path, encoding="utf-8", errors="replace") as fh:
        recs, _ = norm_gpfn3.records_from_lines(fh)
    data = rg.ndmp.canonical(recs)
    omr = {}
    n_q = 0
    for (space, loc, addr), v in sorted(data.items()):
        if loc not in LOCS:
            continue
        code = LOCS.index(loc)
        if space == "OMR":
            e, c = divmod(addr, 4)
            if 1 <= e <= 15:
                omr[(code, e)] = omr.get((code, e), 0) | (v << (4 * c))
            continue
        if space not in rg.SP_ID or (space in rg.DEPTH_LW and addr >= rg.DEPTH_LW[space]):
            continue
        lines.append(f"Q {rg.SP_ID[space]:x} {code:x} {addr:x} {v:016x}")
        n_q += 1
    for (code, e), v in sorted(omr.items()):
        lines.append(f"Q {rg.SP_ID['OMR']:x} {code:x} {e:x} {v:016x}")
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
        (BUILD / f"{t['name']}.vsm").write_text(program(t), encoding="utf-8", newline="\n")
    cmd = gl.wsl_cmd(CORE / "emu_batch.sh", [gl.wsl_path_arg(BUILD), str(a.jobs)])
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
        erc = (BUILD / f"{n}.erc").read_text().strip() if (BUILD / f"{n}.erc").exists() else "?"
        if erc != "0":
            print(f"{n}: emulator failed ({erc}): {(BUILD / f'{n}.eout').read_text(errors='replace')[-400:]}")
            ok = False
            continue
        try:
            scr, n_q, n_w = make_fixed(t, (BUILD / f"{n}.asm").read_text(encoding="utf-8"), BUILD / f"{n}.dmp")
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
        print(f"wrote {len(scripts)} tests to {FIXED.relative_to(ROOT)}/ (all.scr)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

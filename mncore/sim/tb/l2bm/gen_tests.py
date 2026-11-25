#!/usr/bin/env python3
"""WP32: directed tests of the L2BM unit, with the official emulator's results as expectations.

    python mncore/sim/tb/l2bm/gen_tests.py [--only NAME,...] [--jobs 8] [--no-model]

Every test is a small program (l2prog.Prog): initial data from splitmix64 (L2BM of n0c0 long
words 0..2047, the L1BM 0..1023 of L1Bs n0c0b0.. and, for tests with PEs, the 4 PEs of
n0c0b0m0), the body, and d get of the L2BM, the 8 L1BMs and the PEs. It is assembled with the
official assemble3 (flat, no packer) and run on the official emulator (WSL; only called,
contract section 9); some words are edited by hand after the assembly (fields the assembler
never sets, to pin the emulator's semantics). Tests with DAR entries run a second time with the
DAR observer (l2prog.dar_lines: an indirect MV that reads DRAM chunks through DAR) instead of
the d get. The result is a test file for tb_l2bm_env.v (format there): the words, FNV-1a hashes
of the final state taken from the emulator's dump, and the DAR entries:
    fixed/l1.tst   l1bs = 1: data only in L1B 0 (and MAB 0), for N_L1B = 1 (the M2 topology)
    fixed/l8.tst   l1bs = 8: the whole L2B, L2BM instructions only, for N_L1B = 8
Tests that end in E_RANGE (the reduced L2BM / L1BM; the emulator has 32768 / 8192 long words)
or E_UNSUPPORTED take the expected stop from the test definition and the expected state from
the emulator run of the words before the stop. The files are committed: `python
mncore/tools/simrun.py l2bm` needs neither WSL nor the tools.

The reference model (l2pe.py: l2model.py with WP31's L1BM / PE model) runs on the same words
as a check of the semantics (--no-model skips it); it is reported, never used as an
expectation. For l1 tests it runs with N_L1B = 1 (the other L1Bs absent): a test is valid for
the reduced topology only if that matches the emulator (gen_tests refuses it otherwise).
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Dict, List

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import l2model as M  # noqa: E402
import l2pe  # noqa: E402
import l2prog as LP  # noqa: E402
from l2prog import Prog  # noqa: E402

FIXED = HERE / "fixed"
BUILD = HERE / "build"
M64 = (1 << 64) - 1
# field indices (mn_jfields.vh MN_J_<field>_IDX)
F_GWRITE, F_BDMODE, F_DMODE, F_OPCODE, F_DARSEND = 80, 83, 87, 88, 89


def fnv(h: int, v: int) -> int:
    return ((h ^ v) * 0x100000001B3) & M64


def hashes(dump: Dict, l1bs: int, pes: bool) -> List[str]:
    out = []
    for blk in range(LP.L2 // 64):
        h = 0xCBF29CE484222325
        for a in range(64 * blk, 64 * blk + 64):
            h = fnv(h, dump.get(("L2BM", "n0c0", a), 0))
        out.append(f"K C {blk} {h:016x}")
    for b in range(l1bs):
        for blk in range(LP.L1 // 64):
            h = 0xCBF29CE484222325
            for a in range(64 * blk, 64 * blk + 64):
                h = fnv(h, dump.get(("L1BM", f"n0c0b{b}", a), 0))
            out.append(f"K L {b} {blk} {h:016x}")
    if pes:
        for i in range(4):
            loc = LP.pe_loc(i)
            for sp, (space, nlong) in enumerate((("GRF0", 32), ("GRF1", 32), ("LM0", 64), ("LM1", 64), ("T", 8))):
                h = 0xCBF29CE484222325
                for a in range(nlong):
                    v = dump.get((space, loc, a), 0)
                    h = fnv(h, v >> 32)
                    h = fnv(h, v & 0xFFFFFFFF)
                out.append(f"K P {i} {sp} {h:016x}")
    return out


# ------------------------------------------------------------------------------------ tests
def T(name, body, l1bs=1, data="bits", edits=None, stop=None, pes=False, dar=None, l2z=False, l1z=False,
      note=""):
    p = Prog(name, body, l1bs=l1bs, pes=pes, data=data, edits=edits or [], stop=stop, dar=dar,
             l2_zero=l2z, l1_zero=l1z, note=note)
    return p


DATA_OF = {"d": "f64", "f": "f32", "h": "f16", "l": "int", "i": "int", "s": "int"}


def tests_l1() -> List[Prog]:
    """N_L1B = 1: data in L1B 0 (and the PEs of its MAB 0) only."""
    t = [
        # ---------------------------------------------------------------- L2BM -> L1BM
        T("bcast", ["l2bmb $lc64 $lb128", "l2bmb@0 $lc320 $lb512", "l2bmb@[0,4] $lc1024 $lb0",
                    "l2bmb@1 $lc0 $lb256", "l2bmb@4/6 $lc16 $lb768", "l2bmb $lc1984 $lb960"]),
        T("bcast2", ["l2bmb2 $lc128 $lb64", "l2bmb2@0/1 $lc512 $lb256", "l2bmb2@2/1 $lc768 $lb512",
                     "l2bmb2 $lc1792 $lb960"]),
        T("distrib", ["l2bmd $lc128 $lb64", "l2bmd $lc256 $lb8", "l2bmd@[0,2] $lc1792 $lb984",
                      "l2bmd@1 $lc512 $lb0"]),
        # ---------------------------------------------------------------- L1BM -> L2BM
        T("from", ["l2bm@0 $lb64 $lc256", "nop/3", "l2bm@3 $lb128 $lc512", "nop/3", "l2bm@0 $lb960 $lc1984"]),
        T("gather", ["l2bmd $lb64 $lc256", "nop/3", "l2bmd $lb8 $lc512", "nop/3", "l2bmd $lb992 $lc1792"]),
        T("roundtrip", ["l2bm@0 $lb0 $lc0", "nop/3", "l2bmb@0 $lc0 $lb64", "nop/2", "l2bmd $lb64 $lc128", "nop/3",
                        "l2bmb2@0 $lc128 $lb256", "nop/2", "l2bmd@0 $lc0 $lb512", "nop/2", "l2bm@0 $lb512 $lc1024"]),
        T("clear", ["l2bm@0 $lb0 $lc64", "nop/3", "l2bmb $lc128 $lb256", "nop/2", "l2bmd $lb0 $lc512"],
          l2z=True, l1z=True),
        # ---------------------------------------------------------------- l2bmi
        T("imcast", ["l2bmi@0/4 $lb64 $lb128", "nop/3", "l2bmi@1 $lb64 $lb256", "nop/3", "l2bmi@2/1 $lb320 $lb512",
                     "nop/3", "l2bmi@0/3 $lb0 $lb768", "nop/3", "l2bmi@4 $lb16 $lb960"]),
        # ---------------------------------------------------------------- DAR
        T("dar_basic", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdarw"], data="dar", dar=(0, 16)),
        T("dar_later", ["l2bmdars $lc64@.0 $dar16", "nop", "l2bmdarw", "l2bmdarw", "nop/2", "l2bmdarw"],
          data="dar", dar=(12, 32)),
        T("dar_first", ["l2bmdarw", "l2bmdars $lc128@.0 $dar4; l2bmdarw", "l2bmdarw"], data="dar", dar=(0, 16)),
        T("dar_wrap", ["l2bmdars $lc0@.0 $dar1022; l2bmdarw", "l2bmdarw"], data="dar", dar=(1016, 16)),
        T("dar_buf512", ["l2bmdars $lc256@.0 $dar0; l2bmdarw"] + ["l2bmdarw"] * 128, data="dar", dar=(504, 16)),
        T("dar_l2b1", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "nop", "l2bmdars $lc4032@.1 $dar2; l2bmdarw"], data="dar",
          dar=(0, 8)),
        T("dar_restart", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdarw", "l2bmdars $lc512@.0 $dar4; l2bmdarw"],
          data="dar", dar=(0, 16)),
        T("dar_with", ["l2bmdars $lc0@.0 $dar5", "l2bmb $lc64 $lb128; l2bmdarw", "nop/2",
                       "l2bmrliadd $lb64 $lc0; l2bmdarw", "nop/3", "l2bm@0 $lb128 $lc1024; l2bmdarw"],
          data="dar", dar=(0, 16)),
        T("dar_odd", ["l2bmdars $lc0@.0 $dar1; l2bmdarw", "l2bmdars $lc192@.0 $dar1021; l2bmdarw"], data="dar",
          dar=(1016, 16)),
        T("dar_odd2", ["l2bmdars $lc0@.0 $dar1; l2bmdarw", "nop", "l2bmdars $lc192@.0 $dar1021; l2bmdarw"],
          data="dar", dar=(1016, 16)),
        # consecutive l2bmdars words keep the DAR write and DAR buffer read addresses (m words do not
        # separate them, j words do, nop included)
        T("dar_consec", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar",
          dar=(0, 8)),
        T("dar_consec3", ["l2bmdars $lc0@.0 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdars $lc128@.0 $dar200",
                          "l2bmdarw"], data="dar", dar=(0, 8)),
        T("dar_consec_l2b", ["l2bmdars $lc0@.1 $dar0", "l2bmdars $lc64@.0 $dar100", "l2bmdars $lc128@.0 $dar200",
                             "l2bmdarw", "nop", "l2bmdars $lc0@.0 $dar8; l2bmdarw", "l2bmdars $lc64@.1 $dar100; l2bmdarw"],
          data="dar", dar=(0, 16)),
        T("dar_consec_mv", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "mvp/n64 $lc1024@0.0 $d0@0",
                            "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar", dar=(0, 8)),
        T("dar_sep_ll0", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc128@.0 $dar50; l2bmdarw",
                          "l2bmdars $lc64@.0 $dar100; l2bmdarw"], data="dar", dar=(96, 8), edits=[(1, {"ll": 0})]),
        T("dar_sep_other", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmb $lc0 $lb0", "l2bmdars $lc64@.0 $dar100; l2bmdarw",
                            "lpassa $lr0 $lr2", "l2bmdars $lc128@.0 $dar200; l2bmdarw"], data="dar", dar=(96, 8)),
        T("dar_sep_other_b", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmb $lc0 $lb0", "l2bmdars $lc64@.0 $dar100; l2bmdarw",
                              "lpassa $lr0 $lr2", "l2bmdars $lc128@.0 $dar200; l2bmdarw"], data="dar", dar=(196, 8)),
        # ---------------------------------------------------------------- hand-edited words
        T("e_from_set", ["l2bm@0 $lb64 $lc256", "nop/3", "l2bm@0 $lb128 $lc512"], data="int",
          edits=[(0, {"l2bm_immode": 1}), (4, {"l2bm_immode": 7, "l2bm_opcode": 8})]),
        T("e_gather_set", ["l2bmd $lb64 $lc256", "nop/3", "l2bmd $lb64 $lc512"],
          edits=[(0, {"l2bm_immode": 3, "l2bm_l1adr": 4}), (4, {"l2bm_immode": 0})]),
        T("e_gw_bd3", ["l2bmb $lc64 $lb128"], edits=[(0, {"l2bm_bdmode": 3})]),
        T("e_imc_all", ["l2bmi@0/4 $lb64 $lb128"], edits=[(0, {"l2bm_immode": 7})]),
        T("e_unaligned", ["l2bmb $lc64 $lb128", "nop/2", "l2bm@0 $lb64 $lc256", "nop/3", "l2bmb2 $lc128 $lb256",
                          "nop/2", "l2bmd $lc128 $lb512"],
          edits=[(0, {"l1bm_gadr": 17}), (3, {"l1bm_gadr": 9}), (7, {"l2bm_ladr": 9, "l1bm_gadr": 33}),
                 (10, {"l2bm_ladr": 10})]),
        T("e_red2_set", ["l2bmr2liadd $lb64 $lc256", "nop/3", "l2bmr2liadd $lb64 $lc512"], data="int",
          edits=[(0, {"l2bm_immode": 1, "l2bm_l1adr": 0}), (4, {"l2bm_immode": 1, "l2bm_l1adr": 2})]),
        T("e_red_unaligned", ["l2bmr2liadd $lb64 $lc256"], data="int", edits=[(0, {"l2bm_ladr": 19, "l1bm_gadr": 9})]),
        T("e_dars_l2b2", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc64@.0 $dar4; l2bmdarw"], data="dar",
          dar=(0, 8), edits=[(0, {"l2bm_opcode": 2}), (1, {"l2bm_opcode": 3})]),
        T("e_nofwd", ["l2bmb $lc64 $lb128", "nop/3", "l2bmrliadd $lb64 $lc256", "nop/3", "l2bmi@1 $lb0 $lb512"],
          data="int", edits=[(0, {"ll": 3}), (4, {"ll": 3}), (8, {"ll": 3})]),
        T("e_nop", ["l2bmb $lc64 $lb128", "nop/3", "l2bm@0 $lb64 $lc256"], edits=[(0, {"ll": 0}), (4, {"ll": 0})]),
        # ---------------------------------------------------------------- the order within a word
        T("s_bcast_read", ["l2bmb $lc64 $lb16; l1bmm $lb16 $lr0v"], pes=True),
        T("s_pew_from", ["l1bmm@0 $lr0v $lb16; l2bm@0 $lb16 $lc256"], pes=True),
        T("s_red_read", ["l2bmrliadd $lb16 $lc256; l1bmrliadd $lr0v $lb16"], pes=True, data="int"),
        T("s_imc_read", ["l2bmi@1 $lb16 $lb64; l1bmm $lb64 $lr0v"], pes=True),
        T("w_m_b16", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb16"], pes=True),
        T("w_m_b20", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb20"], pes=True),
        T("w_m_b0", ["l2bmb $lc64 $lb32; l1bmm@0 $lr0v $lb24"], pes=True),
        T("w_mw_b16", ["l2bmb $lc64 $lb16; l1bmm@0 $llr0v $llb16"], pes=True),
        T("w_m4_b16", ["l2bmb $lc64 $lb16; l1bmm4@0 $lr0v $lb16"], pes=True),
        T("w_m4_b32", ["l2bmb $lc64 $lb32; l1bmm4@0 $lr0v $lb16"], pes=True),
        T("w_d_b64", ["l2bmb $lc64 $lb64; l1bmd $lr0v $lb0"], pes=True),
        T("w_dist_m", ["l2bmd $lc64 $lb8; l1bmm@0 $lr0v $lb16"], pes=True),
        T("w_dist_mw", ["l2bmd $lc64 $lb16; l1bmm@0 $llr0v $llb24"], pes=True),
        T("w_b2_m4", ["l2bmb2 $lc64 $lb32; l1bmm4@0 $lr0v $lb16"], pes=True),
        T("w_imc_m", ["l2bmi@1 $lb16 $lb64; l1bmm@0 $lr0v $lb68"], pes=True),
        T("w_red_m", ["l2bmb $lc64 $lb16; l1bmrliadd $lr0v $lb20"], pes=True, data="int"),
        T("w_me0", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lbi"], pes=True, edits=[(0, {"l1bm_me": 0, "l1bm_ladr": 20})]),
        T("w_nofwd", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb20"], pes=True, edits=[(0, {"ll": 3})]),
        # ---------------------------------------------------------------- sequences with the PEs
        T("seq_pe", ["l1bmm@0 $lr0v $lb0", "nop/3", "l2bm@0 $lb0 $lc0", "nop/3", "l2bmb $lc0 $lb64", "nop/2",
                     "l1bmm $lb64 $lr16v", "l2bmd $lc64 $lb128", "nop/2", "l1bmd $lb128 $ls0v"], pes=True),
        T("seq_hello", ["l1bmrhfadd $lr[16,16,16,0] $lb36", "nop", "nop", "l2bmrhfadd $lb16 $lc32"], pes=True,
          data="f16"),
        T("seq_reduce", ["l1bmrffadd $lr0v $lb0", "nop/3", "l2bmrffadd $lb0 $lc0", "nop/3", "l2bmb $lc0 $lb64",
                         "nop/2", "l1bmm $lb64 $ls0v"], pes=True, data="f32"),
        # ---------------------------------------------------------------- stops (contract 3)
        T("r_bcast_l2", ["l2bmb $lc64 $lb0", "l2bmb $lc2048 $lb64"], stop=(1, 1, 0)),
        T("r_bcast_l1", ["l2bmb $lc64 $lb0", "l2bmb $lc0 $lb1024"], stop=(1, 1, 0)),
        T("r_bcast2_l2", ["l2bmb $lc64 $lb0", "l2bmb2 $lc1856 $lb64"], stop=(1, 1, 0)),
        T("r_gather_l2", ["l2bmb $lc64 $lb0", "nop/2", "l2bmd $lb0 $lc1856"], stop=(3, 1, 0)),
        T("r_red2_l2", ["l2bmb $lc64 $lb0", "nop/2", "l2bmr2liadd $lb0 $lc1856"], stop=(3, 1, 0), data="int"),
        T("r_from_l1", ["l2bmb $lc64 $lb0", "nop/2", "l2bm@0 $lb992 $lc0"], stop=(3, 1, 0)),
        T("r_imc_dst", ["l2bmb $lc64 $lb0", "nop/3", "l2bmi@1 $lb0 $lb1024"], stop=(4, 1, 0)),
        T("r_dars", ["l2bmb $lc64 $lb0", "l2bmdars $lc1920@.0 $dar0"], stop=(1, 1, 0)),
        T("n_no_access", ["l2bm@3 $lb2000 $lc256", "nop/3", "l2bmb@1 $lc0 $lb2000", "nop/3",
                          "l2bmi@0/4 $lb2000 $lb3008", "nop/3", "l2bmdars $lc4032@.1 $dar0; l2bmdarw"]),
        T("u_lw_bd3", ["l2bmb $lc64 $lb0", "nop/2", "l2bmrliadd $lb64 $lc256"], data="int",
          edits=[(3, {"l2bm_bdmode": 3})], stop=(3, 2, F_BDMODE)),
        T("u_imc_bd1", ["l2bmb $lc64 $lb0", "nop/3", "l2bmi@0/4 $lb64 $lb128"],
          edits=[(4, {"l2bm_bdmode": 1})], stop=(4, 2, F_BDMODE)),
        T("u_red_dm3", ["l2bmb $lc64 $lb0", "nop/2", "l2bmrliadd $lb64 $lc256"], data="int",
          edits=[(3, {"l2bm_dmode": 3})], stop=(3, 2, F_DMODE)),
        T("u_red_op", ["l2bmb $lc64 $lb0", "nop/2", "l2bmrliadd $lb64 $lc256"], data="int",
          edits=[(3, {"l2bm_opcode": 3})], stop=(3, 2, F_OPCODE)),
        T("u_dars_lw", ["l2bmb $lc64 $lb0", "l2bmdars $lc0@.0 $dar0"], edits=[(1, {"l2bm_lwrite": 1})],
          stop=(1, 2, F_DARSEND)),
    ]
    # reductions: every operation and precision, sets with and without L1B 0
    red = {
        "f64": ["l2bmrdfadd $lb64 $lc256", "l2bmrdmax $lb128 $lc512", "l2bmrdmin $lb192 $lc768",
                "l2bmrdmax@0 $lb256 $lc1024", "l2bmrdfadd@[0,4] $lb320 $lc1088", "l2bmrdmin@1/6 $lb384 $lc1152"],
        "f32": ["l2bmrffadd $lb64 $lc256", "l2bmrfmax $lb128 $lc512", "l2bmrfmin $lb192 $lc768",
                "l2bmrfmin@[0,4] $lb256 $lc1024", "l2bmrffadd@1/6 $lb320 $lc1088", "l2bmrfmax@0 $lb384 $lc1152"],
        "f16": ["l2bmrhfadd $lb64 $lc256", "l2bmrhmax $lb128 $lc512", "l2bmrhmin $lb192 $lc768",
                "l2bmrhmax@0 $lb256 $lc1024", "l2bmrhmin@[0,1] $lb320 $lc1088", "l2bmrhfadd@0 $lb384 $lc1152"],
        "int": ["l2bmrliadd $lb64 $lc256", "l2bmriiadd $lb128 $lc512", "l2bmrsiadd $lb192 $lc768",
                "l2bmrlband $lb256 $lc1024", "l2bmriband@0 $lb320 $lc1088", "l2bmrsband@[0,4] $lb384 $lc1152",
                "l2bmrland $lb448 $lc1216", "l2bmriand@0 $lb512 $lc1280", "l2bmrsand@2/1 $lb576 $lc1344"],
        "bits": ["l2bmrlbor $lb64 $lc256", "l2bmribor@3/4 $lb128 $lc512", "l2bmrsbor $lb192 $lc768",
                 "l2bmrlor $lb256 $lc1024", "l2bmrior@0 $lb320 $lc1088", "l2bmrsor@[1,3] $lb384 $lc1152",
                 "l2bmrland@0 $lb448 $lc1216", "l2bmrsiadd@1/6 $lb512 $lc1280"],
    }
    for d, body in red.items():
        t.append(T(f"red_{d}", body, data=d))
    red2 = {
        "int": ["l2bmr2liadd $lb64 $lc256", "l2bmr2sband $lb128 $lc512", "l2bmr2iand $lb192 $lc768",
                "l2bmr2lbor $lb256 $lc1024", "l2bmr2sor $lb320 $lc1280"],
        "f32": ["l2bmr2ffadd $lb64 $lc256", "l2bmr2fmax $lb128 $lc512", "l2bmr2fmin $lb192 $lc768"],
        "f16": ["l2bmr2hfadd $lb64 $lc256", "l2bmr2hmax $lb128 $lc512", "l2bmr2hmin $lb192 $lc768"],
        "f64": ["l2bmr2dfadd $lb64 $lc256", "l2bmr2dmax $lb128 $lc512", "l2bmr2dmin $lb192 $lc768"],
    }
    for d, body in red2.items():
        t.append(T(f"red2_{d}", body, data=d))
    return t


def tests_l8() -> List[Prog]:
    """N_L1B = 8: the whole L2B, L2BM instructions only."""
    t = [
        T("b8_bcast", ["l2bmb $lc64 $lb128", "l2bmb@5 $lc320 $lb512", "l2bmb@[1,3] $lc1024 $lb0",
                       "l2bmb@4/3 $lc0 $lb256", "l2bmb@1/6 $lc16 $lb768"], l1bs=8),
        T("b8_bcast2", ["l2bmb2 $lc128 $lb64", "l2bmb2@0/1 $lc512 $lb256", "l2bmb2@6/1 $lc768 $lb512",
                        "l2bmb2@1/4 $lc1792 $lb960"], l1bs=8),
        T("b8_distrib", ["l2bmd $lc128 $lb64", "l2bmd $lc256 $lb8", "l2bmd@[1,3] $lc512 $lb256",
                         "l2bmd@5/2 $lc1792 $lb984"], l1bs=8),
        T("b8_from", [x for b in range(8) for x in (f"l2bm@{b} $lb{64 * b} $lc{128 * b}", "nop/3")], l1bs=8),
        T("b8_gather", ["l2bmd $lb64 $lc256", "nop/3", "l2bmd $lb8 $lc512", "nop/3", "l2bmd $lb992 $lc1792"], l1bs=8),
        T("b8_imcast", ["l2bmi@0/4 $lb64 $lb128", "nop/3", "l2bmi@3 $lb64 $lb256", "nop/3",
                        "l2bmi@1/2 $lb128 $lb512", "nop/3", "l2bmi@2/6 $lb0 $lb768", "nop/3",
                        "l2bmi@5/1 $lb16 $lb960"], l1bs=8),
        T("b8_imcast2", ["l2bmi@0/3 $lb64 $lb128", "nop/3", "l2bmi@4/5 $lb64 $lb256", "nop/3",
                         "l2bmi@6/1 $lb128 $lb512", "nop/3", "l2bmi@[0,4] $lb0 $lb768"], l1bs=8),
        T("b8_e_from_set", ["l2bm@5 $lb64 $lc256", "nop/3", "l2bm@5 $lb128 $lc512"], l1bs=8, data="int",
          edits=[(0, {"l2bm_immode": 1}), (4, {"l2bm_immode": 7, "l2bm_opcode": 8})]),
        T("b8_e_gather_set", ["l2bmd $lb64 $lc256", "nop/3", "l2bmd $lb64 $lc512"], l1bs=8,
          edits=[(0, {"l2bm_immode": 3, "l2bm_l1adr": 4}), (4, {"l2bm_immode": 6})]),
        T("b8_e_imc_all", ["l2bmi@0/4 $lb64 $lb128"], l1bs=8, edits=[(0, {"l2bm_immode": 7})]),
        T("b8_e_gw_bd3", ["l2bmb $lc64 $lb128"], l1bs=8, edits=[(0, {"l2bm_bdmode": 3})]),
        T("b8_e_unaligned", ["l2bmb $lc64 $lb128", "nop/2", "l2bm@5 $lb64 $lc256", "nop/3", "l2bmi@0/4 $lb64 $lb256"],
          l1bs=8, edits=[(0, {"l1bm_gadr": 17}), (3, {"l1bm_gadr": 9}), (7, {"l1bm_gadr": 9})]),
        T("b8_e_red2_set", ["l2bmr2liadd $lb64 $lc256", "nop/3", "l2bmr2ffadd $lb64 $lc512"], l1bs=8, data="int",
          edits=[(0, {"l2bm_immode": 1, "l2bm_l1adr": 2}), (4, {"l2bm_immode": 3, "l2bm_l1adr": 4})]),
        T("b8_dar", ["l2bmdars $lc256@.0 $dar100; l2bmdarw", "l2bmdarw", "l2bmb $lc0 $lb0; l2bmdarw"], l1bs=8,
          data="dar", dar=(96, 16)),
        T("b8_no_trap", ["l2bmb2 $lc1792 $lb0", "l2bmd $lc1792 $lb64"], l1bs=8),
        T("b8_r_bcast2", ["l2bmb $lc64 $lb0", "l2bmb2 $lc1856 $lb64"], l1bs=8, stop=(1, 1, 0)),
        T("b8_r_distrib", ["l2bmb $lc64 $lb0", "l2bmd $lc1856 $lb64"], l1bs=8, stop=(1, 1, 0)),
        T("b8_r_imc_src", ["l2bmb $lc64 $lb0", "nop/3", "l2bmi@0/4 $lb1024 $lb0"], l1bs=8, stop=(4, 1, 0)),
    ]
    red = {
        "f64": ["l2bmrdfadd $lb64 $lc256", "l2bmrdmax@[0,4] $lb128 $lc512", "l2bmrdmin@1/6 $lb192 $lc768",
                "l2bmrdfadd@3 $lb256 $lc1024"],
        "f32": ["l2bmrffadd $lb64 $lc256", "l2bmrfmax $lb128 $lc512", "l2bmrfmin@[0,4] $lb192 $lc768",
                "l2bmrffadd@2/5 $lb256 $lc1024"],
        "f16": ["l2bmrhfadd $lb64 $lc256", "l2bmrhmax@4/3 $lb128 $lc512", "l2bmrhmin $lb192 $lc768",
                "l2bmrhfadd@[1,5] $lb256 $lc1024"],
        "int": ["l2bmrliadd $lb64 $lc256", "l2bmriiadd@[0,4] $lb128 $lc512", "l2bmrsiadd@1/6 $lb192 $lc768",
                "l2bmrlband@0/3 $lb256 $lc1024", "l2bmriand@6/1 $lb320 $lc1088", "l2bmrsband $lb384 $lc1152"],
        "bits": ["l2bmrlbor $lb64 $lc256", "l2bmribor@3/4 $lb128 $lc512", "l2bmrsor@[1,3] $lb192 $lc768",
                 "l2bmrlor $lb256 $lc1024", "l2bmrland@5/2 $lb320 $lc1088"],
    }
    for d, body in red.items():
        t.append(T(f"b8_red_{d}", body, l1bs=8, data=d))
    red2 = {
        "int": ["l2bmr2liadd $lb64 $lc256", "l2bmr2sband $lb128 $lc512", "l2bmr2ior $lb192 $lc768"],
        "f32": ["l2bmr2ffadd $lb64 $lc256", "l2bmr2fmax $lb128 $lc512"],
        "f16": ["l2bmr2hfadd $lb64 $lc256", "l2bmr2hmin $lb128 $lc512"],
    }
    for d, body in red2.items():
        t.append(T(f"b8_red2_{d}", body, l1bs=8, data=d))
    return t


# --------------------------------------------------------------------------------- generator
def emit(p: Prog, words: List[str], dump: Dict, dar_vals, l1bs_check: int) -> List[str]:
    ini = LP.Init(p)
    lines = [f"# {p.name}: {' | '.join(p.body)}" + (f"  edits {p.edits}" if p.edits else "") +
             (f"  stop {p.stop}" if p.stop else ""),
             f"T {p.name} {p.l1bs} {ini.seed:016x} {LP.STYLES[p.data]} {int(p.l2_zero)} {int(p.l1_zero)} {int(p.pes)}"]
    for k, w in enumerate(words):
        kind, arg = 0, 0
        if p.stop and k == p.stop[0]:
            kind, arg = p.stop[1], p.stop[2]
        lines.append(f"W {kind} {arg} {int(w, 2):0107x}")
        if kind:
            break
    lines += hashes(dump, l1bs_check, p.pes)
    if dar_vals is not None:
        a0, n = p.dar
        for i, v in enumerate(dar_vals):
            lines.append(f"D {(a0 + i) % 1024} {v}")
    lines.append("E")
    return lines


def model_check(p: Prog, dump, ini, words, n_l1b, dar_vals=None):
    """The model on the official words vs the official dump (L2BM, L1Bs < n_l1b, PEs)."""
    st = l2pe.State(p, ini, n_l1b)
    for w in words:
        st.step(LP.fields(w))
    got = st.dump(dump.keys())
    bad = [(k, dump[k], got[k]) for k in sorted(got) if got[k] != dump[k]]
    if dar_vals is not None:
        a0, n = p.dar
        for i, v in enumerate(dar_vals):
            e = (a0 + i) % 1024
            if st.l2.dar[e] != v:
                bad.append((("DAR", "n0", e), v, st.l2.dar[e]))
    return bad


def nwords_of(body: List[str]) -> int:
    """j words of a body (nop/n gives n, MV lines give m words)."""
    n = 0
    for b in body:
        head = b.split(";")[0].strip()
        if head.startswith("mv"):
            continue
        n += int(head.split("/")[1]) if head.startswith("nop/") else 1
    return n


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="comma separated test names (written to build/, not fixed/)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--no-model", action="store_true")
    ap.add_argument("--reuse", action="store_true", help="read the official runs of an earlier call")
    a = ap.parse_args(argv)
    sets = {"l1": tests_l1(), "l8": tests_l8()}
    if a.only:
        keep = set(a.only.split(","))
        sets = {k: [p for p in v if p.name in keep] for k, v in sets.items()}
    allp = [p for v in sets.values() for p in v]
    names = [p.name for p in allp]
    assert len(names) == len(set(names)), "duplicate test names"
    t0 = time.time()
    res = LP.run(allp, BUILD / "emu", jobs=a.jobs, reuse=a.reuse)
    # stop tests: the expected state is the emulator's state before the stopping word
    stops = [p for p in allp if p.stop]
    tr = {}
    if stops:
        trunc = []
        for p in stops:
            r0 = res[p.name][0]
            if r0.asm_err:
                continue
            q = Prog(p.name, [], l1bs=p.l1bs, pes=p.pes, data=p.data, seed=p.seed, l2_zero=p.l2_zero,
                     l1_zero=p.l1_zero)
            # the body up to the stop word, as assembled (nop/n gives n words)
            body, n = [], 0
            for line in p.body:
                head = line.split(";")[0].strip()
                k = 0 if head.startswith("mv") else int(head.split("/")[1]) if head.startswith("nop/") else 1
                if n + k > p.stop[0]:
                    assert n == p.stop[0], f"{p.name}: the stop is inside {line}"
                    break
                body.append(line)
                n += k
            q.body = body
            q.edits = [e for e in p.edits if e[0] < p.stop[0]]
            trunc.append(q)
        tr = LP.run(trunc, BUILD / "emu_pre", jobs=a.jobs, reuse=a.reuse)
    dprogs = [p for p in allp if p.dar and not res[p.name][0].asm_err]
    dres = LP.run(dprogs, BUILD / "emu_dar", jobs=a.jobs, reuse=a.reuse, observe_dar=True) if dprogs else {}
    print(f"[official] {len(allp)} programs (+{len(tr)} before a stop, +{len(dres)} DAR observers), "
          f"{time.time() - t0:.0f} s")
    ok = True
    for fname, progs in sets.items():
        out = [f"# WP32 L2BM unit tests ({fname}): generated by gen_tests.py from the official emulator.",
               "# Format: tb_l2bm_env.v. Do not edit by hand."]
        l1bs_check = 1 if fname == "l1" else 8
        for p in progs:
            r, ini, words = res[p.name]
            if r.asm_err:
                print(f"{p.name}: ASSEMBLER ERROR {r.asm_err.strip().splitlines()[-1][:200]}")
                ok = False
                continue
            if p.stop:
                rp, _, pre_words = tr[p.name]
                if rp.asm_err or not rp.ok:
                    print(f"{p.name}: the run before the stop failed: {rp.asm_err or rp.emu_out[-200:]}")
                    ok = False
                    continue
                dump = rp.dump
                mwords = words[:p.stop[0]]
                assert pre_words == mwords, f"{p.name}: words before the stop differ"
            else:
                if not r.ok:
                    print(f"{p.name}: EMULATOR rc={r.emu_rc} {r.emu_out.strip()[-200:]}")
                    ok = False
                    continue
                dump = r.dump
                mwords = words
            if len(words) != nwords_of(p.body):
                print(f"{p.name}: {len(words)} words for {nwords_of(p.body)} in the body")
                ok = False
            dar_vals = None
            if p.dar:
                rd, _, dwords = dres[p.name]
                if not rd.ok:
                    print(f"{p.name}: the DAR observer failed: {rd.asm_err or rd.emu_out[-200:]}")
                    ok = False
                    continue
                dar_vals = LP.dar_of(rd.dump, *p.dar)
                if any(v is None for v in dar_vals):
                    print(f"{p.name}: DAR entries outside the marked DRAM: {dar_vals}")
                    ok = False
                    continue
            note = ""
            if not a.no_model:
                for nl in ((1, 8) if fname == "l1" else (8,)):
                    try:
                        bad = model_check(p, dump, ini, mwords, nl, dar_vals)
                    except Exception as e:  # noqa
                        bad = [(("model", repr(e), 0), 0, 0)]
                    if nl == 8 and fname == "l1" and p.pes:
                        continue     # the model has the PEs of L1B 0 only
                    note += f" model(N_L1B={nl}): {'ok' if not bad else 'DIFF %d' % len(bad)}"
                    if bad and nl == l1bs_check:
                        ok = False
                        for (k, e, g) in bad[:6]:
                            print(f"    {k}: official {e:#x} model {g:#x}" if isinstance(e, int) else f"    {k}")
            print(f"{p.name}: {len(mwords)} words{note}")
            out += emit(p, words, dump, dar_vals, l1bs_check)
        dst = (BUILD if a.only else FIXED) / f"{fname}.tst"
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
        print(f"-> {dst} ({len(progs)} tests)")
    print("OK" if ok else "SOME TESTS ARE NOT VALID")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

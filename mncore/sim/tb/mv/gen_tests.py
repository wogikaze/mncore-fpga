#!/usr/bin/env python3
"""WP33: MV test programs, with the official emulator's results as expectations.

    python mncore/sim/tb/mv/gen_tests.py [--only NAME,...] [--jobs 8] [--reuse]

Every test is a small program on the reduced topology of the RTL (contract section 3 (b): the
official full chip with data only in the units that exist: group 0, L2B n0c0, L1B n0c0b0):
  - initial data (splitmix64 of the test, styled as l2prog.styled): L2BM n0c0 long words
    0..2047, the L1BM of n0c0b0 0..1023 (tests with L2BM instructions), DRAM n0 0..2047, and the
    PDM source DRAM n0 0x8000..0x83ff, copied to PDM n0 0..1023 by the first word
    (mvp/n1024 $d32768@0 $p0@0); extra DRAM windows and explicit values where a test says so;
  - the body (MV words, waits, L2BM instructions; some words edited after the assembly: fields
    the assembler never sets, to pin the emulator's semantics);
  - the last word copies PDM n0 0..1023 to DRAM n0 0x10000 (the official d get $p shows the
    DRAM, contract section 1), then d get of the L2BM, the DRAM windows and the L1BM.
It is assembled with the official assemble3 (flat, no packer) and run on the official emulator
(WSL; only called, contract section 9). The result is fixed/mv.tst for tb_mv_env.v (format
there): fills, the words, the expected stop record and FNV-1a hashes of every 64 long words of
the L2BM, the DRAM windows and the L1BM, taken from the emulator's dump.
Tests that stop (E_RANGE beyond the reduced capacities, E_UNSUPPORTED for the words the
emulator aborts on) take the state from the emulator's run of the words before the stop; a wait
for a tag that was never issued stops the RUN (reason 4) where the emulator stops executing.

The reference model (mvmodel.py, the reduced topology) runs on the same words; a test is valid
only if the model agrees with the emulator on everything compared (the data flow stays in the
units that exist) and touches no PDM / DRAM outside the windows the testbench fills.
"""
from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mvmodel as MM  # noqa: E402
from mvemu import fields, mfields, rline, run  # noqa: E402

sys.path.insert(0, str(HERE.parent / "l2bm"))
from l2prog import STYLES, styled  # noqa: E402
from l1prog import SplitMix64, name_seed  # noqa: E402

FIXED = HERE / "fixed"
BUILD = HERE / "build"
M64 = (1 << 64) - 1
L2N, L1N, DN, PN = 2048, 1024, 2048, 1024
PSRC, POBS = 0x8000, 0x10000
PRE = [f"mvp/n{PN} $d{PSRC}@0 $p0@0"]
POST = [f"mvp/n{PN} $p0@0 $d{POBS}@0"]
F_IDX = {"valid": 0, "mmode": 1, "tmode": 2, "destid": 3, "srcid": 4, "dmode": 5, "mvid": 6, "indirect": 7,
         "adra": 8, "adrb": 9, "nw": 10, "priority": 11}
J_WD_IDX = 91
R_OK, R_RANGE, R_UNSUP, R_WAIT = 0, 1, 2, 4
REDUCED = dict(groups=1, l2b1=False, l2_cap=2048, pdm_cap=1 << 17, dram_cap=1 << 19)


@dataclass
class Test:
    name: str
    body: List[str]
    data: str = "bits"
    l1: bool = False                     # the L1BM of n0c0b0 gets data (else zeros)
    l2z: bool = False                    # the L2BM stays zero
    edits: List[Tuple[int, Dict[str, int]]] = field(default_factory=list)   # (body word index, fields)
    stop: Optional[Tuple[int, int]] = None   # (body word index, reason) of the expected stop
    win: List[Tuple[int, int, bool]] = field(default_factory=list)   # extra DRAM windows (addr, n, data)
    pwin: List[Tuple[int, int]] = field(default_factory=list)        # extra PDM windows (zeros)
    vals: List[Tuple[int, int, int]] = field(default_factory=list)   # explicit (space, addr, value)
    note: str = ""


def body_kinds(body: List[str]) -> List[str]:
    out = []
    for b in body:
        head = b.split(";")[0].strip()
        if head.startswith("mv"):
            out.append("m")
        elif head.startswith("nop/"):
            out += ["j"] * int(head.split("/")[1])
        else:
            out.append("j")
    return out


class Data:
    """The initial data of a test, in the order the testbench fills it (F lines)."""

    def __init__(self, t: Test):
        self.seed = name_seed(f"mv:{t.name}")
        self.style = STYLES[t.data]
        g = SplitMix64(self.seed)
        nxt = lambda: styled(g.next(), self.style)  # noqa: E731
        self.l2 = [0] * L2N if t.l2z else [nxt() for _ in range(L2N)]
        self.l1 = [nxt() for _ in range(L1N)] if t.l1 else [0] * L1N
        self.dram: Dict[int, int] = {}
        for a in range(DN):
            self.dram[a] = nxt()
        for a in range(PN):
            self.dram[PSRC + a] = nxt()
        for a in range(PN):
            self.dram[POBS + a] = 0
        for (wa, n, dat) in t.win:
            for a in range(n):
                self.dram[wa + a] = nxt() if dat else 0
        for sp, a, v in t.vals:
            if sp == 7:
                self.l2[a] = v
            elif sp == 6:
                self.l1[a] = v
            elif sp == 9:
                self.dram[a] = v
            else:
                raise ValueError(sp)

    def fills(self, t: Test) -> List[str]:
        """The first 64 long words of a fill go through the host port (F), the rest through the
        backdoor (G): the same values, in the same order of the generator."""
        out = [f"T {t.name} {self.seed:016x}"]

        def fill(sp, a, n, style):
            out.append(f"F {sp} {a:x} {min(n, 64)} {style}")
            if n > 64:
                out.append(f"G {sp} {a + 64:x} {n - 64} {style}")
        if not t.l2z:
            fill(7, 0, L2N, self.style)
        fill(6, 0, L1N, self.style if t.l1 else 9)
        fill(9, 0, DN, self.style)
        fill(9, PSRC, PN, self.style)
        fill(9, POBS, PN, 9)
        for (wa, n, dat) in t.win:
            fill(9, wa, n, self.style if dat else 9)
        for (pa, n) in t.pwin:
            fill(8, pa, n, 9)
        for sp, a, v in t.vals:
            out.append(f"V {sp} {a:x} {v:016x}")
        return out

    def windows(self, t: Test) -> List[Tuple[int, int]]:
        return [(0, DN), (PSRC, PN), (POBS, PN)] + [(wa, n) for wa, n, _ in t.win]


def vsm_of(t: Test, d: Data, body: List[str], post: bool) -> str:
    out = []
    runs = sorted(d.dram.items())
    # r lines for the nonzero DRAM data, in runs of consecutive addresses
    blk: List[Tuple[int, int]] = []
    for a, v in runs:
        if v == 0:
            continue
        if blk and blk[-1][0] + len(blk[-1][1]) == a:
            blk[-1][1].append(v)
        else:
            blk.append((a, [v]))
    for a, vs in blk:
        out += rline(0, a, vs)
    if any(d.l2):
        out.append(f"d set $lc0n0c0 {L2N} " + "".join(f"{v:016x}" for v in d.l2))
    if any(d.l1):
        out.append(f"d set $lb0n0c0b0 {L1N} " + "".join(f"{v:016x}" for v in d.l1))
    out += PRE + body + (POST if post else [])
    out.append(f"d get $lc0n0c0 {L2N}")
    for wa, n in d.windows(t):
        out.append(f"d get $d{wa}n0 {n}")
    out.append(f"d get $lb0n0c0b0 {L1N}")
    return "\n".join(out) + "\n"


# ------------------------------------------------------------------------------------- tests
def T(name, body, **kw):
    return Test(name, body, **kw)


def dar_set(entries: int) -> List[str]:
    """DAR[0 .. entries-1] from L2BM n0c0 0.. (l2bmdars + l2bmdarw, 4 entries per word)."""
    return ["l2bmdars $lc0@.0 $dar0; l2bmdarw"] + ["l2bmdarw"] * (entries // 4 - 1)


def hello_values(jobs: int) -> Tuple[List[Tuple[int, int, int]], List[Tuple[int, int, int]]]:
    """The official hello world (problems/challenge/21.hello-world): the L2BM n0c0 right before its
    MV, and the L1BM n0c0b0 right before its l2bmrhfadd (nonzero long words)."""
    root = HERE.parents[3]
    src = (root / "third_party/mncore/problems/challenge/21.hello-world/main.vsm").read_text(encoding="utf-8")
    lines = [ln for ln in src.replace("\r", "").splitlines() if ln.strip()]
    assert lines[7].startswith("l2bmrhfadd") and lines[8].startswith("mvp"), lines[:9]
    progs = {"hello_l1": "\n".join(lines[:7] + [f"d get $lb0n0c0b0 {L1N}"]) + "\n",
             "hello_l2": "\n".join(lines[:8] + [f"d get $lc0n0c0 {L2N}"]) + "\n"}
    res = run(progs, BUILD / "hello", jobs=jobs)
    l2 = [(7, a, v) for (sp, loc, a), v in sorted(res["hello_l2"].dump.items()) if sp == "L2BM" and v]
    l1 = [(6, a, v) for (sp, loc, a), v in sorted(res["hello_l1"].dump.items()) if sp == "L1BM" and v]
    return l2, l1


def tests(hello) -> List[Test]:
    hl2, hl1 = hello
    t = [
        # ---------------------------------------------------------------- individual transfers
        T("p2d", ["mvp/n128 $p64@0 $d512@0", "mvp/n64 $p256@1 $d1024@0", "mvp/n64 $p0@0 $d1152@2",
                  "mvp/n64 $p320@0 $d1280@0"]),
        T("d2p", ["mvp/n128 $d64@0 $p512@0", "mvp/n64 $d256@3 $p640@0", "mvp/n64 $d0@0 $p0@1",
                  "mvp/n64 $d1024@0 $p832@0"]),
        T("p2c", ["mvp/n128 $p64@0 $lc256@0.0", "mvp/n64 $p0@0 $lc512@0.1", "mvp/n64 $p128@2 $lc640@0.0",
                  "mvp/n64 $p448@0 $lc1984@0.0"]),
        T("c2p", ["mvp/n128 $lc64@0.0 $p512@0", "mvp/n64 $lc0@0.1 $p640@0", "mvp/n64 $lc128@1.0 $p704@0",
                  "mvp/n64 $lc0@0.0 $p768@3", "mvp/n64 $lc1984@0.0 $p896@0"]),
        T("d2c", ["mvp/n128 $d64@0 $lc256@0.0", "mvp/n64 $d0@1 $lc512@0.0", "mvp/n64 $d0@0 $lc640@1.1",
                  "mvp/n64 $d1984@0 $lc1984@0.0"]),
        T("c2d", ["mvp/n192 $lc64@0.0 $d512@0", "mvp/n64 $lc0@0.1 $d1024@0", "mvp/n64 $lc0@0.0 $d1152@3",
                  "mvp/n64 $lc1984@0.0 $d1984@0"]),
        T("p2p", ["mvp/n128 $p0@0 $p512@0", "mvp/n64 $p0@1 $p768@0", "mvp/n64 $p0@0 $p0@2",
                  "mvp/n64 $p960@0 $p896@0"]),
        T("p2p_up", ["mvp/n256 $p0@0 $p64@0"], edits=[(0, {"adrb": 1})], note="PDM 0 -> 16, overlapping"),
        T("p2p_down", ["mvp/n256 $p64@0 $p0@0"], edits=[(0, {"adrb": 3})], note="PDM 64 -> 48, overlapping"),
        T("par", ["mvp/n128 $p64 $lc256@.0", "mvp/n64 $lc0@.0 $p512", "mvp/n64 $d128 $lc512@.0",
                  "mvp/n64 $lc256@.0 $d1024", "mvp/n64 $p0 $lc640@.1", "mvp/n64 $lc0@.1 $p576",
                  "mvp/n64 $d0 $lc704@.1", "mvp/n64 $lc0@.1 $d1152"]),
        T("par_more", ["mvp/n64 $p64@0 $d512@0", "mvp/n128 $d64@0 $p640@0", "mvp/n64 $p0@0 $p832@0",
                       "mvp/n64 $p576@0 $p448@0"],
          edits=[(0, {"tmode": 1}), (1, {"tmode": 1}), (2, {"tmode": 1}), (3, {"tmode": 1, "adrb": 29})],
          note="PDM <-> DRAM and PDM -> PDM parallel (the assembler does not make them)"),
        T("sizes", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $d128@0 $lc256@0.0", "mvp/n64 $lc0@0.0 $d1024@0",
                    "mvp/n64 $lc256@0.0 $p256@0"],
          edits=[(0, {"nw": 1}), (1, {"nw": 5}), (2, {"nw": 3}), (3, {"nw": 6})],
          note="nw 1 / 5 / 3 / 6 chunks in the individual forms"),
        T("big", ["mvp/n2048 $d0@0 $lc0@0.0", "mvp/n2048 $lc0@0.0 $d4096@0", "mvp/n1024 $lc1024@0.0 $p1024@0",
                  "mvp/n1024 $p1024@0 $d6144@0"],
          win=[(4096, 2048, False), (6144, 1024, False)], pwin=[(1024, 1024)]),
        T("unal", ["mvp/n64 $d16@0 $lc64@0.0", "mvp/n64 $lc128@0.0 $d1040@0", "mvp/n64 $d0@0 $p512@0",
                   "mvp/n64 $p512@0 $lc512@0.0"],
          edits=[(0, {"adrb": 7}), (1, {"adrb": 10}), (2, {"adrb": 33}), (3, {"adra": 33, "adrb": 34})],
          note="adrb bits 1..0 of the L2BM are not used; PDM addresses in 16s"),
        # ---------------------------------------------------------------- broadcasts, distribution
        T("b2", ["mvb2/n128 $d64 $lc256", "mvb2/n64 $d512 $lc640", "mvp/n64 $p128@0 $lc768@0.0",
                 "mvp/n64 $p192@0 $lc896@0.0"],
          edits=[(1, {"destid": 3, "srcid": 2}), (2, {"tmode": 2}), (3, {"tmode": 2, "destid": 2})],
          note="ids of mvb2 not used; p2c b2 (assembler does not make it) of group 0 / 1"),
        T("b4", ["mvb4/n128 $d64 $lc256", "mvb4/n64 $d512 $lc640"]),
        T("b", ["mvb/n128 $d64 $lc256", "mvb/n64 $p128@0 $lc512", "mvb/n64 $p0@2 $lc640", "mvb/n64 $d1024 $lc768"]),
        T("d_p2c", ["mvd/n64 $p0@0 $lc256", "mvd/n64 $p512@1 $lc512", "mvd/n64 $p64@0 $lc640"],
          edits=[(2, {"nw": 5})]),
        T("d_c2p", ["mvd/n64 $lc64 $p0@0", "mvd/n64 $lc128 $p512@2", "mvd/n64 $lc256 $p512@0"],
          edits=[(2, {"nw": 5})], pwin=[(1024, 128)]),
        T("d_p2d", ["mvd/n128 $p0@0 $d512", "mvd/n64 $p256@0 $d768", "mvd/n64 $p512@3 $d1024", "mvd/n64 $p128@0 $d1280"],
          edits=[(3, {"nw": 5})]),
        T("d_d2p", ["mvd/n128 $d64 $p512@0", "mvd/n64 $d256 $p768@2"]),
        T("forms_nop", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $d0@0 $lc64@0.0", "mvp/n64 $d0@0 $lc128@0.0",
                        "mvp/n64 $d0@0 $lc192@0.0"],
          edits=[(0, {"mmode": 7}), (1, {"tmode": 6}), (2, {"tmode": 7}), (3, {"valid": 0})],
          note="mmode 111, tmode 110 / 111: nothing; valid 0: mvnop"),
        # ---------------------------------------------------------------- reductions
        T("red_f64", ["mvrdfadd/n64 $lc0 $d512", "mvrdmax/n64 $lc64 $d528", "mvrdmin/n64 $lc128 $d544",
                      "mvr2dfadd/n64 $lc192 $d576", "mvr2dmax/n64 $lc256 $d640", "mvr4dmin/n64 $lc320 $d704",
                      "mvrdmax/n64 $lc384 $p512@0", "mvr2dfadd/n64 $lc448@0 $p576@0", "mvr4dfadd/n64 $lc512 $d768"],
          data="f64"),
        T("red_f32", ["mvrffadd/n64 $lc0 $d512", "mvrfmax/n64 $lc64 $d528", "mvrfmin/n64 $lc128 $d544",
                      "mvr2ffadd/n64 $lc192 $d576", "mvr2fmin/n64 $lc256 $d640", "mvr4fmax/n64 $lc320 $d704",
                      "mvrfmin/n64 $lc384 $p512@0", "mvr2fmax/n64 $lc448@0 $p576@0"], data="f32"),
        T("red_f16", ["mvrhfadd/n64 $lc0 $d512", "mvrhmax/n64 $lc64 $d528", "mvrhmin/n64 $lc128 $d544",
                      "mvr2hfadd/n64 $lc192 $d576", "mvr2hmax/n64 $lc256 $d640", "mvr4hmin/n64 $lc320 $d704",
                      "mvrhfadd/n64 $lc384 $p512@0", "mvr2hmin/n64 $lc448@0 $p576@0"], data="f16"),
        T("red_int", ["mvrliadd/n64 $lc0 $d512", "mvriiadd/n64 $lc64 $d528", "mvrsiadd/n64 $lc128 $d544",
                      "mvrlband/n64 $lc192 $d560", "mvriand/n64 $lc256 $d576", "mvr2sband/n64 $lc320 $d640",
                      "mvr4land/n64 $lc384 $d704", "mvr2iiadd/n64 $lc448@0 $p512@0", "mvrsand/n64 $lc512 $p576@0"],
          data="int"),
        T("red_bits", ["mvrlbor/n64 $lc0 $d512", "mvribor/n64 $lc64 $d528", "mvrsor/n64 $lc128 $d544",
                       "mvrlor/n64 $lc192 $d560", "mvr2ior/n64 $lc256 $d576", "mvr4sbor/n64 $lc320 $d640",
                       "mvr2lor/n64 $lc384@0 $p512@0", "mvrsbor/n64 $lc448 $p576@0", "mvr2hmax/n64 $lc512@2 $p640@2"],
          note="the last: group 2 (does not exist)"),
        # ---------------------------------------------------------------- indirect DRAM
        T("ind_s", dar_set(32) + ["mvp/n128nd2 $lc0@0.0 $di4@0", "mvp/n128 $di8@0 $lc256@0.0",
                                  "mvp/n64nd3 $p0@0 $di12@0", "mvp/n64nd1 $di16@0 $p512@0",
                                  "mvp/n64nd31 $lc512@0.0 $di20@0", "mvp/n128 $lc640@0.0 $di24@0"], data="dar"),
        T("ind_p", dar_set(16) + ["mvp/n128nd2 $lc0@.0 $di4", "mvp/n128 $di8 $lc256@.0", "mvp/n64nd3 $lc512@.1 $di2"],
          data="dar"),
        T("ind_b", dar_set(32) + ["mvb/n128nd2 $di4 $lc0", "mvb2/n128nd3 $di6 $lc256", "mvb4/n128nd2 $di10 $lc512",
                                  "mvb4/n128 $di20 $lc768"], data="dar"),
        T("ind_r", dar_set(32) + ["mvrliadd/n128nd2 $lc0 $di4", "mvr2lbor/n128nd3 $lc256 $di6",
                                  "mvr4liadd/n128nd2 $lc512 $di10", "mvr4lbor/n128 $lc768 $di20"], data="dar"),
        # (the DRAM -> PDM forms first: on the chip, PDM -> DRAM also writes the DRAMs of groups 1..3,
        # whose DAR is 0, at the chunks DRAM -> PDM would read back)
        T("ind_d", dar_set(32) + ["mvd/n128nd2 $di8 $p512@0", "mvd/n64 $di12 $p768@0", "mvd/n128nd2 $p0@0 $di4"],
          data="dar"),
        T("ind_nd", dar_set(16) + ["mvp/n128nd3 $lc0@0.0 $di4@0", "mvp/n128nd3 $lc0@0.0 $di4@0"], data="dar",
          edits=[(len(dar_set(16)), {"adra": (0x23 << 10) | 4}), (len(dar_set(16)) + 1, {"adra": (0x13 << 10) | 5})],
          note="nd is adra[14:10] (bit 15 and up are not used)"),
        # ---------------------------------------------------------------- tags and waits
        T("w_ok", ["mvp/n64i01 $d0@0 $lc0@0.0", "nop; wait i01", "mvp/n64i02 $lc0@0.0 $d1024@0", "nop",
                   "mvp/n64i03 $d64@0 $lc64@0.0", "nop; wait i03", "nop; wait i02", "mvp/n64 $lc64@0.0 $d1088@0"]),
        T("w_reuse", ["mvp/n64i05 $d0@0 $lc0@0.0", "nop; wait i05", "mvp/n64i05 $d64@0 $lc64@0.0", "nop; wait i05",
                      "mvp/n64iff $lc0@0.0 $d1024@0", "nop; wait iff", "mvp/n64 $lc64@0.0 $d1088@0"]),
        T("w_never", ["mvp/n64i01 $d0@0 $lc0@0.0", "nop; wait i02", "mvp/n64 $d64@0 $lc64@0.0"], stop=(1, R_WAIT),
          note="a wait for a tag never issued: nothing after it runs"),
        T("w_twice", ["mvp/n64i01 $d0@0 $lc0@0.0", "nop; wait i01", "nop; wait i01", "mvp/n64 $d64@0 $lc64@0.0"],
          stop=(2, R_WAIT), note="the completion is consumed by the first wait"),
        T("w_before", ["nop; wait i07", "mvp/n64i07 $d0@0 $lc0@0.0"], stop=(0, R_WAIT)),
        T("w_double", ["mvp/n64i07 $d0@0 $lc0@0.0", "mvp/n64i07 $d64@0 $lc64@0.0", "nop; wait i07"],
          stop=(2, R_UNSUP), note="two completions, then a wait: the emulator aborts"),
        T("w_noop_tag", ["mvp/n64i01 $d0@0 $lc0@0.0", "nop; wait i01", "mvp/n64i02 $d64@0 $lc64@0.0", "nop; wait i02"],
          edits=[(0, {"mmode": 7})], stop=None, note="mmode 111 moves nothing but completes: the wait passes"),
        T("w_mvnop_tag", ["mvp/n64i01 $d0@0 $lc0@0.0", "nop; wait i01", "mvp/n64 $d64@0 $lc64@0.0"],
          edits=[(0, {"valid": 0})], stop=(1, R_WAIT), note="valid 0: no tag"),
        T("w_l2", ["mvp/n64i11 $d0@0 $lc0@0.0", "l2bmb $lc0 $lb0; wait i11", "nop/3", "mvp/n64 $lc64@0.0 $d1024@0"],
          l1=True, note="the wait in an L2BM word"),
        # ---------------------------------------------------------------- order with the L2BM instructions
        T("o_mv_l2", ["mvp/n64 $d0@0 $lc0@0.0", "l2bmb $lc0 $lb0", "nop/3", "l2bm@0 $lb64 $lc64", "nop",
                      "mvp/n64 $lc64@0.0 $d1024@0", "mvp/n64 $lc0@0.0 $d1088@0"], l1=True,
          note="an L2BM instruction right after an MV sees its data, an MV after an L2BM instruction too"),
        T("o_chain", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $lc0@0.0 $p0@0", "mvp/n64 $p0@0 $d1024@0",
                      "mvp/n64 $d1024@0 $lc64@0.0"]),
        T("o_dar", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "mvp/n64nd1 $lc0@0.0 $di0@0", "l2bmdars $lc64@.0 $dar0; l2bmdarw",
                    "mvp/n64nd1 $lc256@0.0 $di0@0"], data="dar",
          note="the DAR an MV reads is the one of the L2BM words before it"),
        # ---------------------------------------------------------------- E_RANGE
        T("r_c", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $d0@0 $lc2048@0.0"], stop=(1, R_RANGE)),
        T("r_c_end", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n128 $d0@0 $lc1984@0.0"], stop=(1, R_RANGE)),
        T("r_c_src", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $lc4096@0.0 $d1024@0"], stop=(1, R_RANGE)),
        T("r_p", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $d0@0 $p131072@0"], stop=(1, R_RANGE)),
        T("r_p_end", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n128 $lc0@0.0 $p131008@0"], stop=(1, R_RANGE)),
        T("r_d", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $lc0@0.0 $d524288@0"], stop=(1, R_RANGE)),
        T("r_d_end", ["mvp/n64 $d0@0 $lc0@0.0", "mvb/n128 $d524272 $lc0"], stop=(1, R_RANGE)),
        T("r_ind", ["l2bmdars $lc1792@.0 $dar0; l2bmdarw", "mvp/n64nd1 $lc0@0.0 $di0@0"], data="dar",
          vals=[(7, 1792, (1 << 32) | 2), (7, 1793, (0x8000 << 32) | 3)], stop=(1, R_RANGE),
          note="DAR 1, 2, 0x8000, 3: the third chunk is beyond the DRAM; nothing is written"),
        T("r_absent", ["mvp/n64 $d1048576@1 $lc0@0.1", "mvp/n64 $lc4096@0.1 $d1024@0", "mvp/n64 $p131072@2 $d1088@0",
                       "mvp/n64 $lc0@0.0 $d524288@3"],
          note="no check for the accesses of the units that do not exist"),
        T("r_wrap", ["mvp/n64 $lc0@0.0 $d0@0", "mvp/n64 $d0@0 $lc64@0.0"],
          edits=[(0, {"adra": (1 << 25) + 64}), (1, {"adra": (1 << 26) + 64})],
          note="DRAM addresses wrap at 2**29 long words, then the capacity applies"),
        T("r_wrap_c", ["mvp/n64 $d0@0 $lc0@0.0"], edits=[(0, {"adrb": 2048 + 8})],
          note="L2BM addresses wrap at 2**15 long words"),
        # ---------------------------------------------------------------- E_UNSUPPORTED (the emulator aborts)
        T("u_form", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $p64@0 $d512@0"], edits=[(1, {"tmode": 4})],
          stop=(1, R_UNSUP)),
        T("u_nw0", ["mvp/n64 $d0@0 $lc0@0.0", "mvp/n64 $d0@0 $lc64@0.0"], edits=[(1, {"nw": 0})], stop=(1, R_UNSUP)),
        T("u_nw5", ["mvp/n64 $d0@0 $lc0@0.0", "mvb/n64 $d0 $lc64"], edits=[(1, {"nw": 5})], stop=(1, R_UNSUP)),
        T("u_op", ["mvp/n64 $d0@0 $lc0@0.0", "mvrliadd/n64 $lc0 $d1024"], edits=[(1, {"srcid": 3})],
          stop=(1, R_UNSUP), data="int"),
        T("u_dm3", ["mvp/n64 $d0@0 $lc0@0.0", "mvrliadd/n64 $lc0 $d1024"], edits=[(1, {"dmode": 3})],
          stop=(1, R_UNSUP), data="int"),
        T("u_d2p_nw", ["mvp/n64 $d0@0 $lc0@0.0", "mvd/n64 $d64 $p512@0"], edits=[(1, {"nw": 5})], stop=(1, R_UNSUP)),
        # ---------------------------------------------------------------- hello world (problems/challenge/21)
        T("hello_mv", ["mvp/n64 $lc64@0.0 $d0@0"], l2z=True, vals=hl2,
          note="the official hello world's L2BM n0c0 before its MV (4096 PEs), then the MV"),
        T("hello_l2mv", ["nop", "nop", "l2bmrhfadd $lb16 $lc32", "mvp/n64 $lc64@0.0 $d0@0"], l2z=True, vals=hl1,
          note="hello world's L1BM n0c0b0 before its l2bmrhfadd, in L1B 0 only (the reduced topology: "
               "the other L1Bs send 0, the official full chip sums 8 equal L1Bs)"),
    ]
    return t


# --------------------------------------------------------------------------------- generator
def fnv(h: int, v: int) -> int:
    return ((h ^ v) * 0x100000001B3) & M64


def hash64(vals: List[int]) -> int:
    h = 0xCBF29CE484222325
    for v in vals:
        h = fnv(h, v)
    return h


def model_run(t: Test, d: Data, words, stop_at: Optional[int]):
    st = MM.State(topo=MM.Topo(**REDUCED))
    st.l2[0].l2bm[:L2N] = list(d.l2)
    st.l2[0].l1bm[0][:L1N] = list(d.l1)
    for a, v in d.dram.items():
        st.dram[0][a] = v
    err = None
    for i, (k, b) in enumerate(words):
        before = set(st.touched)
        try:
            MM.step(st, k, mfields(b) if k == "m" else fields(b))
        except (MM.RangeError, MM.Unsupported) as e:
            st.touched = before      # the stopping word does nothing
            err = (i, e)
            break
        if st.halted and err is None:
            err = (i, "halt")
            break
    return st, err


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="comma separated test names (written to build/, not fixed/)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--reuse", action="store_true", help="read the official runs of an earlier call")
    a = ap.parse_args(argv)
    t0 = time.time()
    hello = hello_values(a.jobs)
    allt = tests(hello)
    if a.only:
        keep = set(a.only.split(","))
        allt = [x for x in allt if x.name in keep]
    names = [x.name for x in allt]
    assert len(names) == len(set(names)), "duplicate test names"
    datas = {x.name: Data(x) for x in allt}
    # edits: body word index -> (kind, index among the words of that kind), the preamble is one m word
    edits, kinds = {}, {}
    for x in allt:
        k = ["m"] + body_kinds(x.body) + ["m"]
        kinds[x.name] = k
        if x.edits:
            ed = []
            for bi, ch in x.edits:
                ai = 1 + bi
                kk = k[ai]
                ed.append((kk, sum(1 for q in k[:ai] if q == kk), ch))
            edits[x.name] = ed
    texts = {x.name: vsm_of(x, datas[x.name], x.body, True) for x in allt}
    res = run(texts, BUILD / "emu", jobs=a.jobs, reuse=a.reuse, edits=edits)
    # the stop tests: the state of the words before the stop (a wait that blocks: the full run)
    pre = {}
    for x in allt:
        if x.stop and x.stop[1] != R_WAIT:
            k = kinds[x.name]
            n_body = x.stop[0]
            body, cnt = [], 0
            for line in x.body:
                c = len(body_kinds([line]))
                if cnt + c > n_body:
                    assert cnt == n_body, f"{x.name}: the stop is inside {line}"
                    break
                body.append(line)
                cnt += c
            pre[x.name] = (body, [e for e in edits.get(x.name, []) if
                                  (sum(1 for q in k[:1 + n_body] if q == e[0]) > e[1])])
    tr = run({n: vsm_of(next(x for x in allt if x.name == n), datas[n], b, False) for n, (b, _) in pre.items()},
             BUILD / "emu_pre", jobs=a.jobs, reuse=a.reuse,
             edits={n: e for n, (_, e) in pre.items() if e}) if pre else {}
    print(f"[official] {len(allt)} programs (+{len(tr)} before a stop), {time.time() - t0:.0f} s")

    ok = True
    out = ["# WP33 MV unit tests: generated by gen_tests.py from the official emulator. Format: tb_mv_env.v.",
           "# Do not edit by hand."]
    for x in allt:
        d = datas[x.name]
        r = res[x.name]
        if r.asm_err:
            print(f"{x.name}: ASSEMBLER ERROR {r.asm_err.strip().splitlines()[-1][:200]}")
            ok = False
            continue
        words = [(k, b) for k, b in r.seq if k in "jm"]
        if [k for k, _ in words] != kinds[x.name]:
            print(f"{x.name}: words {''.join(k for k, _ in words)} for {''.join(kinds[x.name])}")
            ok = False
            continue
        if x.stop:
            si = 1 + x.stop[0]
            if x.stop[1] == R_WAIT:
                dump = r.dump
                if not r.ok:
                    print(f"{x.name}: EMULATOR rc={r.emu_rc}")
                    ok = False
                    continue
            else:
                rp = tr[x.name]
                if rp.asm_err or not rp.ok:
                    print(f"{x.name}: the run before the stop failed: {rp.asm_err[-200:] or rp.emu_out[-300:]}")
                    ok = False
                    continue
                dump = rp.dump
                pw = [(k, b) for k, b in rp.seq if k in "jm"]
                assert pw == words[:si], f"{x.name}: the words before the stop differ"
            kword, bword = words[si]
            if x.stop[1] == R_RANGE:
                stoprec = (R_RANGE, si, si, si)
            elif x.stop[1] == R_WAIT:
                stoprec = (R_WAIT, fields(bword)["wd"], si, si)
            elif kword == "m":
                st = None
                try:
                    MM.check(mfields(bword))
                except MM.Unsupported as e:
                    st = e.field
                if st is None:
                    print(f"{x.name}: the model accepts the stop word")
                    ok = False
                    continue
                stoprec = (R_UNSUP, 0x80 | F_IDX[st], si, si)
            else:
                stoprec = (R_UNSUP, J_WD_IDX, si, si)
            if x.stop[1] == R_UNSUP and r.ok:
                print(f"{x.name}: the emulator did not abort on the stop word (rc {r.emu_rc})")
                ok = False
        else:
            if not r.ok:
                print(f"{x.name}: EMULATOR rc={r.emu_rc} {r.emu_out.strip()[-300:]}")
                ok = False
                continue
            dump = r.dump
            stoprec = (R_OK, 0, len(words), len(words))
        # the model (reduced topology) on the same words
        st, err = model_run(x, d, words, None)
        note = ""
        exp_err = None if not x.stop else (1 + x.stop[0], x.stop[1])
        if exp_err is None and err is not None:
            print(f"{x.name}: model stops at word {err[0]}: {err[1]}")
            ok = False
        if exp_err is not None:
            kinds_ok = {R_RANGE: MM.RangeError, R_UNSUP: MM.Unsupported}
            if err is None or err[0] != exp_err[0] or (exp_err[1] == R_WAIT and err[1] != "halt") or \
                    (exp_err[1] != R_WAIT and not isinstance(err[1], kinds_ok[exp_err[1]])):
                print(f"{x.name}: model stop {err}, expected word {exp_err[0]} reason {exp_err[1]}")
                ok = False
        bad = []
        for aa in range(L2N):
            if st.l2bm(0, 0)[aa] != dump.get(("L2BM", "n0c0", aa), 0):
                bad.append(("L2BM", aa))
        for wa, n in d.windows(x):
            for aa in range(wa, wa + n):
                if st.dram[0][aa] != dump.get(("DRAM", "n0", aa), 0):
                    bad.append(("DRAM", aa))
        for aa in range(L1N):
            if st.l2[0].l1bm[0][aa] != dump.get(("L1BM", "n0c0b0", aa), 0):
                bad.append(("L1BM", aa))
        if bad:
            print(f"{x.name}: model differs from the official at {len(bad)} long words, e.g. {bad[:4]}")
            for sp, aa in bad[:3]:
                loc = "n0c0" if sp == "L2BM" else "n0" if sp == "DRAM" else "n0c0b0"
                mv = st.l2bm(0, 0)[aa] if sp == "L2BM" else st.dram[0][aa] if sp == "DRAM" else st.l2[0].l1bm[0][aa]
                print(f"    {sp} {aa:#x}: official {dump.get((sp, loc, aa), 0):016x} model {mv:016x}")
            ok = False
        # every PDM / DRAM chunk the model used is inside the windows the testbench fills
        inside = []
        for kind, g, c16 in sorted(st.touched):
            aa = c16 * 16
            if kind == "D":
                inwin = any(w <= aa < w + n for w, n in d.windows(x))
            else:
                inwin = aa < PN or any(w <= aa < w + n for w, n in x.pwin)
            if not inwin:
                inside.append((kind, aa))
        if inside:
            print(f"{x.name}: PDM / DRAM used outside the filled windows: {inside[:6]}")
            ok = False
        else:
            note = " model ok"
        # the test
        out.append(f"# {x.name}: {' | '.join(x.body)}" + (f"  edits {x.edits}" if x.edits else "") +
                   (f"  stop {x.stop}" if x.stop else "") + (f"  ({x.note})" if x.note else ""))
        out += d.fills(x)
        for k, b in words:
            out.append(f"{'J' if k == 'j' else 'M'} {int(b, 2):0{107 if k == 'j' else 21}x}")
        out.append("R {} {:x} {} {}".format(*stoprec))
        # the first block of every memory / window through the host port (K; for the SDRAM this
        # also waits for the requests before it), the others through the backdoor (B)
        mems = [(7, "L2BM", "n0c0", 0, L2N)] + [(9, "DRAM", "n0", wa, n) for wa, n in d.windows(x)] + \
               [(6, "L1BM", "n0c0b0", 0, L1N)]
        for sp, space, loc, wa, n in mems:
            for blk in range(wa, wa + n, 64):
                hh = hash64([dump.get((space, loc, aa), 0) for aa in range(blk, blk + 64)])
                out.append(f"{'K' if blk == wa else 'B'} {sp} {blk:x} {hh:016x}")
        out.append("E")
        print(f"{x.name}: {len(words)} words, stop {stoprec}{note}")
    dst = (BUILD if a.only else FIXED) / "mv.tst"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"-> {dst} ({len(allt)} tests, {time.time() - t0:.0f} s)")
    print("OK" if ok else "SOME TESTS ARE NOT VALID")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

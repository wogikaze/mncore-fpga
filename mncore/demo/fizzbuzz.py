#!/usr/bin/env python3
"""fizzbuzz.py: FizzBuzz on the Tang Nano 20K (WP41), problem 23.fizzbuzz-pe of the MN-Core 2 challenge.

  python mncore/demo/fizzbuzz.py                    # the challenge solution on 4 PEs, numbers 1..32
  python mncore/demo/fizzbuzz.py --program int      # an integer-only solution on 64 PEs, numbers 1..512
  python mncore/demo/fizzbuzz.py --input testcase   # the problem's testcase (random numbers)
  python mncore/demo/fizzbuzz.py --no-official      # without the official tools (WSL)
  python mncore/demo/fizzbuzz.py --dry-run          # prepare and plan only

The problem: each PE has 8 unsigned 32-bit numbers in its LM0; write them to the LM1 with multiples of
15 replaced by 0xFFFFBBBB ("FizzBuzz"), other multiples of 3 by 0x0000FFFF ("Fizz") and other multiples of
5 by 0x0000BBBB ("Buzz"). Every PE works on its own numbers, so the PEs of the board give the same LM1 as
those PEs of the 4096-PE official emulator.

--program pe (default): problems/challenge/23.fizzbuzz-pe/main.vsm (9 words). It uses the MAU (fvmul,
  fvadd) and the L1BM (l1bmd) in the same words, so mnrun.py runs it on the member L1MAU of the bitstream
  set (mncore/fpga/multi: L1BM + MAU in one bitstream, one MAB = 4 PEs).
--program int: demo/programs/fizzbuzz_int.vsm (27 words, written for this demo): the same problem with
  the integer ALU only (sum of the hexadecimal digits for the remainder by 15, a bit table for 3 / 5 / 15,
  masked writes). It runs on V64, the virtual-PE design of WP34 (mncore/fpga/top_vpe, design 0x06):
  16 MABs = 64 PEs whose state lives in the SDRAM.

--input seq (default) gives the PEs the numbers 1..32768 in the index order of the problem (PE
n0c0b0m0p0 gets 1..8, p1 9..16, ...), so the board prints FizzBuzz for 1..32 (4 PEs) or 1..512 (64
PEs). --input testcase uses the problem's testcase. The LM1 that the board read is checked against the
official emulator (gpfn3_package_main in WSL, or its output recorded in demo/programs/) and against
FizzBuzz computed in Python.
"""
from __future__ import annotations

import argparse
import itertools
import sys
import textwrap
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import demolib as dl  # noqa: E402
import mnhost  # noqa: E402

FB = dl.ROOT / "third_party" / "mncore" / "problems" / "challenge" / "23.fizzbuzz-pe"
VSM_HERE = "# ======= YOUR VSM WILL BE INSERTED HERE ======="
LABEL = {0xFFFFBBBB: "FizzBuzz", 0x0000FFFF: "Fizz", 0x0000BBBB: "Buzz"}
PES = list(itertools.product(range(4), range(2), range(8), range(16), range(4)))   # n c b m p (p fastest)
PROGRAMS = {
    # name: (solution, committed machine code stem, how it runs)
    "pe": (FB / "main.vsm", "fizzbuzz_pe", "multi"),
    "int": (dl.PROGRAMS / "fizzbuzz_int.vsm", "fizzbuzz_int", "V64"),
}


def seq_testcase() -> str:
    """A testcase like the problem's, with the numbers 1..32768 (index order of the problem)."""
    lines = ["# ======= In(0): ((8_L2B:1, 8_L1B:1, 16_MAB:1, 4_PE:1, 4:1, 2_W:1))@LM0 / UInt, "
             "the numbers 1..32768 (mncore/demo/fizzbuzz.py) ======="]
    for lin, (n, c, b, m, p) in enumerate(PES):
        for k in range(4):
            v = 8 * lin + 2 * k + 1
            lines.append(f"d set $lm{2 * k}n{n}c{c}b{b}m{m}p{p} 1 {v:08X}{v + 1:08X}")
    lines.append(VSM_HERE)
    lines.append("# ======= Out(0): ((8_L2B:1, 8_L1B:1, 16_MAB:1, 4_PE:1, 4:1, 2_W:1))@LM1 / UInt =======")
    for n, c, b, m, p in PES:
        for k in range(4):
            lines.append(f"d getd $ln{2 * k}n{n}c{c}b{b}m{m}p{p} 1")
    return "\n".join(lines) + "\n"


def inputs_of(testcase: str) -> dict:
    """(loc, long word of LM0) -> value, from the d set lines of the testcase."""
    out = {}
    for raw in testcase.split(VSM_HERE, 1)[0].splitlines():
        if raw.startswith("d set $lm"):
            d = mnhost.parse_dline(raw)
            loc = "".join(f"{k}{d.loc[k]}" for k in "ncbmp")
            for (lw, v, _m) in mnhost.long_words(d):
                out[(loc, lw)] = v
    return out


def fizzbuzz(x: int) -> int:
    return 0xFFFFBBBB if x % 15 == 0 else 0x0000FFFF if x % 3 == 0 else 0x0000BBBB if x % 5 == 0 else x


def label(w: int) -> str:
    return LABEL.get(w, str(w))


def pe_order(loc: str) -> tuple:
    f = dl.ndmp.loc_parts(loc)
    return tuple(f.get(k, 0) for k in "ncbmp")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--program", choices=sorted(PROGRAMS), default="pe",
                    help="pe: the challenge solution on 4 PEs (default); int: integer-only on 64 PEs (V64)")
    ap.add_argument("--input", choices=["seq", "testcase"], default="seq",
                    help="the numbers: 1, 2, 3, ... (seq, default) or the problem's testcase")
    dl.common_args(ap)
    a = ap.parse_args(argv)
    out = dl.Out(a.log)
    try:
        return run(a, out)
    finally:
        out.close()


def run(a, out: dl.Out) -> int:
    t_all = time.monotonic()
    solution, stem, how = PROGRAMS[a.program]
    rule = "zero"            # the PEs do not exchange data: the rule of the missing units does not matter
    out(f"== FizzBuzz (23.fizzbuzz-pe) on the Tang Nano 20K ({time.strftime('%Y-%m-%d %H:%M:%S')}) ==")
    tc = seq_testcase() if a.input == "seq" else (FB / "testcase.vsm").read_text(encoding="utf-8")
    demo = dl.Demo(f"{stem}_{a.input}", solution, tc, asm_name=stem)
    out(f"program   {dl.rel(demo.solution)}, input: "
        + ("the numbers 1..32768 (8 per PE)" if a.input == "seq" else f"{dl.rel(FB / 'testcase.vsm')}"))

    # 1. the program and the official result
    t0 = time.monotonic()
    p = dl.prepare(demo, out, use_official=not a.no_official, update=a.update)
    out(f"          {p.words} words (assemble3 flat, no packer); reference: {p.official_src} "
        f"({time.monotonic() - t0:.1f} s)")
    for n in p.notes:
        out(f"          {n}")

    # 2. the bitstreams
    if how == "multi":
        need, plan = dl.needed_members(p.asm_text, rule)
        out("plan      " + ", ".join(f"words {s.a}-{s.b - 1} on {s.member.name} ({'+'.join(sorted(s.member.caps))})"
                                     for s in plan.segments))
        if not plan.complete:
            out(f"          the plan is incomplete: {plan.problem}")
    else:
        need = [dl.V64]
        out(f"plan      words 0-{p.words - 1} on V64 (mncore/fpga/top_vpe: 16 MABs = 64 PEs in the SDRAM, "
            f"integer ALU, design 0x06)")
    dl.ensure_bitstreams(need, out, build=not a.no_build, report_only=a.dry_run)
    if a.dry_run:
        out("dry run: the board is not used")
        return 0

    # 3. the board
    if not dl.detect_board():
        out("RESULT: PENDING (openFPGALoader --detect finds no Tang Nano 20K)")
        return 3
    with dl.BoardLock("WP41 demo fizzbuzz.py", out, force=a.force_lock):
        if how == "multi":
            br = dl.run_board(p.asm_text, rule, out, a.port, a.baud, a.verbose, reuse=a.reuse)
        else:
            br = dl.run_board_single(p.asm_text, dl.V64, dl.VPE_DESIGN, out, a.port, a.baud, a.verbose)
    out(f"board     {dl.describe_segments(br.segments)}")
    out(f"          {dl.timing_line(br)}")
    st = dl.stop_text(br)
    if st:
        out(f"RESULT: FAIL (the board stopped: {st})")
        return 2

    # 4. the output: LM1 of every PE the board has, two numbers per long word (MSB half first)
    ins = inputs_of(tc)
    res = []                                       # (loc, element, input, board, reference)
    for (space, loc, lw), v in sorted(br.records.items(), key=lambda kv: (pe_order(kv[0][1]), kv[0][2])):
        if space != "LM1":
            continue
        x = ins.get((loc, lw), 0)
        for half, (xi, vi) in enumerate(((x >> 32, v >> 32), (x & 0xFFFFFFFF, v & 0xFFFFFFFF))):
            res.append((loc, 2 * lw + half, xi, vi, fizzbuzz(xi)))
    if not res:
        out("RESULT: FAIL (the board returned no LM1)")
        return 1
    locs = sorted({r[0] for r in res}, key=pe_order)
    out("")
    if a.input == "seq":
        out(f"  FizzBuzz {res[0][2]}..{res[-1][2]} from the LM1 of the {len(locs)} PEs ({locs[0]}..{locs[-1]}):")
        for line in textwrap.wrap(" ".join(label(r[3]) for r in res), 96):
            out("    " + line)
    else:
        out(f"  the numbers of the testcase and the board's LM1 ({len(locs)} PEs; \"n=Fizz\" where the board "
            f"replaced n, \"n\" where it kept it):")
        for loc in locs:
            row = [r for r in res if r[0] == loc]
            out(f"    {loc}: " + " ".join(f"{r[2]}" if r[3] == r[2] else f"{r[2]}={label(r[3])}" for r in row))
    out("")

    # 5. the checks
    bad_ref = [r for r in res if r[3] != r[4]]
    out(f"Python    FizzBuzz of the inputs: {len(res) - len(bad_ref)} of {len(res)} numbers as the board")
    for r in bad_ref[:8]:
        out(f"            {r[0]} [{r[1]}]: input {r[2]}, board {r[3]:#010x}, expected {r[4]:#010x}")
    n, diff = dl.compare(br.records, p.official)
    if p.official is not None:
        out(f"official  {p.official_src}: " + (f"the board equals it ({n} of {n} long words of LM1)" if not diff
                                              else f"{len(diff)} of {len(br.records)} long words differ"))
        for k, b, o in diff[:8]:
            out(f"            {k[0]} {k[1]} {k[2]:#x}: board {b:016x}, official "
                + (f"{o:016x}" if o is not None else "-"))
    else:
        out("official  (not compared: no official tools and no recorded output)")
    out(f"total     {time.monotonic() - t_all:.1f} s")
    ok = not bad_ref and not diff
    out(f"RESULT: {'PASS' if ok else 'FAIL'} ({len(res)} numbers on {len(locs)} PEs"
        f"{', as the official emulator and Python' if ok and p.official else ''})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

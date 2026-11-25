#!/usr/bin/env python3
"""hello.py: the official hello_world of the MN-Core 2 challenge on the Tang Nano 20K (WP41).

  python mncore/demo/hello.py                 # assemble, build missing bitstreams, run, print
  python mncore/demo/hello.py --no-official   # without the official tools (WSL): committed machine code
  python mncore/demo/hello.py --dry-run       # prepare and plan only

The program is problems/challenge/21.hello-world/main.vsm, assembled by assemble3 (flat, no packer)
as the judge does. Its words 1..2 use the MAU and its words 4..8 the L1BM / L2BM reductions and an MV
transfer to the DRAM, which no single bitstream holds, so mnrun.py runs words 0..3 on the member MAU
and 4..8 on M2aR, handing the PE state over (mncore/fpga/multi). The reduced board has one MAB of the
chip's 2048; with the replica rule (contract 06 section 3, `--rule replica`, the default) the missing
MABs / L1Bs repeat the implemented one, and the DRAM of group 0 gets "Hello, world!" like on the
4096-PE official emulator. With `--rule zero` they are 0 and the reductions give other bytes.

The demo reads DRAM n0 long words 0..1 (the d get lines of the testcase), prints them as text and
compares them with the official emulator (gpfn3_package_main in WSL, or the output recorded in
demo/programs/ when the official tools are not there).
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import demolib as dl  # noqa: E402

HELLO = dl.ROOT / "third_party" / "mncore" / "problems" / "challenge" / "21.hello-world"
EXPECT = "Hello, world!"
# DRAM n0 [0..1] of the reduced-topology Rust simulator with the zero rule (mncore/status/WP-37.md, WP-38.md)
ZERO_RULE_RUST = [0x3A655E6C612C1277, 0x61725E64132AF362]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rule", choices=["replica", "zero"], default="replica",
                    help="units missing in the reduced topology: copies of the implemented ones (replica, "
                         "default) or zeros")
    dl.common_args(ap)
    a = ap.parse_args(argv)
    out = dl.Out(a.log)
    try:
        return run(a, out)
    finally:
        out.close()


def run(a, out: dl.Out) -> int:
    t_all = time.monotonic()
    out(f"== hello_world on the Tang Nano 20K ({time.strftime('%Y-%m-%d %H:%M:%S')}) ==")
    demo = dl.Demo("hello", HELLO / "main.vsm", (HELLO / "testcase.vsm").read_text(encoding="utf-8"))
    out(f"program   {dl.rel(demo.solution)} with its testcase")

    # 1. the program and the official result
    t0 = time.monotonic()
    p = dl.prepare(demo, out, use_official=not a.no_official, update=a.update)
    out(f"          {p.words} words (assemble3 flat, no packer); reference: {p.official_src} "
        f"({time.monotonic() - t0:.1f} s)")
    for n in p.notes:
        out(f"          {n}")

    # 2. the members and their bitstreams
    need, plan = dl.needed_members(p.asm_text, a.rule)
    out(f"plan      rule {a.rule}: " + ", ".join(f"words {s.a}-{s.b - 1} on {s.member.name} "
                                                  f"({'+'.join(sorted(s.member.caps))})" for s in plan.segments))
    if not plan.complete:
        out(f"          the plan is incomplete: {plan.problem}")
    dl.ensure_bitstreams(need, out, build=not a.no_build, report_only=a.dry_run)
    if a.dry_run:
        out("dry run: the board is not used")
        return 0

    # 3. the board
    if not dl.detect_board():
        out("RESULT: PENDING (openFPGALoader --detect finds no Tang Nano 20K)")
        return 3
    with dl.BoardLock("WP41 demo hello.py", out, force=a.force_lock):
        br = dl.run_board(p.asm_text, a.rule, out, a.port, a.baud, a.verbose, reuse=a.reuse)
    out(f"board     {dl.describe_segments(br.segments)}")
    out(f"          {dl.timing_line(br)}")
    st = dl.stop_text(br)
    if st:
        out(f"RESULT: FAIL (the board stopped: {st})")
        return 2

    # 4. the output
    keys = sorted(k for k in br.records if k[0] == "DRAM")
    vals = [br.records[k] for k in keys]
    text = dl.ascii_of(vals, len(EXPECT))
    out("")
    out(f"  DRAM {keys[0][1]} [0..{len(keys) - 1}]  {dl.hexwords(vals)}")
    out(f"  first {len(EXPECT)} bytes as text:  \"{text}\"")
    out("")
    n, diff = dl.compare(br.records, p.official)
    ok = True
    if p.official is not None:
        ov = [p.official.get(k) for k in keys]
        otext = dl.ascii_of([v or 0 for v in ov], len(EXPECT))
        out(f"official  DRAM {keys[0][1]} [0..{len(keys) - 1}]  "
            + " ".join(f"{v:016x}" if v is not None else "-" for v in ov) + f"  \"{otext}\"")
        if diff:
            ok = False
            out(f"          {len(diff)} of {len(br.records)} long words differ from the official emulator:")
            for k, b, o in diff[:8]:
                out(f"            {k[0]} {k[1]} {k[2]:#x}: board {b:016x}, official {o:016x}" if o is not None
                    else f"            {k[0]} {k[1]} {k[2]:#x}: not in the official output")
        else:
            out(f"          the board equals the official emulator ({n} of {n} long words)")
    else:
        out("official  (not compared: no official tools and no recorded output)")
    out(f"total     {time.monotonic() - t_all:.1f} s")
    if a.rule == "zero":
        same = vals == ZERO_RULE_RUST
        out(f"reduced   the Rust simulator on the reduced topology (zero rule, WP37 / WP38 reports): "
            f"{dl.hexwords(ZERO_RULE_RUST)} -> {'the board equals it' if same else 'the board DIFFERS'}")
        out("RESULT: " + ("PASS" if same else "FAIL") + " (zero rule: the missing MABs / L1Bs add zeros to the "
            "reductions, so the bytes are not \"Hello, world!\" as on the 4096-PE official emulator)")
        return 0 if same else 1
    if text != EXPECT:
        ok = False
    out(f"RESULT: {'PASS' if ok else 'FAIL'} (\"{text}\"{', as the official emulator' if ok and p.official else ''})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

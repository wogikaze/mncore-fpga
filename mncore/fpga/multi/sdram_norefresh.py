#!/usr/bin/env python3
"""How long does the embedded SDRAM keep its content without any refresh? (WP38)

  python mncore/fpga/multi/sdram_norefresh.py --other <a bitstream without the SDRAM controller>
         [--seconds 10,60] [--words 65536] [--set mncore/fpga/multi/set.json] [--member M2a]

Loads the member (mn_top_multi with the SDRAM), RESET, writes a pseudo-random pattern into the DRAM (the
first and the last --words long words) and the PDM (the first --words), loads --other (a design that
does not drive the SDRAM: no refresh, no self refresh), waits, loads the member back (its controller
initialises the SDRAM: PRECHARGE, AUTO REFRESH, MRS) and counts the long words and bits that differ.
mnrun.py sdram-hold does the same through a member of the set (a member with the SDRAM keeps refreshing,
one without it puts the SDRAM into self refresh). Take the board lock first.
"""
from __future__ import annotations

import argparse
import random
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
import mnhost  # noqa: E402
import mnplan  # noqa: E402
import mnrun  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--other", required=True)
    ap.add_argument("--seconds", default="10,60")
    ap.add_argument("--words", type=int, default=65536)
    ap.add_argument("--set", default=str(mnplan.SET_JSON))
    ap.add_argument("--member", default="M2a")
    ap.add_argument("--log")
    a = ap.parse_args(argv)
    logf = open(a.log, "a", encoding="utf-8") if a.log else None

    def log(s):
        print(s, flush=True)
        if logf:
            logf.write(s + "\n")
            logf.flush()

    m = next(x for x in mnplan.load_set(Path(a.set)) if x.name == a.member)
    board = mnrun.Board([m], log=log)
    rng = random.Random(1)
    bad_all = 0
    for sec in [float(s) for s in a.seconds.split(",")]:
        board.load(m)
        dev = board.dev
        dev.reset()
        ranges = [("DRAM", 0), ("DRAM", (1 << 19) - a.words), ("PDM", 0)]
        pats = {}
        for sp, base in ranges:
            pats[(sp, base)] = [rng.getrandbits(64) for _ in range(a.words)]
            dev.write(mnhost.SPACES[sp], 0, base, pats[(sp, base)], window=mnrun.WINDOW)
        board.close()
        t0 = time.monotonic()
        r = subprocess.run(["openFPGALoader", "-b", "tangnano20k", a.other], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stdout + r.stderr)
        time.sleep(sec)
        board.load(m)
        dt = time.monotonic() - t0
        bad = 0
        for sp, base in ranges:
            got = board.dev.read(mnhost.SPACES[sp], 0, base, a.words, window=mnrun.WINDOW)
            e = sum(1 for x, y in zip(got, pats[(sp, base)]) if x != y)
            bits = sum(bin(x ^ y).count("1") for x, y in zip(got, pats[(sp, base)]))
            bad += e
            log(f"#   {sp} {base:#x} +{a.words}: {e} long words differ ({bits} bits)")
        bad_all += bad
        log(f"# {'PASS' if not bad else 'FAIL'}: {3 * a.words} long words, {dt:.1f} s without refresh "
            f"({Path(a.other).name} loaded, {sec} s waited)")
    board.close()
    return 1 if bad_all else 0


if __name__ == "__main__":
    sys.exit(main())

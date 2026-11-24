#!/usr/bin/env python3
"""WP31: when does the official emulator update $lbf? (backs the report's open point 1)

    python mncore/sim/tb/l1bm/probe_lbf.py

Program: l1bmm $lb16 $lr0v / nop / X / nop / (lpassa $lr8v $ls0v edited to read $lbf).
The assembler rejects reading $lbf after a word without an L1BM -> PE transfer, so the last
word is edited after assembly (isela = 13), and X is an ALU word with one L1BM field set by hand.
Printed: which L1BM long word PE m0p1 got in cycle 0 through $lbf. L1BM[17] means $lbf kept the
l1bmm data (16 + p); L1BM[0] means X loaded it with its implicit l1bmp $lb0 read.
Official result (2026-11-25): every X, also the one without any L1BM field (z1), gives L1BM[0]
or the read of its own fields; the RTL keeps $lbf in z1 (rtl/l1bm/README.md).
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from l1prog import Prog, run  # noqa: E402

BASE = ["l1bmm $lb16 $lr0v", "nop", "ipassa $r0v $r40v", "nop", "lpassa $lr8v $ls0v"]
READ_LBF = (4, {"pe_aluc_isela": 13})
CASES = {
    "z0_no_word": None,
    "z1_alu_only": {},
    "z2_ladr": {"l1bm_ladr": 40},
    "z4_me": {"l1bm_me": 1},
    "z5_bmode": {"l1bm_bmode": 1},
    "z8_dest_isel10": {"pe_rfc1_write": 1, "pe_rfc1_isel": 2, "pe_rfc1_wwl": 1, "pe_rfc1_wadr": 40,
                       "pe_rfc1_wadr_c1": 42, "pe_rfc1_wadr_c2": 44, "pe_rfc1_wadr_c3": 46},
}


def main() -> int:
    progs = []
    for name, ch in CASES.items():
        if ch is None:
            progs.append(Prog(name, ["l1bmm $lb16 $lr0v", "nop", "lpassa $lr8v $ls0v"],
                              edits=[(2, {"pe_aluc_isela": 13})]))
        else:
            progs.append(Prog(name, BASE, edits=([(2, ch)] if ch else []) + [READ_LBF]))
    res = run(progs, HERE / "build" / "probe_lbf")
    for p in progs:
        r, _ini, _w = res[p.name]
        if r.asm_err or not r.ok:
            print(f"{p.name}: failed {r.asm_err or r.emu_out[-200:]}")
            continue
        v = r.dump.get(("GRF1", "n0c0b0m0p1", 0))
        who = [a for a in range(48) if r.dump.get(("L1BM", "n0c0b0", a)) == v]
        print(f"{p.name}: $lbf of m0p1 cycle 0 = L1BM{who}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

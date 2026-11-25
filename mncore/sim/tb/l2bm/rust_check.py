#!/usr/bin/env python3
"""WP32: the L2BM programs where the Rust Sim (viz/core) and the official emulator differ.

    python mncore/sim/tb/l2bm/rust_check.py [--exe path/to/golden_dump.exe] [--reuse]

Runs a few programs (l2prog.Prog, the same text) on the official tools and on the Rust Sim
(WP02's golden_dump, which runs viz/core on a .vsm and prints ndmp lines), and compares the L2BM
of n0c0 and the L1BMs of n0c0b0..b7 (and the PEs of n0c0b0m0 for tests with PEs). The DAR is
compared through the DAR observer (l2prog.dar_lines), on both. Contract section 1: the RTL
follows the official emulator; the differences are reported, the Rust Sim is not changed.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
import l2prog as LP  # noqa: E402
from l2prog import Prog  # noqa: E402

BUILD = HERE / "build"

PROGS = [
    # the order of the L1BM writes within a word (the official: per cycle, PE side first)
    Prog("x_ww_l2_first", ["l2bmb $lc64 $lb16; l1bmm@0 $lr0v $lb16"], pes=True),
    Prog("x_ww_pe_first", ["l1bmm@0 $lr0v $lb16; l2bmb $lc64 $lb16"], pes=True),
    Prog("x_ww_m4", ["l2bmb $lc64 $lb32; l1bmm4@0 $lr0v $lb16"], pes=True),
    # a run of l2bmdars words keeps the DAR addresses and the L2B of its first word
    Prog("x_dars_consec", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
         data="dar", dar=(0, 8)),
    Prog("x_dars_consec_b", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
         data="dar", dar=(96, 8)),
    Prog("x_dars_sep", ["l2bmdars $lc0@.0 $dar0; l2bmdarw", "nop", "l2bmdars $lc64@.0 $dar100; l2bmdarw"],
         data="dar", dar=(96, 8)),
    # forms where both agree (a check of the comparison)
    Prog("x_bcast", ["l2bmb@[0,4] $lc64 $lb128", "nop/2", "l2bmb2 $lc128 $lb256", "nop/2", "l2bmd $lc256 $lb512"],
         l1bs=8),
    Prog("x_reduce", ["l2bmrliadd@[0,4] $lb64 $lc256", "nop/3", "l2bmr2sband $lb128 $lc512", "nop/3",
                      "l2bmriand@1/6 $lb128 $lc1024"], l1bs=8, data="int"),
    Prog("x_imcast", ["l2bmi@0/4 $lb64 $lb128", "nop/3", "l2bmi@1/2 $lb128 $lb512"], l1bs=8),
]


def rust_dump(exe: Path, text: str):
    import ndmp
    r = subprocess.run([str(exe), "-"], input=text.encode("utf-8"), capture_output=True, timeout=1800)
    if r.returncode != 0:
        return None, r.stderr.decode("utf-8", "replace")[-400:]
    out = {}
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        if not line or line.startswith("#"):
            continue
        sp, loc, ad, v = ndmp.parse_line(line)
        out[(sp, loc, ad)] = v
    return out, ""


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", type=Path, default=ROOT / "mncore" / "golden_rs" / "target" / "release" / "golden_dump.exe")
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args(argv)
    if not a.exe.exists():
        sys.exit(f"no {a.exe}: build it with `cargo build --release --manifest-path mncore/golden_rs/Cargo.toml`")
    plain = [p for p in PROGS if not p.dar]
    dars = [p for p in PROGS if p.dar]
    res = LP.run(plain, BUILD / "rust_off", reuse=a.reuse)
    dres = LP.run(dars, BUILD / "rust_off_dar", reuse=a.reuse, observe_dar=True)
    for p in PROGS:
        ini = LP.Init(p)
        text = LP.vsm_of(p, ini, observe_dar=bool(p.dar))
        off = (dres if p.dar else res)[p.name][0]
        rd, err = rust_dump(a.exe, text)
        if rd is None:
            print(f"{p.name}: Rust Sim error {err.strip()}")
            continue
        if p.dar:
            o, r = LP.dar_of(off.dump, *p.dar), LP.dar_of(rd, *p.dar)
            print(f"{p.name}: DAR[{p.dar[0]}..] official {o} rust {r} -> {'same' if o == r else 'DIFFERENT'}")
            continue
        keys = [k for k in off.dump if (k[0] == "L2BM" and k[1] == "n0c0" and k[2] < LP.L2) or k[0] == "L1BM" or
                (p.pes and k[1].startswith("n0c0b0m0p"))]
        bad = [k for k in keys if rd.get(k, 0) != off.dump[k]]
        print(f"{p.name}: {len(keys)} long words, {len(bad)} different" +
              (f" (first {bad[0]}: official {off.dump[bad[0]]:016x} rust {rd.get(bad[0], 0):016x})" if bad else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

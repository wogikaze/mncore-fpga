#!/usr/bin/env python3
"""WP33: MV programs on the Rust Sim (viz/core) and on the official emulator.

    python mncore/sim/tb/mv/rust_check.py [--exe path/to/golden_dump.exe] [--reuse]

Runs a few MV programs (the same .vsm text) on the official tools and on the Rust Sim (WP02's
golden_dump, which runs viz/core on a .vsm and prints ndmp lines) and compares the L2BM of n0c0
and the DRAM of group 0 (the official `d get $p` shows the DRAM, so the PDM is seen through DRAM
copies). Contract section 1: the RTL follows the official emulator; the differences are reported,
the Rust Sim is not changed.
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
from mvemu import rline, run  # noqa: E402

BUILD = HERE / "build"
EXE = Path(r"C:\wgkz\nano20k\mncore\golden_rs\target\release\golden_dump.exe")


def dval(a):
    return 0xD000000000000000 | a


def dar_long(i):
    # DAR entries 2i, 2i + 1: (7 e + 5) % 40 (DRAM chunks 0..39)
    return (((14 * i + 5) % 40) << 32) | ((14 * i + 12) % 40)


def prog(body):
    out = rline(0, 0, [dval(a) for a in range(1024)])
    out.append("d set $lc0n0c0 32 " + "".join(f"{dar_long(i):016x}" for i in range(32)))
    out.append("d set $lc512n0c0 256 " + "".join(f"{0xC000000000000000 | a:016x}" for a in range(256)))
    out += ["l2bmdars $lc0@.0 $dar0; l2bmdarw"] + ["l2bmdarw"] * 15 + ["nop/3"]
    out += body + ["nop/3", "d get $lc0n0c0 1024", "d get $d0n0 1024", "d get $d4096n0 1024"]
    return "\n".join(out) + "\n"


PROGS = {
    # indirect without nd: the official uses DAR[M] + i (N infinite); viz/core DAR[(M + i) % 1024] + 0
    "x_nd0_read": ["mvp/n128 $di8@0 $lc256@0.0"],
    "x_nd0_write": ["mvp/n128 $lc512@0.0 $di8@0"],
    "x_nd0_mvb": ["mvb/n128 $di8 $lc256"],
    # with nd both agree
    "x_nd2": ["mvp/n128nd2 $di8@0 $lc256@0.0", "mvp/n128nd3 $lc512@0.0 $di12@0"],
    # direct forms (a check of the comparison)
    "x_direct": ["mvp/n128 $d64@0 $lc256@0.0", "mvp/n64 $lc512@0.0 $p0@0", "mvp/n64 $p0@0 $d4096@0",
                 "mvb2/n64 $d128 $lc640", "mvrliadd/n64 $lc512 $d4160"],
    # PDM -> PDM over the same range (all reads before the writes)
    "x_overlap": ["mvp/n256 $d0@0 $p0@0", "mvp/n256 $p0@0 $p64@0", "mvp/n512 $p0@0 $d4096@0"],
}


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
    ap.add_argument("--exe", default=str(EXE))
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args(argv)
    texts = {n: prog(b) for n, b in PROGS.items()}
    res = run(texts, BUILD / "rust_check", jobs=8, reuse=a.reuse)
    for n, t in texts.items():
        r = res[n]
        if not r.ok:
            print(f"{n}: official failed: {r.asm_err[-200:] or r.emu_out[-200:]}")
            continue
        rd, err = rust_dump(Path(a.exe), t)
        if rd is None:
            print(f"{n}: rust failed: {err}")
            continue
        keys = [k for k in r.dump if k[0] in ("L2BM", "DRAM")]
        bad = [k for k in keys if rd.get(k, 0) != r.dump[k]]
        print(f"{n}: {len(keys)} long words, {len(bad)} different" + (" -> DIFFERENT" if bad else ""))
        for k in bad[:4]:
            print(f"    {k[0]} {k[1]} {k[2]:#x}: official {r.dump[k]:016x} rust {rd.get(k, 0):016x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

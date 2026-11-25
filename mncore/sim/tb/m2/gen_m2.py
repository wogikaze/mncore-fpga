#!/usr/bin/env python3
"""Make the directed test script of the unit m2 (WP37): mncore/sim/tb/m2/fixed/<name>.scr.

    python mncore/sim/tb/m2/gen_m2.py              # fixed/all.scr: the zero rule (unit m2)
    python mncore/sim/tb/m2/gen_m2.py --replica    # fixed/replica.scr: the replica rule (unit m2_rep)
    python mncore/sim/tb/m2/gen_m2.py [--list FILE] [--out FILE]

The programs (default: LIST below, or LIST_REPLICA with --replica) are corpus programs of the M2
regression (`python mncore/sim/regress/run.py --m2` must have run: build/m2/<name>/ holds rtl.scr, the
tb_core script of the program, official.ndmp and rust.ndmp) or directed programs directed/<name>.vsm
(standalone programs with their own d set / d get lines; m2_try.prepare() runs the official emulator and
the Rust simulator for them in build/directed/<name>/, WSL). For each program the script is its rtl.scr
(RESET, IMEM, WR_MEM of the d set / r lines, RUNs split at the d lines) without its R reads, followed by K
(the stop record of the last RUN: OK) and Q checks of the final state against the reference:
  - the official emulator (4096 PEs, cut to the implemented units) when the program is "closed": the
    official equals the Rust simulator on the reduced topology (pass b), or with --replica;
  - else the Rust simulator on the reduced topology (the zero rule, contract 06 section 3 (a)).
The checks of a corpus program are the long words of the M2 probe: GRF0 / GRF1 / LM0 / LM1 (256 long
words) of PEs p0..p3, T, OMR 1..15, L1BM n0c0b0 (1024), L2BM n0c0 (2048) and DRAM n0 (the first 256 long
words and every non-zero one below 8192); those of a directed program are its d get records. PDM is not
checked (the official d get $p shows the DRAM).
tb_core prints PASS when every Q matches (mncore/tools/simrun.py m2).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(HERE))
import run as regress  # noqa: E402
import ndmp  # noqa: E402
import m2_try  # noqa: E402

regress.configure(4, m2=True)

# zero rule: hello_world (the M2 goal; the reference is the reduced Rust run), closed L1BM / L2BM / MV
# programs of the regression (official = Rust = RTL) and the directed programs
LIST = [
    # the zero rule differs from the official (reductions / gathers over the absent MABs, L1Bs)
    "problems/challenge/21.hello-world/main.vsm",       # l1bmrhfadd, l2bmrhfadd, mvp
    "problems/8.sumcol/answer.vsm",                     # L1BM / L2BM reductions, MV
    "research/experiments/isa-analyst/progs/e2_l1bmd_extent.vsm",   # l1bmd
    "problems/25.dram-ul-16/main.vsm",                  # DRAM -> PDM -> L2BM -> L1BM -> PE
    # closed: the official = the reduced Rust run
    "proofs_lean/evidence/lbf-encoded/08-producer-new/intended.vsm",  # $lbf
    "proofs_lean/evidence/forwarding/programs/36-lbf-noforward-alu.vsm",
    "research/experiments/isa-analyst/progs/t_mvp.vsm",
    "research/experiments/isa-analyst/progs/t_l2bm_dram.vsm",
    "problems/24.dram-dl-16/main.vsm",
    "problems/29.dram-ul-16-16/answer.vsm",
    "problems/challenge/23.fizzbuzz-pe/main.vsm",
    "problems/21.dram-dl-256-16-l2b/main.vsm",
    # directed (WP37): isel 111 = $lbf (official), the L1BM / L2BM reduction and gather forms
    "directed/lbf_src.vsm",
    "directed/replica_forms.vsm",
]
# replica rule: the official emulator is the reference of every program
LIST_REPLICA = [
    "problems/challenge/21.hello-world/main.vsm",
    "directed/replica_forms.vsm",
]

SP = {"LM0": 0x01, "LM1": 0x02, "GRF0": 0x03, "GRF1": 0x04, "T": 0x05, "L1BM": 0x06, "L2BM": 0x07,
      "DRAM": 0x09, "OMR": 0x10}


def loc_code(loc: str) -> int:
    f = dict.fromkeys("ncbmp", 0)
    k = None
    num = ""
    for ch in loc + "x":
        if ch.isalpha():
            if k is not None:
                f[k] = int(num)
            k, num = ch, ""
        else:
            num += ch
    return (f["n"] << 10) | (f["c"] << 9) | (f["b"] << 6) | (f["m"] << 2) | f["p"]


def checks(ref: dict) -> list[str]:
    """Q lines (space, loc, long word address, value) of the probe records of the reference."""
    out = []
    omr: dict = {}
    for (space, loc, addr), v in sorted(ref.items()):
        if not regress.keep_record((space, loc, addr)):
            continue
        if space == "OMR":
            e, c = divmod(addr, 4)
            if 1 <= e <= 15:
                omr.setdefault((loc, e), {})[c] = v
            continue
        if space not in SP:
            continue          # word access records (LM0W ...): the long words cover them
        if space == "DRAM" and addr >= 256 and v == 0:
            continue
        out.append(f"Q {SP[space]:x} {loc_code(loc):x} {addr:x} {v:x}")
    for (loc, e), nib in sorted(omr.items()):
        if len(nib) == 4:
            out.append(f"Q {SP['OMR']:x} {loc_code(loc):x} {e:x} {sum(nib[c] << (4 * c) for c in range(4)):x}")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", help="programs (corpus paths), one per line")
    ap.add_argument("--out")
    ap.add_argument("--replica", action="store_true", help="the replica rule: the official is the reference")
    a = ap.parse_args(argv)
    if not a.out:
        a.out = str(HERE / "fixed" / ("replica.scr" if a.replica else "all.scr"))
    paths = LIST_REPLICA if a.replica else LIST
    if a.list:
        paths = [ln.split("#", 1)[0].strip() for ln in Path(a.list).read_text(encoding="utf-8").splitlines()]
        paths = [p for p in paths if p]
    out = [f"# WP37 unit m2 ({'replica' if a.replica else 'zero'} rule): made by gen_m2.py from the M2 regression"]
    for p in paths:
        if p.startswith("directed/"):
            vsm = HERE / p
            job = HERE / "build" / "directed" / vsm.stem
            scr = job / "rtl.scr"
            if not scr.exists() or scr.stat().st_mtime < vsm.stat().st_mtime:
                if m2_try.prepare(vsm, job) != "ok":
                    raise SystemExit(f"{p}: the official run failed")
        else:
            job = regress.BUILD / regress.prog_name(p)
            scr = job / "rtl.scr"
        if not scr.exists():
            raise SystemExit(f"no {scr}: run mncore/sim/regress/run.py --m2 first")
        off, _ = ndmp.read(str(job / "official.ndmp"))
        rust, _ = ndmp.read(str(job / "rust.ndmp")) if (job / "rust.ndmp").exists() else ({}, None)
        a_ = {k: v for k, v in off.items() if regress.keep_record(k)}
        b_ = {k: v for k, v in rust.items() if regress.keep_record(k)}
        closed = a_ == b_
        ref, which = (off, "official") if (a.replica or closed) else (rust, "rust (zero rule)")
        out.append(f"# ---- {p}: reference {which}")
        for ln in scr.read_text(encoding="utf-8").splitlines():
            if ln.startswith(("R ", "E")):
                continue
            out.append(ln)
        out.append("K 0 0")
        out += checks(ref)
    out.append("E")
    Path(a.out).write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {a.out}: {len(paths)} programs, {sum(1 for x in out if x.startswith('Q'))} checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())

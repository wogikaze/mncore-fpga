#!/usr/bin/env python3
"""Run the MV test programs on the board (mvt_top, WP33) and compare with the official emulator.

usage: python mncore/fpga/mv_test/hwrun.py [--tests mncore/sim/tb/mv/fixed/mv.tst] [--only NAME,...]
           [--port auto] [--baud 2000000] [--log FILE] [--no-lock-check]

The test file is the one of the RTL testbench (gen_tests.py; format in mncore/sim/tb/mv/tb_mv_env.v),
run the same way through the UART host protocol (mncore/rtl/board/PROTOCOL.md, mnhost.Device):
  T -> RESET; F / G (fills; the testbench's backdoor fills are WR_MEM here too) and V -> WR_MEM;
  J / M -> WR_IMEM; R -> RUN(0, entries), wait, STATUS against the expected stop record;
  K / B (hashes of 64 long words; B is a backdoor read in the testbench) -> RD_MEM.
The expected values are the official emulator's (contract 06 section 1). The board must be
locked first (contract 06 section 9): C:\\wgkz\\nano20k\\mncore\\.board.lock.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "l2bm"))
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "tb" / "l1bm"))
import mnhost  # noqa: E402
from l1prog import SplitMix64  # noqa: E402
from l2prog import styled  # noqa: E402

LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")
DESIGN_ID = 0x33
M64 = (1 << 64) - 1


def fnv64(vals):
    h = 0xCBF29CE484222325
    for v in vals:
        h = ((h ^ v) * 0x100000001B3) & M64
    return h


def parse(path: Path):
    tests, cur = [], None
    for raw in path.read_text(encoding="utf-8").splitlines():
        p = raw.split()
        if not p or p[0] == "#":
            continue
        c = p[0]
        if c == "T":
            cur = {"name": p[1], "seed": int(p[2], 16), "ops": []}
            tests.append(cur)
        elif c in "FG":
            cur["ops"].append(("F", int(p[1]), int(p[2], 16), int(p[3]), int(p[4])))
        elif c == "V":
            cur["ops"].append(("V", int(p[1]), int(p[2], 16), int(p[3], 16)))
        elif c in "JM":
            cur["ops"].append(("W", c.lower(), int(p[1], 16)))
        elif c == "R":
            cur["ops"].append(("R", int(p[1]), int(p[2], 16), int(p[3]), int(p[4])))
        elif c in "KB":
            cur["ops"].append(("K", int(p[1]), int(p[2], 16), int(p[3], 16)))
        elif c == "E":
            cur = None
    return tests


def run_test(dev: mnhost.Device, t: dict, window: int) -> list:
    errs = []
    g = SplitMix64(t["seed"])
    dev.reset()
    entries = []
    reads = {}            # (space, block address) -> expected hash
    for op in t["ops"]:
        if op[0] == "F":
            _, sp, a, n, style = op
            vals = [0] * n if style == 9 else [styled(g.next(), style) for _ in range(n)]
            dev.write(sp, 0, a, vals, window=window)
        elif op[0] == "V":
            _, sp, a, v = op
            dev.write(sp, 0, a, [v])
        elif op[0] == "W":
            entries.append(mnhost.imem_entry(op[1], op[2]))
        elif op[0] == "R":
            _, xr, xi, xp, xs = op
            dev.write_imem(0, entries, window=window)
            dev.run(0, len(entries))
            st = dev.wait_idle(timeout=30.0)
            if (st.reason, st.info, st.pc, st.steps) != (xr, xi, xp, xs):
                errs.append(f"stop reason {st.reason} info {st.info:#x} pc {st.pc} steps {st.steps}, "
                            f"expected {xr} {xi:#x} {xp} {xs}")
        else:
            _, sp, a, h = op
            reads[(sp, a)] = h
    # the hashes: read every window in one go
    by_sp = {}
    for (sp, a) in sorted(reads):
        by_sp.setdefault(sp, []).append(a)
    for sp, blocks in by_sp.items():
        runs, s0, prev = [], blocks[0], blocks[0]
        for a in blocks[1:]:
            if a != prev + 64:
                runs.append((s0, prev + 64))
                s0 = a
            prev = a
        runs.append((s0, prev + 64))
        for lo, hi in runs:
            vals = dev.read(sp, 0, lo, hi - lo, window=window)
            for a in range(lo, hi, 64):
                h = fnv64(vals[a - lo:a - lo + 64])
                if h != reads[(sp, a)]:
                    sname = {6: "L1BM", 7: "L2BM", 8: "PDM", 9: "DRAM"}[sp]
                    errs.append(f"{sname} {a:#x}..{a + 63:#x} differ")
    return errs


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tests", default=str(ROOT / "mncore" / "sim" / "tb" / "mv" / "fixed" / "mv.tst"))
    ap.add_argument("--only")
    ap.add_argument("--port", default="auto")
    ap.add_argument("--baud", type=int, default=2000000, help="switch to this baud rate first (0: stay at 1M)")
    ap.add_argument("--window", type=int, default=6300, help="response bytes in flight (mnhost pipelining)")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--log")
    ap.add_argument("--no-lock-check", action="store_true")
    a = ap.parse_args(argv)
    logf = open(a.log, "a", encoding="utf-8") if a.log else None

    def log(s=""):
        print(s, flush=True)
        if logf:
            logf.write(s + "\n")
            logf.flush()

    if not a.no_lock_check and not LOCK.exists():
        raise SystemExit(f"take the board lock first: {LOCK} (WP number, start time)")
    tests = parse(Path(a.tests))
    if a.only:
        keep = set(a.only.split(","))
        tests = [t for t in tests if t["name"] in keep]
    link = mnhost.Link.open(a.port, 1000000, timeout=0.2)
    dev = mnhost.Device(link)
    inf = dev.info()
    if inf.design_id != DESIGN_ID:
        raise SystemExit(f"design id 0x{inf.design_id:02x}, expected 0x{DESIGN_ID:02x} (mvt_top)")
    if a.baud and a.baud != 1000000:
        dev.set_baud(a.baud)
    inf = dev.info(refresh=True)
    log(f"# mv hwrun {time.strftime('%Y-%m-%d %H:%M:%S')}: design 0x{inf.design_id:02x}, {inf.clk_hz} Hz, "
        f"{inf.baud:.0f} baud, imem {inf.imem_depth}, topo {inf.topo}, depths "
        + ", ".join(f"{k}:{v}" for k, v in sorted(inf.space_depth.items())) + f", {len(tests)} tests x {a.repeat}")
    nfail = 0
    t0 = time.monotonic()
    for rep in range(a.repeat):
        for i, t in enumerate(tests, 1):
            t1 = time.monotonic()
            try:
                errs = run_test(dev, t, a.window)
            except (mnhost.ProtocolError, mnhost.DeviceError) as e:
                errs = [f"error: {e}"]
                dev.link.flush_input(0.1)
            nfail += bool(errs)
            log(f"[{rep + 1}:{i}/{len(tests)}] {'ok  ' if not errs else 'FAIL'} {t['name']:<14} "
                f"{time.monotonic() - t1:5.1f} s" + ("  " + "; ".join(errs[:4]) if errs else ""))
    st = dev.status()
    log(f"# {len(tests) * a.repeat} runs in {time.monotonic() - t0:.0f} s, {nfail} failed; link: crc_err {st.crc_err} "
        f"frame_err {st.frame_err} overrun {st.overrun} timeout {st.timeout}, host retries {dev.link.stats['retries']}")
    if a.baud and a.baud != 1000000:
        try:
            dev.set_baud(1000000)
        except mnhost.ProtocolError:
            pass
    log("PASS" if nfail == 0 else "FAIL")
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

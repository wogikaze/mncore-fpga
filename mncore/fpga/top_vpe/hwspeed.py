#!/usr/bin/env python3
"""Time the RUNs of corpus programs on the board (mn_top_vpe, WP34).

usage: python mncore/fpga/top_vpe/hwspeed.py [--port COMx] PROGRAM ...

For each program (the official.asm of the regression build directory, `run.py --vpe N_MAB --lm-aw LM_AW` must
have run): execute it once (mnhost.execute_program; prints the wall time of its RUNs: RUN command to the
STATUS that shows the core idle, polled over the UART), then fill the instruction memory with its words
repeated and time a RUN of n words and one of n * k words (best of 5 each). The difference gives the time
per word without the fixed cost of a RUN and its polling (about 10 ms at 2 Mbaud), in microseconds and in
core clocks. The values the repeated words compute are not checked. The board must be locked first
(contract 06 section 9): C:\\wgkz\\nano20k\\mncore\\.board.lock.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
import run as regress  # noqa: E402
import mnhost  # noqa: E402

LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("programs", nargs="+")
    ap.add_argument("--port", default="auto")
    ap.add_argument("--no-lock-check", action="store_true")
    a = ap.parse_args(argv)
    if not a.no_lock_check and not LOCK.exists():
        raise SystemExit(f"take the board lock first: {LOCK}")
    dev = mnhost.Device(mnhost.Link.open(a.port, 1000000, timeout=0.2))
    inf = dev.info()
    if inf.design_id != 0x05:
        raise SystemExit(f"design id 0x{inf.design_id:02x}, expected 0x05 (mn_top_vpe)")
    lm_aw = inf.space_depth.get(mnhost.SPACES["LM0"], 0).bit_length() - 1
    units = (1 if inf.space_depth.get(mnhost.SPACES["L2BM"], 0) > 0 else
             2 if inf.space_depth.get(mnhost.SPACES["L1BM"], 0) > 0 else 0)
    regress.configure_vpe(inf.topo[3], lm_aw, units)
    dev.set_baud(2000000)
    inf = dev.info(refresh=True)
    print(f"design 0x{inf.design_id:02x}, {inf.clk_hz} Hz, topo {inf.topo}, LM {1 << lm_aw}, units {units}")

    run0, wait0 = dev.run, dev.wait_idle
    acc = {"t": 0.0, "n": 0, "t0": 0.0}

    def run(*x, **k):
        acc["t0"] = time.perf_counter()
        return run0(*x, **k)

    def wait_idle(*x, **k):
        st = wait0(*x, **k)
        acc["t"] += time.perf_counter() - acc["t0"]
        acc["n"] += 1
        return st

    dev.run, dev.wait_idle = run, wait_idle
    for p in a.programs:
        job = regress.BUILD / regress.prog_name(p)
        prog = mnhost.parse_asm((job / "official.asm").read_text(encoding="utf-8"))
        acc.update(t=0.0, n=0)
        t0 = time.perf_counter()
        r = mnhost.execute_program(dev, prog, mnhost.Topology(dev.info().topo), run_timeout=600.0)
        print(f"{p}: {r.stats['steps']} steps in {acc['n']} RUNs, {acc['t'] * 1e3:.1f} ms of RUN, "
              f"{time.perf_counter() - t0:.2f} s in all, stop {r.stop.reason_name if r.stop else '-'}", flush=True)
        n = min(len(prog.entries), inf.imem_depth)
        k = inf.imem_depth // n if n else 0
        if k < 2:
            continue
        dev.write_imem(0, list(prog.entries[:n]) * k)
        best = {}
        for cnt in (n, n * k):
            ts = []
            for _ in range(5):
                acc.update(t=0.0, n=0)
                dev.run(0, cnt)
                s = dev.wait_idle(60.0)
                if s.reason == 0 and s.steps == cnt:
                    ts.append(acc["t"])
            best[cnt] = min(ts) if ts else None
        if best[n] is not None and best[n * k] is not None:
            per = (best[n * k] - best[n]) / (n * k - n)
            print(f"   RUN {n} words {best[n] * 1e3:.2f} ms, RUN {n * k} words {best[n * k] * 1e3:.2f} ms: "
                  f"{per * 1e6:.1f} us = {per * inf.clk_hz:.0f} core clocks per word", flush=True)
        else:
            print("   a repeated RUN stopped early (the repeated words change the state); no time per word")
    dev.set_baud(1000000)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Program an sdram_test bitstream into SRAM and read its UART report.

    python mncore/fpga/sdram_test/run_test.py mncore/fpga/sdram_test/build/f108_cl3_dyn/sdram_test.fs
    python mncore/fpga/sdram_test/run_test.py a.fs b.fs --iters 3 --port COM6

Takes the board lock C:\\wgkz\\nano20k\\mncore\\.board.lock (contract section 9) unless this WP already
holds it, and removes only a lock it created. Never writes the flash. Prints the sweep as an eye map
and the bandwidth of every full-test iteration. Exit status 0 only if every bitstream completed its
iterations error-free.

BL616 bridge notes (measured 2026-11-24): the FPGA -> PC relay stops for good (until a BL616 reboot,
`mnhost.py bridge reboot`, which also reloads the FPGA from flash) when the FPGA sends while no host
reads the port. The test design therefore only sends while it sees host traffic on uart_rx, and this
script sends 0x00 about every 50 ms. Data the bridge buffered earlier can arrive first; lines before
the "SDRAM f=" header are ignored.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import serial  # pyserial

LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")

if shutil.which("openFPGALoader") is None:
    _oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
    os.environ["PATH"] = os.pathsep.join([str(_oss / "bin"), str(_oss / "lib"), os.environ.get("PATH", "")])


def take_lock():
    """Returns True if this run created the lock (and must remove it)."""
    if LOCK.exists():
        age = time.time() - LOCK.stat().st_mtime
        text = LOCK.read_text(encoding="utf-8", errors="replace").strip()
        if text.startswith("WP05"):
            return False                    # already held by this WP's session
        if age < 2 * 3600:
            sys.exit(f"board is locked ({text!r}, {age / 60:.0f} min old): test deferred")
    LOCK.write_text(f"WP05 {datetime.datetime.now().isoformat(timespec='seconds')} sdram_test\n",
                    encoding="utf-8")
    return True


def drop_lock():
    try:
        if LOCK.read_text(encoding="utf-8").startswith("WP05"):
            LOCK.unlink()
    except FileNotFoundError:
        pass


def eye_map(eye_hex):
    eye = int(eye_hex, 16)
    rows = ["      phase 0123456789abcdef"]
    for k in range(4):
        bits = "".join("#" if eye >> (k * 16 + p) & 1 else "." for p in range(16))
        rows.append(f"      rdx={k}  {bits}")
    return "\n".join(rows)


def run_one(fs, port, baud, iters, timeout):
    print(f"=== {fs}", flush=True)
    r = subprocess.run(["openFPGALoader", "-b", "tangnano20k", str(fs)], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout + r.stderr)
        return False
    # The design sends only while it sees host traffic on its RX pin: send a 0x00 about every 50 ms
    # (never 0x18 / 0x03, which put the BL616 into its shell).
    ser = serial.Serial(port, baud, timeout=0.05)
    t0 = time.time()
    freq, aw, ok, n_r, buf, eye_seen = None, None, True, 0, b"", None
    while time.time() - t0 < timeout and n_r < iters:
        ser.write(b"\x00")
        buf += ser.read(4096)
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = raw.decode("ascii", errors="replace").strip()
            m = re.search(r"SDRAM f=([0-9a-f]+) cl=(\d) aw=([0-9a-f]+)", line)
            if m:
                freq, aw = int(m.group(1), 16), int(m.group(3), 16)
                line = m.group(0)
            if not line or freq is None:
                continue     # the BL616 bridge first delivers stale bytes from the previous design
            print(f"[{time.time() - t0:6.2f}s] {line}", flush=True)
            m = re.match(r"C p=(\w) k=(\w) n=(\w+) eye=([0-9a-f]+)", line)
            if m:
                if m.group(0) != eye_seen:       # repeated before every R line
                    print(eye_map(m.group(4)))
                    eye_seen = m.group(0)
                if int(m.group(3), 16) == 0 and int(m.group(4), 16) != 0:
                    ok = False                  # a sweep ran but no window was found
            m = re.match(r"R i=(\w+) p=(\w) k=(\w) e=(\w+) m=(\w+) sw=(\w+) sr=(\w+) rr=(\w+) rw=(\w+)", line)
            if m and freq:
                n_r += 1
                e, mm = int(m.group(4), 16), int(m.group(5), 16)
                if e or mm:
                    ok = False
                nbytes = (1 << aw) * 8
                bw = []
                for name, g in (("seq write", 6), ("seq read", 7), ("rand read", 8), ("rand write", 9)):
                    cyc = int(m.group(g), 16)
                    bw.append(f"{name} {nbytes / (cyc / freq) / 1e6:7.1f} MB/s ({cyc / (1 << aw):.3f} cyc/LW)")
                print("      " + " | ".join(bw), flush=True)
    ser.close()
    if n_r < iters:
        print(f"timeout: {n_r}/{iters} iterations")
        ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fs", nargs="+")
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--baud", type=int, default=1000000)
    ap.add_argument("--iters", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=60.0)
    a = ap.parse_args()
    mine = take_lock()
    try:
        results = [(fs, run_one(fs, a.port, a.baud, a.iters, a.timeout)) for fs in a.fs]
    finally:
        if mine:
            drop_lock()
    for fs, ok in results:
        print(f"{'PASS' if ok else 'FAIL'} {fs}")
    return 0 if all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())

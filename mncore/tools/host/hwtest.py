#!/usr/bin/env python3
"""WP04 hardware acceptance test for the board_test bitstream (mncore/fpga/board_test).

    python mncore/tools/host/hwtest.py [--port COM6] [--bauds 1000000,2000000,3000000]

Checks: PING echo, INFO, 64 KiB write/read at each baud rate (stop-and-wait and pipelined), byte masks,
error responses (E_RANGE / E_CMD / E_LEN / E_CRC), WR_IMEM read-back, RUN / STATUS / RESET with the run stub,
SET_BAUD revert, and an .asm smoke test whose expected ndmp comes from the official emulator.
Prints one line per check and PASS / FAIL at the end.  Take the board lock (contract §9) before running.
"""
import argparse
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mnhost as mh  # noqa: E402

TEST = mh.SPACES["TEST"]
IMEM = mh.SPACES["IMEM"]

# d lines from a program run through assemble3 + gpfn3_package_main (official emulator, 2024 build);
# the j words are dummies because the board_test run stub does not decode them.
SMOKE_ASM = """\
d set $lm0n0c0b0m0p0 2 0123456789ABCDEFFEDCBA9876543210
d set $lb4n0c0b0 1 1111222233334444
d set $lc8n0c0 1 5555666677778888
d set $lltn0c0b0m0p0 1 AAAAAAAAAAAAAAAABBBBBBBBBBBBBBBB
d set $m5n0c0b0m0p0 1 99999999CCCCCCCC
j {j}
d get $lm0n0c0b0m0p0 2
d getf $m1n0c0b0m0p0 1
d getf $m4n0c0b0m0p0 3
d get $ln0n0c0b0m0p1 1
d get $lb4n0c0b0 1
d get $lc8n0c0 1
d get $p0n0 1
d get $d0n0 1
d get $lltn0c0b0m0p0 1
d get $ltn0c0b0m0p0 2
m {m}
j {j}
""".format(j="0" * 426, m="0" * 82)

# Official dump (DEBUG-... lines) for the gets above, rewritten as ndmp long words:
#   LM0(…,0)=0x0123456789ABCDEF LM0(…,2)=0xFEDCBA9876543210 LM0 word1=0x89abcdef word4=0 word5=0x99999999
#   word6=0, L1BM(n0c0b0,4)=0x1111222233334444, L2BM(n0c0,8)=0x5555666677778888, PIU(n0,0)=0, DRAM(n0,0)=0,
#   TREG cycle0 = {0xAAAA…, 0xBBBB…}, TREG cycle1 MSB = 0.  LM1 of p1 is outside the 1-PE topology.
SMOKE_NDMP = sorted([
    "LM0 n0c0b0m0p0 0x0000 0123456789abcdef",
    "LM0 n0c0b0m0p0 0x0001 fedcba9876543210",
    "LM0 n0c0b0m0p0 0x0000 0123456789abcdef",
    "LM0 n0c0b0m0p0 0x0002 0000000099999999",
    "LM0 n0c0b0m0p0 0x0003 0000000000000000",
    "L1BM n0c0b0 0x0004 1111222233334444",
    "L2BM n0c0 0x0008 5555666677778888",
    "PDM n0 0x0000 0000000000000000",
    "DRAM n0 0x0000 0000000000000000",
    "T n0c0b0m0p0 0x0000 aaaaaaaaaaaaaaaa",
    "T n0c0b0m0p0 0x0001 bbbbbbbbbbbbbbbb",
    "T n0c0b0m0p0 0x0000 aaaaaaaaaaaaaaaa",
    "T n0c0b0m0p0 0x0002 0000000000000000",
])


class Runner:
    def __init__(self):
        self.fails = 0

    def check(self, cond, name, detail=""):
        print(f"{'OK ' if cond else 'NG '} {name}{(' - ' + detail) if detail else ''}", flush=True)
        if not cond:
            self.fails += 1
        return cond


def connect(port, bauds):
    for b in bauds:
        link = mh.Link.open(port, b, timeout=0.1)
        dev = mh.Device(link)
        try:
            dev.ping()
            return dev
        except (mh.ProtocolError, mh.DeviceError):
            link.ser.close()
    raise SystemExit("board does not answer at " + ", ".join(map(str, bauds)))


def expect_status(dev, cmd, payload, status):
    st, body = dev.link.transact(cmd, payload, check=False)
    return st == status, body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="auto")
    ap.add_argument("--bauds", default="1000000,2000000,3000000")
    ap.add_argument("--seed", type=int, default=2026)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    r = Runner()
    bauds = [int(x) for x in a.bauds.split(",")]

    dev = connect(a.port, [1000000, 2000000, 3000000])
    if dev.link.baudrate != 1000000:
        dev.set_baud(1000000)
    dev.reset(clear_counters=True)

    # --- INFO / PING
    inf = dev.info(refresh=True)
    r.check(inf.proto == 1 and inf.design_id == 1, "INFO protocol 1, design board_test",
            f"clk {inf.clk_hz} Hz, pbuf {inf.pbuf}, imem {inf.imem_depth}, spaces {inf.space_depth}")
    ok = True
    t0 = time.perf_counter()
    for size in [0, 1, 2, 255, 256, 1000, 2047, 2048] + [rng.randrange(2049) for _ in range(40)]:
        data = bytes(rng.getrandbits(8) for _ in range(size))
        try:
            dev.ping(data)
        except (mh.ProtocolError, mh.DeviceError) as e:
            ok = r.check(False, f"PING {size} B", str(e))
    r.check(ok, "PING echo, 48 frames of 0..2048 B", f"{time.perf_counter() - t0:.2f} s")
    n = 50
    t0 = time.perf_counter()
    for _ in range(n):
        dev.ping()
    rtt = (time.perf_counter() - t0) / n * 1000
    r.check(True, "PING round trip (empty)", f"{rtt:.2f} ms average over {n}")

    # --- error responses
    ok, body = expect_status(dev, 0x05, bytes([TEST, 0]) + (0).to_bytes(2, "little") + (8190).to_bytes(4, "little")
                             + (4).to_bytes(2, "little"), 5)
    r.check(ok and body == (2).to_bytes(4, "little"), "RD_MEM past the end -> E_RANGE at word 2")
    ok, _ = expect_status(dev, 0x04, bytes([0x05, 0xFF]) + bytes(6) + bytes(8), 5)
    r.check(ok, "WR_MEM to an absent space -> E_RANGE")
    ok, _ = expect_status(dev, 0x04, bytes([TEST, 0xFF]) + bytes(6) + bytes(5), 3)
    r.check(ok, "WR_MEM with a ragged length -> E_LEN")
    ok, _ = expect_status(dev, 0x55, b"", 2)
    r.check(ok, "unknown command -> E_CMD")
    f = bytearray(mh.encode_frame(0x01, b"xyz"))
    f[-1] ^= 0xFF
    dev.link.ser.write(bytes(f))
    c, d = dev.link.recv(2.0)
    r.check(c == 0x81 and d == bytes([1]), "corrupted frame -> E_CRC")
    dev.ping(b"after")
    st = dev.status()
    r.check(st.crc_err == 1, "STATUS counts the CRC error", f"crc_err={st.crc_err}")

    # --- WR_IMEM
    ents = [rng.getrandbits(426) | (mh.IMEM_TYPE_J << 446) for _ in range(inf.imem_depth)]
    dev.write_imem(0, ents)
    back = dev.read(IMEM, 0, 0, inf.imem_depth * 8)
    ok = all(back[e * 8 + k] == (ents[e] >> (64 * k)) & mh.MASK64 for e in range(len(ents)) for k in range(7))
    r.check(ok, f"WR_IMEM {len(ents)} entries, lanes read back")

    # --- RUN / STATUS / RESET (run stub: 1 entry per clock)
    dev.run(0, 50)
    st = dev.wait_idle(2.0)
    r.check(st.reason == 0 and st.pc == 50 and st.steps == 50, "RUN 0,50 -> OK pc 50", str(st))
    dev.run(60, 10)
    st = dev.wait_idle(2.0)
    r.check(st.reason == 1 and st.info == 64 and st.steps == 4, "RUN past IMEM -> E_RANGE at 64", str(st))
    dev.reset()
    st = dev.status()
    r.check(not st.busy and st.steps == 0 and st.reason == 0, "RESET clears the core status")

    # --- byte mask
    dev.write(TEST, 0, 100, [0x1111111111111111])
    dev.write(TEST, 0, 100, [0x2222222222222222], mask=0x0F)
    r.check(dev.read(TEST, 0, 100, 1) == [0x1111111122222222], "WR_MEM byte mask 0x0F")

    # --- .asm smoke test (spaces mapped into TEST, 1 PE)
    dev.write(TEST, 0, 0, [0] * 8192, window=6300)
    lines, st = mh.run_program(dev, mh.parse_asm(SMOKE_ASM), mh.Topology((1, 1, 1, 1, 1)), mh.TestSpaceMap())
    r.check(st is None and lines == SMOKE_NDMP, ".asm smoke test: d set / d get ndmp matches the official dump",
            "" if lines == SMOKE_NDMP else "\n      got: " + "\n           ".join(lines))

    # --- SET_BAUD probation revert: the host never follows, the board must come back by itself
    other = 2000000 if dev.link.baudrate != 2000000 else 1000000
    dev.link.transact(mh.CMD["SET_BAUD"], round(inf.clk_hz * 256 / other).to_bytes(4, "little"))
    time.sleep(1.6)
    dev.link.flush_input()
    try:
        dev.ping(b"still here")
        r.check(dev.status().div_q8 == inf.div_q8, "SET_BAUD without confirmation reverts after 1 s")
    except mh.ProtocolError as e:
        r.check(False, "SET_BAUD without confirmation reverts after 1 s", str(e))

    # --- 64 KiB at each baud rate
    words = [rng.getrandbits(64) for _ in range(8192)]
    for baud in bauds:
        try:
            exact = dev.set_baud(baud) if baud != dev.link.baudrate else dev.info().baud
        except mh.ProtocolError as e:
            r.check(False, f"SET_BAUD {baud}", str(e))
            continue
        host = inf.clk_hz / dev.measure_host_bit()
        dev.reset(clear_counters=True)
        for window in (0, 6300):
            words = [rng.getrandbits(64) for _ in range(8192)]
            t0 = time.perf_counter()
            dev.write(TEST, 0, 0, words, window=window)
            t1 = time.perf_counter()
            back = dev.read(TEST, 0, 0, 8192, window=window)
            t2 = time.perf_counter()
            bad = sum(1 for x, y in zip(words, back) if x != y)
            st = dev.status()
            r.check(bad == 0 and len(back) == 8192 and st.crc_err == 0 and st.frame_err == 0 and st.overrun == 0,
                    f"{baud} baud {'pipelined' if window else 'stop-and-wait'}: 64 KiB write/read/compare",
                    f"FPGA {exact:.0f} baud, bridge {host:.0f} baud; write {65536 / (t1 - t0) / 1024:.1f} KiB/s, "
                    f"read {65536 / (t2 - t1) / 1024:.1f} KiB/s; mismatches {bad}; crc {st.crc_err} frame "
                    f"{st.frame_err} overrun {st.overrun} timeout {st.timeout}; host retries "
                    f"{dev.link.stats['retries']}")
    if dev.link.baudrate != 1000000:
        dev.set_baud(1000000)

    print("PASS" if r.fails == 0 else f"FAIL {r.fails} check(s)")
    return 1 if r.fails else 0


if __name__ == "__main__":
    sys.exit(main())

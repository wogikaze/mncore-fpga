"""Offline tests for mnhost (no board needed):  python mncore/tools/host/test_mnhost.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mnhost as mh                      # noqa: E402
from fakedev import FakeDevice           # noqa: E402


def dev_on_fake(**kw):
    fd = FakeDevice(**kw)
    return mh.Device(mh.Link(fd)), fd


J0 = "j " + "0" * 426
J1 = "j " + "1" + "0" * 425
M0 = "m " + "1" * 82


class Framing(unittest.TestCase):
    def test_crc_check_value(self):
        self.assertEqual(mh.crc8(b"123456789"), 0xF4)

    def test_encode(self):
        f = mh.encode_frame(0x01, b"\x11\x22")
        self.assertEqual(f[:4], bytes([0xA5, 0x01, 0x02, 0x00]))
        self.assertEqual(f[-1], mh.crc8(f[1:-1]))

    def test_loc(self):
        self.assertEqual(mh.parse_loc("n0c0b0m0p1"), 1)
        self.assertEqual(mh.parse_loc("n3c1b7m15p3"), 0xFFF)
        self.assertEqual(mh.loc_fields(mh.parse_loc("n1c0b2m3p0")), {"n": 1, "c": 0, "b": 2, "m": 3, "p": 0})


class AsmParsing(unittest.TestCase):
    def test_dline_forms(self):
        d = mh.parse_dline("d set $lm0n0c0b0m0p0 2 0123456789ABCDEFFEDCBA9876543210")
        self.assertEqual((d.space, d.width, d.addr, d.loc, d.count), ("LM0", "l", 0, {"n": 0, "c": 0, "b": 0, "m": 0, "p": 0}, 2))
        self.assertEqual(d.payload, [0x0123456789ABCDEF, 0xFEDCBA9876543210])
        d = mh.parse_dline("d getd $d0n0 1 # expect=\"Hello, w\"")
        self.assertEqual((d.op, d.space, d.addr, d.loc, d.count), ("get", "DRAM", 0, {"n": 0}, 1))
        d = mh.parse_dline("d get $lltn0c0b0m0p0 4")
        self.assertEqual((d.space, d.width), ("T", "ll"))
        d = mh.parse_dline("d get $ln0n0c0b0m0p1 1")
        self.assertEqual((d.space, d.addr, d.loc["p"]), ("LM1", 0, 1))
        d = mh.parse_dline("d set $lb4n0c0b0 1 1111222233334444")
        self.assertEqual((d.space, d.addr, d.loc), ("L1BM", 4, {"n": 0, "c": 0, "b": 0}))
        d = mh.parse_dline("d get $lr0n0c0m0p0 1")                       # no b: all L1Bs
        self.assertEqual(d.loc, {"n": 0, "c": 0, "m": 0, "p": 0})

    def test_payload_sugar(self):
        # SDM 3.4.4 table 3.4: all four notations give 0x0123456789abcdef
        for t in ["0123456789abcdef", "l123456789abcdef", "s1234567_89abcdef", "h123_4567_89ab_cdef"]:
            self.assertEqual(mh.parse_payload(t), [0x0123456789ABCDEF], t)
        self.assertEqual(mh.parse_payload("h1_2_3_4h5_6_7_8"), [0x0001000200030004, 0x0005000600070008])
        self.assertEqual(mh.parse_payload("l4321hf_e_d_c"), [0x4321, 0x000F000E000D000C])

    def test_word_mapping(self):
        # SDM 3.4.4 example 3: d set $m0 2 h1_2_3_4h5_6_7_8 -> LM0 long word 0 = 0x0001000200050006
        d = mh.parse_dline("d set $m0n0c0b0m0p0 2 h1_2_3_4h5_6_7_8")
        lw = mh.long_words(d)
        self.assertEqual(lw, [(0, 0x0001000200000000, 0xF0), (0, 0x0000000000050006, 0x0F)])
        runs = list(mh._runs(lw))
        self.assertEqual(runs, [[(0, 0x0001000200050006, 0xFF)]])
        # odd word address -> low half
        d = mh.parse_dline("d set $m5n0c0b0m0p0 1 99999999CCCCCCCC")
        self.assertEqual(mh.long_words(d), [(2, 0x99999999, 0x0F)])
        # $lm word address 8 = long word 4
        d = mh.parse_dline("d get $lm8n0c0b0m0p0 2")
        self.assertEqual([a for a, _, _ in mh.long_words(d)], [4, 5])
        # T: $lt n -> MSB long word of each cycle; $llt -> both
        d = mh.parse_dline("d get $ltn0c0b0m0p0 2")
        self.assertEqual([a for a, _, _ in mh.long_words(d)], [0, 2])
        d = mh.parse_dline("d set $lltn0c0b0m0p0 2 " + "1" * 16 + "2" * 16 + "3" * 16 + "4" * 16)
        self.assertEqual([a for a, _, _ in mh.long_words(d)], [0, 1, 2, 3])

    def test_program(self):
        text = "\n".join(["d set $lm0 1 00000000000000AA", J0, J1, "d get $lm0n0c0b0m0p0 1", M0, J0,
                          "d getd $d0n0 1"])
        p = mh.parse_asm(text)
        self.assertEqual(len(p.entries), 4)
        self.assertEqual([pos for pos, _ in p.events], [0, 2, 4])
        self.assertEqual(p.entries[1] >> 446, mh.IMEM_TYPE_J)
        self.assertEqual(p.entries[1] & ((1 << 426) - 1), 1 << 425)        # pos 0 -> jw[425]
        self.assertEqual(p.entries[2] >> 446, mh.IMEM_TYPE_M)
        self.assertEqual(p.entries[2] & ((1 << 446) - 1), (1 << 82) - 1)
        with self.assertRaises(ValueError):
            mh.parse_asm("i 0101")

    def test_rlines_merged(self):
        """WP37: consecutive r lines with continuing addresses are one DRAM write; a gap, another group
        or a word between them starts a new one."""
        text = "\n".join(["r 0 000000010 001 " + "1" * 16, "r 0 000000011 002 " + "2" * 32,
                          "r 0 000000020 001 " + "3" * 16, "r 1 000000021 001 " + "4" * 16, J0,
                          "r 0 000000022 001 " + "5" * 16])
        p = mh.parse_asm(text)
        self.assertEqual(len(p.rlines), 5)
        ops = [(pos, d.space, d.loc, d.addr, d.count) for pos, d in p.events]
        self.assertEqual(ops, [(0, "DRAM", {"n": 0}, 0x10, 3), (0, "DRAM", {"n": 0}, 0x20, 1),
                               (0, "DRAM", {"n": 1}, 0x21, 1), (1, "DRAM", {"n": 0}, 0x22, 1)])
        self.assertEqual(p.events[0][1].payload, [0x1111111111111111, 0x2222222222222222, 0x2222222222222222])

    def test_topology(self):
        t = mh.Topology((1, 1, 2, 1, 4))
        self.assertEqual(len(t.locations("LM0", {})), 8)
        self.assertEqual(len(t.locations("LM0", {"n": 0, "c": 0, "m": 0, "p": 0})), 2)  # b0, b1
        self.assertEqual(t.locations("LM0", {"p": 5}), [])                              # not implemented
        self.assertEqual(t.locations("L1BM", {}), [{"n": 0, "c": 0, "b": 0}, {"n": 0, "c": 0, "b": 1}])
        self.assertEqual(t.locations("DRAM", {"n": 0}), [{"n": 0}])


class DeviceOps(unittest.TestCase):
    def test_info_status(self):
        dev, fd = dev_on_fake()
        inf = dev.info()
        self.assertEqual((inf.proto, inf.pbuf, inf.imem_depth, inf.topo), (1, 2048, 64, (1, 1, 1, 1, 1)))
        self.assertEqual(inf.space_depth[0x0F], 8192)
        self.assertEqual((inf.rxfifo, inf.txfifo), (2048, 2048))
        st = dev.status()
        self.assertFalse(st.busy)

    def test_write_read_multi_frame(self):
        dev, fd = dev_on_fake()
        words = [(i * 0x9E3779B97F4A7C15) & mh.MASK64 for i in range(1000)]
        dev.write(0x0F, 0, 5, words)
        self.assertEqual(dev.read(0x0F, 0, 5, 1000), words)
        dev.write(0x0F, 0, 5, words[:300], window=4096)                  # pipelined path
        self.assertEqual(dev.read(0x0F, 0, 5, 300, window=4096), words[:300])
        dev.write(0x0F, 0, 0, [0xFFFFFFFFFFFFFFFF])
        dev.write(0x0F, 0, 0, [0], mask=0x0F)
        self.assertEqual(dev.read(0x0F, 0, 0, 1), [0xFFFFFFFF00000000])

    def test_errors_and_retry(self):
        dev, fd = dev_on_fake()
        with self.assertRaises(mh.DeviceError) as cm:
            dev.read(0x0F, 0, 8190, 4)
        self.assertEqual((cm.exception.status, cm.exception.body), (5, (2).to_bytes(4, "little")))
        fd.corrupt_next_response = 1                                       # lost response -> retried
        self.assertEqual(dev.ping(b"abc"), b"abc")
        self.assertEqual(dev.link.stats["retries"], 1)

    def test_imem(self):
        dev, fd = dev_on_fake()
        ents = [mh.imem_entry("j", (1 << 425) | i) for i in range(40)]  # 2 frames (36 per frame)
        dev.write_imem(3, ents)
        e = ents[37]
        for k in range(7):
            self.assertEqual(fd.mem[(0, 0, (3 + 37) * 8 + k)], (e >> (64 * k)) & mh.MASK64)


class RunProgram(unittest.TestCase):
    def test_segments_and_ndmp(self):
        dev, fd = dev_on_fake(topo=(1, 1, 1, 1, 2))
        text = "\n".join([
            "d set $lm0 2 0123456789ABCDEFFEDCBA9876543210",          # all implemented PEs (p0, p1)
            "d set $m5n0c0b0m0p1 1 99999999CCCCCCCC",                   # word 5 = low half of long word 2
            J0, J0, J0,
            "d get $lm0n0c0b0m0p0 2",
            J0,
            "d get $lm4n0c0b0m0p1 1",
            "d get $lm0n0c0b0m0p3 1",                                   # p3 not implemented -> no lines
            J0, M0])
        lines, st = mh.run_program(dev, mh.parse_asm(text), mh.Topology((1, 1, 1, 1, 2)))
        self.assertIsNone(st)
        self.assertEqual(fd.runs, [(0, 3), (3, 1), (4, 2)])
        self.assertEqual(lines, sorted([
            "LM0 n0c0b0m0p0 0x0000 0123456789abcdef",
            "LM0 n0c0b0m0p0 0x0001 fedcba9876543210",
            "LM0 n0c0b0m0p1 0x0002 0000000099999999",
        ]))

    def test_imem_window(self):
        dev, fd = dev_on_fake(imem_depth=4)
        text = "\n".join([J0] * 10 + ["d get $lm0n0c0b0m0p0 1"] + [J0] * 3)
        lines, st = mh.run_program(dev, mh.parse_asm(text), mh.Topology())
        self.assertIsNone(st)
        # windows [0,4) [4,8) [8,12): run 8..9, stop for d get, continue 10..11 in the same window, then [12,16)
        self.assertEqual(fd.runs, [(0, 4), (0, 4), (0, 2), (2, 2), (0, 1)])

    def test_cli_on_fake(self):
        import io
        import tempfile
        from contextlib import redirect_stdout, redirect_stderr
        with tempfile.TemporaryDirectory() as td:
            asm = os.path.join(td, "t.asm")
            out = os.path.join(td, "t.ndmp")
            with open(asm, "w") as fh:
                fh.write("d set $lb4n0c0b0 1 1111222233334444\n" + J0 + "\nd get $lb4n0c0b0 1\n")
            buf = io.StringIO()
            with redirect_stdout(buf), redirect_stderr(io.StringIO()):
                mh.main(["--port", "fake", "run", asm, "-o", out])
            with open(out) as fh:
                text = fh.read()
            self.assertTrue(text.startswith("# ndmp v1\n"))
            self.assertEqual([l for l in text.splitlines() if not l.startswith("#")],
                             ["L1BM n0c0b0 0x0004 1111222233334444"])

    def test_ndmp_units_like_norm_gpfn3(self):
        """WP21: word access -> LM0W.., T 2c+k, OMR entry*4+cycle, cut at the INFO depth, skipped spaces."""
        sd = {0x00: 64 * 8, 0x01: 512, 0x02: 512, 0x03: 256, 0x04: 256, 0x05: 8, 0x10: 16}
        dev, fd = dev_on_fake(space_depth=sd)
        text = "\n".join([
            "r 0 000000000 001 3E8000003FE00000 # DRAM data",        # skipped (no DRAM)
            "d set $lm0 2 0123456789ABCDEFFEDCBA9876543210",
            "d set $lb0n0c0b0 1 1111222233334444",                   # no L1BM: skipped
            "d set $ln1022 2 AAAAAAAAAAAAAAAABBBBBBBBBBBBBBBB",       # long words 511 (kept) and 512 (dropped)
            J0,
            "d getf $m1n0c0b0m0p0 2",                                # words 1, 2 -> LM0W
            "d get $lm2n0c0b0m0p0 1",                                # long word 1
            "d get $lltn0c0b0m0p0 4",                                # T 0..7
            "d get $lt1n0c0b0m0p0 1",                                # T cycle 1, MSB long word -> 2
            "d get $omr0n0c0b0m0p0 2",                               # entry 0 (all ones) and entry 1
            "d get $omr17n0c0b0m0p0 1",                              # fixed pattern 10001
            "d get $ln0n0c0b0m0p0 2048",                             # cut at 512 long words
            "d get $lb0n0c0b0 4",                                    # no L1BM: skipped
        ])
        fd.mem[(0x05, 0, 3)] = 0x3333
        fd.mem[(0x10, 0, 1)] = 0x8421                               # cycle c nibble = bits 4c+3..4c
        r = mh.execute_program(dev, mh.parse_asm(text), mh.Topology())
        self.assertIsNone(r.stop)
        rec = r.records
        self.assertEqual(rec[("LM0W", "n0c0b0m0p0", 1)], 0x89ABCDEF)
        self.assertEqual(rec[("LM0W", "n0c0b0m0p0", 2)], 0xFEDCBA98)
        self.assertEqual(rec[("LM0", "n0c0b0m0p0", 1)], 0xFEDCBA9876543210)
        self.assertEqual(rec[("T", "n0c0b0m0p0", 3)], 0x3333)
        self.assertEqual(sorted(a for s, _, a in rec if s == "T"), list(range(8)))
        self.assertEqual([rec[("OMR", "n0c0b0m0p0", a)] for a in range(8)], [15, 15, 15, 15, 1, 2, 4, 8])
        # fixed pattern 1xxxx: cycle c takes bit 3 - c (mn_pe_lsu f_all)
        self.assertEqual([rec[("OMR", "n0c0b0m0p0", 68 + c)] for c in range(4)], [0, 0, 0, 15])
        self.assertEqual(len([1 for s, _, _ in rec if s == "LM1"]), 512)
        self.assertEqual(rec[("LM1", "n0c0b0m0p0", 511)], 0xAAAAAAAAAAAAAAAA)
        self.assertEqual(r.stats["dropped"], 1)
        self.assertEqual(r.stats["skipped_d"], 2)
        self.assertEqual(r.stats["rlines"], 1)
        self.assertFalse(any(s == "L1BM" for s, _, _ in rec))
        self.assertIn("LM0W n0c0b0m0p0 0x0001 0000000089abcdef", r.lines())

    def test_stop_in_window(self):
        """A RUN that stops reports the program entry (window base + pc) and the E_RANGE word."""
        dev, fd = dev_on_fake(imem_depth=4)
        fd.stop_rule = lambda start, count: (1, start + 1, start + 1) if fd.runs[-1:] and len(fd.runs) == 2 else None
        text = "\n".join([J0] * 10)
        r = mh.execute_program(dev, mh.parse_asm(text), mh.Topology())
        self.assertEqual(fd.runs, [(0, 4), (0, 4)])
        self.assertEqual((r.stop.reason, r.stop_entry, r.stats["e_range_word"]), (1, 5, 5))


if __name__ == "__main__":
    unittest.main(verbosity=1)

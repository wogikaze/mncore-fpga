"""Offline tests for mnplan / mnrun (no board needed):  python mncore/tools/host/test_mnrun.py

The word analysis on words made with mnisa.codec, the liveness and the plan, and the executor
(mnrun.ProgramRun) on a fake board whose members keep memories like mn_top_multi: the configuration
clears the PEs / L1BM / L2BM / MV tags and keeps the SDRAM; RESET clears the SDRAM too (a member with it).
"""
import os
import sys
import unittest
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

import mnhost as mh                      # noqa: E402
import mnplan as mp                      # noqa: E402
import mnrun as mr                       # noqa: E402
from mnisa import codec                  # noqa: E402

NONE_ALU = {"ll": 1, "pe_aluc_dmode": 3, "pe_aluc_aluop": 0, "pe_aluc_isela": 8, "pe_aluc_iselb": 7,
            "l1bm_isel": 7, "pe_mauc_isela": 7, "pe_mauc_iselb": 7, "pe_mauc_iselc": 7}


def jword(**f) -> int:
    v = dict(NONE_ALU)
    v.update(f)
    return mh.imem_entry("j", int(codec.encode(v, "j"), 2))


def mword(**f) -> int:
    return mh.imem_entry("m", int(codec.encode(f, "m"), 2))


IMM = jword(pe_aluc_aluop=0b11111, pe_aluc_dmode=0)                         # imm: writes $aluf
MAU_LR = jword(pe_mauc_enfma=1, pe_mauc_dmode=1, pe_mauc_isela=0, pe_mauc_iselb=0, pe_mauc_iselc=0)
MAU_ALUF = jword(pe_mauc_enfma=1, pe_mauc_dmode=1, pe_mauc_isela=6, pe_mauc_iselb=0, pe_mauc_iselc=0)
L1_READ = jword(l1bm_bmode=1, l1bm_ladr=8)                                   # l1bmm $lb8 ... (lwrite 0)
L1_LBF = jword(l1bm_lwrite=1, l1bm_bmode=1, l1bm_isel=7, l1bm_wl=1)           # PE -> L1BM of $lbf
L2_WORD = jword(l2bm_lwrite=1, l2bm_bdmode=1)
FLOOR = jword(pe_aluc_aluop=0b11110, pe_aluc_dmode=1, pe_aluc_iselb=0b110, pe_aluc_isela=0)
FMAX = jword(pe_aluc_aluop=0b11011, pe_aluc_dmode=1, pe_aluc_isela=0, pe_aluc_iselb=1)
RSQRT = jword(pe_aluc_aluop=0b10000, pe_aluc_dmode=1, pe_aluc_isela=0)
NOP = mh.imem_entry("j", 0)


def wait_word(tag):
    return mh.imem_entry("j", int(codec.encode({"ll": 0, "wd": tag}, "j"), 2))


def member(name, **p):
    p.setdefault("UNITS", 2)
    return mp.Member(name=name, params=p, caps=mp.member_caps(p), rule="zero", fs=None, design_id=5,
                     flags=mp.member_flags(p))


M2A = member("M2a", UNITS=2)
MAU = member("MAU", UNITS=0, MAU=1)
MAUN = member("MAUN", UNITS=0, MAU=1, SDRAM=0)


class Words(unittest.TestCase):
    def w(self, e):
        return mp.analyze_entries([e])[0]

    def test_needs(self):
        self.assertEqual(self.w(IMM).needs, frozenset())
        self.assertEqual(self.w(IMM).writes, {"aluf"})
        self.assertEqual(self.w(MAU_LR).needs, {"MAU"})
        self.assertEqual(self.w(MAU_LR).writes, {"mauf"})
        self.assertEqual(self.w(MAU_ALUF).reads, {"aluf"})
        self.assertEqual(self.w(L1_READ).needs, {"L1"})
        self.assertEqual(self.w(L1_READ).writes, {"lbf"})
        w = self.w(L1_LBF)
        self.assertEqual(w.needs, {"L1"})
        self.assertEqual(w.reads, {"lbf"})
        self.assertEqual(w.writes, {"lbf", "lbi0", "lbi1", "lbim"})
        self.assertEqual(self.w(L2_WORD).needs, {"L2"})
        self.assertEqual(self.w(FLOOR).needs, {"FP1"})
        self.assertEqual(self.w(FMAX).needs, {"FP2"})
        self.assertEqual(self.w(RSQRT).needs, {"FP3"})
        self.assertEqual(self.w(wait_word(5)).needs, {"MV"})
        self.assertEqual(self.w(NOP).needs, frozenset())
        m = self.w(mword(valid=1, mmode=6, mvid=7))
        self.assertEqual((m.needs, m.tag_issue), ({"MV"}, 7))
        self.assertEqual(self.w(mword(valid=0)).needs, frozenset())

    def test_caps(self):
        self.assertTrue(M2A.supports({"L1", "L1R", "L2", "MV", "SDRAM"}))
        self.assertFalse(M2A.supports({"MAU"}))
        self.assertTrue(MAU.supports({"MAU", "MAUF", "SDRAM"}))
        self.assertFalse(MAUN.supports({"SDRAM"}))
        f3 = member("F3", UNITS=0, FPALU=3)
        self.assertTrue(f3.supports({"FP3"}) and not f3.supports({"FP2"}) and not f3.supports({"FP1"}))
        self.assertEqual(mp.member_flags({"FPALU": 3, "MAU": 1}), 0x1d)
        self.assertEqual(mp.member_flags({"REPLICA": 1}), 0x81)

    def test_nop_m_word(self):
        f = codec.decode(mr.nop_m_word(0x5a) & ((1 << 82) - 1), "m")
        self.assertEqual((f["valid"], f["mmode"], f["mvid"]), (1, 7, 0x5a))


class Plan(unittest.TestCase):
    def test_liveness_blocks_a_switch(self):
        ws = mp.analyze_entries([IMM, MAU_ALUF, L1_READ])
        live = mp.liveness(ws)
        self.assertEqual(live[1], {"aluf"})            # imm -> the MAU word reads $aluf
        self.assertEqual(live[2], frozenset())
        p = mp.plan(ws, [M2A, MAU])
        self.assertTrue(p.complete)
        self.assertEqual([(s.a, s.b, s.member.name) for s in p.segments], [(0, 2, "MAU"), (2, 3, "M2a")])

    def test_unwritten_state_is_not_live(self):
        # $lbf read before any word wrote it: its value after reset, not carried over
        ws = mp.analyze_entries([MAU_LR, L1_LBF])
        self.assertEqual(mp.liveness(ws)[1], frozenset())

    def test_no_member(self):
        ws = mp.analyze_entries([IMM, jword(pe_mauc_enfma=1, pe_mauc_dmode=1, pe_mauc_isela=0, pe_mauc_iselb=0,
                                            pe_mauc_iselc=0, l1bm_bmode=1, l1bm_ladr=8)])
        p = mp.plan(ws, [M2A, MAU])
        self.assertFalse(p.complete)
        self.assertIn("word 1 needs L1+MAU", p.problem)
        self.assertEqual(len(p.segments), 1)

    def test_live_across_every_switch(self):
        ws = mp.analyze_entries([IMM, L1_READ, MAU_ALUF])     # $aluf of word 0 read by word 2
        p = mp.plan(ws, [M2A, MAU])
        self.assertFalse(p.complete)
        self.assertIn("hidden state (aluf)", p.problem)

    def test_prefers_the_loaded_member(self):
        ws = mp.analyze_entries([IMM, NOP])
        self.assertEqual(mp.plan(ws, [M2A, MAU], first=MAU).segments[0].member.name, "MAU")
        self.assertEqual(mp.plan(ws, [M2A, MAU], first=M2A).segments[0].member.name, "M2a")


# --------------------------------------------------------------------------------- fake board
class FakeDev:
    """A member on the board: memories by (space, loc, addr); the SDRAM dict outlives it."""

    def __init__(self, m, sdram):
        self.m, self.sdram = m, sdram
        self.mem, self.imem, self.tags, self.runs = {}, {}, {}, []
        self.link = SimpleNamespace(baudrate=1000000, stats={"retries": 0}, ser=SimpleNamespace(close=lambda: None))
        self.last = mh.Status(False, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, False)
        self.resets = 0

    def info(self, refresh=False):
        c = self.m.caps
        depth = {0: 4096, 1: 256, 2: 256, 3: 256, 4: 256, 5: 8}
        if "L1" in c:
            depth[6] = 1024
        if "L2" in c:
            depth[7] = 2048
        if "SDRAM" in c:
            depth[8], depth[9] = 1 << 17, 1 << 19
        return mh.Info(1, 5, 2048, 27000000, 6912, 512, (1, 1, 1, 1, 4), self.m.flags, depth, 1024, 1024)

    def reset(self, clear_counters=False):
        self.resets += 1
        self.mem.clear()
        self.tags.clear()
        if "SDRAM" in self.m.caps:
            self.sdram.clear()

    def _store(self, space):
        if space in (8, 9):
            if "SDRAM" not in self.m.caps:
                raise mh.DeviceError(4, 5, b"")
            return self.sdram
        if (space == 6 and "L1" not in self.m.caps) or (space == 7 and "L2" not in self.m.caps):
            raise mh.DeviceError(4, 5, b"")
        return self.mem

    def write(self, space, loc, addr, words, mask=0xFF, window=0):
        st = self._store(space)
        bm = sum(0xFF << (8 * i) for i in range(8) if (mask >> i) & 1)
        for i, v in enumerate(words):
            k = (space, loc, addr + i)
            st[k] = (st.get(k, 0) & ~bm) | (v & bm)

    def read(self, space, loc, addr, n, window=0):
        st = self._store(space)
        return [st.get((space, loc, addr + i), 0) for i in range(n)]

    def write_imem(self, addr, entries):
        for i, e in enumerate(entries):
            self.imem[addr + i] = e

    def run(self, start, count):
        ents = [self.imem[start + i] for i in range(count)]
        self.runs.append(ents)
        steps, reason, info = 0, 0, 0
        for e in ents:
            if (e >> 446) == mh.IMEM_TYPE_M:
                f = codec.decode(e & ((1 << 82) - 1), "m")
                if f["valid"]:
                    if "MV" not in self.m.caps:
                        reason, info = 2, 0x80
                        break
                    self.tags[f["mvid"]] = min(self.tags.get(f["mvid"], 0) + 1, 2)
            else:
                f = codec.decode(e & ((1 << 426) - 1), "j")
                if f["wd"]:
                    if self.tags.get(f["wd"], 0) == 0 or "MV" not in self.m.caps:
                        reason, info = 4, f["wd"]
                        break
                    self.tags[f["wd"]] = 0
            steps += 1
        self.last = mh.Status(False, reason, start + steps, info, steps, 0, 0, 0, 0, 0, 0, False)

    def wait_idle(self, timeout=10.0):
        return self.last

    def status(self):
        return self.last

    def set_baud(self, b):
        pass


class FakeBoard(mr.Board):
    def __init__(self, members, decay=None):
        super().__init__(members, log=lambda s: None)
        self.sdram = {}
        self.history = []
        self.decay = decay or {}                 # (space, loc, addr) -> bits that flip on a configuration

    def load(self, m, st=None):
        for k, bits in self.decay.items():       # the SDRAM is not refreshed while the FPGA is configured
            self.sdram[k] = self.sdram.get(k, 0) ^ bits
        self.dev = FakeDev(m, self.sdram)
        self.cur = m
        self.history.append(m.name)
        if st is not None:
            st.loads += 1

    def ensure(self):
        pass

    def close(self):
        pass


def program(entries, events):
    p = mh.AsmProgram(entries=list(entries))
    for pos, line in events:
        d = mh.parse_rline(line) if line.startswith("r ") else mh.parse_dline(line)
        p.events.append((pos, d))
    return p


class Executor(unittest.TestCase):
    def test_hand_over(self):
        # words: MAU part, L1BM + MV part (an m word with tag 5), MAU part, the wait for tag 5
        ents = [IMM, MAU_LR, L1_READ, mword(valid=1, mmode=7, mvid=5), MAU_LR, wait_word(5)]
        ev = [(0, "d set $lm0n0c0b0m0p1 1 1111222233334444"),
              (0, "d set $lb0n0c0b0 1 5555666677778888"),
              (0, "r 0 10 1 99990000aaaabbbb"),
              (6, "d get $lm0n0c0b0m0p1 1"),
              (6, "d get $lb0n0c0b0 1"),
              (6, "d get $d16n0 1")]
        b = FakeBoard([M2A, MAUN])
        pr = mr.ProgramRun(b, program(ents, ev))
        r = pr.execute()
        self.assertIsNone(r.stop)
        self.assertEqual([(s.a, s.b, s.member.name) for s in pr.plan.segments],
                         [(0, 2, "MAUN"), (2, 4, "M2a"), (4, 5, "MAUN"), (5, 6, "M2a")])
        self.assertEqual(b.history, ["MAUN", "M2a", "MAUN", "M2a"])
        self.assertEqual(r.stats["switches"], 3)
        self.assertEqual(r.records[("LM0", "n0c0b0m0p1", 0)], 0x1111222233334444)
        self.assertEqual(r.records[("L1BM", "n0c0b0", 0)], 0x5555666677778888)
        self.assertEqual(r.records[("DRAM", "n0", 16)], 0x99990000aaaabbbb)
        # the second M2a got the tag count of the m word back (an mmode 111 m word), so the wait passed
        self.assertIn([mr.nop_m_word(5)], b.dev.runs)

    def test_dram_d_get_after_a_member_without_sdram(self):
        ents = [L1_READ, MAU_LR]
        ev = [(0, "r 0 0 1 0123456789abcdef"), (2, "d get $d0n0 1"), (2, "d get $lm0n0c0b0m0p0 1")]
        b = FakeBoard([M2A, MAUN])
        pr = mr.ProgramRun(b, program(ents, ev))
        r = pr.execute()
        self.assertEqual(b.history, ["M2a", "MAUN", "M2a"])     # one more load for the DRAM d get
        self.assertEqual(r.records[("DRAM", "n0", 0)], 0x0123456789abcdef)
        self.assertEqual(r.records[("LM0", "n0c0b0m0p0", 0)], 0)

    def test_dram_cleared_once_per_program(self):
        b = FakeBoard([M2A, MAUN])
        b.sdram[(9, 0, 3)] = 0xdead                            # left by an earlier program
        pr = mr.ProgramRun(b, program([MAU_LR, L1_READ], [(2, "d get $d3n0 1")]))
        r = pr.execute()
        self.assertEqual(b.history, ["MAUN", "M2a"])
        self.assertEqual(r.records[("DRAM", "n0", 3)], 0)      # the RESET on M2a cleared it

    def test_zero_dram_is_cleared_again_after_a_switch(self):
        # MAU part, then an MV word: the DRAM held only zeros across the switch, a bit decayed meanwhile
        ents = [MAU_LR, L1_READ, mword(valid=1, mmode=7, mvid=3)]
        b = FakeBoard([M2A, MAU], decay={(9, 0, 5): 1 << 7})
        pr = mr.ProgramRun(b, program(ents, [(0, "r 0 8 1 00000000000000aa"), (3, "d get $d5n0 1"),
                                             (3, "d get $d8n0 1")]))
        r = pr.execute()
        self.assertEqual(b.history, ["MAU", "M2a"])
        self.assertEqual(r.records[("DRAM", "n0", 5)], 0)            # RESET on M2a cleared it again
        self.assertEqual(r.records[("DRAM", "n0", 8)], 0xaa)         # the r line came after that RESET

    def test_stop_ends_the_program(self):
        b = FakeBoard([M2A, MAU])
        pr = mr.ProgramRun(b, program([IMM, wait_word(9), NOP], [(3, "d get $lm0n0c0b0m0p0 1")]))
        r = pr.execute()
        self.assertEqual(r.stop.reason, 4)                     # WAIT: the d gets still read
        self.assertIn(("LM0", "n0c0b0m0p0", 0), r.records)


if __name__ == "__main__":
    unittest.main()

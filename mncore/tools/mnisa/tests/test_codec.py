"""decode / encode against assemble3 output (fixtures in tests/data, made by make_fixtures.py)."""
import random
import unittest
from pathlib import Path

from mnisa import codec, csv_import, schema
from mnisa.asm_io import read_asm
from mnisa.tests.make_fixtures import IMM_VALUES

DATA = Path(__file__).resolve().parent / "data"


def words(name):
    return [ln for ln in read_asm(DATA / f"{name}.asm") if ln.kind in ("j", "m")]


class FixtureTest(unittest.TestCase):
    """Same checks as verify_corpus.py, on the committed fixtures (no WSL needed)."""

    def check_file(self, name):
        ws = words(name)
        rows = csv_import.read_csv(DATA / f"{name}.csv").words()
        self.assertEqual([w.kind for w in ws], [r.kind for r in rows])
        self.assertGreater(len(ws), 0)
        for w, r in zip(ws, rows):
            self.assertEqual(r.bits, w.bits)  # CSV columns concatenate to the word
            dec = codec.decode(w.bits)
            self.assertEqual(csv_import.to_fields(r), dec)
            self.assertEqual(codec.encode(dec, w.kind), w.bits)

    def test_sample(self):
        self.check_file("sample")

    def test_imm_probe(self):
        self.check_file("imm_probe")

    def test_imm_payload(self):
        ws = [w for w in words("imm_probe") if w.kind == "j"]
        self.assertEqual(len(ws), len(IMM_VALUES))
        for w, (lit, payload) in zip(ws, IMM_VALUES):
            with self.subTest(literal=lit):
                self.assertTrue(codec.is_imm(w.bits))
                self.assertEqual(codec.imm_payload(w.bits), payload)
                self.assertTrue(codec.imm_replicas_ok(w.bits))
                cleared = codec.imm_insert(w.bits, 0)
                self.assertEqual(codec.imm_insert(cleared, payload), w.bits)


class SampleSemanticsTest(unittest.TestCase):
    """Spot checks of field meanings on sample.vsm (see spec/isa/j_flat.yaml)."""

    @classmethod
    def setUpClass(cls):
        cls.j = [codec.decode(w.bits) for w in words("sample") if w.kind == "j"]
        cls.m = [codec.decode(w.bits) for w in words("sample") if w.kind == "m"]

    def find(self, **cond):
        hits = [d for d in self.j if all(d[k] == v for k, v in cond.items())]
        self.assertTrue(hits, cond)
        return hits[0]

    def test_iadd_cycle_addresses(self):
        d = self.find(pe_aluc_aluop=0, pe_aluc_dmode=1, pe_aluc_isela=0b0011)  # iadd $lm8v $lr0v $ln8v
        ca = codec.cycle_addrs(d)
        self.assertEqual(ca["rfc0_r"], [0, 2, 4, 6])
        self.assertEqual(ca["lm0"], [8, 10, 12, 14])
        self.assertEqual(ca["lm1"], [8, 10, 12, 14])

    def test_flat_explicit_addresses(self):
        d = self.find(pe_lm1_adr=16, pe_lm1_write=1)  # lpassa $lm[0,4,10,14] $ln16v
        self.assertEqual(codec.cycle_addrs(d)["lm0"], [0, 4, 10, 14])
        self.assertEqual(codec.cycle_addrs(d)["lm1"], [16, 18, 20, 22])

    def test_ll(self):
        self.assertEqual(self.find(pe_rfc0_wadr=88)["ll"], 0b11)  # ...; noforward
        self.assertTrue(any(d["ll"] == 0 for d in self.j))  # nop

    def test_masks(self):
        d = self.find(pe_mrc_target_tr=1)  # lpassa $lr0 $t/0101
        self.assertEqual(d["pe_mrc_imr"], 0b10101)
        d = self.find(pe_mrc_zero=1)  # lpassa/0101 $lr0 $lr32
        self.assertEqual((d["pe_mrc_imr"], d["pe_mrc_zero_sel"]), (0b10101, 0b01))

    def test_mau_flags(self):
        d = self.find(pe_mauc_signa=1)  # fvfma -$lr0 $ls0e $lm0 $lr48
        self.assertEqual((d["pe_mauc_extb"], d["pe_mauc_signb"], d["pe_mauc_signc"]), (1, 0, 0))
        self.assertEqual(self.find(pe_mrc_omr=2)["pe_mrc_ifsel"], 1)  # fvadd ... $omr2
        self.assertEqual(self.find(pe_mrc_omr=3)["pe_mrc_ifsel"], 0)  # lpassa ... $omr3

    def test_l1bm(self):
        self.assertEqual(self.find(l1bm_bmode=0b01, l1bm_rmode=0, l1bm_lwrite=1)["l1bm_mabadr"], 2)  # l1bmm@2
        self.assertEqual(self.find(l1bm_rmode=1)["l1bm_opcode"], 0b1100)  # l1bmrsbor
        self.assertEqual(self.find(l1bm_bmode=0b11)["l1bm_isel"], 0b010)  # l1bmd $t $lb64

    def test_bar_write(self):
        d = self.find(pe_lm0_write=1, pe_lm0_madpe=3, pe_lm0_maadj=0, pe_aluc_aluop=0b01010)  # lpassa $lr0 $mb
        self.assertEqual(d["pe_lm0_wl"], 0)

    def test_mv(self):
        r = [d for d in self.m if d["tmode"] == 0b100 and d["mmode"] == 0b110][0]  # mvriand/n64 $lc0 $d0
        self.assertEqual((r["destid"] & 1, r["srcid"], r["dmode"]), (1, 0b010, 0b01))
        self.assertTrue(any(d["valid"] == 0 and not any(d.values()) for d in self.m))  # mvnop
        self.assertTrue(any(d["priority"] == 2 for d in self.m))  # mvp/n64p2
        self.assertTrue(any(d["mvid"] == 1 for d in self.m))
        self.assertEqual(self.find(wd=1)["ll"], 0)  # nop; wait i01


class CodecTest(unittest.TestCase):
    def test_random_round_trip(self):
        rnd = random.Random(1)
        for k in ("j", "m"):
            s = schema.load(k)
            for _ in range(200):
                bits = "".join(rnd.choice("01") for _ in range(s.width))
                self.assertEqual(codec.encode(codec.decode(bits), k), bits)
                vals = {f.name: rnd.getrandbits(f.width) for f in s.fields}
                self.assertEqual(codec.decode(codec.encode(vals, k)), vals)

    def test_int_and_bits_forms(self):
        bits = words("sample")[0].bits
        self.assertEqual(codec.decode(codec.to_int(bits), "j"), codec.decode(bits))
        self.assertEqual(codec.from_int(codec.to_int(bits), "j"), bits)
        db = codec.decode_bits(bits)
        self.assertEqual("".join(db.values()), bits)

    def test_encode_partial_and_errors(self):
        w = codec.encode({"ll": 1, "pe_aluc_aluop": "01010"})
        self.assertEqual(len(w), 426)
        self.assertEqual(codec.decode(w)["pe_aluc_aluop"], 0b01010)
        self.assertEqual(codec.nonzero(codec.decode(w)), {"ll": 1, "pe_aluc_aluop": 0b01010})
        with self.assertRaises(KeyError):
            codec.encode({"no_such_field": 1})
        with self.assertRaises(ValueError):
            codec.encode({"ll": 4})
        with self.assertRaises(ValueError):
            codec.encode({"ll": "1"})
        with self.assertRaises(ValueError):
            codec.decode("0" * 425)
        with self.assertRaises(ValueError):
            codec.decode("0" * 292)  # auto_stride 'i' words are out of scope
        with self.assertRaises(ValueError):
            codec.decode(1)  # int needs kind

    def test_verilog_bit_order(self):
        """Contract: jw[425-pos] is pos. A field value's MSB is at the field's pos."""
        f = schema.load("j")["wd"]
        w = codec.encode({"wd": 0b10000001})
        jw = int(w, 2)  # bit i of this int is Verilog jw[i]
        self.assertEqual((jw >> (425 - f.pos)) & 1, 1)
        self.assertEqual((jw >> (425 - (f.pos + f.width - 1))) & 1, 1)
        self.assertEqual((jw >> (425 - (f.pos + 1))) & 1, 0)


if __name__ == "__main__":
    unittest.main()

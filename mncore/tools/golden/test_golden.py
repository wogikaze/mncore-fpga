#!/usr/bin/env python3
"""Self-tests of the golden tools. Needs neither WSL nor the official tools.

    python mncore/tools/golden/test_golden.py

The Rust cross-check (golden_dump vs the captured official dump of testdata/dget_forms.vsm)
runs when mncore/golden_rs has been built (run_rust.py builds it); otherwise it is skipped.
"""

from __future__ import annotations

import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import corpus  # noqa: E402
import goldenlib as gl  # noqa: E402
import ndiff  # noqa: E402
import ndmp  # noqa: E402
import norm_gpfn3  # noqa: E402
import norm_mem  # noqa: E402

TESTDATA = HERE / "testdata"


def norm(lines):
    recs, _ = norm_gpfn3.records_from_lines(lines)
    return ndmp.canonical(recs)


class NormTest(unittest.TestCase):
    def test_long_word_default_dtype(self):
        d = norm(["DEBUG-GREG0(n0c0b0m0p0,2):(f:-inf, i:{{0xFFFF,0xFFFF},{0xFFFF,0xFFFF}}, "
                  "v:0xFFFFFFFFFFFFFFFF) #d get $lr0n0c0b0m0p0 4"])
        self.assertEqual(d, {("GRF0", "n0c0b0m0p0", 1): 0xFFFFFFFFFFFFFFFF})

    def test_odd_word_address_reads_aligned_long_word(self):
        d = norm(["DEBUG-LM0(n0c0b0m0p0,3):(f:-inf, i:{{0xFFFF,0xFFFF},{0xFFFF,0xFFFF}}, "
                  "v:0xFFFFFFFFFFFFFFFF) #d get $lm3n0c0b0m0p0 1"])
        self.assertEqual(d, {("LM0", "n0c0b0m0p0", 1): 0xFFFFFFFFFFFFFFFF})

    def test_two_long_words(self):
        d = norm(["DEBUG-LM0(n0c0b0m0p0,2):{(f:-inf, i:{{0xFFFF,0xFFFF},{0xFFFF,0xFFFF}}, v:0xFFFFFFFFFFFFFFFF), "
                  "(f:0, i:{{0x0,0x3},{0x0,0x4}}, v:0x300000004)} #d get $llm2n0c0b0m0p0 1"])
        self.assertEqual(d, {("LM0", "n0c0b0m0p0", 1): 0xFFFFFFFFFFFFFFFF, ("LM0", "n0c0b0m0p0", 2): 0x300000004})

    def test_typed_dumps(self):
        d = norm([
            "DEBUG-LM0(n0c0b0m0p0,3):(-inf) (0xffffffff) #d getf $m3n0c0b0m0p0 1",
            "DEBUG-GREG0(n0c0b0m0p0,1):(0, 0) (0x0000, 0x0002) #d geth $r1n0c0b0m0p0 1",
            "DEBUG-LM0(n0c0b0m0p0,0):(0, 0) (0x00000001, 0x00000002) #d getf $lm0n0c0b0m0p0 1",
            "DEBUG-LM1(n0c0b0m0p1,0):{(1.8e-226) (0x1111111122222222), (4.6e-62) (0x3333333344444444)} "
            "#d getd $lln0n0c0b0m0p1 1",
        ])
        self.assertEqual(d, {
            ("LM0W", "n0c0b0m0p0", 3): 0xFFFFFFFF,
            ("GRF0W", "n0c0b0m0p0", 1): 0x00000002,
            ("LM0", "n0c0b0m0p0", 0): 0x100000002,
            ("LM1", "n0c0b0m0p1", 0): 0x1111111122222222,
            ("LM1", "n0c0b0m0p1", 1): 0x3333333344444444,
        })

    def test_t_register(self):
        d = norm([
            "DEBUG-TREG(n0c0b0m0p0,1):{(f:0, i:{{0x0,0x0},{0x0,0x0}}, v:0x22), (f:0, i:{{0x0,0x0},{0x0,0x0}}, v:0x33)}"
            " #d get $lltn0c0b0m0p0 4",
            "DEBUG-TREG(n0c0b0m0p0,2):(f:0, i:{{0x0,0x0},{0x0,0x0}}, v:0x44) #d get $ltn0c0b0m0p0 4",
        ])
        self.assertEqual(d, {("T", "n0c0b0m0p0", 2): 0x22, ("T", "n0c0b0m0p0", 3): 0x33,
                             ("T", "n0c0b0m0p0", 4): 0x44})

    def test_mask_register_cycles(self):
        cmd = " #d get $omr17n0c0b0m0p0 1"
        d = norm([f"DEBUG-OMR(n0c0b0m0p0,17):Mask{{{v}}}{cmd}" for v in (0, 0, 0, 15)])
        self.assertEqual(d, {("OMR", "n0c0b0m0p0", 68): 0, ("OMR", "n0c0b0m0p0", 69): 0,
                             ("OMR", "n0c0b0m0p0", 70): 0, ("OMR", "n0c0b0m0p0", 71): 15})

    def test_block_and_offchip_memories(self):
        d = norm([
            "DEBUG-L1BM(n0c0b0,1):{(f:0, i:{{0x0,0x0},{0x0,0xB}}, v:0xB), (f:0, i:{{0x0,0x0},{0x0,0xF}}, v:0xF)}"
            " #d get $llb0n0c0b0 2",
            "DEBUG-L2BM(n0c0,2):(f:0, i:{{0x0,0x0},{0x0,0xC0}}, v:0xC0) #d get $lc1n0c0 2",
            "DEBUG-PIU(n0,16):(f:0, i:{{0x0,0x0},{0x0,0x5}}, v:0x5) #d get $p16n0 2",
            "DEBUG-DRAM(n3,17):(f:0, i:{{0x0,0x0},{0x0,0x6}}, v:0x6) #d get $d16 2",
        ])
        self.assertEqual(d, {("L1BM", "n0c0b0", 1): 0xB, ("L1BM", "n0c0b0", 5): 0xF, ("L2BM", "n0c0", 2): 0xC0,
                             ("PDM", "n0", 16): 5, ("DRAM", "n3", 17): 6})

    def test_last_read_wins(self):
        d = norm(["DEBUG-LM0(n0c0b0m0p0,0):(f:0, i:{{0x0,0x0},{0x0,0x0}}, v:0x1) #d get $lm0n0c0b0m0p0 1",
                  "DEBUG-LM0(n0c0b0m0p0,0):(f:0, i:{{0x0,0x0},{0x0,0x0}}, v:0x2) #d get $lm0n0c0b0m0p0 1"])
        self.assertEqual(d, {("LM0", "n0c0b0m0p0", 0): 2})


class NdmpTest(unittest.TestCase):
    def test_roundtrip_and_order(self):
        data = {("LM0", "n0c0b0m0p0", 0x10): 5, ("DRAM", "n0", 0x10000): 7, ("GRF1", "n0c0b0m0p3", 0xFF): 1}
        text = ndmp.dumps(data, {"src": "x"})
        lines = text.splitlines()
        self.assertEqual(lines[0], "# ndmp v1")
        body = [x for x in lines if not x.startswith("#")]
        self.assertEqual(body, sorted(body))
        self.assertIn("GRF1 n0c0b0m0p3 0x00ff 0000000000000001", body)
        self.assertIn("DRAM n0 0x00010000 0000000000000007", body)
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "a.ndmp"
            p.write_text(text, encoding="utf-8")
            back, meta = ndmp.read(str(p))
        self.assertEqual(back, data)
        self.assertEqual(meta["src"], "x")

    def test_loc_matches(self):
        self.assertTrue(ndmp.loc_matches("n0c0b0m0p0", "n0c0b0m0p0"))
        self.assertFalse(ndmp.loc_matches("n0c0b0m0p1", "n0c0b0m0p0"))
        self.assertTrue(ndmp.loc_matches("n0c0b0", "n0c0b0m0p0"))  # its L1BM
        self.assertTrue(ndmp.loc_matches("n0", "n0c0b0m0p0"))  # its DRAM
        self.assertFalse(ndmp.loc_matches("n2c1b5", "n0c0b0m0p0"))
        self.assertTrue(ndmp.loc_matches("n0c0b0m0p3", "n0c0b0m0"))
        self.assertFalse(ndmp.loc_matches("n0c0b0m10p3", "n0c0b0m1"))


class NdiffTest(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        d = Path(self.td.name)
        a = {("LM0", "n0c0b0m0p0", 0): 1, ("LM0", "n0c0b0m0p1", 0): 2, ("L1BM", "n0c0b0", 3): 3,
             ("LM0", "n0c0b0m0p0", 300): 9}
        b = dict(a)
        b[("LM0", "n0c0b0m0p1", 0)] = 99
        del b[("LM0", "n0c0b0m0p0", 300)]
        self.a, self.b = str(d / "a.ndmp"), str(d / "b.ndmp")
        ndmp.write(self.a, a)
        ndmp.write(self.b, b)

    def tearDown(self):
        self.td.cleanup()

    def run_ndiff(self, *args):
        out = io.StringIO()
        old, sys.stdout = sys.stdout, out
        try:
            rc = ndiff.main([self.a, self.b, *args])
        finally:
            sys.stdout = old
        return rc, out.getvalue()

    def test_differences_fail(self):
        rc, out = self.run_ndiff()
        self.assertEqual(rc, 1)
        self.assertIn("MISMATCH LM0 n0c0b0m0p1 0x0000", out)
        self.assertIn("ONLY-A LM0 n0c0b0m0p0 0x012c", out)

    def test_filters(self):
        self.assertEqual(self.run_ndiff("--only-pes", "n0c0b0m0p0", "--max-addr", "256")[0], 0)
        self.assertEqual(self.run_ndiff("--only-pes", "n0c0b0m0p0")[0], 1)  # address 300 is only in a
        self.assertEqual(self.run_ndiff("--only-pes", "n0c0b0m0p0", "--allow-missing")[0], 0)
        self.assertEqual(self.run_ndiff("--spaces", "L1BM")[0], 0)


class NormMemTest(unittest.TestCase):
    def test_memh_and_lines(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "lm0.hex").write_text("// LM0 words\n00000001\n00000002\n@4\ndeadbeef 0000_0005\n", encoding="utf-8")
            (d / "t.hex").write_text("0123456789abcdef\n", encoding="utf-8")
            (d / "rd.txt").write_text("GRF1 n0c0b0m0p0 0x10 ff  # read back\nDRAM n0 16 0x5\n", encoding="utf-8")
            out = d / "x.ndmp"
            rc = norm_mem.main(["-o", str(out), "--memh", f"LM0:n0c0b0m0p0:32:{d / 'lm0.hex'}",
                                "--memh", f"T:n0c0b0m0p0:64:{d / 't.hex'}", "--lines", str(d / "rd.txt")])
            self.assertEqual(rc, 0)
            data, _ = ndmp.read(str(out))
        self.assertEqual(data, {
            ("LM0", "n0c0b0m0p0", 0): 0x0000000100000002,
            ("LM0", "n0c0b0m0p0", 2): 0xDEADBEEF00000005,
            ("T", "n0c0b0m0p0", 0): 0x0123456789ABCDEF,
            ("GRF1", "n0c0b0m0p0", 16): 0xFF,
            ("DRAM", "n0", 16): 5,
        })


class CorpusTest(unittest.TestCase):
    def test_classify_opcode(self):
        cases = {
            "iadd": "alu_int", "lpassa": "alu_int", "ullsr": "alu_int", "imm": "alu_int", "zero": "alu_int",
            "fpassa": "fp", "dmax": "fp", "frelu": "fp", "hbfn/7": "fp", "dbfn": "fp",
            "fvfma": "mau", "hvmul": "mau", "dvadd": "mau", "fvmulr": "mau", "fvfmau": "mau",
            "fmfma": "matrix", "hmmul": "matrix", "dmwrite": "matrix", "fmread": "matrix", "msl": "matrix",
            "l1bmd": "l1bm", "l2bmb": "l2bm", "nop": "ctl", "nop/3": "ctl", "wait": "ctl",
            "iadd/1000": "alu_int",
        }
        for op, want in cases.items():
            self.assertEqual(corpus.classify_opcode(op), want, op)
        self.assertIsNone(corpus.classify_opcode("inc"))
        self.assertIsNone(corpus.classify_opcode("frobnicate"))

    def test_lm_operand_max(self):
        self.assertEqual(corpus.lm_operand_max("$lm0"), (1, False))
        self.assertEqual(corpus.lm_operand_max("$lm8v"), (8 + 6 + 1, False))
        self.assertEqual(corpus.lm_operand_max("$llm16v"), (16 + 12 + 3, False))
        self.assertEqual(corpus.lm_operand_max("$lm[0,4,8,12]"), (13, False))
        self.assertEqual(corpus.lm_operand_max("-$ln2v4/$imr1"), (2 + 12 + 1, False))
        self.assertEqual(corpus.lm_operand_max("$mt0"), (0, True))
        self.assertEqual(corpus.lm_operand_max("$lr0v"), (None, False))
        self.assertEqual(corpus.lm_operand_max("$mabid"), (None, False))
        self.assertEqual(corpus.lm_operand_max("$mb"), (None, False))


class GoldenlibTest(unittest.TestCase):
    def test_probe_sizes(self):
        self.assertEqual(len(gl.probe_lines("pe")), 6)
        self.assertEqual(len(gl.probe_lines("mab")), 4 * 6 + 2)
        self.assertEqual(len(gl.probe_lines("wide")), 6 * 6 + 3)
        self.assertEqual(gl.probe_lines("none"), [])

    def test_compose_solution_like_the_judge(self):
        sol = gl.PROBLEMS / "1.a-b" / "main.vsm"
        if not sol.exists():
            self.skipTest("submodule not checked out")
        prog = gl.load_program(sol, "auto", "none")
        self.assertEqual(prog.kind, "solution")
        self.assertEqual(prog.testcase, (gl.PROBLEMS / "1.a-b" / "testcase.vsm").resolve())
        src = prog.rust_source()
        self.assertLess(src.index("d set"), src.index(prog.main_vsm.strip().splitlines()[0]))
        self.assertTrue(prog.output.lstrip().startswith("#") or prog.output.lstrip().startswith("d "))

    def test_resolve_by_problem_name(self):
        f = gl.MNCORE / "docs" / "mnist-golf" / "submissions" / "10.sumrow.vsm"
        if not f.exists():
            self.skipTest("submodule not checked out")
        self.assertEqual(gl.resolve_testcase(f), (gl.PROBLEMS / "10.sumrow" / "testcase.vsm").resolve())

    def test_to_wsl(self):
        if sys.platform == "win32":
            self.assertEqual(gl.to_wsl(Path("C:/wgkz/x y/a.vsm")), "/mnt/c/wgkz/x y/a.vsm")


class RustCrossCheck(unittest.TestCase):
    """golden_dump reads every d get form like the official emulator (captured dump)."""

    def test_dget_forms(self):
        exe = gl.golden_dump_exe()
        if not exe.exists():
            self.skipTest("golden_dump not built (run run_rust.py once)")
        want, _ = norm_gpfn3.normalize_file(str(TESTDATA / "dget_forms.official.dmp"))
        prog = gl.load_program(TESTDATA / "dget_forms.vsm", "none", "none")
        res = gl.run_rust_program(prog, exe)
        self.assertEqual(res.status, "ok", res.message)
        got = ndmp.canonical(ndmp.iter_records(io.StringIO(res.body)))
        self.assertEqual(got, want)
        self.assertEqual(res.words, 5)

    def test_pdm_dget_differs_as_documented(self):
        """Known discrepancy: official `d get $p` shows DRAM, golden_dump shows PDM."""
        exe = gl.golden_dump_exe()
        if not exe.exists():
            self.skipTest("golden_dump not built (run run_rust.py once)")
        off, _ = norm_gpfn3.normalize_file(str(TESTDATA / "pdm_dget.official.dmp"))
        prog = gl.load_program(TESTDATA / "pdm_dget.vsm", "none", "none")
        res = gl.run_rust_program(prog, exe)
        self.assertEqual(res.status, "ok", res.message)
        rust = ndmp.canonical(ndmp.iter_records(io.StringIO(res.body)))
        data = {0: 0x1234567890ABCDEF, 1: 0x1111111122222222}
        for a, v in data.items():
            self.assertEqual(off[("L2BM", "n0c0", 128 + a)], v)  # the round trip worked
            self.assertEqual(rust[("L2BM", "n0c0", 128 + a)], v)
            self.assertEqual(off[("PDM", "n0", a)], off[("DRAM", "n0", a)])  # $p prints DRAM
            self.assertEqual(rust[("PDM", "n0", a)], v)  # the real PDM
        diff = {k for k in off if off[k] != rust.get(k)}
        self.assertEqual({k[0] for k in diff}, {"PDM"})


if __name__ == "__main__":
    unittest.main(verbosity=2)

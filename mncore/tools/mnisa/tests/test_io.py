"""asm_io / csv_import / dump on the fixtures."""
import contextlib
import io
import unittest
from pathlib import Path

from mnisa import asm_io, csv_import, dump

DATA = Path(__file__).resolve().parent / "data"


class AsmIoTest(unittest.TestCase):
    def test_kinds_and_round_trip(self):
        text = (DATA / "sample.asm").read_text(encoding="utf-8")
        lines = asm_io.parse_asm(text)
        kinds = [ln.kind for ln in lines]
        self.assertEqual(kinds[0], "d")
        self.assertEqual(kinds[1], "r")
        self.assertEqual(kinds[-1], "d")
        self.assertEqual(lines[0].args, ["set", "$lm0n0c0b0m0p0", "1", "000000260000001C"])
        self.assertEqual(asm_io.format_asm(lines), text)

    def test_crlf_and_comments(self):
        bits = "01" + "0" * 424
        lines = asm_io.parse_asm(f"# ! assembler version : x\r\nj {bits}\r\n\r\nd get $lm0n0c0b0m0p0 1\r\n")
        self.assertEqual([ln.kind for ln in lines], ["#", "j", "d"])
        self.assertEqual(lines[1].bits, bits)
        self.assertEqual(str(lines[0]), "# ! assembler version : x")
        self.assertEqual(asm_io.words(lines), [lines[1]])

    def test_rejects_bad_word(self):
        with self.assertRaises(ValueError):
            asm_io.parse_asm("j 0101\n")
        with self.assertRaises(ValueError):
            asm_io.parse_asm("m " + "2" * 82 + "\n")
        with self.assertRaises(ValueError):
            _ = asm_io.AsmLine("d", "get x").bits


class CsvImportTest(unittest.TestCase):
    def test_headers_and_rows(self):
        cf = csv_import.read_csv(DATA / "sample.csv")
        self.assertEqual(len(cf.headers["i"]), 95)  # auto_stride names
        self.assertEqual(cf.headers["m"][:3], ["valid", "mmode", "tmode"])
        asm_kinds = [ln.kind for ln in asm_io.read_asm(DATA / "sample.asm")]
        self.assertEqual([r.kind for r in cf.rows], asm_kinds)
        for r in cf.words(("j",)):
            self.assertEqual(len(r.cols), 110)

    def test_i_row_uses_header_names(self):
        hdr = {"i": ["ll", "pe.mrc.imr"]}
        row = csv_import.CsvRow("i", ["01", "10000"])
        self.assertEqual(csv_import.to_fields(row, hdr), {"ll": 1, "pe.mrc.imr": 16})

    def test_width_mismatch_is_reported(self):
        row = csv_import.parse_csv('j,="1",\n').rows[0]
        with self.assertRaises(ValueError):
            csv_import.to_fields(row)


class DumpTest(unittest.TestCase):
    def test_dump_lists_words(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            dump.main([str(DATA / "sample.asm"), "--no-d"])
        text = out.getvalue().splitlines()
        n_words = sum(1 for ln in asm_io.read_asm(DATA / "sample.asm") if ln.kind in ("j", "m"))
        self.assertEqual(len(text), n_words)
        self.assertTrue(any("imm_payload=0x12345678" in t for t in text))
        self.assertTrue(text[0].startswith("j0 (line 3): ll=01(normal)"))


if __name__ == "__main__":
    unittest.main()

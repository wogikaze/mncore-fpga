"""The YAML schemas cover every bit exactly once and follow the naming contract."""
import re
import unittest

from mnisa import schema


class SchemaTest(unittest.TestCase):
    def test_no_problems(self):
        for k in ("j", "m"):
            with self.subTest(kind=k):
                self.assertEqual(schema.load(k).check(), [])

    def test_widths(self):
        self.assertEqual(schema.load("j").width, 426)
        self.assertEqual(len(schema.load("j")), 110)  # the j row of --print-csv has 110 columns
        self.assertEqual(schema.load("m").width, 82)
        self.assertEqual(len(schema.load("m")), 12)

    def test_every_bit_exactly_once(self):
        """Independent of Schema.check(): no gap, no overlap, fields in CSV-column order."""
        for k in ("j", "m"):
            s = schema.load(k)
            with self.subTest(kind=k):
                owners = [[] for _ in range(s.width)]
                for f in s.fields:
                    for b in range(f.pos, f.pos + f.width):
                        owners[b].append(f.name)
                self.assertEqual([b for b, o in enumerate(owners) if len(o) != 1], [])
                self.assertEqual(sum(f.width for f in s.fields), s.width)
                by_col = sorted(s.fields, key=lambda f: f.csv_col)
                pos = 0
                for f in by_col:
                    self.assertEqual(f.pos, pos, f.name)
                    pos += f.width

    def test_naming_contract(self):
        """name = CSV name with '.' and '/' -> '_'; cycle 1..3 addresses add _c1.._c3 (contract section 2)."""
        s = schema.load("j")
        exceptions = {"l1bm_mabadr", "l1bm_opcode"}  # two columns share the CSV name l1bm.mabadr/opcode
        for f in s.fields:
            if f.name in exceptions:
                self.assertEqual(f.csv_name, "l1bm.mabadr/opcode")
            elif f.csv_name:
                self.assertEqual(f.name, f.csv_name.replace(".", "_").replace("/", "_"))
            elif f.group.startswith("addr_c"):
                c = int(f.group[-1])
                self.assertTrue(f.name.endswith(f"_c{c}"), f.name)
                self.assertIn(f.name[:-3], s.by_name)
                self.assertEqual(s[f.name[:-3]].width, f.width)
            else:
                self.assertEqual(f.name, f"rsv_{f.pos}")
        for f in schema.load("m").fields:
            self.assertEqual(f.name, f.csv_name)

    def test_known_positions(self):
        """Positions recorded on Scrapbox 機械語 (flat tables) and confirmed by probes."""
        s = schema.load("j")
        expect = {
            "pe_rfc0_wadr": 28, "pe_rfc0_radr": 41, "pe_rfc1_wadr": 53, "pe_rfc1_radr": 66, "pe_lm0_adr": 78,
            "pe_lm1_adr": 99, "pe_lm1_maadj": 111, "pe_lm1_madpe": 112, "pe_mauc_dmode": 116, "pe_mauc_exta": 132,
            "pe_mauc_extb": 133, "pe_mauc_extc": 134, "pe_aluc_dmode": 145, "pe_aluc_iselb": 159, "rsv_162": 162,
            "l1bm_mabadr": 187, "l1bm_opcode": 191, "wd": 238,
            "pe_rfc0_wadr_c1": 246, "pe_rfc0_radr_c1": 255, "pe_rfc1_wadr_c1": 264, "pe_rfc1_radr_c1": 273,
            "pe_lm0_adr_c1": 282, "pe_lm1_adr_c1": 294, "pe_rfc0_wadr_c2": 306, "pe_lm0_adr_c2": 342,
            "pe_rfc0_wadr_c3": 366, "pe_lm0_adr_c3": 402, "pe_lm1_adr_c3": 414,
        }
        for name, pos in expect.items():
            self.assertEqual(s[name].pos, pos, name)
        m = schema.load("m")
        for name, (pos, w) in {"valid": (0, 1), "mmode": (1, 3), "tmode": (4, 3), "destid": (7, 3), "srcid": (10, 3),
                               "dmode": (13, 2), "mvid": (15, 8), "indirect": (23, 1), "adra": (24, 30),
                               "adrb": (54, 15), "nw": (69, 11), "priority": (80, 2)}.items():
            self.assertEqual((m[name].pos, m[name].width), (pos, w), name)

    def test_cycle_addr(self):
        s = schema.load("j")
        self.assertEqual(set(s.cycle_addr), {"rfc0_w", "rfc0_r", "rfc1_w", "rfc1_r", "lm0", "lm1"})
        for key, names in s.cycle_addr.items():
            self.assertEqual([s[n].addr_info()["cycle"] for n in names], [0, 1, 2, 3])
            self.assertEqual(len({s[n].addr_info()["unit"] for n in names}), 1)

    def test_imm_layout(self):
        s = schema.load("j")
        bits = sorted(b for seg in s.imm_layout["segments"] for b in range(seg["bits"][1], seg["bits"][0] + 1))
        self.assertEqual(bits, list(range(32)))
        self.assertIn("pe_lm0_adr_c3", s.imm_fields())

    def test_unknown_md_positions(self):
        """Every '`a` / `b`（x..y）' in UNKNOWN.md must match the schema bit ranges."""
        text = (schema.SPEC_DIR / "UNKNOWN.md").read_text(encoding="utf-8")
        found = 0
        for m in re.finditer(r"((?:`\w+`(?:、| / )?)+)（(\d+)(?:\.\.(\d+))?）", text):
            names = re.findall(r"`(\w+)`", m.group(1))
            lo, hi = int(m.group(2)), int(m.group(3) or m.group(2))
            for k in ("j", "m"):
                s = schema.load(k)
                if all(n in s.by_name for n in names):
                    bits = sorted(b for n in names for b in range(s[n].pos, s[n].end))
                    self.assertEqual(bits, list(range(lo, hi + 1)), m.group(0))
                    found += 1
                    break
            else:
                self.fail(f"unknown field in UNKNOWN.md: {m.group(0)}")
        self.assertGreater(found, 10)

    def test_enum_values_fit(self):
        for k in ("j", "m"):
            for f in schema.load(k).fields:
                for e in f.enum:
                    self.assertEqual(len(e.val), f.width, f"{f.name} {e.val}")
                    self.assertTrue(e.name.isidentifier(), f"{f.name} {e.name}")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Make the test vectors of the RTL decoders (WP10) and check that the generated RTL is up to date.

    python mncore/sim/tb/dec/gen_vectors.py            full set -> mncore/sim/vectors/dec/{j,m}.memb
    python mncore/sim/tb/dec/gen_vectors.py --fixed    small set -> mncore/sim/vectors_fixed/dec/ (committed)
    python mncore/sim/tb/dec/gen_vectors.py --check-fixed   exit 1 if the committed small set is stale
    python mncore/sim/tb/dec/gen_vectors.py --require-corpus   fail when the corpus cache is missing
    then: python mncore/tools/simrun.py dec --lint --synth

Words (deduplicated; a combinational decoder gives the same output for the same word):
  1. corpus: every j / m word that assemble3 (judge 2024 flat, packer disabled) produced for the
     .vsm files of third_party/mncore, read from the cache of mnisa/verify_corpus.py
     (mncore/tools/mnisa/build/corpus/out/*.flat.asm, sources with return code 0 only).
  2. fixtures: mncore/tools/mnisa/tests/data/*.asm (assemble3 output committed by WP01).
  3. synthetic (seeded): random words, random words cleaned to supported values, single-field
     changes of the nop word, and targeted unsupported values (each check, with the gates on / off).

Expected values (the reference): fields = mnisa.decode, cycle addresses = mnisa.cycle_addrs,
imm = mnisa.is_imm / imm_payload, enum applicability = mnisa.schema.enum_applies / enum_name.
The issue-group flags and the unsupported rule are recomputed here in Python, independently of the
Verilog written by mncore/tools/gen_dec.py. The vector layout comes from gen_dec.j_items / m_items.

Before writing, the script checks that the generated RTL is up to date (gen_dec --check) and that the
corpus satisfies the assumptions behind the issue-group flags (see ground_checks).
"""
from __future__ import annotations

import argparse
import collections
import glob
import os
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
TOOLS = REPO / "mncore" / "tools"
sys.path.insert(0, str(TOOLS))

import gen_dec  # noqa: E402
from mnisa import codec, schema  # noqa: E402
from mnisa.asm_io import read_asm  # noqa: E402

CORPUS_OUT = TOOLS / "mnisa" / "build" / "corpus" / "out"
CORPUS_FILES = TOOLS / "mnisa" / "build" / "corpus" / "files.tsv"
FIXTURES = sorted((TOOLS / "mnisa" / "tests" / "data").glob("*.asm"))
OUT_FULL = REPO / "mncore" / "sim" / "vectors" / "dec"
OUT_FIXED = REPO / "mncore" / "sim" / "vectors_fixed" / "dec"
FIXED_NOTE = "fixed (fixtures + small synthetic)"

SJ = schema.load("j")
SM = schema.load("m")

# The word assemble3 emits for 'nop' (probe, judge 2024 assemble3): all fields 0 except these.
NOP_FIELDS = {
    "pe_rfc0_wwl": 1, "pe_rfc0_rwl": 1, "pe_rfc1_wwl": 1, "pe_mauc_isela": 7, "pe_mauc_iselb": 7,
    "pe_mauc_iselc": 7, "pe_aluc_dmode": 3, "pe_aluc_isela": 8, "pe_aluc_iselb": 7, "l1bm_isel": 7,
    "l2bm_dmode": 3,
}
NOP = codec.encode(NOP_FIELDS, "j")


# ---------------------------------------------------------------------------------------------
# reference model

def ref_groups(d: dict, imm: bool, ex: bool) -> dict[str, bool]:
    nop = codec.decode(NOP, "j")

    def wr(unit, isel=None):
        w = d[f"pe_{unit}_write"] == 1
        return w if isel is None else w and d[f"pe_{unit}_isel"] == isel

    lm0_base = d["pe_lm0_maadj"] == 0 and d["pe_lm0_madpe"] == 0b11
    lm1_base = d["pe_lm1_maadj"] == 0 and d["pe_lm1_madpe"] == 0b11
    l1bm_fields = [f.name for f in SJ.fields if f.group == "l1bm" and f.name not in ("l1bm_gwrite", "l1bm_gadr")]
    l1bm = any(d[n] != nop[n] for n in l1bm_fields)
    l1bm |= wr("trc", 2) or wr("rfc0", 2) or wr("rfc1", 2) or wr("lm1", 2) or (wr("lm0", 2) and not imm)
    g = {
        "ALU": not (d["pe_aluc_dmode"] == 3 and d["pe_aluc_aluop"] == 0),
        "IMM": imm,
        "MAU": d["pe_mauc_enfma"] == 1,
        "MW": d["pe_mauc_mw"] == 1,
        "L1BM": l1bm,
        "L2BM": bool(d["l1bm_gwrite"] or d["l2bm_lwrite"] or d["l2bm_darsend"] or d["l2bm_darwrite"]),
        "WAIT": d["wd"] != 0,
        "WR_T": wr("trc"),
        "WR_GRF0": wr("rfc0"),
        "WR_GRF1": wr("rfc1"),
        "WR_LM0": wr("lm0") and not imm and not lm0_base,
        "WR_LM1": wr("lm1") and not lm1_base,
        "WR_MB": wr("lm0") and not imm and lm0_base,
        "WR_NB": wr("lm1") and lm1_base,
        "WR_OMR": d["pe_mrc_omr"] != 0,
    }
    assert list(g) == gen_dec.GROUP_NAMES
    # 'nop ; wait i01' is an ll = 00 word with wd = 01: wait counts in every word but ll = 10
    return {k: bool(v) and (d["ll"] != 0b10 if k == "WAIT" else ex) for k, v in g.items()}


def ref_unsup(kind: str, d: dict, imm: bool) -> list[str]:
    """Names of the fields whose value is not supported, in field order."""
    s = SJ if kind == "j" else SM
    out = []
    if kind == "j":
        if d["ll"] == 0b10:
            return ["ll"]
        if d["ll"] == 0b00:
            return []
    elif d["valid"] == 0:
        return []
    for f in s.fields:
        if f.group == "rsv":
            if d[f.name] != 0:
                out.append(f.name)
        elif f.enum and f.name != "ll" and s.enum_applies(f, d, imm) and f.enum_name(d[f.name]) is None:
            out.append(f.name)
    return out


def expect_j(bits: str) -> dict[str, int]:
    d = codec.decode(bits, "j")
    imm = codec.is_imm(bits)
    ex = d["ll"] in (0b01, 0b11)
    e = dict(d)
    e.update(exec=int(ex), nop=int(d["ll"] == 0), noforward=int(d["ll"] == 0b11))
    for key, vals in codec.cycle_addrs(d).items():
        for c, v in enumerate(vals):
            e[f"cyc_{key}[{c}]"] = v
    e["is_imm"] = int(imm)
    e["imm32"] = codec.imm_payload(bits)
    for k, v in ref_groups(d, imm, ex).items():
        e[f"grp.{k}"] = int(v)
    bad = ref_unsup("j", d, imm)
    idx = {f.name: i for i, f in enumerate(SJ.fields)}
    e["unsup_vec"] = sum(1 << idx[n] for n in bad)
    e["err_field"] = idx[bad[0]] if bad else 0
    e["err_kind"] = 0 if not bad else (1 if bad[0] == "ll" else 2)
    return e


def expect_m(bits: str) -> dict[str, int]:
    d = codec.decode(bits, "m")
    e = dict(d)
    bad = ref_unsup("m", d, False)
    idx = {f.name: i for i, f in enumerate(SM.fields)}
    e["unsup_vec"] = sum(1 << idx[n] for n in bad)
    e["err_field"] = idx[bad[0]] if bad else 0
    e["err_kind"] = 2 if bad else 0
    return e


def vec_line(bits: str, exp: dict, items) -> str:
    parts = [bits]
    for label, _, w, slot in items:
        v = exp[label]
        if v < 0 or v >> w:
            raise ValueError(f"{label}={v} does not fit in {w} bits")
        parts.append(format(v, f"0{slot}b"))
    return "_".join(parts)


# ---------------------------------------------------------------------------------------------
# word sources

def corpus_words(require: bool) -> tuple[list[str], list[str], int, int, int]:
    """(j words, m words, sources, j total, m total) from the verify_corpus cache."""
    if not CORPUS_OUT.is_dir():
        if require:
            sys.exit(f"corpus cache missing: {CORPUS_OUT} (run python mncore/tools/mnisa/verify_corpus.py)")
        return [], [], 0, 0, 0
    jw, mw = [], []
    nsrc = 0
    for p in sorted(glob.glob(str(CORPUS_OUT / "*.flat.asm"))):
        rc = Path(p[:-4] + ".rc")
        if not rc.exists() or rc.read_text().strip() != "0":
            continue
        nsrc += 1
        for ln in read_asm(p):
            if ln.kind == "j":
                jw.append(ln.bits)
            elif ln.kind == "m":
                mw.append(ln.bits)
    return jw, mw, nsrc, len(jw), len(mw)


def fixture_words(small: bool = False) -> tuple[list[str], list[str]]:
    """Words of the mnisa fixtures. small: sample.asm and the first 4 j words of each other fixture."""
    jw, mw = [], []
    for p in FIXTURES:
        n = 0
        for ln in read_asm(p):
            if ln.kind == "j":
                n += 1
                if not small or p.stem == "sample" or n <= 4:
                    jw.append(ln.bits)
            elif ln.kind == "m":
                mw.append(ln.bits)
    return jw, mw


def set_field(bits: str, s, name: str, v: int) -> str:
    f = s[name]
    return bits[:f.pos] + format(v, f"0{f.width}b") + bits[f.end:]


def clean(bits: str, kind: str, rng: random.Random) -> str:
    """Make every value supported (keep the rest): ll / valid on, rsv 0, enum values from the tables."""
    s = SJ if kind == "j" else SM
    if kind == "j":
        bits = set_field(bits, s, "ll", rng.choice((0b01, 0b11)))
    else:
        bits = set_field(bits, s, "valid", 1)
    for _ in range(3):  # enum_when / imm depend on other fields; settle
        d = codec.decode(bits, kind)
        imm = kind == "j" and codec.is_imm(bits)
        for f in s.fields:
            if f.group == "rsv" and d[f.name]:
                bits = set_field(bits, s, f.name, 0)
            elif f.enum and s.enum_applies(f, d, imm) and f.enum_name(d[f.name]) is None:
                bits = set_field(bits, s, f.name, int(rng.choice(f.enum).val, 2))
    return bits


def rand_bits(rng: random.Random, n: int) -> str:
    return format(rng.getrandbits(n), f"0{n}b")


def unsup_targets(kind: str):
    """(field, [unsupported values]) for every check."""
    s = SJ if kind == "j" else SM
    out = []
    for f in s.fields:
        if kind == "j" and f.name == "ll":
            continue
        if f.group == "rsv":
            out.append((f, list(range(1, 1 << f.width))))
        elif f.enum and len(f.enum) < (1 << f.width):
            ok = {int(e.val, 2) for e in f.enum}
            out.append((f, [v for v in range(1 << f.width) if v not in ok]))
    return out


def synth_j(rng: random.Random, bases: list[str], n_rand: int, n_clean: int, small: bool) -> list[str]:
    W = SJ.width
    out = []
    out += [rand_bits(rng, W) for _ in range(n_rand)]
    out += [clean(rand_bits(rng, W), "j", rng) for _ in range(n_clean)]
    nop = NOP
    exe = set_field(nop, SJ, "ll", 0b01)
    out += [nop, exe, set_field(nop, SJ, "ll", 0b11), set_field(nop, SJ, "ll", 0b10)]
    ones = "1" * W  # every field at its maximum: each field toggles against the nop word
    out += [ones, set_field(ones, SJ, "ll", 0b01), set_field(clean(ones, "j", rng), SJ, "pe_aluc_aluop", 0)]
    imm_base = set_field(exe, SJ, "pe_aluc_aluop", 0b11111)
    if not small:
        # one field changed from the nop word (exercises every term of the group logic on its own)
        for f in SJ.fields:
            if f.name == "ll":
                continue
            vals = [v for v in range(1 << f.width) if v != codec.decode(exe, "j")[f.name]]
            for v in rng.sample(vals, min(len(vals), 3)):
                out.append(set_field(exe, SJ, f.name, v))
    # PE writes of each source (isel) to each unit, also in an imm word; $mb / $nb
    for base in ((exe, imm_base) if not small else (exe,)):
        for u in ("trc", "rfc0", "rfc1", "lm0", "lm1"):
            for isel in (range(4) if not small else (2,)):
                w = set_field(base, SJ, f"pe_{u}_write", 1)
                out.append(set_field(w, SJ, f"pe_{u}_isel", isel))
        for u in ("lm0", "lm1"):
            for maadj in ((0, 1) if not small else (0,)):
                for madpe in (range(4) if not small else (3,)):
                    w = set_field(base, SJ, f"pe_{u}_write", 1)
                    w = set_field(w, SJ, f"pe_{u}_maadj", maadj)
                    out.append(set_field(w, SJ, f"pe_{u}_madpe", madpe))
    out.append(set_field(imm_base, SJ, "pe_lm0_write", 1))
    # targeted unsupported values, with each gate on and off (imm word, enum_when, ll = 00 / 10)
    for f, bad in unsup_targets("j"):
        bases_t = (exe, imm_base, rng.choice(bases)) if not small else (
            (exe, imm_base) if f.name in SJ.imm_fields() else (exe,))
        for v in (bad if not small else bad[:1]):
            for base in bases_t:
                b = clean(base, "j", rng)
                if f.enum_when:
                    for gv in range(1 << SJ[f.enum_when[0]].width):
                        out.append(set_field(set_field(b, SJ, f.enum_when[0], gv), SJ, f.name, v))
                else:
                    out.append(set_field(b, SJ, f.name, v))
                if not small:
                    w = set_field(out[-1], SJ, "ll", 0b00)
                    out += [w, set_field(w, SJ, "ll", 0b10)]
    if small:
        w = set_field(out[-1], SJ, "ll", 0b00)
        out += [w, set_field(w, SJ, "ll", 0b10)]
    # imm payloads
    for _ in range(2 if small else 64):
        b = clean(imm_base, "j", rng)
        b = set_field(b, SJ, "pe_aluc_is_unsigned", rng.getrandbits(1))
        out.append(codec.imm_insert(b, rng.getrandbits(32), replicate=rng.random() < 0.7))
    # two violations (priority of err_field)
    tg = unsup_targets("j")
    for _ in range(2 if small else 200):
        b = clean(rng.choice(bases), "j", rng)
        for f, bad in rng.sample(tg, 2):
            b = set_field(b, SJ, f.name, rng.choice(bad))
        out.append(b)
    return out


def synth_m(rng: random.Random, n_rand: int, n_clean: int, small: bool) -> list[str]:
    W = SM.width
    out = [rand_bits(rng, W) for _ in range(n_rand)]
    out += [clean(rand_bits(rng, W), "m", rng) for _ in range(n_clean)]
    zero = "0" * W
    out.append(zero)
    for f, bad in unsup_targets("m"):
        for v in (bad if not small else bad[:1]):
            for valid in (0, 1):
                b = clean(rand_bits(rng, W), "m", rng)
                out.append(set_field(set_field(b, SM, "valid", valid), SM, f.name, v))
    for f in SM.fields:
        out.append(set_field(zero, SM, f.name, (1 << f.width) - 1))
    return out


def dedup(words: list[str]) -> list[str]:
    seen = set()
    out = []
    for w in words:
        if w not in seen:
            seen.add(w)
            out.append(w)
    return out


# ---------------------------------------------------------------------------------------------
# assumptions behind the issue-group flags, checked on the corpus

def ground_checks(words: list[str]) -> list[str]:
    """Return violations (empty when every assumption holds on these words)."""
    probs = []
    nop = codec.decode(NOP, "j")
    l2 = [f.name for f in SJ.fields if f.group == "l2bm"] + ["l1bm_gwrite", "l1bm_gadr"]
    cnt = collections.Counter()
    for w in words:
        d = codec.decode(w, "j")
        imm = codec.is_imm(w)
        if d["ll"] == 0:
            continue
        units = [u for u in ("trc", "rfc0", "rfc1", "lm0", "lm1") if not (u == "lm0" and imm)]
        alu_none = d["pe_aluc_dmode"] == 3 and d["pe_aluc_aluop"] == 0
        if alu_none:
            cnt["alu_none"] += 1
            if any(d[f"pe_{u}_write"] and d[f"pe_{u}_isel"] == 1 for u in units) or (d["pe_mrc_omr"] and not d["pe_mrc_ifsel"]):
                probs.append(f"ALU result written without an ALU expression: {w}")
            if (d["pe_aluc_isela"], d["pe_aluc_iselb"], d["pe_aluc_is_unsigned"], d["pe_aluc_rounda"], d["pe_aluc_roundb"]) != (8, 7, 0, 0, 0):
                probs.append(f"ALU-none word with other ALUC values: {w}")
        if not d["pe_mauc_enfma"]:
            cnt["mau_none"] += 1
            if any(d[f"pe_{u}_write"] and d[f"pe_{u}_isel"] == 0 for u in units) or (d["pe_mrc_omr"] and d["pe_mrc_ifsel"]):
                probs.append(f"MAU result written with enfma=0: {w}")
        if not (d["l1bm_gwrite"] or d["l2bm_lwrite"] or d["l2bm_darsend"] or d["l2bm_darwrite"]):
            cnt["l2bm_none"] += 1
            if any(d[n] != nop[n] for n in l2):
                probs.append(f"L2BM fields set without gwrite/lwrite/darsend/darwrite: {w}")
        if ref_unsup("j", d, imm):
            probs.append(f"corpus word flagged unsupported {ref_unsup('j', d, imm)}: {w}")
    return probs


def ground_checks_m(words: list[str]) -> list[str]:
    return [f"corpus m word flagged unsupported: {w}" for w in words
            if ref_unsup("m", codec.decode(w, "m"), False)]


# ---------------------------------------------------------------------------------------------

def coverage(jwords: list[str], mwords: list[str], jexp: list[dict], mexp: list[dict]) -> list[str]:
    """Things the vector set must exercise; returns what is missing."""
    miss = []
    for g in gen_dec.GROUP_NAMES:
        vals = {e[f"grp.{g}"] for e in jexp}
        if vals != {0, 1}:
            miss.append(f"grp.{g} only {sorted(vals)}")
    for kind, exps, s in (("j", jexp, SJ), ("m", mexp, SM)):
        checks = gen_dec.unsup_checks(kind)
        idxs = {s.fields.index(c["field"]) for c in checks}
        for i in idxs:
            if not any(e["unsup_vec"] >> i & 1 for e in exps):
                miss.append(f"{kind} unsup_vec[{i}] ({s.fields[i].name}) never set")
            if not any(e["err_kind"] and e["err_field"] == i for e in exps):
                miss.append(f"{kind} err_field never {i} ({s.fields[i].name})")
        # m: E_UNSUPPORTED only while m.yaml has unsupported values (none since WP37: mn_mv decides)
        if {e["err_kind"] for e in exps} != ({0, 1, 2} if kind == "j" else ({0, 2} if checks else {0})):
            miss.append(f"{kind} err_kind values {sorted({e['err_kind'] for e in exps})}")
    for f in SJ.fields:  # every bit of every field toggles
        if len({e[f.name] for e in jexp}) < 2:
            miss.append(f"j field {f.name} constant")
    for f in SM.fields:
        if len({e[f.name] for e in mexp}) < 2:
            miss.append(f"m field {f.name} constant")
    return miss


def write_set(outdir: Path, jwords, mwords, note: str) -> tuple[list[dict], list[dict]]:
    ji, mi = gen_dec.j_items(), gen_dec.m_items()
    jexp = [expect_j(w) for w in jwords]
    mexp = [expect_m(w) for w in mwords]
    outdir.mkdir(parents=True, exist_ok=True)
    for kind, words, exps, items, width in (("j", jwords, jexp, ji, SJ.width), ("m", mwords, mexp, mi, SM.width)):
        total = width + gen_dec.exp_width(items)
        text = [f"// mn_dec vectors v1 kind={kind} count={len(words)} width={total} {note}"]
        text += [vec_line(w, e, items) for w, e in zip(words, exps)]
        with open(outdir / f"{kind}.memb", "w", encoding="ascii", newline="\n") as fh:
            fh.write("\n".join(text) + "\n")
    return jexp, mexp


def build(fixed: bool, require_corpus: bool, seed: int = 10):
    rng = random.Random(seed)
    fj, fm = fixture_words(small=fixed)
    if fixed:
        cj, cm, nsrc, tj, tm = [], [], 0, 0, 0
    else:
        cj, cm, nsrc, tj, tm = corpus_words(require_corpus)
    bases = [w for w in dedup(fj + cj) if codec.decode(w, "j")["ll"] != 0]
    sj = synth_j(rng, bases, 3 if fixed else 1500, 3 if fixed else 1500, fixed)
    sm = synth_m(rng, 4 if fixed else 500, 4 if fixed else 500, fixed)
    jwords = dedup(cj + fj + sj)
    mwords = dedup(cm + fm + sm)
    info = dict(corpus_sources=nsrc, corpus_j=tj, corpus_m=tm, corpus_j_unique=len(dedup(cj)),
                corpus_m_unique=len(dedup(cm)), fixture_j=len(fj), fixture_m=len(fm),
                synth_j=len(sj), synth_m=len(sm), total_j=len(jwords), total_m=len(mwords))
    return jwords, mwords, dedup(cj), dedup(cm), info


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fixed", action="store_true", help="write the small committed set")
    ap.add_argument("--check-fixed", action="store_true", help="exit 1 if the committed small set is stale")
    ap.add_argument("--require-corpus", action="store_true")
    a = ap.parse_args(argv)

    stale = gen_dec.stale_files()
    if stale:
        print("FAIL generated RTL is stale (run python mncore/tools/gen_dec.py):\n  " + "\n  ".join(stale))
        return 1
    print(f"gen_dec --check: {len(gen_dec.outputs())} generated files up to date")
    if codec.decode(NOP, "j")["ll"] != 0:
        return 1

    if a.check_fixed:
        jw, mw, _, _, _ = build(True, False)
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            write_set(Path(tmp), jw, mw, FIXED_NOTE)
            for k in ("j", "m"):
                new = (Path(tmp) / f"{k}.memb").read_bytes()
                old = (OUT_FIXED / f"{k}.memb").read_bytes().replace(b"\r\n", b"\n") if (OUT_FIXED / f"{k}.memb").exists() else b""
                if new != old:
                    print(f"FAIL {OUT_FIXED.relative_to(REPO).as_posix()}/{k}.memb is stale (run gen_vectors.py --fixed)")
                    return 1
        print("fixed vectors up to date")
        return 0

    jwords, mwords, cj, cm, info = build(a.fixed, a.require_corpus)
    print("words: " + ", ".join(f"{k} {v}" for k, v in info.items()))
    if not a.fixed:
        probs = ground_checks(cj) + ground_checks_m(cm)
        if probs:
            print(f"FAIL {len(probs)} corpus words break the decoder assumptions:")
            for p in probs[:20]:
                print("  " + p)
            return 1
        if cj:
            print(f"corpus assumptions hold on {len(cj)} unique j words and {len(cm)} m words "
                  "(ALU-none / enfma=0 / L2BM-off consistent, no unsupported value)")
    outdir = OUT_FIXED if a.fixed else OUT_FULL
    note = FIXED_NOTE if a.fixed else (
        f"full (corpus {info['corpus_sources']} sources + fixtures + synthetic)")
    jexp, mexp = write_set(outdir, jwords, mwords, note)
    miss = coverage(jwords, mwords, jexp, mexp)
    if miss:
        print("FAIL coverage:\n  " + "\n  ".join(miss))
        return 1
    # summary
    if cj:
        ce = [expect_j(w) for w in cj]
        grp = {g: sum(e[f"grp.{g}"] for e in ce) for g in gen_dec.GROUP_NAMES}
        print("corpus issue groups (unique words): " + ", ".join(f"{k} {v}" for k, v in grp.items()))
    ek = collections.Counter(e["err_kind"] for e in jexp)
    print(f"j err_kind: OK {ek[0]}, E_DECODE {ek[1]}, E_UNSUPPORTED {ek[2]}; "
          f"m err_kind: OK {sum(1 for e in mexp if not e['err_kind'])}, E_UNSUPPORTED {sum(1 for e in mexp if e['err_kind'])}")
    for k in ("j", "m"):
        p = outdir / f"{k}.memb"
        print(f"wrote {p.relative_to(REPO).as_posix()} ({os.path.getsize(p) // 1024} KiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

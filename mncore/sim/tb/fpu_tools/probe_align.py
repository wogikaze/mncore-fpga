"""Probe rows for the MAU adder alignment, checked against the official emulator (WP12).

    python mncore/sim/tb/fpu_tools/probe_align.py <out_dir> [1|2|3|4]
    cd mncore/vecgen && cargo run --release -- fp --check-official --sample all \
        --in <out_dir> --work <work_dir>
    python mncore/sim/tb/fpu_tools/probe_align.py --collect <out_dir> <work_dir>
    python mncore/sim/tb/fpu_tools/probe_align.py --fixed <dest_dir> <out_dir> [<out_dir> ...]

The first step writes fp-unit vector files (fma_d, fma_dr, fma_f, fma_fr, fma_h, fma_hr)
under <out_dir>/fp, whose rows sit on the boundaries of the alignment rules in mnfp_ref.py,
with the model's results as the expected values. Sets: 1 c larger / product larger /
cancellation, 2 the product-drop and c-grid boundaries, 3 the c grid with the product
exactly on a tie of the output, 4 random stress (4,000 rows per form).
vecgen runs them on the official tools and logs the rows where the official result differs.
--collect merges the logs into <out_dir>/official.tsv (every row with the official result)
and reports how many rows the current model gets wrong.
--fixed copies the rows that discriminate the rule parameters (K, T moved by 1 or 2) from
checked sets (no mismatch) into a small sample, e.g. mncore/sim/tb/fpu_fp/probe.
The RTL runs on a set with `vvp ... +vecdir=<out_dir>/fp` (see tb_fpu_fp.sv).
"""

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mnfp_ref as R  # noqa: E402
from vecio import VecFile  # noqa: E402

HEADERS = {
    "fma_d": "# vec v1 unit=fp op=fma_d insn=dvfmau fmt_ab=64 fmt_c=64 fmt_z=64 kind=fma sdm=yes seed=0 edge=0 rows={n} cols: a b c | z",
    "fma_dr": "# vec v1 unit=fp op=fma_dr insn=dvfmaur fmt_ab=64 fmt_c=64 fmt_z=32 kind=fma sdm=yes seed=0 edge=0 rows={n} cols: a b c | z",
    "fma_f": "# vec v1 unit=fp op=fma_f insn=fvfma fmt_ab=32 fmt_c=32 fmt_z=32 kind=fma sdm=yes seed=0 edge=0 rows={n} cols: a b c | z",
    "fma_fr": "# vec v1 unit=fp op=fma_fr insn=fvfmar fmt_ab=32 fmt_c=32 fmt_z=16 kind=fma sdm=no seed=0 edge=0 rows={n} cols: a b c | z",
    "fma_h": "# vec v1 unit=fp op=fma_h insn=hvfma fmt_ab=16 fmt_c=32 fmt_z=32 kind=fma sdm=yes seed=0 edge=0 rows={n} cols: a b c | z",
    "fma_hr": "# vec v1 unit=fp op=fma_hr insn=hvfmar fmt_ab=16 fmt_c=32 fmt_z=16 kind=fma sdm=yes seed=0 edge=0 rows={n} cols: a b c | z",
}
PREC = {"fma_d": ("d", False), "fma_dr": ("d", True), "fma_f": ("f", False),
        "fma_fr": ("f", True), "fma_h": ("h", False), "fma_hr": ("h", True)}


def enc(f, neg, e, frac_bits):
    """Value (-1)^neg * (1 + frac/2^m) * 2^e in format f (None if out of range)."""
    be = e + f.bias
    if not (1 <= be < f.emax):
        return None
    return (int(neg) << (f.width - 1)) | (be << f.man_bits) | (frac_bits & ((1 << f.man_bits) - 1))


def sig_choices(f, r):
    m = f.man_bits
    top = (1 << m) - 1
    return [0, 1 << (m - 1), top, 1, r.getrandbits(m), r.getrandbits(m) | 1, (1 << (m - 1)) | 1]


def tie_c(fc, fo, r, neg, e):
    """A value of fc on a rounding tie of fo (fo has fewer mantissa bits)."""
    drop = fc.man_bits - fo.man_bits
    hi = r.getrandbits(fo.man_bits)
    frac = (hi << drop) | (1 << (drop - 1))
    return enc(fc, neg, e, frac)


def gen(r):
    rows = {k: [] for k in HEADERS}
    for name, (prec, rnd) in PREC.items():
        fa, fc, fz, fzr, _ = R.FORMATS[prec]
        fo = fzr if rnd else fz
        out = rows[name]
        emax_a = fa.emax - 1 - fa.bias
        # 1. c larger than the product: product lead k below c's lead.
        for k in range(18, 60) if prec == "d" else range(14, 36):
            for _ in range(10):
                ea = r.randint(-emax_a // 2, emax_a // 2)
                uc = r.randint(-6, 6)
                eb = uc - k - ea
                sa = r.choice(sig_choices(fa, r))
                sb = r.choice(sig_choices(fa, r))
                a = enc(fa, r.random() < 0.5, ea, sa)
                b = enc(fa, r.random() < 0.5, eb, sb)
                if rnd:
                    c = tie_c(fc, fo, r, r.random() < 0.5, uc)
                else:
                    # power of two (binade crossing when the product is negative) or random
                    c = enc(fc, r.random() < 0.5, uc, 0 if r.random() < 0.5 else r.getrandbits(fc.man_bits))
                if None not in (a, b, c):
                    out.append((a, b, c))
        # 2. product larger than c: product on a tie of the output, c lead k below Ep.
        for k in range(20, 96) if prec == "d" else range(10, 50):
            for _ in range(8):
                # a * b exactly on a tie of fo: a = 1 + 2^-j (on the output grid), b chosen
                ea = r.randint(-8, 8)
                eb = r.randint(-8, 8)
                if rnd or fo.man_bits < 2 * fa.man_bits:
                    mo = fo.man_bits
                    # a has its lowest output-grid bit set, b = 1.5 shifts it half an ulp down
                    if mo + 1 <= fa.man_bits:
                        sa = (r.getrandbits(mo) | 1) << (fa.man_bits - mo)
                        sb = 1 << (fa.man_bits - 1)  # 1.5
                    else:
                        sa = r.getrandbits(fa.man_bits)
                        sb = r.getrandbits(fa.man_bits)
                else:
                    sa = r.getrandbits(fa.man_bits)
                    sb = r.getrandbits(fa.man_bits)
                a = enc(fa, r.random() < 0.5, ea, sa)
                b = enc(fa, r.random() < 0.5, eb, sb)
                ep = ea + eb
                cfr = r.choice([0, 1, (1 << fc.man_bits) - 1, r.getrandbits(fc.man_bits), 1 << (fc.man_bits - 1)])
                c = enc(fc, r.random() < 0.5, ep - k, cfr)
                if None not in (a, b, c):
                    out.append((a, b, c))
        # 3. random near-equal magnitudes with cancellation
        for _ in range(300):
            ea = r.randint(-10, 10)
            eb = r.randint(-10, 10)
            a = enc(fa, r.random() < 0.5, ea, r.getrandbits(fa.man_bits))
            b = enc(fa, r.random() < 0.5, eb, r.getrandbits(fa.man_bits))
            p = R.vfma(fa, fc, R.decode(fa, a), R.decode(fa, b), ("z", False))
            c = (p ^ (1 << (fc.width - 1))) + r.randint(-3, 3)
            out.append((a, b, c & ((1 << fc.width) - 1)))
    return rows


def tie_product(fa, fo, r):
    """(sa, sb, extra exponent) whose product is exactly on a rounding tie of fo, if possible.

    sa has its lowest set bit on the fo grid, sb = 1.5 shifts it half a unit lower; when the
    product reaches 2 the lead moves up, so the pair 1.5 x (1.5 + 2^-(mo-1)) is used instead.
    """
    m, mo = fa.man_bits, fo.man_bits
    if mo > m:
        return None
    if r.random() < 0.5:
        # product < 2: a < 4/3
        while True:
            hi = r.getrandbits(mo) | 1
            if (1 << mo) + hi < (4 << mo) // 3:
                break
        return hi << (m - mo), 1 << (m - 1)
    # product >= 2: a = 1.5, b = 1.5 + 2^-(mo - 1) (lowest bit lands on lead - mo)
    return 1 << (m - 1), (1 << (m - 1)) | (1 << (m - mo + 1))


def gen2(r):
    """Boundaries: the product drop (c much larger) and the c grid (product much larger)."""
    rows = {k: [] for k in HEADERS}
    T = {"d": 55, "f": 26, "h": 26}
    K = {"d": 88, "f": 41, "h": 28}
    for name, (prec, rnd) in PREC.items():
        fa, fc, fz, fzr, _ = R.FORMATS[prec]
        fo = fzr if rnd else fz
        out = rows[name]
        # product drop: d = Uc - Ep in T-3 .. T+2, products below and above 2
        for dd in range(T[prec] - 3, T[prec] + 3):
            for _ in range(60):
                uc = r.randint(-5, 5)
                ep = uc - dd
                ea = r.randint(ep // 2 - 3, ep // 2 + 3)
                eb = ep - ea
                big = r.random() < 0.5
                sa = (1 << (fa.man_bits - 1)) | r.getrandbits(fa.man_bits - 1) if big else r.getrandbits(fa.man_bits - 2)
                sb = (1 << (fa.man_bits - 1)) | r.getrandbits(fa.man_bits - 1) if big else r.getrandbits(fa.man_bits - 2)
                a = enc(fa, r.random() < 0.5, ea, sa)
                b = enc(fa, r.random() < 0.5, eb, sb)
                if rnd:
                    c = tie_c(fc, fo, r, r.random() < 0.5, uc)
                else:
                    c = enc(fc, r.random() < 0.5, uc, 0 if r.random() < 0.7 else r.getrandbits(fc.man_bits))
                if None not in (a, b, c):
                    out.append((a, b, c))
        # c grid: product on a tie of fo (when fo is narrower than the product), c lead
        # k below Ep for k around K + 2
        for k in range(K[prec] - 4, K[prec] + 5):
            for _ in range(60):
                tp = tie_product(fa, fo, r) if (rnd or prec == "d") else None
                if tp is None:
                    sa, sb = r.getrandbits(fa.man_bits), r.getrandbits(fa.man_bits)
                else:
                    sa, sb = tp
                ea = r.randint(-6, 6)
                eb = r.randint(-6, 6)
                a = enc(fa, r.random() < 0.5, ea, sa)
                b = enc(fa, r.random() < 0.5, eb, sb)
                ep = ea + eb
                cfr = r.choice([0, 1, (1 << fc.man_bits) - 1, r.getrandbits(fc.man_bits), 1 << (fc.man_bits - 1)])
                c = enc(fc, r.random() < 0.5, ep - k, cfr)
                if None not in (a, b, c):
                    out.append((a, b, c))
    return rows


def model_z(name, a, b, c):
    prec, rnd = PREC[name]
    return R.fp_row(prec, rnd, a, b, c)


def gen3(r):
    """The c grid with the product exactly on a tie of the output (all six forms)."""
    rows = {k: [] for k in HEADERS}
    K = {"d": 88, "f": 41, "h": 28}
    for name, (prec, rnd) in PREC.items():
        fa, fc, fz, fzr, _ = R.FORMATS[prec]
        fo = fzr if rnd else fz
        out = rows[name]
        for k in range(K[prec] - 5, K[prec] + 6):
            for _ in range(80):
                tp = tie_product(fa, fo, r)
                if tp is None:
                    continue
                sa, sb = tp
                ea = r.randint(-6, 6)
                eb = r.randint(-6, 6)
                if r.random() < 0.5:
                    sa, sb, ea, eb = sb, sa, eb, ea
                a = enc(fa, r.random() < 0.5, ea, sa)
                b = enc(fa, r.random() < 0.5, eb, sb)
                ep = ea + eb
                cfr = r.choice([0, 1, (1 << fc.man_bits) - 1, r.getrandbits(fc.man_bits), 1 << (fc.man_bits - 1)])
                c = enc(fc, r.random() < 0.5, ep - k, cfr)
                if None not in (a, b, c):
                    out.append((a, b, c))
    return rows


def gen4(r, n=4000):
    """Random stress: alignment region, cancellation, ties, and raw random bit patterns."""
    rows = {k: [] for k in HEADERS}
    T = {"d": 55, "f": 26, "h": 26}
    K = {"d": 88, "f": 41, "h": 28}
    for name, (prec, rnd) in PREC.items():
        fa, fc, fz, fzr, _ = R.FORMATS[prec]
        fo = fzr if rnd else fz
        out = rows[name]
        emax_a = fa.emax - 1 - fa.bias
        emax_c = fc.emax - 1 - fc.bias
        while len(out) < n:
            kind = r.randrange(5)
            if kind == 0:  # raw bits (specials included)
                a = r.getrandbits(fa.width)
                b = r.getrandbits(fa.width)
                c = r.getrandbits(fc.width)
            elif kind == 1:  # c anywhere around the product: d in [-K-6, T+6]
                ea = r.randint(-emax_a // 2, emax_a // 2)
                eb = r.randint(-emax_a // 2, emax_a // 2)
                d = r.randint(-K[prec] - 6, T[prec] + 6)
                a = enc(fa, r.random() < 0.5, ea, r.getrandbits(fa.man_bits))
                b = enc(fa, r.random() < 0.5, eb, r.getrandbits(fa.man_bits))
                c = enc(fc, r.random() < 0.5, ea + eb + d, r.getrandbits(fc.man_bits))
            elif kind == 2:  # cancellation: c = -(a*b) rounded to c's format, perturbed
                ea = r.randint(-20, 20)
                eb = r.randint(-20, 20)
                a = enc(fa, r.random() < 0.5, ea, r.getrandbits(fa.man_bits))
                b = enc(fa, r.random() < 0.5, eb, r.getrandbits(fa.man_bits))
                if None in (a, b):
                    continue
                p = R.vfma(fa, fc, R.decode(fa, a), R.decode(fa, b), ("z", False))
                c = ((p ^ (1 << (fc.width - 1))) + r.randint(-40, 40)) & ((1 << fc.width) - 1)
            elif kind == 3:  # product on a tie of the output, small c
                tp = tie_product(fa, fo, r)
                if tp is None:
                    continue
                sa, sb = tp
                ea = r.randint(-30, 30)
                eb = r.randint(-30, 30)
                a = enc(fa, r.random() < 0.5, ea, sa)
                b = enc(fa, r.random() < 0.5, eb, sb)
                c = enc(fc, r.random() < 0.5, ea + eb - r.randint(1, K[prec] + 4), r.getrandbits(fc.man_bits))
            else:  # c on a tie of the output (when narrower), product small
                if fo.man_bits >= fc.man_bits:
                    continue
                uc = r.randint(-emax_c // 2, emax_c // 2)
                c = tie_c(fc, fo, r, r.random() < 0.5, uc)
                ea = r.randint(-emax_a // 2, emax_a // 2)
                eb = uc - r.randint(1, T[prec] + 4) - ea
                a = enc(fa, r.random() < 0.5, ea, r.getrandbits(fa.man_bits))
                b = enc(fa, r.random() < 0.5, eb, r.getrandbits(fa.man_bits))
            if None not in (a, b, c):
                out.append((a, b, c))
    return rows


def write(out_dir, which="1"):
    r = random.Random({"1": 12, "2": 34, "3": 56, "4": 78}[which])
    rows = {"1": gen, "2": gen2, "3": gen3, "4": gen4}[which](r)
    d = Path(out_dir) / "fp"
    d.mkdir(parents=True, exist_ok=True)
    for name, rs in rows.items():
        prec, rnd = PREC[name]
        fa, fc, fz, fzr, _ = R.FORMATS[prec]
        fo = fzr if rnd else fz
        wa, wc, wo = fa.width // 4, fc.width // 4, fo.width // 4
        lines = [HEADERS[name].format(n=len(rs))]
        for a, b, c in rs:
            z = model_z(name, a, b, c)
            lines.append(f"{a:0{wa}x} {b:0{wa}x} {c:0{wc}x} | {z:0{wo}x}")
        (d / f"{name}.vec").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        print(f"{name}: {len(rs)} rows")


def collect(out_dir, work_dir):
    """work_dir is the --work directory of vecgen (the logs are in its fp/ subdirectory)."""
    out = []
    bad = 0
    for name in HEADERS:
        if not (Path(out_dir) / "fp" / f"{name}.vec").exists():
            continue
        f = VecFile(Path(out_dir) / "fp" / f"{name}.vec")
        official = {i: outs[0] for i, (_, outs) in enumerate(f.rows)}
        mm = Path(work_dir) / "fp" / f"{name}.mismatch.txt"
        logged = 0
        if mm.exists():
            lines = mm.read_text(encoding="utf-8").splitlines()
            for i, ln in enumerate(lines):
                if ln.startswith("line "):
                    idx = int(ln.split()[1]) - 2
                    off = lines[i + 2].split("|")[1].split()
                    official[idx] = int(off[0], 16)
                    logged += 1
        nb = 0
        for i, (ins, _) in enumerate(f.rows):
            out.append(f"{name}\t{ins[0]:x}\t{ins[1]:x}\t{ins[2]:x}\t{official[i]:x}")
            if model_z(name, *ins[:3]) != official[i]:
                nb += 1
                if nb <= 5:
                    print(f"  {name} line {i + 2}: {ins[0]:x} {ins[1]:x} {ins[2]:x} official "
                          f"{official[i]:x} model {model_z(name, *ins[:3]):x}")
        bad += nb
        print(f"{name}: {len(f.rows)} rows ({logged} logged by vecgen), current model differs on {nb}")
    (Path(out_dir) / "official.tsv").write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"current model differs from the official emulator on {bad} rows")
    return bad


def discriminating(name, a, b, c):
    """Does the row change its result when K or T of its format moves by one or two?"""
    prec, _ = PREC[name]
    key = {"d": "d", "f": "s", "h": "h"}[prec]
    base = model_z(name, a, b, c)
    hit = False
    for table in (R.GRID_K, R.DROP_T):
        keep = table[key]
        for dv in (-2, -1, 1, 2):
            table[key] = keep + dv
            if model_z(name, a, b, c) != base:
                hit = True
        table[key] = keep
        if hit:
            break
    return hit


def fixed(out_dir, probe_dirs, per_file=300, extra=40):
    """Select the discriminating rows of checked probe sets into a small committed sample.

    The probe sets must have been checked against the official emulator with no mismatch
    (their expected values are then the official results).
    """
    r = random.Random(90)
    d = Path(out_dir)
    d.mkdir(parents=True, exist_ok=True)
    for name in HEADERS:
        rows = []
        for pd in probe_dirs:
            p = Path(pd) / "fp" / f"{name}.vec"
            if p.exists():
                rows += [(ins[0], ins[1], ins[2], outs[0]) for ins, outs in VecFile(p).rows]
        if not rows:
            continue
        hits = [x for x in rows if discriminating(name, *x[:3])]
        rest = [x for x in rows if x not in hits]
        r.shuffle(hits)
        r.shuffle(rest)
        pick = hits[:per_file] + rest[:extra]
        prec, rnd = PREC[name]
        fa, fc, fz, fzr, _ = R.FORMATS[prec]
        fo = fzr if rnd else fz
        wa, wc, wo = fa.width // 4, fc.width // 4, fo.width // 4
        head = HEADERS[name].format(n=len(pick)).replace("seed=0", "seed=probe")
        lines = [head]
        for a, b, c, z in pick:
            assert model_z(name, a, b, c) == z
            lines.append(f"{a:0{wa}x} {b:0{wa}x} {c:0{wc}x} | {z:0{wo}x}")
        (d / f"{name}.vec").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        print(f"{name}: {len(hits)} discriminating rows of {len(rows)}, wrote {len(pick)}")


if __name__ == "__main__":
    if sys.argv[1] == "--collect":
        sys.exit(1 if collect(sys.argv[2], sys.argv[3]) else 0)
    if sys.argv[1] == "--fixed":
        fixed(sys.argv[2], sys.argv[3:])
        sys.exit(0)
    write(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "1")

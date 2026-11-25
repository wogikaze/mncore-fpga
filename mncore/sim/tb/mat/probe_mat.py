#!/usr/bin/env python3
"""WP36 experiments on the official emulator behind the matrix unit (mncore/status/WP-36.md).

    python mncore/sim/tb/mat/probe_mat.py fields              # faces / addresses of the MAUC fields
    python mncore/sim/tb/mat/probe_mat.py num <d|f|g|h> [nprog] [seed] [kinds]   # ?mfma numerics
    python mncore/sim/tb/mat/probe_mat.py ext [nprog] [seed]  # products of extended half elements

The official assemble3 / gpfn3_package_main run in WSL (emu_asm_batch.sh; only called, contract
section 9). Work files go to mncore/sim/tb/mat/build/probe/.

fields: the matrix register is filled with halves that name their face / row / column, then one
  word (assembled, then MAUC bits edited: readh, mw, ma, the read address in signa / signc / passa /
  zeroc, mdw_side, dmode) reads it to GRF0 and to $mreadf; the matrix is read back afterwards. Every
  case is compared with matref.Mat and matref.faces (226 cases).
num: random and edge block-float ?mfma / ?mmul tests on 16 MABs at once (each MAB its own data),
  compared with matref.mfma (grid, drop rule, special values, e / - / r, u / d for d).
ext: hmmul with one extended product per output: how the shifted product is rounded (prints the
  share that matches round-to-nearest-even by shift 6 / 12).
"""
from __future__ import annotations

import json
import random
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
sys.path.insert(0, str(HERE))
import goldenlib as gl  # noqa: E402
import norm_gpfn3  # noqa: E402
import matref as M  # noqa: E402
from mnisa.codec import decode_bits  # noqa: E402
from mnisa.schema import load  # noqa: E402

R = M.R
S = load("j")
WORK = HERE / "build" / "probe"


def batch(name, progs=None, asm_in=None, jobs=12):
    d = WORK / name
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for k, src in (progs or {}).items():
        (d / f"{k}.vsm").write_text(src, encoding="utf-8", newline="\n")
    for k, lines in (asm_in or {}).items():
        (d / f"{k}.asm.in").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    subprocess.run(gl.wsl_cmd(HERE / "emu_asm_batch.sh", [gl.wsl_path_arg(d), str(jobs)]),
                   capture_output=True, text=True)
    out = {}
    for k in list(progs or {}) + list(asm_in or {}):
        r = {}
        for ext in ("asm", "arc", "aerr", "dmp", "erc", "eout"):
            f = d / f"{k}.{ext}"
            r[ext] = f.read_text(errors="replace") if f.exists() else None
        out[k] = r
    return out


def dump_vals(dmp):
    recs, _ = norm_gpfn3.records_from_lines((dmp or "").splitlines())
    return {(sp, loc, a): v for sp, loc, a, v in recs}


def edit(bits, **kv):
    b = list(bits)
    for name, val in kv.items():
        f = S["pe_mauc_" + name]
        if isinstance(val, int):
            val = format(val, f"0{f.width}b")
        b[f.pos:f.pos + f.width] = list(val)
    return "".join(b)


# ---------------------------------------------------------------------------- fields
LOCS = [f"n0c0b0m0p{p}" for p in range(4)]


def hv(face, row, j):
    return (0xB000 if face else 0xA000) | (row << 4) | j


def fields_main():
    setup = []
    for p, loc in enumerate(LOCS):
        for reg, fa in (("lr", 0), ("ls", 1)):
            setup.append(f"d set ${reg}0{loc} 16 " + "".join(
                f"{hv(fa, L, 4 * p + k):04x}" for L in range(16) for k in range(4)))
        setup.append(f"d set $lm0{loc} 4 " + "".join(
            f"{0xC000 | (p << 8) | (c << 4) | k:04x}" for c in range(4) for k in range(4)))
    setup += ["hmwrite $llr0v $llx0", "hmwrite $llr16v $llx8", "hmwrite $lls0v $lly0", "hmwrite $lls16v $lly8", "nop"]
    tail = ["lpassa $mreadf $lls64v", "nop/2", "hmread $llx0 $llr128v", "hmread $llx8 $llr160v",
            "hmread $lly0 $llr192v", "hmread $lly8 $llr224v", "nop/2"]
    gets = [f"d get $lr64{loc} 8" for loc in LOCS] + [f"d get $ls64{loc} 8" for loc in LOCS] + \
           [f"d get $lr128{loc} 64" for loc in LOCS]
    bases = {"r": "hmread $llx0 $llr64v", "w": "hmwrite $lm0v $lly0 ; hmread $llx0 $llr64v",
             "v": "fvpassa $lr0v $nowrite"}
    asm = batch("fields_base", progs={k: "\n".join(setup + [b] + tail + gets) + "\n" for k, b in bases.items()},
                asm_in=None)
    lines = {k: asm[k]["asm"].splitlines() for k in asm}

    def test_index(ls):
        n = -1
        for i, ln in enumerate(ls):
            if ln.startswith("j "):
                n += 1
                if n == 5:
                    return i
        raise ValueError
    tests, meta = {}, {}
    for readh in (0, 1):
        for dm in ("00", "01", "10", "11"):
            for ma in (0, 1, 3, 6, 9, 14, 15):
                for side in ((0, 1) if ma in (0, 1, 3) else (0,)):
                    ls = list(lines["r"])
                    i = test_index(ls)
                    ls[i] = "j " + edit(ls[i][2:], readh=readh, dmode=dm, ma=ma, mdw_side=side)
                    n = f"r_h{readh}_d{dm}_a{ma}_s{side}"
                    tests[n], meta[n] = ls, dict(base="r", readh=readh, dm=dm, ma=ma, side=side, mw=0, ra=0)
            for wa, ra in ((0, 0), (1, 2), (5, 3), (9, 6), (14, 15)):
                for side in (0, 1):
                    ls = list(lines["w"])
                    i = test_index(ls)
                    rb = format(ra, "04b")
                    ls[i] = "j " + edit(ls[i][2:], readh=readh, dmode=dm, ma=wa, mdw_side=side, signa=rb[0],
                                        signc=rb[1], passa=rb[2], zeroc=rb[3])
                    n = f"w_h{readh}_d{dm}_w{wa}_r{ra}_s{side}"
                    tests[n], meta[n] = ls, dict(base="w", readh=readh, dm=dm, ma=wa, side=side, mw=1, ra=ra)
        for ma in (0, 2, 5):
            ls = list(lines["v"])
            i = test_index(ls)
            ls[i] = "j " + edit(ls[i][2:], readh=readh, ma=ma)
            n = f"v_h{readh}_a{ma}"
            tests[n], meta[n] = ls, dict(base="v", readh=readh, dm="01", ma=ma, side=0, mw=0, ra=0)
    res = batch("fields", asm_in=tests)
    prec_of = {"00": "d", "01": "f", "10": "h", "11": "g"}
    nbad = 0
    for n, md in meta.items():
        r = res[n]
        if (r["erc"] or "").strip() != "0":
            print(f"{n}: emulator rc {r['erc']}")
            nbad += 1
            continue
        vals = dump_vals(r["dmp"])

        def bus(space, lw0):
            return [[((vals.get((space, loc, lw0 + 2 * c), 0) << 64) | vals.get((space, loc, lw0 + 2 * c + 1), 0))
                     for c in range(4)] for loc in LOCS]
        m = M.Mat()
        for fa in range(2):
            for row in range(16):
                m.f[fa][row] = [hv(fa, row, j) for j in range(16)]
        fw, fr, _ = M.faces(md["readh"], md["mw"])
        prec = prec_of[md["dm"]]
        exp = m.read(fr, prec, md["ra"] if md["mw"] else md["ma"])
        m2 = m.copy()
        if md["mw"]:
            src = [[sum(((0xC000 | (p << 8) | (c << 4) | k) << (16 * (3 - k)) for k in range(4))) << 64
                    for c in range(4)] for p in range(4)]
            m2.write(fw, prec, md["ma"], md["side"] == 1 and prec == "h", src)
        after = M.Mat()
        for fa, lw0s in ((0, (64, 80)), (1, (96, 112))):
            for blk, lw0 in enumerate(lw0s):
                b = bus("GRF0", lw0)
                for p in range(4):
                    for c in range(4):
                        h = [(b[p][c] >> (16 * (7 - i))) & 0xffff for i in range(8)]
                        for k in range(4):
                            after.f[fa][4 * p + k][8 * blk + 2 * c] = h[k]
                            after.f[fa][4 * p + k][8 * blk + 2 * c + 1] = h[4 + k]
        ok = (md["base"] == "v" or bus("GRF0", 32) == exp) and bus("GRF1", 32) == exp and after.f == m2.f
        nbad += not ok
        if not ok:
            print(f"BAD {n}")
    print(f"fields: {len(meta) - nbad}/{len(meta)} cases agree with matref (faces, addresses, layout, $mreadf)")
    return 0 if nbad == 0 else 1


# ---------------------------------------------------------------------------- numerics
NMAB = 16
LAY = {"d": (4, 4, 4, 4), "f": (8, 2, 4, 4), "g": (8, 4, 4, 4), "h": (16, 4, 8, 8)}


def rand_block(rng, prec, n, ce, kind):
    f = M.BF[prec][0]
    out = []
    for _ in range(n):
        man = rng.getrandbits(f.man_bits)
        r = rng.random()
        man = 0 if r < 0.05 else ((1 << f.man_bits) - 1) if r < 0.1 else man
        e = 0 if (prec == "h" and kind == "ext" and rng.random() < 0.3) else ce
        out.append((rng.getrandbits(1) << (f.width - 1)) | (e << f.man_bits) | man)
    return out


def rand_val(rng, fmt, lead):
    be = max(1, min(fmt.emax - 1, lead + fmt.bias))
    return (rng.getrandbits(1) << (fmt.width - 1)) | (be << fmt.man_bits) | rng.getrandbits(fmt.man_bits)


def gen_case(rng, prec, kind, opt):
    f = M.BF[prec][0]
    rows = M.ROWS[prec]
    spread = 60 if kind == "wide" else 12

    def ce():
        e = rng.randint(max(1, f.bias - spread), min(f.emax - 1, f.bias + spread))
        if kind == "special":
            r = rng.random()
            e = 0 if r < 0.12 else f.emax if r < 0.24 else e
        return e
    mat = [rand_block(rng, prec, rows, ce(), kind) for _ in range(rows)]
    nx = {"d": 4, "f": 4, "g": 8, "h": 16}[prec]
    xs = [rand_block(rng, prec, nx, ce(), kind) for _ in range(4)]
    yf = R.DOUBLE if prec == "d" else R.SINGLE
    raw = (R.SINGLE if prec == "d" else R.HALF) if opt["extc"] else yf
    ys = []
    for c in range(4):
        cb = max(M.fields(prec, v)[1] for v in xs[c])
        yc = []
        for i in range(rows):
            ca = max(M.fields(prec, v)[1] for v in mat[i])
            ep = (ca - f.bias) + (cb - f.bias)
            lead = (ep - M.GRID_K[prec] + rng.randint(-4, 30)) if kind == "grid" else \
                   (ep + rng.randint(15, 70)) if kind == "drop" else (ep + rng.randint(-50, 40))
            v = rand_val(rng, raw, lead)
            if kind == "drop" and opt["rnd"] and not opt["extc"]:
                k = raw.man_bits - (23 if prec == "d" else 9)
                v = (v & ~((1 << raw.man_bits) - 1)) | (rng.getrandbits(raw.man_bits - k) << k) | (1 << (k - 1))
            if rng.random() < 0.04:
                v = 0
            yc.append(v)
        ys.append(yc)
    return dict(mat=mat, xs=xs, ys=ys, yraw=raw.name)


def pack(elems, w):
    per = 64 // w
    out = []
    for k in range(0, len(elems), per):
        v = 0
        for e in elems[k:k + per]:
            v = (v << w) | e
        out.append(v << (w * (per - len(elems[k:k + per]))))
    return out


def per_pe(prec, t):
    rows = M.ROWS[prec]
    n = rows // 4
    w = M.BF[prec][0].width
    pe = [dict(mat=[], x=[], y=[]) for _ in range(4)]
    if prec == "h":
        for blk in range(2):
            for c in range(4):
                for k in range(2):
                    for p in range(4):
                        pe[p]["mat"] += pack(t["mat"][8 * blk + 2 * c + k][4 * p:4 * p + 4], 16)
    elif prec in ("f", "g"):
        for blk in range(2):
            for c in range(4):
                for p in range(4):
                    pe[p]["mat"] += pack(t["mat"][4 * blk + c][2 * p:2 * p + 2], 32)
    else:
        for c in range(4):
            for p in range(4):
                pe[p]["mat"].append(t["mat"][c][p])
    for c in range(4):
        for p in range(4):
            xs = t["xs"][c]
            pe[p]["x"] += [xs[p]] if prec in ("d", "f") else pack(xs[2 * p:2 * p + 2], 32) if prec == "g" else \
                pack(xs[4 * p:4 * p + 4], 16)
    for p in range(4):
        if prec == "f":
            pe[p]["x"] = pack(pe[p]["x"], 32)
        yw = {"d": 64, "s": 32, "h": 16}[t["yraw"]]
        pe[p]["y"] = pack([v for c in range(4) for v in t["ys"][c][n * p:n * (p + 1)]], yw)
    return pe


def instr(prec, t, mb, xb, yb, ob, reg):
    R_ = {"lr": "r", "ls": "s"}[reg]
    if prec == "h":
        out = [f"hmwrite $ll{R_}{2 * mb}v $llx0", f"hmwrite $ll{R_}{2 * mb + 16}v $llx8"]
    elif prec in ("f", "g"):
        out = [f"{prec}mwrite $l{R_}{2 * mb}v $lx0", f"{prec}mwrite $l{R_}{2 * mb + 8}v $lx4"]
    else:
        out = [f"dmwrite $l{R_}{2 * mb}v $lx0"]
    sa, sc = ("-" if t["signa"] else ""), ("-" if t["signc"] else "")
    xop = f"{sa}${R_}{2 * xb}v" if prec == "f" else f"{sa}$l{R_}{2 * xb}v"
    if t["extc"]:
        yop = f"{sc}$n{2 * yb}ve" if prec != "h" else f"{sc}$ln{2 * yb}ve"
    else:
        yop = f"{sc}$ln{2 * yb}v" if prec != "h" else f"{sc}$lln{2 * yb}v"
    dst = f"$llm{2 * ob}v" if (prec == "h" and not t["rnd"]) else f"$m{2 * ob}v" if (prec == "d" and t["rnd"]) \
        else f"$lm{2 * ob}v"
    op = f"{prec}m" + ("mul" if t["zeroc"] else "fma") + (t["half"] or "") + ("r" if t["rnd"] else "")
    out.append(f"{op} $lx {xop} {dst}" if t["zeroc"] else f"{op} $lx {xop} {yop} {dst}")
    return out + ["nop/3"]


def expected(prec, t):
    f = M.BF[prec][0]
    rows = M.ROWS[prec]
    n = rows // 4
    yf = R.DOUBLE if prec == "d" else R.SINGLE
    raw = {"d": R.DOUBLE, "s": R.SINGLE, "h": R.HALF}[t["yraw"]]
    res, fout = [], None
    for c in range(4):
        cs = []
        for i in range(rows):
            v = ("z", False) if t["zeroc"] else R.decode(raw, t["ys"][c][i])
            if raw is not yf and v[0] != "z":
                v = R.decode(yf, R.encode(yf, v))
            cs.append(R.negate(v) if t["signc"] and v[0] != "z" else v)
        xs = [x ^ (1 << (f.width - 1)) for x in t["xs"][c]] if t["signa"] else t["xs"][c]
        out, fout = M.mfma(prec, t["mat"], xs, cs, half=t["half"], rnd=t["rnd"])
        res.append([out[n * p:n * (p + 1)] for p in range(4)])
    return res, fout


def num_main(prec, nprog=1, seed=1, kinds=("rand", "grid", "drop", "special", "wide")):
    rng = random.Random(seed)
    lay = LAY[prec]
    ntests = min(2 * (256 // (lay[0] + lay[1])), 256 // lay[3], 512 // lay[2])
    progs, meta = {}, {}
    for n in range(nprog):
        tests = [[] for _ in range(NMAB)]
        for k in range(ntests):
            kind = rng.choice(kinds)
            opt = dict(half=rng.choice(["u", "d"]) if prec == "d" else None, rnd=prec in "dh" and rng.random() < 0.35,
                       zeroc=rng.random() < 0.15, signa=rng.random() < 0.2, signc=rng.random() < 0.2)
            opt["extc"] = not opt["zeroc"] and rng.random() < 0.2
            for m in range(NMAB):
                t = dict(opt)
                t.update(gen_case(rng, prec, kind, opt))
                tests[m].append(t)
        regions = [(("lr", "ls")[k % 2], (k // 2) * (lay[0] + lay[1]), (k // 2) * (lay[0] + lay[1]) + lay[0],
                    k * lay[2], k * lay[3]) for k in range(ntests)]
        lines = []
        for m in range(NMAB):
            for p in range(4):
                data = {"lr": [0] * 256, "ls": [0] * 256, "ln": [0] * 512}
                for k, t in enumerate(tests[m]):
                    reg, mb, xb, yb, ob = regions[k]
                    d = per_pe(prec, t)[p]
                    for i, v in enumerate(d["mat"]):
                        data[reg][mb + i] = v
                    for i, v in enumerate(d["x"]):
                        data[reg][xb + i] = v
                    for i, v in enumerate(d["y"]):
                        data["ln"][yb + i] = v
                for reg, vals in data.items():
                    top = max((i + 1 for i, v in enumerate(vals) if v), default=0)
                    if top:
                        lines.append(f"d set ${reg}0n0c0b0m{m}p{p} {top} " + "".join(f"{v:016x}" for v in vals[:top]))
        for k in range(ntests):
            reg, mb, xb, yb, ob = regions[k]
            lines += instr(prec, tests[0][k], mb, xb, yb, ob, reg)
        for m in range(NMAB):
            for p in range(4):
                lines.append(f"d get $lm0n0c0b0m{m}p{p} {ntests * lay[3]}")
        name = f"{prec}{seed}_{n}"
        progs[name] = "\n".join(lines) + "\n"
        meta[name] = (tests, regions)
    res = batch(f"num_{prec}_{seed}", progs=progs)
    nt = nbad = nel = 0
    for name, (tests, regions) in meta.items():
        r = res[name]
        if (r["erc"] or "").strip() != "0":
            print(name, "emulator failed:", (r["aerr"] or "")[-200:], (r["eout"] or "")[-200:])
            continue
        vals = dump_vals(r["dmp"])
        for m in range(NMAB):
            for k, t in enumerate(tests[m]):
                ob = regions[k][4]
                exp, fout = expected(prec, t)
                bad = False
                for c in range(4):
                    for p in range(4):
                        loc = f"n0c0b0m{m}p{p}"
                        if prec == "h" and not t["rnd"]:
                            lw = [vals.get(("LM0", loc, ob + 2 * c + i), 0) for i in range(2)]
                            got = [lw[0] >> 32, lw[0] & 0xffffffff, lw[1] >> 32, lw[1] & 0xffffffff]
                        elif prec == "h":
                            v = vals.get(("LM0", loc, ob + c), 0)
                            got = [(v >> (16 * (3 - j))) & 0xffff for j in range(4)]
                        elif prec == "d" and t["rnd"]:
                            v = vals.get(("LM0", loc, ob + c // 2), 0)
                            got = [(v >> 32) if c % 2 == 0 else (v & 0xffffffff)]
                        elif prec == "d":
                            got = [vals.get(("LM0", loc, ob + c), 0)]
                        else:
                            v = vals.get(("LM0", loc, ob + c), 0)
                            got = [v >> 32, v & 0xffffffff]
                        nel += len(got)
                        bad |= got != exp[c][p]
                nt += 1
                nbad += bad
    print(f"num {prec}: {nt - nbad}/{nt} tests ({nel} elements) agree with matref")
    return 0 if nbad == 0 else 1


def ext_main(nprog=1, seed=7):
    """hmmul: element 0 of every row and of x, one of them extended; the rest zero."""
    rng = random.Random(seed)
    stats = {6: [0, 0], 12: [0, 0]}
    progs, meta = {}, {}
    for n in range(nprog):
        tests = []
        for m in range(NMAB):
            row = []
            for k in range(24):
                mat = [[0x3e00 if j == 14 else (0x3e00 & 0x7e00) for j in range(16)] for _ in range(16)]
                xs = []
                for c in range(4):
                    x = [31 << 9 for _ in range(16)]
                    x[15] = (31 << 9) | 256
                    x[0] = rng.randint(1, 511) | (0 if rng.random() < 0.8 else 31 << 9)
                    xs.append(x)
                for i in range(16):
                    mat[i] = [31 << 9 for _ in range(16)]
                    mat[i][14] = (31 << 9) | 256
                    mat[i][0] = rng.randint(1, 511) | (0 if rng.random() < 0.5 else 31 << 9)
                row.append(dict(mat=mat, xs=xs, ys=[[0] * 16 for _ in range(4)], yraw="s", half=None, rnd=False,
                                zeroc=True, signa=False, signc=False, extc=False))
            tests.append(row)
        lay = LAY["h"]
        regions = [(("lr", "ls")[k % 2], (k // 2) * 20, (k // 2) * 20 + 16, k * 8, k * 8) for k in range(24)]
        lines = []
        for m in range(NMAB):
            for p in range(4):
                data = {"lr": [0] * 256, "ls": [0] * 256}
                for k, t in enumerate(tests[m]):
                    reg, mb, xb, yb, ob = regions[k]
                    d = per_pe("h", t)[p]
                    for i, v in enumerate(d["mat"]):
                        data[reg][mb + i] = v
                    for i, v in enumerate(d["x"]):
                        data[reg][xb + i] = v
                for reg, vals in data.items():
                    top = max((i + 1 for i, v in enumerate(vals) if v), default=0)
                    lines.append(f"d set ${reg}0n0c0b0m{m}p{p} {top} " + "".join(f"{v:016x}" for v in vals[:top]))
        for k in range(24):
            reg, mb, xb, yb, ob = regions[k]
            lines += instr("h", tests[0][k], mb, xb, yb, ob, reg)
        for m in range(NMAB):
            for p in range(4):
                lines.append(f"d get $lm0n0c0b0m{m}p{p} {24 * lay[3]}")
        progs[f"ext{seed}_{n}"] = "\n".join(lines) + "\n"
        meta[f"ext{seed}_{n}"] = (tests, regions)
    res = batch(f"ext_{seed}", progs=progs)
    for name, (tests, regions) in meta.items():
        vals = dump_vals(res[name]["dmp"])
        for m in range(NMAB):
            for k, t in enumerate(tests[m]):
                ob = regions[k][4]
                for c in range(4):
                    _, eb, mb = M.fields("h", t["xs"][c][0])
                    for p in range(4):
                        lw = [vals.get(("LM0", f"n0c0b0m{m}p{p}", ob + 2 * c + i), 0) for i in range(2)]
                        got = [lw[0] >> 32, lw[0] & 0xffffffff, lw[1] >> 32, lw[1] & 0xffffffff]
                        for j in range(4):
                            _, ea, ma = M.fields("h", t["mat"][4 * p + j][0])
                            sh = (6 if ea == 0 else 0) + (6 if eb == 0 else 0)
                            if sh == 0:
                                continue
                            want = M.R.encode(M.R.SINGLE, ("f", False, M._shift_round(ma * mb, sh), -16)) \
                                if M._shift_round(ma * mb, sh) else 0
                            stats[sh][0] += 1
                            stats[sh][1] += got[j] == want
    for sh, (n, ok) in stats.items():
        print(f"ext: shift {sh}: {ok}/{n} products rounded to nearest even")
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    if argv[0] == "fields":
        return fields_main()
    if argv[0] == "num":
        prec = argv[1]
        nprog = int(argv[2]) if len(argv) > 2 else 1
        seed = int(argv[3]) if len(argv) > 3 else 1
        kinds = tuple(argv[4].split(",")) if len(argv) > 4 else ("rand", "grid", "drop", "special", "wide")
        return num_main(prec, nprog, seed, kinds)
    if argv[0] == "ext":
        return ext_main(int(argv[1]) if len(argv) > 1 else 1, int(argv[2]) if len(argv) > 2 else 7)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

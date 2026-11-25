#!/usr/bin/env python3
"""Make the scripts of tb_multi (WP38): mncore/sim/tb/multi/fixed/u0.scr, u0n.scr, u1.scr, u1n.scr, u2.scr.

    python mncore/sim/tb/multi/gen_multi.py

Needs the M2 regression (`python mncore/sim/regress/run.py --m2`: build/m2/<name>/official.asm and
rust.ndmp). Each script checks one member of the bitstream set (mncore/fpga/multi/mn_top_multi.v)
through its UART pin:

  all   INFO (design 0x05, the flags, the depths of the L1BM / L2BM / PDM / DRAM spaces); the PDM / DRAM
        host spaces (writes with a byte mask, the last long word of each, E_RANGE beyond the depth and
        at another group); the button S1 (a new configuration) keeps the DRAM / PDM; RESET clears them.
  u0    UNITS 0 (the MAU member): words 0..3 of hello_world (the MAU part, as mnrun.py runs them) and the
        PE state after them; an L1BM word and an m word stop with E_UNSUPPORTED.
  u1    UNITS 1 (the L1BM-only member with the stubs): problems/15.onehot-mini/answer.vsm (L1BM + MAU in
        the same words); the L2BM space is rejected, an L2BM word and an m word stop with
        E_UNSUPPORTED, a wait stops with WAIT.
  u2    UNITS 2 (M2a): the L1BM / L2BM host spaces; an MAU word stops with E_UNSUPPORTED; the second
        segment of hello_world as mnrun.py runs it: RESET, the PE state after words 0..3 written back
        (only the long words that are not 0), words 4..8, and the M2 probe compared with the
        reduced-topology Rust run (the zero rule): the hand-over of mnrun.py in RTL.
  u0n / u1n  u0 / u1 without the SDRAM (SDRAM = 0: the MAUF3 member with FPALU 3, the L1MAU member with
        L1_RRN 0): no PDM / DRAM spaces (rejected), the SDRAM model checks the self refresh entry.
The expected values of u0 / u1 and the PE state handed to u2 come from tb_core (mncore/sim/tb/core,
the M2 core with the MAU: TB_NPE=4 TB_M2=1 TB_SDMEM TB_FPALU=0 TB_MAU=1 TB_BFN=0) running the same
requests: tb_multi checks the board top (UART, the host spaces, the SDRAM, the stubs) around the core.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import run as regress  # noqa: E402
import ndmp  # noqa: E402
import mnhost  # noqa: E402
import simrun  # noqa: E402

regress.configure(4, m2=True)
HELLO = "problems/challenge/21.hello-world/main.vsm"
ONEHOT = "problems/15.onehot-mini/answer.vsm"
PE_LOCS = [mnhost.loc_code(p=p) for p in range(4)]
PE_STATE = [(3, 0, 256), (4, 0, 256), (1, 0, 256), (2, 0, 256), (5, 0, 8), (0x10, 1, 15), (0x11, 0, 2)]
DRAM_AW, PDM_AW = 10, 8           # tb_multi's small DRAM / PDM
FIELD = {}
for m in re.finditer(r"MN_J_(\w+)_IDX = (\d+)", (ROOT / "mncore/rtl/dec/mn_jfields.vh").read_text()):
    FIELD[m.group(1)] = int(m.group(2))


def job(path: str) -> Path:
    return regress.BUILD / regress.prog_name(path)


def load(path: str) -> mnhost.AsmProgram:
    return mnhost.parse_asm((job(path) / "official.asm").read_text(encoding="utf-8"))


def prog_lines(prog: mnhost.AsmProgram, a: int, b: int, cap: int = 4, total: int = 256) -> list[str]:
    """I / W / X lines of entries [a, b) (at entry 0..) and the d set / r lines among them (each
    d set cut to its first `cap` long words, at most `total` long words in all: the UART model is
    slow); d gets are left out. The reference (tb_core) runs the same requests."""
    out = [f"I {k:x} {e:0112x}" for k, e in enumerate(prog.entries[a:b])]
    topo = mnhost.Topology((1, 1, 1, 1, 4))
    pc = a
    nw = 0
    for pos, d in prog.events:
        if pos < a or pos > b or d.op != "set":
            continue
        if pos > pc:
            out.append(f"X {pc - a:x} {pos - pc:x}")
            pc = pos
        if d.space in ("DRAM", "PDM"):
            locs = [{"n": 0}] if d.loc.get("n", 0) == 0 else []
        elif d.space in ("L1BM", "L2BM"):
            locs = []
        else:
            locs = topo.locations(d.space, d.loc)
        sp = mnhost.SPACES[d.space]
        for f in locs:
            for lw, v, m in mnhost.long_words(d)[:cap]:
                if nw < total:
                    out.append(f"W {sp:x} {mnhost.loc_code(**f):x} {lw:x} {m:x} {v:x}")
                    nw += 1
    if b > pc:
        out.append(f"X {pc - a:x} {b - pc:x}")
    return out


def tb_core(lines: list[str], tag: str) -> tuple[dict, list]:
    """Runs tb_core (the M2 core with the MAU) on the script; returns the R reads {(tag, space, addr): v}
    and the stop records."""
    files, cfg = simrun.parse_files("m2")
    defs = ["TB_NPE=4", "TB_M2=1", "TB_SDMEM", "TB_FPALU=0", "TB_MAU=1", "TB_BFN=0"]
    bdir = HERE / "build"
    bdir.mkdir(exist_ok=True)
    vvp = bdir / "ref.vvp"
    if not vvp.exists():
        cmd = ["iverilog", "-g2012", "-Wno-timescale", "-o", str(vvp)] + [f"-D{d}" for d in defs]
        cmd += [f"-I{d}" for d in cfg["incdir"]] + ["-s", cfg["top"]] + files
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stdout + r.stderr)
    scr = bdir / f"ref_{tag}.scr"
    scr.write_text("\n".join(lines + ["E"]) + "\n", encoding="utf-8", newline="\n")
    r = subprocess.run(["vvp", "-n", str(vvp), f"+script={scr.as_posix()}", "+quiet"], cwd=ROOT,
                       capture_output=True, text=True)
    reads, stops = {}, []
    for line in r.stdout.splitlines():
        p = line.split()
        if p and p[0] == "D":
            reads[(int(p[1], 16), int(p[2], 16), int(p[3], 16))] = int(p[4], 16)
        elif p and p[0] == "S":
            stops.append(tuple(int(x, 16) for x in p[1:5]))
        elif p and p[0] in ("ERR", "DERR"):
            raise SystemExit(f"tb_core: {line}")
    return reads, stops


def pe_reads() -> list[str]:
    out = []
    t = 0
    for loc in PE_LOCS:
        for sp, a0, n in PE_STATE:
            out.append(f"R {t:x} {sp:x} {loc:x} {a0:x} {n:x}")
            t += 1
    return out


def pe_values(reads: dict) -> dict:
    """{(space, loc, addr): value} of the R reads of pe_reads()."""
    vals = {}
    t = 0
    for loc in PE_LOCS:
        for sp, a0, n in PE_STATE:
            for a in range(a0, a0 + n):
                vals[(sp, loc, a)] = reads[(t, sp, a)]
            t += 1
    return vals


def q_lines(vals: dict, zeros_every: int = 32) -> list[str]:
    """Q checks of the long words that are not 0, and of some zeros, in runs."""
    keep = sorted(k for k, v in vals.items() if v or k[2] % zeros_every == 0)
    out = []
    run: list = []
    for k in keep:
        if run and k[0] == run[-1][0] and k[1] == run[-1][1] and k[2] == run[-1][2] + 1 and len(run) < 64:
            run.append(k)
        else:
            if run:
                out.append(f"Q {run[0][0]:x} {run[0][1]:x} {run[0][2]:x} {len(run):x} " +
                           " ".join(f"{vals[x]:x}" for x in run))
            run = [k]
    if run:
        out.append(f"Q {run[0][0]:x} {run[0][1]:x} {run[0][2]:x} {len(run):x} " + " ".join(f"{vals[x]:x}" for x in run))
    return out


def common(design: int, flags: int, d_l1: int, d_l2: int, sdram: bool = True) -> list[str]:
    dl, pl = (1 << DRAM_AW) - 1, (1 << PDM_AW) - 1
    if not sdram:
        return [
            f"# INFO: design 0x{design:02x}, flags 0x{flags:02x}, L1BM {d_l1}, L2BM {d_l2}, no PDM / DRAM (SDRAM = 0)",
            f"N {design:x} {flags:x} {d_l1:x} {d_l2:x} 0 0",
            "# no PDM / DRAM spaces: rejected (the SDRAM is in self refresh; the model checks its commands)",
            "G 9 0 0 5", "G 8 0 0 5", "H 9 0 0 5", "H 8 0 0 5",
            "B", f"N {design:x} {flags:x} {d_l1:x} {d_l2:x} 0 0", "G 9 0 0 5",
            "C",
        ]
    return [
        f"# INFO: design 0x{design:02x}, flags 0x{flags:02x}, L1BM {d_l1}, L2BM {d_l2}, PDM / DRAM",
        f"N {design:x} {flags:x} {d_l1:x} {d_l2:x} {1 << PDM_AW:x} {1 << DRAM_AW:x}",
        "# the PDM / DRAM host spaces",
        "W 9 0 0 ff 1111111111111111", f"W 9 0 {dl:x} ff 2222222222222222",
        "W 8 0 0 ff 3333333333333333", f"W 8 0 {pl:x} ff 4444444444444444",
        "W 9 0 5 ff ffffffffffffffff", "W 9 0 6 ff 0123456789abcdef",
        "W 9 0 5 f 55555555aaaaaaaa", "W 9 0 6 f0 66666666bbbbbbbb",      # byte masks: one half each
        "Q 9 0 0 1 1111111111111111", f"Q 9 0 {dl:x} 1 2222222222222222",
        "Q 8 0 0 1 3333333333333333", f"Q 8 0 {pl:x} 1 4444444444444444",
        "Q 9 0 5 2 ffffffffaaaaaaaa 6666666689abcdef",
        "# beyond the depth, another group: rejected (E_RANGE)",
        f"G 9 0 {dl + 1:x} 5", f"G 8 0 {pl + 1:x} 5", "G 9 400 0 5", f"H 9 0 {dl + 1:x} 5", "H 8 400 0 5",
        "# the button S1 (like a new configuration) keeps the DRAM / PDM",
        "B",
        f"N {design:x} {flags:x} {d_l1:x} {d_l2:x} {1 << PDM_AW:x} {1 << DRAM_AW:x}",
        "Q 9 0 0 1 1111111111111111", f"Q 8 0 {pl:x} 1 4444444444444444",
        "Q 9 0 5 2 ffffffffaaaaaaaa 6666666689abcdef",
        "# RESET clears them",
        "C",
        "Q 9 0 0 1 0", f"Q 9 0 {dl:x} 1 0", "Q 8 0 0 1 0", f"Q 8 0 {pl:x} 1 0", "Q 9 0 5 2 0 0",
    ]


def main() -> int:
    hello = load(HELLO)
    onehot = load(ONEHOT)
    fixed = HERE / "fixed"
    fixed.mkdir(exist_ok=True)
    hdr = ["# made by mncore/sim/tb/multi/gen_multi.py (WP38); do not edit"]

    # ---- u0: the MAU member; hello_world words 0..3 (the reference: tb_core)
    part1 = ["C"] + prog_lines(hello, 0, 4)
    reads, stops = tb_core(part1 + pe_reads(), "hello0")
    assert stops and stops[-1][0] == 0, stops
    state = pe_values(reads)
    body0 = ["# hello_world words 0..3 (the MAU part); the PE state after them (tb_core)"] + part1
    body0 += [f"K 0 0", f"P 4 4"] + q_lines(state)
    body0 += ["# an L1BM word and an m word: E_UNSUPPORTED (no units)", "C",
              f"I 0 {hello.entries[4]:0112x}", "X 0 1", f"K 2 {FIELD['L1BM_BMODE']:x}",
              f"I 0 {hello.entries[8]:0112x}", "X 0 1", "K 2 80", "E"]
    u0 = hdr + common(5, 0x11, 0, 0) + body0
    (fixed / "u0.scr").write_text("\n".join(u0) + "\n", encoding="utf-8", newline="\n")
    # the same without the SDRAM (the MAUF3 member: FPALU 3, SDRAM 0; flags 0x1d)
    u0n = hdr + common(5, 0x1d, 0, 0, sdram=False) + body0
    (fixed / "u0n.scr").write_text("\n".join(u0n) + "\n", encoding="utf-8", newline="\n")

    # ---- u1: the L1BM-only member (stubs); onehot-mini (L1BM + MAU in the same words)
    p1 = ["C"] + prog_lines(onehot, 0, len(onehot.entries))
    reads1, stops1 = tb_core(p1 + pe_reads() + ["R 99 6 0 0 100"], "onehot")
    assert stops1 and stops1[-1][0] == 0, stops1
    st1 = pe_values(reads1)
    st1.update({(6, 0, a): reads1[(0x99, 6, a)] for a in range(0x100)})
    body1 = ["# the L1BM host space; the L2BM space is not there", "W 6 0 3ff ff 7777777777777777",
             "Q 6 0 3ff 1 7777777777777777", "G 7 0 0 5", "H 7 0 0 5"]
    body1 += [f"# {ONEHOT}: L1BM and MAU in the same words (tb_core)"] + p1 + ["K 0 0"] + q_lines(st1)
    body1 += ["# an L2BM word, an m word: E_UNSUPPORTED (the stubs); a wait: WAIT", "C",
              f"I 0 {hello.entries[7]:0112x}", "X 0 1", f"K 2 {FIELD['L2BM_LWRITE']:x}",
              f"I 0 {hello.entries[8]:0112x}", "X 0 1", "K 2 80"]
    wait_word = mnhost.imem_entry("j", (hello.entries[5] & ((1 << 426) - 1)) | (0x5A << (426 - 238 - 8)))
    body1 += [f"I 0 {wait_word:0112x}", "X 0 1", "K 4 5a", "E"]
    u1 = hdr + common(5, 0x11, 1024, 0) + body1
    (fixed / "u1.scr").write_text("\n".join(u1) + "\n", encoding="utf-8", newline="\n")
    # the same without the SDRAM and without the L1BM reductions (the L1MAU member: L1_RRN 0, SDRAM 0)
    u1n = hdr + common(5, 0x11, 1024, 0, sdram=False) + body1
    (fixed / "u1n.scr").write_text("\n".join(u1n) + "\n", encoding="utf-8", newline="\n")

    # ---- u2: M2a; the second segment of hello_world after the hand-over of the PE state
    u2 = hdr + common(5, 0x01, 1024, 2048)
    u2 += ["# the L1BM / L2BM host spaces", "W 6 0 3ff ff 7777777777777777", "Q 6 0 3ff 1 7777777777777777",
           "W 7 0 7ff ff 8888888888888888", "Q 7 0 7ff 1 8888888888888888", "G 7 0 800 5"]
    u2 += ["# an MAU word: E_UNSUPPORTED", "C", f"I 0 {hello.entries[1]:0112x}", "X 0 1",
           f"K 2 {FIELD['PE_MAUC_ENFMA']:x}"]
    u2 += ["# hello_world words 4..8 after the PE state of words 0..3 (u0), as mnrun.py hands it over", "C"]
    for (sp, loc, a), v in sorted(state.items()):
        if v:
            u2.append(f"W {sp:x} {loc:x} {a:x} ff {v:x}")
    u2 += prog_lines(hello, 4, len(hello.entries)) + ["K 0 0"]
    # the probe against the reduced-topology Rust run (zero rule): the records that are not 0, some 0s
    rd, _ = ndmp.read(str(job(HELLO) / "rust.ndmp"))
    sp_id = {"LM0": 1, "LM1": 2, "GRF0": 3, "GRF1": 4, "T": 5, "L1BM": 6, "L2BM": 7, "DRAM": 9}
    exp = {}
    for (s, l, a), v in rd.items():
        if s not in sp_id or (s == "DRAM" and a >= 1 << DRAM_AW):
            continue
        loc = mnhost.parse_loc(l)
        if s in ("LM0", "LM1", "GRF0", "GRF1") and a >= 256:
            continue
        exp[(sp_id[s], loc, a)] = v
    u2 += q_lines(exp, zeros_every=128) + ["E"]
    (fixed / "u2.scr").write_text("\n".join(u2) + "\n", encoding="utf-8", newline="\n")
    print(f"u0 {len(u0)} lines, u0n {len(u0n)}, u1 {len(u1)} lines, u1n {len(u1n)}, u2 {len(u2)} lines; hello state: "
          f"{sum(1 for v in state.values() if v)} long words not 0; probe checks {len(exp)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

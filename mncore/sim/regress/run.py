#!/usr/bin/env python3
"""WP20 / WP30 regression: the corpus programs comparable on the reduced core, on the RTL.

usage: python mncore/sim/regress/run.py [--pes 1|4] [--only TEXT] [-j N] [--official-jobs N]
           [--skip-official] [--force-official] [--table FILE] [--keep] [--define D] [--matrix]

--matrix (WP36, with --pes 4 --define TB_MAT=1): the programs that pe1 leaves out only for the
   matrix group (?mwrite / ?mread / ?mfma / msl / msr) instead of pe1 = yes.

--m2 (WP37): the M2 core (mn_core N_PE = 4, M2 = 1: one MAB, L1B, L2B and group with the L1BM,
   L2BM and MV units; tb_core of the unit m2 with the behavioural SDRAM memory), on the programs
   that pe1 leaves out for the l1bm / l2bm / mv groups (and their run-time LM addresses), not the
   matrix ones (--matrix: the ones with the matrix group, with --define TB_MAT=1). Results in build/m2/.
   The probe adds L1BM n0c0b0 (1024 long words), L2BM n0c0 (2048) and DRAM n0 (8192); `r` lines
   become DRAM writes. Each program is also run on the Rust simulator on the reduced topology (zero
   rule, contract 06 section 3 (a); mncore/sim/regress/topo_rs, `topo_dump`), and the RTL is compared
   with both: "pass b" = the official equals the reduced Rust run and the RTL equals both (the data
   stays inside the implemented units), "pass c" = they differ and the RTL equals the reduced Rust
   run (the zero rule), "pass b (rust differs)" = the RTL equals the official only (a known
   divergence of the Rust simulator). PDM is not compared (the official d get $p shows the DRAM).
   --define TB_REPLICA=1 (the replica rule, WP-3x) compares with the official only (pass / mismatch).

--vpe N_MAB (WP34): the virtual PEs (mn_core VPE = 1, the PE state in the SDRAM; tb_core of the unit vpe
   with -DTB_VPE=1 -DTB_NMAB=N_MAB -DTB_LMAW=<--lm-aw, default 11>), with the M2 units: N_MAB = 16 is one
   L1B of 64 PEs (n0c0b0m0..15p0..3), N_MAB = 1 the M2 topology (4 PEs) with the chip's LM. The programs:
   every corpus program the official ran (pe1, the M2 set, the LM and matrix ones: MAT is not there, the
   matrix words stop with E_UNSUPPORTED), or with --m2 the M2 set only. The probe is the whole state of
   the implemented PEs (LM0 / LM1 2**lm-aw, GRF0 / GRF1, T, OMR) and the L1BM / L2BM / DRAM of the M2
   probe; the reference is the official (pass b) or the reduced-topology Rust simulator (pass c), as
   --m2 (topology l2b=1,l1b=1,mab=N_MAB,lm=2**lm-aw). Results in build/vpe<N_MAB>_lm<lm-aw>/.

--pes 1 (default, WP20): the 1-PE core (mn_core N_PE = 1, LM 512 long words), PE n0c0b0m0p0.
--pes 4 (WP30): one MAB of 4 PEs on the time-multiplexed core (mn_core N_PE = 4, LM_AW = 8:
   LM 256 long words per PE), PEs n0c0b0m0p0..p3; results in build/mab/ (official runs with the
   4-PE probe are cached there).

1. official (WSL, cached in build/<name>/ or build/mab/<name>/): every corpus.tsv row with
   pe1 = yes is composed like the golden tools do (goldenlib.load_program) with a probe (the
   whole state of the implemented PEs at the end: "pe" for n0c0b0m0p0; for 4 PEs LM0/LM1/GRF0/GRF1
   long words 0..255, T and OMR of p0..p3) and run on the official assemble3 (flat, no packer)
   and emulator, on all 4096 PEs (contract 06 section 3 (b)).
   pe1 = yes also selects the programs comparable on 1 MAB: only alu_int / fp / mau instructions
   (no L1BM, L2BM, MV, matrix), LM inside 256 long words, no run-time LM addresses (corpus.py).
   msl / msr / bfn / bfe stay inside the MAB, so the 4 implemented PEs compute what the chip does.
2. rtl: official.asm (the emulator's whole input) becomes a tb_core script with the steps of
   `mnhost.py run` (PROTOCOL.md section 6): load the instruction memory in windows of
   IMEM_DEPTH entries, RUN split at the d lines, d set -> WR_MEM, d get -> RD_MEM. Only the
   implemented PEs exist; d set / d get of other locations and spaces are skipped, `r` lines
   (DRAM data) too. The script runs on iverilog (tb_core, mn_core).
3. compare: the RTL's d get values become ndmp records like norm_gpfn3 makes them from the
   emulator's dump (word access -> LM0W.., T 2c+k, OMR entry*4+cycle), and are compared with
   official.ndmp on the implemented PEs: LM0 LM1 GRF0 GRF1 (+ W forms) inside the implemented
   depth (LM 2**LM_AW, GRF 2**GRF_AW long words), T and OMR.

Each program is classified: pass, mismatch(<spaces>), E_UNSUPPORTED <field> (<what>),
E_RANGE, E_DECODE, timeout, error. Results: build/results.tsv (build/mab/results.tsv) (and
--table FILE, a copy that can be committed), and a summary by corpus group on stdout.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BUILD = HERE / "build"
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "host"))
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import goldenlib as gl  # noqa: E402
import ndmp  # noqa: E402
import mnhost  # noqa: E402
import simrun  # noqa: E402  (also puts OSS CAD Suite on PATH)

# must match tb_core / mn_core (the 1-PE configuration; configure(4) switches to the MAB)
IMEM_DEPTH = 512
LM_LW = 512      # 2**LM_AW long words
GRF_LW = 256     # 2**GRF_AW long words
PE_LOC = "n0c0b0m0p0"
PE_LOC_CODE = 0
N_PE = 1
PE_LOCS = [PE_LOC]          # implemented PEs (ndmp location text)
PROBE = "pe"                # goldenlib probe, or "mab4" / "m2" (below)
TB_DEFINES: list = []       # tb_core defines of the configuration
UNIT = "core"               # simrun unit whose files make the testbench
M2 = False                  # the M2 core (WP37)
# the reduced topology of the M2 core for the Rust simulator (WP06 sim_run syntax; topo_dump)
TOPO_M2 = "l2b=1,l1b=1,mab=1,lm=256,grf=256,l1bm=1024,l2bm=2048,pdm=131072,dram=524288"
DRAM_PROBE = 8192           # DRAM n0 long words of the M2 probe
MAXCLK = 0                  # tb_core +maxclk per RUN (0: its default)
N_MAB = 1                   # MABs of the topology (WP34 --vpe: 16)
VPE = False                 # the virtual PEs (WP34)
UNITS = {"L1BM", "L2BM", "PDM", "DRAM"}   # M2: the spaces of the units that exist (WP34 --vpe-units)

SP_ID = {"LM0": 0x01, "LM1": 0x02, "GRF0": 0x03, "GRF1": 0x04, "T": 0x05, "OMR": 0x10}
WORD_SPACES = ("LM0", "LM1", "GRF0", "GRF1")
DEPTH_LW = {"LM0": LM_LW, "LM1": LM_LW, "GRF0": GRF_LW, "GRF1": GRF_LW, "T": 8}
# the spaces of the M2 units (WP37): added by configure(4, m2=True)
UNIT_SP_ID = {"L1BM": 0x06, "L2BM": 0x07, "PDM": 0x08, "DRAM": 0x09}
UNIT_DEPTH = {"L1BM": 1024, "L2BM": 2048, "PDM": 1 << 17, "DRAM": 1 << 19}
UNIT_LOCS = {"L1BM": "n0c0b0", "L2BM": "n0c0", "PDM": "n0", "DRAM": "n0"}


def configure(npe: int, m2: bool = False) -> None:
    """Switches the module to the 1-PE core (default), the MAB of 4 PEs (WP30) or the M2 core (the
    MAB with the L1BM, L2BM and MV units, WP37)."""
    global N_PE, LM_LW, PE_LOCS, PROBE, TB_DEFINES, BUILD, UNIT, M2, MAXCLK
    if npe == 1 and not m2:
        return
    if npe != 4 and not m2:
        raise SystemExit("--pes must be 1 or 4")
    N_PE = 4
    LM_LW = 256                    # mn_core N_PE = 4, LM_AW = 8 (contract LM_DEPTH)
    PE_LOCS = [f"n0c0b0m0p{p}" for p in range(4)]
    PROBE = "mab4"
    TB_DEFINES = ["TB_NPE=4"]
    BUILD = HERE / "build" / "mab"
    DEPTH_LW.update(LM0=LM_LW, LM1=LM_LW)
    if m2:
        M2 = True
        PROBE = "m2"
        UNIT = "m2"
        TB_DEFINES = []            # the defines of the unit m2 (files.txt)
        BUILD = HERE / "build" / "m2"
        SP_ID.update(UNIT_SP_ID)
        DEPTH_LW.update(UNIT_DEPTH)
        MAXCLK = 50_000_000


def configure_vpe(n_mab: int, lm_aw: int, units: int = 1) -> None:
    """The virtual PEs (WP34): N_MAB MABs of 4 PEs, LM 2**lm_aw long words, with the M2 units (units = 1),
    without them (0: the PE-only board design) or with the L1BM unit only (2: L2MV = 0). The spaces of the
    absent units are neither read nor compared. The official and Rust runs are those of the configuration
    with the units (the same probe)."""
    global N_PE, LM_LW, PE_LOCS, PROBE, TB_DEFINES, BUILD, UNIT, M2, MAXCLK, TOPO_M2, N_MAB, VPE, UNITS
    configure(4, m2=True)
    VPE = True
    UNITS = {1: set(UNIT_SP_ID), 0: set(), 2: {"L1BM"}}[units]
    for sp in UNIT_SP_ID:
        if sp not in UNITS:
            SP_ID.pop(sp, None)
    N_MAB = n_mab
    LM_LW = 1 << lm_aw
    PE_LOCS = [f"n0c0b0m{m}p{p}" for m in range(n_mab) for p in range(4)]
    PROBE = "vpe"
    UNIT = "vpe"
    TB_DEFINES = ["TB_NPE=4", f"TB_M2={1 if units else 0}", "TB_SDMEM", "TB_VPE=1", f"TB_NMAB={n_mab}",
                  f"TB_LMAW={lm_aw}"] + (["TB_L2MV=0"] if units == 2 else [])
    BUILD = HERE / "build" / f"vpe{n_mab}_lm{lm_aw}"
    DEPTH_LW.update(LM0=LM_LW, LM1=LM_LW)
    TOPO_M2 = (f"l2b=1,l1b=1,mab={n_mab},lm={LM_LW},grf=256,l1bm=1024,l2bm=2048,pdm=131072,"
               f"dram=524288")
    MAXCLK = 400_000_000


def probe_text() -> str:
    """The probe of the configuration: the whole state of the implemented PEs at the end."""
    if PROBE == "pe":
        return "".join(line + "\n" for line in gl.probe_lines("pe"))
    lines = []
    for pe in PE_LOCS:
        n_lm = LM_LW
        if PROBE == "vpe" and N_MAB > 2 and not (pe.endswith(("m0p0", "m0p1", "m0p2", "m0p3")) or
                                                  f"m{N_MAB - 1}p" in pe):
            # WP34: the whole LM of the first and the last MAB, the first 256 long words of the others
            # (the probe of 64 PEs with the chip's LM would be 307,000 long words a program)
            n_lm = min(LM_LW, 256)
        lines += [f"d get $lm0{pe} {n_lm}", f"d get $ln0{pe} {n_lm}", f"d get $lr0{pe} {GRF_LW}",
                  f"d get $ls0{pe} {GRF_LW}", f"d get $llt{pe} 4", f"d get $omr1{pe} 15"]
    if PROBE in ("m2", "vpe"):
        lines += [f"d get $lb0n0c0b0 {UNIT_DEPTH['L1BM']}", f"d get $lc0n0c0 {UNIT_DEPTH['L2BM']}",
                  f"d get $d0n0 {DRAM_PROBE}"]
    return "".join(line + "\n" for line in lines)


def topology() -> "mnhost.Topology":
    return mnhost.Topology((1, 1, 1, N_MAB, N_PE))

D_RE = re.compile(r"^d\s+(set|get)([dfh]?)\s+(\S+)\s+(\d+)\s*(.*)$")
MEM_RE = re.compile(r"^\$(ll|l)?(omr|[rsmntbcpd])(\d*)((?:[ncbmp]\d+)*)$")


# --------------------------------------------------------------------------------------- fields
def field_names() -> list:
    """j field names by index (j_flat.yaml order)."""
    names = []
    text = (ROOT / "mncore" / "spec" / "isa" / "j_flat.yaml").read_text(encoding="utf-8")
    body = text.split("\nfields:", 1)[1]
    for m in re.finditer(r"^  - name: (\S+)", body, flags=re.MULTILINE):
        names.append(m.group(1))
    return names


FIELDS = field_names()
M_FIELDS = ["valid", "mmode", "tmode", "destid", "srcid", "dmode", "mvid", "indirect", "adra", "adrb",
            "nw", "priority"]


def jfield(word: int, pos: int, width: int) -> int:
    """Field at string position pos of a 426-bit j word (contract 06 section 2)."""
    return (word >> (426 - pos - width)) & ((1 << width) - 1)


# --------------------------------------------------------------------------------------- d lines
class DLine:
    def __init__(self, text: str):
        self.text = text.split("#", 1)[0].strip()
        m = D_RE.match(self.text)
        if not m:
            raise ValueError(f"cannot parse d line: {text}")
        self.op, self.dtype, mem, cnt, rest = m.groups()
        mm = MEM_RE.match(mem)
        if not mm:
            raise ValueError(f"cannot parse memory operand {mem!r}")
        pre, letter, addr, loc = mm.groups()
        self.count = int(cnt)
        self.addr = int(addr or 0)
        self.loc = {k: int(v) for k, v in re.findall(r"([ncbmp])(\d+)", loc)}
        if letter == "omr":
            self.space, self.width = "OMR", "w"
        else:
            self.space = mnhost.MEM_LETTER[letter]
            if letter in "rsmn":
                self.width = {None: "w", "l": "l", "ll": "ll"}[pre]
            elif letter in "tb":
                self.width = "ll" if pre == "ll" else "l"
            else:
                self.width = "l"
        self.payload = []
        if self.op == "set":
            self.payload = mnhost.parse_payload(rest)

    def on_pe(self) -> bool:
        """Whether this line touches an implemented PE."""
        return bool(self.pe_locs())

    def pe_locs(self) -> list:
        """The implemented PEs (or L1B / L2B / group of the M2 units) this line touches, as
        (loc code, location text)."""
        if self.space not in SP_ID:
            return []
        sp = self.space if self.space != "OMR" else "T"
        out = []
        for f in topology().locations(sp, self.loc):
            out.append((mnhost.loc_code(**f), mnhost.loc_text(sp, f)))
        return out

    def mnhost_op(self) -> "mnhost.DOp":
        return mnhost.DOp(op=self.op, space=self.space, width=self.width, addr=self.addr, loc=self.loc,
                          count=self.count, payload=self.payload, text=self.text)


class RLine:
    """An `r` line (DRAM data, contract 06 section 2): r <group> <addr hex> <count hex> <long words>.
    The M2 core has group 0 only; it becomes WR_MEM of space 9 (DRAM n0)."""

    def __init__(self, text: str):
        self.text = text.split("#", 1)[0].strip()
        f = self.text.split()
        if len(f) != 5 or f[0] != "r":
            raise ValueError(f"cannot parse r line: {text}")
        self.group, self.addr, n = int(f[1]), int(f[2], 16), int(f[3], 16)
        if len(f[4]) != 16 * n:
            raise ValueError(f"r line payload is not {n} long words: {text}")
        self.payload = [int(f[4][16 * i:16 * i + 16], 16) for i in range(n)]
        self.op = "r"


def parse_official_asm(text: str):
    entries, events, n_r = [], [], 0
    for ln, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        tag = line[0]
        if tag in "jm" and len(line) > 2 and line[1] == " ":
            bits = line[2:].strip()
            entries.append((tag, int(bits, 2)))
        elif tag == "d":
            events.append((len(entries), DLine(line)))
        elif tag == "r":
            n_r += 1    # DRAM data: there is no DRAM in the 1-PE / 4-PE cores
            if M2:
                events.append((len(entries), RLine(line)))
        else:
            raise ValueError(f"line {ln}: unknown line {line[:30]!r}")
    return entries, events, n_r


# --------------------------------------------------------------------------------------- script
def get_reads(d: DLine):
    """(space id, first long word / entry, count) reads for a d get, inside the implemented depth."""
    if d.space == "OMR":
        ents = [e for e in range(d.addr, d.addr + d.count) if 1 <= e <= 15]
        return [(SP_ID["OMR"], e, 1) for e in ents]
    if d.space == "T":
        return [(SP_ID["T"], 0, 8)]
    if d.space in UNIT_SP_ID:
        # long words; L1BM $llb<a> reads a + i and a + i + 4 (WP02)
        lws = set(range(d.addr, d.addr + d.count))
        if d.space == "L1BM" and d.width == "ll":
            lws |= set(range(d.addr + 4, d.addr + d.count + 4))
        lws = sorted(a for a in lws if a < DEPTH_LW[d.space])
        return [(SP_ID[d.space], r[0], len(r)) for r in mnhost._addr_runs(lws)]
    if d.width == "w":
        lo, hi = d.addr >> 1, (d.addr + d.count - 1) >> 1
    else:
        per = 2 if d.width == "ll" else 1
        lo = d.addr >> 1
        hi = lo + d.count * per - 1
    hi = min(hi, DEPTH_LW[d.space] - 1)
    if hi < lo:
        return []
    return [(SP_ID[d.space], lo, hi - lo + 1)]


def set_writes(d: DLine):
    """(space id, long word, mask, value) writes for a d set on PE n0c0b0m0p0."""
    if d.space == "OMR":
        raise ValueError("d set of a mask register is not handled")
    out = []
    if d.space == "L1BM" and d.width == "ll":
        # $llb<a>: long words a + i (payload 2i) and a + i + 4 (payload 2i + 1)
        items = []
        for i in range(d.count):
            items += [(d.addr + i, d.payload[2 * i], 0xFF), (d.addr + i + 4, d.payload[2 * i + 1], 0xFF)]
    else:
        items = mnhost.long_words(d.mnhost_op())
    for lw, v, m in items:
        if d.space in DEPTH_LW and lw >= DEPTH_LW[d.space]:
            raise ValueError(f"d set beyond the implemented depth: {d.text}")
        out.append((SP_ID[d.space], lw, m, v))
    return out


def make_script(entries, events):
    lines = ["C"]
    runs = []           # (first entry, count) of each X, in order
    gets = []           # (tag, DLine)
    win = {"base": None}

    def load_window(base):
        for k, (tag, word) in enumerate(entries[base:base + IMEM_DEPTH]):
            lines.append(f"I {k:x} {mnhost.imem_entry(tag, word):0112x}")
        win["base"] = base

    def run_range(a, b):
        while a < b:
            if win["base"] is None or not (win["base"] <= a < win["base"] + IMEM_DEPTH):
                load_window(a)
            n = min(b, win["base"] + IMEM_DEPTH) - a
            lines.append(f"X {a - win['base']:x} {n:x}")
            runs.append((a, n, win["base"]))
            a += n

    if entries:
        load_window(0)
    pc = 0
    for pos, d in events:
        if pos > pc:
            run_range(pc, pos)
            pc = pos
        if isinstance(d, RLine):
            # DRAM data of group 0 (the M2 core has no other group; WP34 --vpe-units 0 / 2: no DRAM)
            if d.group == 0 and "DRAM" in SP_ID:
                for i, v in enumerate(d.payload):
                    if d.addr + i >= DEPTH_LW["DRAM"]:
                        raise ValueError(f"r line beyond the implemented DRAM: {d.text}")
                    lines.append(f"W {SP_ID['DRAM']:x} 0 {d.addr + i:x} ff {v:x}")
            continue
        for code, lt in d.pe_locs():
            if d.op == "set":
                for sp, lw, m, v in set_writes(d):
                    lines.append(f"W {sp:x} {code:x} {lw:x} {m:x} {v:x}")
            else:
                tag = len(gets)
                gets.append((tag, d, lt))
                for sp, lo, n in get_reads(d):
                    lines.append(f"R {tag:x} {sp:x} {code:x} {lo:x} {n:x}")
    if len(entries) > pc:
        run_range(pc, len(entries))
    lines.append("E")
    return "\n".join(lines) + "\n", runs, gets


def rtl_records(gets, reads):
    """ndmp records of the RTL's d gets, in program order (like norm_gpfn3 on the emulator dump).
    gets: (tag, DLine, location text) per d get and implemented PE."""
    recs = []
    for tag, d, loc in gets:
        sp = SP_ID[d.space]

        def lw_val(a):
            return reads.get((tag, sp, a))

        if d.space == "OMR":
            for e in range(d.addr, d.addr + d.count):
                for c in range(4):
                    if e == 0:
                        v = 15
                    elif e >= 16:
                        v = 15 if (e >> (3 - c)) & 1 else 0
                    else:
                        w = lw_val(e)
                        if w is None:
                            continue
                        v = (w >> (4 * c)) & 0xF
                    recs.append(("OMR", loc, e * 4 + c, v))
        elif d.space == "T":
            for i in range(d.count):
                c = (d.addr + i) % 4
                for k in range(2 if d.width == "ll" else 1):
                    w = lw_val(2 * c + k)
                    if w is not None:
                        recs.append(("T", loc, 2 * c + k, w))
        elif d.space in UNIT_SP_ID:
            lws = [d.addr + i for i in range(d.count)]
            if d.space == "L1BM" and d.width == "ll":
                lws = [a for i in range(d.count) for a in (d.addr + i, d.addr + i + 4)]
            for a in lws:
                w = lw_val(a)
                if w is not None:
                    recs.append((d.space, loc, a, w))
        elif d.width == "w":
            for i in range(d.count):
                a = d.addr + i
                w = lw_val(a >> 1)
                if w is not None:
                    recs.append((d.space + "W", loc, a, (w >> 32) if a % 2 == 0 else w & 0xFFFFFFFF))
        else:
            per = 2 if d.width == "ll" else 1
            base = d.addr >> 1
            for i in range(d.count * per):
                w = lw_val(base + i)
                if w is not None:
                    recs.append((d.space, loc, base + i, w))
    return ndmp.canonical(recs)


def keep_record(key) -> bool:
    space, loc, addr = key
    if space in UNIT_SP_ID and space not in UNITS:
        return False
    if M2 and space in UNIT_SP_ID:
        # PDM is not compared: the official d get $p shows the DRAM (contract 06 section 1)
        return space != "PDM" and loc == UNIT_LOCS[space] and addr < DEPTH_LW[space]
    if loc not in PE_LOCS:
        return False
    if space in DEPTH_LW:
        return addr < DEPTH_LW[space]
    if space.endswith("W") and space[:-1] in WORD_SPACES:
        return addr < 2 * DEPTH_LW[space[:-1]]
    return space == "OMR"


# --------------------------------------------------------------------------------------- official
def prog_name(path: str) -> str:
    return gl.safe_name(gl.MNCORE / path)


def load_prog(path: str):
    """The program as the official run composes it (goldenlib), with the probe of the configuration."""
    vsm = gl.MNCORE / path
    if PROBE == "pe":
        return gl.load_program(vsm, "auto", "pe")
    prog = gl.load_program(vsm, "auto", "none")
    prog.probe = PROBE
    prog.probe_text = probe_text()
    prog.meta["probe"] = PROBE
    return prog


def prog_key(prog) -> str:
    return hashlib.sha1("\0".join([prog.prefix, prog.main_vsm, prog.suffix_vsm, prog.output,
                                   prog.probe_text]).encode()).hexdigest()


def official_stage(rows, jobs: int, force: bool, log):
    todo = []
    for r in rows:
        prog = load_prog(r["path"])
        job = BUILD / prog_name(r["path"])
        key = prog_key(prog)
        kf = job / "key.txt"
        if (not force and gl.read_status(job) == "ok" and kf.exists() and kf.read_text().strip() == key
                and (job / "official.asm").exists()):
            continue
        gl.write_official_job(prog, job)
        kf.write_text(key + "\n")
        todo.append(job)
    if todo:
        log(f"[official] {len(todo)} programs to run in WSL ({jobs} in parallel)")
        t = time.time()
        n = [0]

        def on_line(s):
            n[0] += 1
            if n[0] % 25 == 0 or not s.startswith("ok"):
                log(f"[official] {n[0]}/{len(todo)} {s}")
        gl.run_official_jobs(todo, parallel=jobs, keep=True, on_line=on_line)
        log(f"[official] done in {time.time() - t:.0f} s")
        if VPE:
            # the emulator's dump of the 64-PE probe is large (about 28 MB): official.ndmp holds it
            for job in todo:
                (job / "official.dmp").unlink(missing_ok=True)


# --------------------------------------------------------------------------------------- rust (M2)
TOPO_DUMP = HERE / "topo_rs" / "target" / "release" / ("topo_dump.exe" if os.name == "nt" else "topo_dump")


def build_topo_dump(log) -> Path:
    """cargo build --release of mncore/sim/regress/topo_rs (topo_dump: the Rust simulator on a reduced
    topology, with the d get records of WP02's golden_dump)."""
    r = subprocess.run([gl.cargo(), "build", "--release", "--quiet", "--manifest-path",
                        str(HERE / "topo_rs" / "Cargo.toml")], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("topo_rs build failed")
    log("[rust] built topo_dump")
    return TOPO_DUMP


def rust_one(path: str, topo: str, force: bool) -> str:
    """Runs one program on topo_dump; writes rust.ndmp and rust.status (ok / range <word> /
    unsupported / parse_error / error<rc> / timeout) into its job directory. Returns the status."""
    prog = load_prog(path)
    job = BUILD / prog_name(path)
    job.mkdir(parents=True, exist_ok=True)
    key = prog_key(prog) + "|" + topo
    kf, sf = job / "rust_key.txt", job / "rust.status"
    if not force and kf.exists() and sf.exists() and kf.read_text().strip() == key:
        return sf.read_text().strip()
    try:
        r = subprocess.run([str(TOPO_DUMP), "--topology", topo, "-"], input=prog.rust_source().encode("utf-8"),
                           capture_output=True, timeout=1800, env=dict(os.environ, RAYON_NUM_THREADS="1"))
        err = r.stderr.decode("utf-8", "replace")
        if r.returncode == 0:
            st = "ok"
        elif r.returncode == 5:
            m = re.search(r"RANGE word=(\d+)", err)
            st = f"range {m.group(1) if m else '?'}"
        else:
            st = {2: "unsupported", 3: "parse_error"}.get(r.returncode, f"error{r.returncode}")
        body = r.stdout.decode("utf-8").replace("\r\n", "\n")
    except subprocess.TimeoutExpired:
        st, body, err = "timeout", "", ""
    (job / "rust.ndmp").write_text("# ndmp v1\n# producer: topo_dump " + topo + "\n" + body, encoding="utf-8",
                                   newline="\n")
    (job / "rust.log").write_text(err, encoding="utf-8", newline="\n")
    sf.write_text(st + "\n")
    kf.write_text(key + "\n")
    return st


def rust_stage(rows, jobs: int, force: bool, log):
    t = time.time()
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        sts = list(ex.map(lambda r: rust_one(r["path"], TOPO_M2, force), rows))
    c = Counter(st.split()[0] for st in sts)
    log(f"[rust] {len(rows)} programs on {TOPO_M2} in {time.time() - t:.0f} s: " +
        ", ".join(f"{k} {v}" for k, v in sorted(c.items())))


# --------------------------------------------------------------------------------------- rtl
def compile_tb(log, defines=()) -> Path:
    files, cfg = simrun.parse_files(UNIT)
    unit_defs = [d for d in cfg.get("define", []) if not d.startswith("TB_SCRIPT")] if UNIT != "core" else []
    # the configuration's defines (and --define) replace the unit's of the same name, --define those of
    # the configuration (WP34: e.g. --vpe 16 --define TB_M2=0)
    given = {d.split("=", 1)[0] for d in defines}
    cfg_defs = [d for d in TB_DEFINES if d.split("=", 1)[0] not in given]
    mine = {d.split("=", 1)[0] for d in cfg_defs} | given
    unit_defs = [d for d in unit_defs if d.split("=", 1)[0] not in mine]
    defines = cfg_defs + unit_defs + list(defines)
    vvp = BUILD / ("sim" + "".join(f"_{d.replace('=', '')}" for d in defines) + ".vvp")
    cmd = ["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", str(vvp)]
    cmd += [f"-D{d}" for d in defines]
    cmd += [f"-I{d}" for d in cfg["incdir"]] + ["-s", cfg["top"]] + files
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("iverilog failed")
    log("[rtl] compiled tb_core")
    return vvp


def classify_stop(reason: int, info: int, entry_word):
    if reason == 1:
        return "E_RANGE", f"word {info}"
    if reason == 4:
        return "WAIT", f"tag {info}"
    if reason == 3:
        return "E_DECODE", f"info {info:#x}"
    if info & 0x80:
        name = M_FIELDS[info & 0x7F] if (info & 0x7F) < len(M_FIELDS) else str(info)
        return f"E_UNSUPPORTED m.{name}", "MV instruction"
    name = FIELDS[info] if info < len(FIELDS) else str(info)
    what = ""
    if entry_word is not None:
        tag, w = entry_word
        if tag == "j":
            aluop = jfield(w, 147, 5)
            iselb = jfield(w, 159, 3)
            if name == "pe_aluc_aluop":
                what = {0b10001: "msl", 0b10010: "msr", 0b10000: "rsqrt", 0b10100: "relu", 0b10101: "relu1",
                        0b10110: "relu2", 0b10111: "relu3", 0b11000: "lrelud", 0b11001: "lreluo",
                        0b11010: "ilrelud", 0b11011: "fmax", 0b11100: "fmin", 0b11101: "bfe"}.get(aluop, "")
                if aluop == 0b11110:
                    what = {0b110: "floor", 0b111: "ftoi"}.get(iselb, "bfn")
            elif name == "pe_mauc_mmode":
                what = "matrix MAU"
            elif name == "pe_mauc_dmode":
                what = "matrix MAU d"
            elif name == "pe_mauc_mw":
                what = "?mwrite"
    return f"E_UNSUPPORTED {name}", what


def run_one(row, vvp: Path, timeout: int, keep: bool, tag: str = ""):
    """tag: suffix of the configuration (e.g. _TB_FPALU0) on the RTL files of the job directory,
    so that runs of different configurations can share the cached official results."""
    name = prog_name(row["path"])
    job = BUILD / name
    res = {"path": row["path"], "groups": row["groups"], "kind": row["kind"], "result": "", "detail": "",
           "words": "", "steps": 0, "clocks": 0, "compared": 0, "seconds": 0.0}
    status = gl.read_status(job)
    if status != "ok":
        res["result"], res["detail"] = "official_fail", status
        return res
    t0 = time.time()
    try:
        entries, events, n_r = parse_official_asm((job / "official.asm").read_text(encoding="utf-8"))
        script, runs, gets = make_script(entries, events)
    except ValueError as e:
        res["result"], res["detail"] = "script_error", str(e)
        return res
    res["words"] = len(entries)
    scr = job / f"rtl{tag}.scr"
    scr.write_text(script, encoding="utf-8", newline="\n")
    try:
        r = subprocess.run(["vvp", "-n", str(vvp), f"+script={scr.as_posix()}", "+quiet"] +
                           ([f"+maxclk={MAXCLK}"] if MAXCLK else []),
                           cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        res["result"], res["detail"] = "timeout", f"{timeout} s"
        return res
    out = r.stdout
    if keep:
        (job / f"rtl{tag}.out").write_text(out, encoding="utf-8", newline="\n")
    reads = {}
    stops = []
    for line in out.splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "D":
            reads[(int(p[1], 16), int(p[2], 16), int(p[3], 16))] = int(p[4], 16)
        elif p[0] == "S":
            stops.append(p[1:])
        elif p[0] == "VPE" and len(p) > 1 and p[1] == "words":
            # WP34: clocks of the context loads / MAB starts / MAB passes / context saves, check-only
            # passes, SDRAM requests (tb_core prints the totals once)
            res["vpe"] = "/".join(re.findall(r"\d+", line)[1:])
        elif p[0] in ("ERR", "DERR") or line.startswith("mn_pe_core: ERROR") or line.startswith("FAIL") or                 ": ERROR" in line:
            res["detail"] += (" | " if res["detail"] else "") + line.strip()
    res["seconds"] = round(time.time() - t0, 2)
    errs = res["detail"]
    # stop records, in RUN order
    waited = None
    for (first, n, base), st in zip(runs, stops):
        if st[0] == "TIMEOUT":
            res["result"] = "timeout"
            return res
        reason, info, pc, steps = (int(x, 16) for x in st[:4])
        res["steps"] += steps
        res["clocks"] += int(st[5])
        if reason == 4:
            # WAIT (M2): the official blocks there for ever; the d gets show the state at that point
            if waited is None:
                waited = base + pc
            continue
        if reason != 0:
            # pc is the entry of the loaded window
            idx = base + pc if base + pc < len(entries) else None
            entry = entries[idx] if idx is not None else None
            res["result"], what = classify_stop(reason, info, entry)
            res["detail"] = (what + " " if what else "") + f"at word {idx}"
            if M2:
                rst = (job / "rust.status").read_text().strip() if (job / "rust.status").exists() else "missing"
                res["rust"] = rst
                if reason == 1 and rst == f"range {idx}":
                    res["cls"] = "E_RANGE as rust"
                else:
                    res["cls"] = res["result"]
            return res
    if len(stops) < len(runs):
        res["result"] = "error"
        res["detail"] = (res["detail"] + " | " if res["detail"] else "") + "missing stop records"
        return res
    if r.returncode != 0 or errs:
        res["result"] = "error"
        return res
    if waited is not None:
        res["detail"] = f"WAIT at word {waited}; " 
    rtl = rtl_records(gets, reads)
    off, _ = ndmp.read(str(job / "official.ndmp"))
    a = {k: v for k, v in off.items() if keep_record(k)}
    b = {k: v for k, v in rtl.items() if keep_record(k)}
    if not VPE:
        ndmp.write(str(job / f"rtl{tag}.ndmp"), rtl, {"producer": "rtl tb_core", "src": row["path"]})
    if M2:
        m2_compare(res, job, a, b, tag)
    if VPE and not res.get("cls", "").startswith("pass"):
        # the 64-PE dump is large: kept only when the RTL matches neither reference (WP34)
        ndmp.write(str(job / f"rtl{tag}.ndmp"), rtl, {"producer": "rtl tb_core", "src": row["path"]})
    mism = sorted(k for k in a.keys() & b.keys() if a[k] != b[k])
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    res["compared"] = len(a.keys() & b.keys())
    # the program must not use LM beyond the implemented depth (the RTL would trap)
    beyond = sum(1 for (s, l, ad), v in off.items() if l in PE_LOCS and s in ("LM0", "LM1") and ad >= LM_LW and v)
    if mism or only_a or only_b:
        sp = Counter(k[0] for k in mism + only_a + only_b)
        res["result"] = "mismatch(" + ",".join(sorted(sp)) + ")"
        lines = [f"{k[0]} {k[1]} {k[2]:#06x} official={a.get(k, 0):016x} rtl={b.get(k, 0):016x}"
                 for k in (mism + only_a + only_b)[:20]]
        (job / f"cmp{tag}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        res["detail"] += f"{len(mism)} differ, {len(only_a)} only official, {len(only_b)} only rtl"
    elif beyond:
        res["result"] = "mismatch(LM beyond depth)"
        res["detail"] = f"{beyond} official LM long words beyond {LM_LW} are not 0"
    else:
        res["result"] = "pass"
    return res


def diff(a: dict, b: dict):
    mism = sorted(k for k in a.keys() & b.keys() if a[k] != b[k])
    return mism, sorted(set(a) - set(b)), sorted(set(b) - set(a))


def m2_compare(res: dict, job: Path, off: dict, rtl: dict, tag: str) -> None:
    """M2 (WP37): the RTL against the official (cut to the implemented units) and the Rust simulator
    on the reduced topology (the zero rule). Sets res["rust"], res["vs_rust"], res["off_rust"], res["cls"]."""
    rst = (job / "rust.status").read_text().strip() if (job / "rust.status").exists() else "missing"
    res["rust"] = rst
    pass_o = not any(diff(off, rtl))
    if rst != "ok":
        res["vs_rust"], res["off_rust"] = "-", "-"
        res["cls"] = "pass (official; rust " + rst + ")" if pass_o else "mismatch (rust " + rst + ")"
        return
    rd, _ = ndmp.read(str(job / "rust.ndmp"))
    rust = {k: v for k, v in rd.items() if keep_record(k)}
    m_r, oa_r, ob_r = diff(rust, rtl)
    pass_r = not (m_r or oa_r or ob_r)
    m_or, oa_or, ob_or = diff(off, rust)
    closed = not (m_or or oa_or or ob_or)
    sp = sorted({k[0] for k in m_or + oa_or + ob_or})
    res["off_rust"] = "same" if closed else "differ(" + ",".join(sp) + ")"
    res["vs_rust"] = "pass" if pass_r else "mismatch(" + ",".join(sorted({k[0] for k in m_r + oa_r + ob_r})) + ")"
    if pass_r and not pass_o:
        lines = [f"{k[0]} {k[1]} {k[2]:#06x} rust={rust.get(k, 0):016x} rtl={rtl.get(k, 0):016x}"
                 for k in (m_r + oa_r + ob_r)[:20]]
        (job / f"cmp_rust{tag}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    elif not pass_r:
        lines = [f"{k[0]} {k[1]} {k[2]:#06x} rust={rust.get(k, 0):016x} rtl={rtl.get(k, 0):016x}"
                 for k in (m_r + oa_r + ob_r)[:20]]
        (job / f"cmp_rust{tag}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if closed and pass_o:
        res["cls"] = "pass b"
    elif pass_r and not closed:
        res["cls"] = "pass c"
    elif pass_o:
        res["cls"] = "pass b (rust differs)"
    else:
        res["cls"] = "mismatch"


# --------------------------------------------------------------------------------------- main
def group_of(row) -> str:
    g = row["groups"]
    if g in ("", "-"):
        return "d set/get only"
    return g


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pes", type=int, default=1, help="1: the 1-PE core (WP20); 4: one MAB of 4 PEs (WP30)")
    ap.add_argument("--only", help="only programs whose path contains this text")
    ap.add_argument("-j", "--jobs", type=int, default=8, help="parallel RTL simulations")
    ap.add_argument("--official-jobs", type=int, default=12)
    ap.add_argument("--skip-official", action="store_true", help="use the cached official results only")
    ap.add_argument("--force-official", action="store_true")
    ap.add_argument("--timeout", type=int, default=1800, help="seconds per RTL simulation")
    ap.add_argument("--table", help="also write the results table here (TSV)")
    ap.add_argument("--keep", action="store_true", help="keep the simulator output (build/<name>/rtl.out)")
    ap.add_argument("--vvp", help="use this compiled tb_core instead of compiling one (e.g. a mutated RTL)")
    ap.add_argument("--define", action="append", default=[],
                    help="iverilog define for tb_core, e.g. TB_FPALU=0 or TB_MAU=0 (reduced cores)")
    ap.add_argument("--also-lm", action="store_true",
                    help="also the programs that pe1 leaves out only for their LM addresses (run-time "
                         "addresses or beyond 256 long words): they pass if they stay inside the LM, "
                         "else the RTL stops with E_RANGE (results<tag>_lm.tsv)")
    ap.add_argument("--matrix", action="store_true",
                    help="WP36: instead of pe1 = yes, the programs that pe1 leaves out only for the "
                         "matrix group (?mwrite / ?mread / ?mfma, also msl / msr; with --also-lm also "
                         "for their LM addresses). Use with --pes 4 --define TB_MAT=1 "
                         "(results<tag>_mat.tsv)")
    ap.add_argument("--m2", action="store_true",
                    help="WP37: the M2 core (L1BM, L2BM, MV units) on the programs left out of pe1 for the "
                         "l1bm / l2bm / mv groups (and their LM addresses); with --matrix also those with "
                         "the matrix group. Also runs the reduced-topology Rust simulator (zero rule)")
    ap.add_argument("--skip-rust", action="store_true", help="M2: use the cached Rust results only")
    ap.add_argument("--force-rust", action="store_true")
    ap.add_argument("--list", help="only the corpus paths in this file (one per line, '#' comments)")
    ap.add_argument("--vpe", type=int, choices=(1, 2, 4, 8, 16),
                    help="WP34: the virtual PEs with this many MABs (16: the 64 PEs of one L1B), with the M2 units")
    ap.add_argument("--lm-aw", type=int, default=11, help="--vpe: LM 2**lm-aw long words (8 .. 11, default 11)")
    ap.add_argument("--vpe-units", type=int, default=1, choices=(0, 1, 2),
                    help="--vpe: 1 the L1BM / L2BM / MV units, 0 none (the PE-only board design), 2 the L1BM only")
    ap.add_argument("--official-only", action="store_true",
                    help="only the official (and, M2 / VPE, the Rust) runs; no RTL")
    a = ap.parse_args(argv)

    def log(s):
        print(s, flush=True)

    if a.vpe:
        configure_vpe(a.vpe, a.lm_aw, a.vpe_units)
    else:
        configure(a.pes, a.m2)
    BUILD.mkdir(parents=True, exist_ok=True)
    rows = []
    lm_only = {"lm_dyn", "lm_max>=256"}
    only_paths = None
    if a.list:
        only_paths = {ln.split("#", 1)[0].strip() for ln in Path(a.list).read_text(encoding="utf-8").splitlines()}
        only_paths.discard("")

    def m2_ok(reasons: set) -> bool:
        groups = set()
        rest = set()
        for x in reasons:
            if x.startswith("groups:"):
                groups |= set(x.split(":", 1)[1].split("+"))
            else:
                rest.add(x)
        # --m2: no matrix group; --m2 --matrix: the ones with the matrix group (TB_MAT=1)
        allowed = {"l1bm", "l2bm", "mv"} | ({"matrix"} if a.matrix else set())
        return bool(groups) and groups <= allowed and rest <= lm_only and \
            (("matrix" in groups) == a.matrix) and bool(groups & {"l1bm", "l2bm", "mv"})

    def selected(r) -> bool:
        reasons = set(filter(None, r.get("pe1_reason", "").split(";")))
        if a.vpe and not a.m2:
            return r.get("official") == "ok"     # WP34: every program the official ran
        if a.m2:
            return r.get("official") == "ok" and m2_ok(reasons)
        if a.matrix:
            allowed = {"groups:matrix"} | (lm_only if a.also_lm else set())
            return r.get("official") == "ok" and "groups:matrix" in reasons and reasons <= allowed
        if r.get("pe1") == "yes":
            return not a.also_lm
        return a.also_lm and r.get("official") == "ok" and bool(reasons) and reasons <= lm_only

    with open(ROOT / "mncore" / "tools" / "golden" / "corpus.tsv", encoding="utf-8") as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(head, line.rstrip("\n").split("\t")))
            if selected(r) and (not a.only or a.only in r["path"]) and \
                    (only_paths is None or r["path"] in only_paths):
                rows.append(r)
    what = ("left out of pe1 only for the matrix group" + (" (and LM)" if a.also_lm else "")) if a.matrix else \
        ("left out of pe1 only for LM" if a.also_lm else "with pe1 = yes")
    if a.m2:
        what = "left out of pe1 for the l1bm / l2bm / mv groups" + (" (with matrix)" if a.matrix else "")
    if a.vpe and not a.m2:
        what = "that the official ran"
    if a.vpe:
        what += f" on the virtual PEs: {N_MAB} MAB(s), LM {LM_LW} long words"
    log(f"[regress] {len(rows)} programs {what}")
    if not a.skip_official:
        official_stage(rows, a.official_jobs, a.force_official, log)
    if M2 and not a.skip_rust:
        build_topo_dump(log)
        rust_stage(rows, a.jobs, a.force_rust, log)
    if a.official_only:
        return 0
    vvp = Path(a.vvp).resolve() if a.vvp else compile_tb(log, a.define)
    # RTL files of the configuration (WP34: _TB_M20 / _TB_L2MV0 for the virtual PEs without (some of) the units)
    utag = {0: "_TB_M20", 1: "", 2: "_TB_L2MV0"}[a.vpe_units] if a.vpe else ""
    ftag = utag + "".join(f"_{d.replace('=', '')}" for d in a.define)
    t0 = time.time()
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(run_one, r, vvp, a.timeout, a.keep, ftag): r for r in rows}
        for i, fu in enumerate(cf.as_completed(futs), 1):
            res = fu.result()
            results.append(res)
            shown = res.get("cls", res["result"]) if M2 else res["result"]   # M2 / VPE: pass b / pass c ...
            if not shown.startswith("pass") or i % 25 == 0:
                log(f"[rtl] {i}/{len(rows)} {shown:<24} {res['path']} {res['detail']}")
    log(f"[rtl] {len(rows)} programs in {time.time() - t0:.0f} s")
    results.sort(key=lambda r: r["path"])
    cols = ["path", "kind", "groups", "words", "steps", "clocks", "compared", "result", "detail"]
    if M2:
        cols += ["rust", "off_rust", "vs_rust", "cls"]
        for r in results:
            for c in ("rust", "off_rust", "vs_rust", "cls"):
                r.setdefault(c, "-")
            if r["cls"] == "-":
                r["cls"] = r["result"]
    if VPE:
        # WP34: load/start/run/save clocks, check passes, SDRAM requests (run_one); simulation seconds
        cols += ["vpe", "seconds"]
        for r in results:
            r.setdefault("vpe", "-")
    text ="\t".join(cols) + "\n" + "".join("\t".join(str(r[c]) for c in cols) + "\n" for r in results)
    tag = utag + "".join(f"_{d.replace('=', '')}" for d in a.define) + ("_lm" if a.also_lm else "") + \
        ("_mat" if a.matrix else "")
    (BUILD / f"results{tag}.tsv").write_text(text, encoding="utf-8", newline="\n")
    if a.table:
        Path(a.table).write_text(text, encoding="utf-8", newline="\n")

    # summary: result class by corpus group
    by = defaultdict(Counter)
    for r in results:
        res = r["result"]
        cls = res.split("(")[0] if res.startswith("mismatch") else res
        if M2 and "TB_REPLICA=1" not in a.define:
            cls = r["cls"]
        by[group_of(r)][cls] += 1
    classes = sorted({c for g in by.values() for c in g}, key=lambda c: (c != "pass", c))
    log("")
    log("group\t" + "\t".join(classes) + "\ttotal")
    for g in sorted(by):
        log(g + "\t" + "\t".join(str(by[g][c]) for c in classes) + f"\t{sum(by[g].values())}")
    tot = Counter(r["result"].split("(")[0] if r["result"].startswith("mismatch") else r["result"] for r in results)
    if M2 and "TB_REPLICA=1" not in a.define:
        tot = Counter(r["cls"] for r in results)
    log("all\t" + "\t".join(str(tot[c]) for c in classes) + f"\t{len(results)}")
    reasons = Counter((r["result"], r["detail"].split(" at word")[0]) for r in results if r["result"] != "pass")
    if reasons:
        log("")
        for (res, det), n in sorted(reasons.items(), key=lambda x: -x[1]):
            log(f"{n:4d}  {res}  {det}")
    npass = sum(n for c, n in tot.items() if c.startswith("pass"))
    log(f"\nPASS {npass}/{len(results)}" if npass == len(results) else f"\n{npass}/{len(results)} pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())

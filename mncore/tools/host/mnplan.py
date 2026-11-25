#!/usr/bin/env python3
"""mnplan: which bitstream of the set can run each word of a program, and where the program can
switch bitstreams (WP38). Used by mnrun.py; no board needed.

  python mncore/tools/host/mnplan.py X.asm [--set mncore/fpga/multi/set.json] [--rule zero|replica] [-v]

A member of the set (mncore/fpga/multi/set.json) has capabilities (caps):
  L1 the L1BM unit, L1R its reductions (L1_RRN != 0), L2 the L2BM unit, MV the MV unit (m words,
  waits), MAU the vector MAU, MAT the matrix unit, FPALU 0..3, BFN, SDRAM (the PDM / DRAM spaces).

Word analysis (analyze_word): from the fields of the machine word (mnisa, j_flat.yaml / m.yaml) and the
rules of the RTL (mn_alu_cls, mn_pe_core, mn_l1bm, mn_core):
  - needs: the caps the word needs (an FP ALU instruction needs FPALU 1 for floor / ftoi, 1 or 2 for
    fmax / fmin, 1..3 for the others; reading $mauf needs MAU or MAT; reading $lbf needs L1; ...).
    Words that no member can run (d matrix MAU, DAR instructions) need "NONE".
  - the hidden state it reads and writes: the state the host cannot read or write (rtl/board/
    PROTOCOL.md): the forwarding registers $aluf, $mauf, $lbf (per PE and cycle; a word that writes
    one writes it whole), the turnaround register $lbi (planes lbi0 / lbi1 and the layout of the
    transfer that wrote it, lbim), the matrix registers (matrix, only in programs with ?mwrite). The
    MV tag counts are hidden too, but mnrun.py restores them with m words that do nothing (mmode 111),
    so they do not limit the switch points.
A switch point (a boundary between two words) is clean when no hidden state is live there (backward
liveness over the straight-line program; the state after RESET / configuration is 0, so state that
is only live from the start is fine). plan() cuts the program at clean boundaries into the fewest
segments that one member can run each (greedy: the farthest clean boundary with a common member;
the member already loaded is preferred). A part that no member can run whole is given to the
member that runs the longest prefix of it; the board then stops at the word it cannot run
(E_UNSUPPORTED), as a single bitstream would.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
sys.path.insert(0, str(HERE))
from mnisa import codec  # noqa: E402
import mnhost  # noqa: E402

SET_JSON = ROOT / "mncore" / "fpga" / "multi" / "set.json"
J_MASK = (1 << 426) - 1

# ALU instructions with a second input (mn_pe_core two_in)
TWO_IN = {0b00000, 0b00001, 0b00101, 0b00110, 0b00111, 0b01000, 0b01001, 0b01011, 0b01100, 0b01101,
          0b01110, 0b10011, 0b10100, 0b10101, 0b10110, 0b10111, 0b11000, 0b11001, 0b11010, 0b11011, 0b11100}
FWD_ITEMS = ("aluf", "mauf", "lbf")


# ----------------------------------------------------------------------------------------- members
@dataclass
class Member:
    name: str
    params: dict
    caps: frozenset
    rule: str                   # "zero", "replica" or "any" (no L1BM / L2BM: the rule does not matter)
    fs: Path
    design_id: int
    flags: int
    desc: str = ""

    def supports(self, needs) -> bool:
        return all(n in self.caps for n in needs)

    def missing(self, needs) -> list:
        return sorted(n for n in needs if n not in self.caps)


def member_caps(p: dict) -> frozenset:
    """The caps of mn_top_multi with these parameters (see the module doc)."""
    caps = set()
    units = int(p.get("UNITS", 2))
    if units >= 1:
        caps.add("L1")
        if int(p.get("L1_RRN", 2)) != 0:
            caps.add("L1R")
    if units == 2:
        caps |= {"L2", "MV"}
    if int(p.get("MAU", 0)):
        caps |= {"MAU", "MAUF"}
    if int(p.get("MAT", 0)):
        caps |= {"MAT", "MAUF"}
    fp = int(p.get("FPALU", 0))
    if fp == 1:
        caps |= {"FP1", "FP2", "FP3"}
    elif fp == 2:
        caps |= {"FP2", "FP3"}
    elif fp == 3:
        caps.add("FP3")
    if int(p.get("BFN", 0)):
        caps.add("BFN")
    if int(p.get("SDRAM", 1)) or units == 2:
        caps.add("SDRAM")
    return frozenset(caps)


def member_flags(p: dict) -> int:
    return (1 + (int(p.get("FPALU", 0)) % 4) * 4 + (16 if int(p.get("MAU", 0)) else 0) +
            (32 if int(p.get("BFN", 0)) else 0) + (64 if int(p.get("MAT", 0)) else 0) +
            (128 if int(p.get("REPLICA", 0)) else 0))


def load_set(path: Path = SET_JSON, rule: str | None = None) -> list[Member]:
    """The members of the set; with rule, those of that rule (zero / replica) and the rule-free ones."""
    js = json.loads(Path(path).read_text(encoding="utf-8"))
    out = []
    for m in js["members"]:
        p = {k: int(v) for k, v in m["params"].items()}
        units = p.get("UNITS", 2)
        mrule = ("replica" if p.get("REPLICA", 0) else "zero") if units else "any"
        fs = Path(path).parent / "build" / m["name"] / "top_multi.fs"
        if m.get("fs"):
            fs = (Path(path).parent / m["fs"]).resolve()
        out.append(Member(name=m["name"], params=p, caps=member_caps(p), rule=mrule,
                          fs=fs, design_id=int(str(js.get("design_id", "0x05")), 0), flags=member_flags(p),
                          desc=m.get("desc", "")))
    if rule:
        out = [m for m in out if m.rule in (rule, "any")]
    return out


# ----------------------------------------------------------------------------------------- words
@dataclass
class Word:
    kind: str                   # "j" or "m"
    needs: frozenset = frozenset()
    reads: frozenset = frozenset()
    writes: frozenset = frozenset()
    lbi_if_lbf: bool = False    # reads $lbi when the $lbf it updates is live after the word
    tag_issue: int = 0          # valid m word: its tag (mvid, 0 = none)
    tag_wait: int = 0           # wd of a j word
    stop: bool = False          # ll = 10 (E_DECODE on every member)
    mwrite: bool = False
    text: str = ""


def alu_class(f: dict) -> str:
    """mn_alu_cls: int / fp / xpe / none / bad."""
    dmode, aluop = f["pe_aluc_dmode"], f["pe_aluc_aluop"]
    if aluop == 0b11111:
        return "int"                                    # imm
    if (f["pe_aluc_rounda"] or f["pe_aluc_roundb"]) and dmode != 0b10:
        return "bad"
    if aluop in (0b10001, 0b10010):
        return "xpe"                                    # msl / msr
    if aluop == 0b11101 and f["pe_aluc_is_unsigned"] and f["pe_aluc_isela"] == 0b0101:
        return "int"                                    # zero
    if dmode == 0b11:
        return "none" if aluop == 0 else "fp" if aluop == 0b11110 else "bad"
    if (aluop >> 4) == 0 or aluop == 0b10011:
        return "int"
    return "fp"


def _code3(s: int) -> int:
    return {5: 11, 6: 12, 7: 13}.get(s, s)


def analyze_word(kind: str, bits: int, matrix_prog: bool = False) -> Word:
    """Needs and hidden state of one instruction memory entry (kind j / m, the 426- / 82-bit word)."""
    if kind == "m":
        f = codec.decode(bits & ((1 << 82) - 1), "m")
        if not f["valid"]:
            return Word("m", text="mvnop")
        return Word("m", needs=frozenset({"MV"}), tag_issue=f["mvid"], text=f"m tag {f['mvid']}")
    f = codec.decode(bits & J_MASK, "j")
    needs, reads, writes = set(), set(), set()
    w = Word("j", tag_wait=f["wd"])
    if f["wd"]:
        needs.add("MV")
    ll = f["ll"]
    if ll == 0b10:
        w.stop = True
        w.needs = frozenset(needs)
        return w
    if not (ll & 1):
        w.needs = frozenset(needs)
        return w
    fwd = ll == 0b01
    cls = alu_class(f)
    aluop, iselb = f["pe_aluc_aluop"], f["pe_aluc_iselb"]
    is_imm = aluop == 0b11111
    cls_bf = aluop == 0b11101 or (aluop == 0b11110 and (iselb >> 1) != 0b11)
    if cls == "fp" and not cls_bf:
        needs.add("FP1" if aluop == 0b11110 else "FP2" if aluop in (0b11011, 0b11100) else "FP3")
    if cls == "fp" and cls_bf:
        needs.add("BFN")
    enfma, mmode, mw, mdmode = f["pe_mauc_enfma"], f["pe_mauc_mmode"], f["pe_mauc_mw"], f["pe_mauc_dmode"]
    if enfma and not mmode:
        needs.add("MAU")
    if enfma and mmode:
        needs.add("MAT" if mdmode != 0 else "NONE")    # d matrix MAU: E_UNSUPPORTED everywhere
        reads.add("matrix")
    if mw:
        needs.add("MAT")
        writes.add("matrix")
        w.mwrite = True
    l1any = (f["l1bm_bmode"] != 0 or f["l1bm_lwrite"] or f["l1bm_rmode"] or f["l1bm_me"] or f["l1bm_ladr"] != 0
             or f["l1bm_dmode"] or f["l1bm_ext"] or f["l1bm_round_out"] or f["l1bm_mabadr"] != 0
             or f["l1bm_opcode"] != 0 or f["l1bm_isel"] != 7 or f["l1bm_wl"])
    dsts = []
    for wr, isel in (("pe_trc_write", "pe_trc_isel"), ("pe_rfc0_write", "pe_rfc0_isel"),
                     ("pe_rfc1_write", "pe_rfc1_isel"), ("pe_lm0_write", "pe_lm0_isel"),
                     ("pe_lm1_write", "pe_lm1_isel")):
        if f[wr] and not (wr == "pe_lm0_write" and is_imm):
            dsts.append(f[isel])
    l1_dst = 0b10 in dsts
    if l1any or l1_dst:
        needs.add("L1")
    if f["l1bm_rmode"]:
        needs.add("L1R")
    if f["l1bm_gwrite"] or f["l2bm_lwrite"]:
        needs.add("L2")
    if f["l2bm_darsend"] or f["l2bm_darwrite"]:
        needs.add("NONE")                               # L2_DAR = 0 in every member: E_UNSUPPORTED
    if 0b11 in dsts:
        reads.add("matrix")                             # the transposed read of the matrix register
    # operands (mn_pe_core rd_use / gather): the forwarding registers they read
    src = []
    alu_rd = cls != "none" and not is_imm and not (aluop == 0b11101 and f["pe_aluc_is_unsigned"]
                                                   and f["pe_aluc_isela"] == 0b0101)
    if alu_rd:
        src.append(f["pe_aluc_isela"])
        if aluop in TWO_IN:
            src.append(_code3(iselb))
    if enfma:
        src.append(_code3(f["pe_mauc_isela"]))
    if (enfma and not f["pe_mauc_passa"]) or mw:
        src.append(_code3(f["pe_mauc_iselb"]))
    if enfma and not f["pe_mauc_zeroc"]:
        src.append(_code3(f["pe_mauc_iselc"]))
    if f["l1bm_lwrite"]:
        src.append(_code3(f["l1bm_isel"]))              # isel 111: $lbf (WP37)
    for s in src:
        if s == 11:
            reads.add("mauf")
            needs.add("MAUF")
        elif s == 12:
            reads.add("aluf")
        elif s == 13:
            reads.add("lbf")
            needs.add("L1")
        elif s == 14:
            reads.add("matrix")                         # $mreadf: the matrix register's read
    if matrix_prog and "matrix" in reads:
        needs.add("MAT")
    # forwarding registers written (not by noforward words)
    if fwd and cls in ("int", "fp", "xpe"):
        writes.add("aluf")
    if fwd and enfma and (not mmode or mdmode != 0):
        writes.add("mauf")
    if fwd and l1any:
        writes.add("lbf")
    # $lbi (mn_l1bm): lwrite = 1 words take their L1BM -> PE value from it and (not noforward) write
    # it: plane 0 always, plane 1 with wl = 1 (not l1bmd); the layout of the last writer (lbim)
    if f["l1bm_lwrite"]:
        if fwd:
            writes |= {"lbi0", "lbim"}
            if f["l1bm_wl"] and f["l1bm_bmode"] != 0b11:
                writes.add("lbi1")
        if l1_dst:
            reads |= {"lbi0", "lbi1", "lbim"}
        elif fwd and l1any:
            w.lbi_if_lbf = True
    w.needs, w.reads, w.writes = frozenset(needs), frozenset(reads), frozenset(writes)
    return w


def analyze_entries(entries) -> list[Word]:
    """IMEM entries (448-bit, mnhost.imem_entry) -> Word list."""
    kinds = [("j" if (e >> 446) == mnhost.IMEM_TYPE_J else "m", e & J_MASK) for e in entries]
    matrix_prog = any(k == "j" and codec.decode(b, "j")["pe_mauc_mw"] for k, b in kinds)
    return [analyze_word(k, b, matrix_prog) for k, b in kinds]


def liveness(words: list[Word]) -> list[frozenset]:
    """live[b]: the hidden state live at boundary b (before word b), b = 0 .. len(words), that some word
    before b wrote. State that no word wrote yet still has its value after RESET, which is also its
    value after a configuration (0; reading a forwarding register before its unit ran is an error of
    the emulator, so valid programs do not), so it does not have to be carried over."""
    n = len(words)
    live = [frozenset()] * (n + 1)
    cur: set = set()
    for i in range(n - 1, -1, -1):
        w = words[i]
        rd = set(w.reads)
        if w.lbi_if_lbf and "lbf" in cur:
            rd |= {"lbi0", "lbi1", "lbim"}
        kills = {x for x in w.writes if x != "matrix"}
        cur = (cur - kills) | rd
        live[i] = frozenset(cur)
    written: set = set()
    for i in range(n + 1):
        live[i] = live[i] & frozenset(written)
        if i < n:
            written |= words[i].writes
    return live


# ----------------------------------------------------------------------------------------- plan
@dataclass
class Segment:
    a: int                      # first word
    b: int                      # end (exclusive)
    member: Member
    note: str = ""              # why the board will stop in this segment (no member runs it whole)


@dataclass
class Plan:
    segments: list = field(default_factory=list)
    clean: list = field(default_factory=list)       # the clean boundaries
    complete: bool = True                           # every word runs on some segment's member
    problem: str = ""                               # why not


def plan(words: list[Word], members: list[Member], first: Member | None = None) -> Plan:
    """Fewest segments between clean boundaries, each run whole by one member (see the module doc)."""
    n = len(words)
    live = liveness(words)
    clean = [b for b in range(1, n + 1) if not live[b]]
    res = Plan(clean=clean)
    a = 0
    cur = first
    while a < n:
        cand = set(range(len(members)))
        k = a
        best = None
        for b in clean:
            if b <= a:
                continue
            while k < b:
                cand = {i for i in cand if members[i].supports(words[k].needs)}
                k += 1
            if not cand:
                break
            best = (b, set(cand))
        if best is None:
            # no member runs the part up to the next clean boundary: the member that runs the longest
            # prefix gets the rest of the program and stops where it cannot go on
            def reach(m):
                k2 = a
                while k2 < n and m.supports(words[k2].needs):
                    k2 += 1
                return k2
            pick = max(members, key=lambda m: (reach(m), m is cur))
            k2 = reach(pick)
            if k2 < n:
                miss = pick.missing(words[k2].needs)
                why = (f"word {k2} needs {'+'.join(sorted(words[k2].needs))}: no member has "
                       f"{'+'.join(miss) if miss else 'it'}")
                nxt = [b for b in clean if b > a]
                if not miss or k2 < (nxt[0] if nxt else n):
                    live_here = sorted(set().union(*(live[j] for j in range(a + 1, k2 + 1))))
                    if live_here and all(any(m.supports(words[j].needs) for m in members) for j in range(a, k2 + 1)):
                        why = (f"word {k2} needs {'+'.join(sorted(words[k2].needs))} but hidden state "
                               f"({', '.join(live_here)}) is live across every switch point before it")
            else:
                why = "no clean switch point"
            if res.segments and res.segments[-1].member is pick:
                res.segments[-1].b = n                       # the same member goes on
                res.segments[-1].note = why
            else:
                res.segments.append(Segment(a, n, pick, why))
            res.complete = False
            res.problem = why
            return res
        b, cset = best
        ms = [members[i] for i in sorted(cset)]
        pick = cur if cur in ms else ms[0]
        res.segments.append(Segment(a, b, pick))
        cur = pick
        a = b
    return res


def describe(words: list[Word], p: Plan) -> list[str]:
    out = []
    for s in p.segments:
        nd = sorted(set().union(*(words[k].needs for k in range(s.a, s.b))))
        out.append(f"words {s.a}..{s.b - 1} on {s.member.name} (needs {'+'.join(nd) or '-'})" +
                   (f"  STOP: {s.note}" if s.note else ""))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("asm")
    ap.add_argument("--set", default=str(SET_JSON))
    ap.add_argument("--rule", choices=["zero", "replica"], default="zero")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    prog = mnhost.parse_asm(Path(a.asm).read_text(encoding="utf-8"))
    words = analyze_entries(prog.entries)
    members = load_set(Path(a.set), a.rule)
    p = plan(words, members)
    if a.verbose:
        live = liveness(words)
        for i, w in enumerate(words):
            print(f"{i:4d} {w.kind} needs {'+'.join(sorted(w.needs)) or '-':20s} reads {sorted(w.reads)} "
                  f"writes {sorted(w.writes)} live-after {sorted(live[i + 1])}")
    for line in describe(words, p):
        print(line)
    print(f"{len(p.segments)} segments, {len(p.segments) - 1} switches"
          + ("" if p.complete else f"; incomplete: {p.problem}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())

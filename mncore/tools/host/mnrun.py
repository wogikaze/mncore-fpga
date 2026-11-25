#!/usr/bin/env python3
"""mnrun: run a whole program on the board across the bitstreams of the set (WP38).

  python mncore/tools/host/mnrun.py [opts] run X.asm [-o X.ndmp]                     # one program
  python mncore/tools/host/mnrun.py [opts] regress [--all | --list FILE | PROGRAM ...] [-o results.tsv]
  python mncore/tools/host/mnrun.py [opts] plan X.asm                                # = mnplan.py
  python mncore/tools/host/mnrun.py [opts] load M2a                                  # load a member
  python mncore/tools/host/mnrun.py [opts] sdram-hold [--seconds 10] [--via MAUF3]   # DRAM retention test
opts (before the command): --set mncore/fpga/multi/set.json, --rule zero|replica (the members of that
rule and the rule-free ones), --port COMx|auto, --baud 2000000, --log FILE, --no-lock-check, -v.

No bitstream holds every unit (WP37: with the MAU the M2 design is LUT_eq 96 % of the GW2AR-18), so
the program is cut into segments, each run by one member of the set (mncore/fpga/multi/set.json:
mn_top_multi with some of the units; mnplan.py decides where to cut, at boundaries where no state that
the host cannot read is live). For every segment:

  1. the member is loaded into the FPGA SRAM (openFPGALoader -b tangnano20k <fs>; never the Flash) unless
     it is loaded already; the host reconnects at 1 Mbaud and switches to --baud;
  2. the state of the program is written into it: the 4 PEs (GRF0, GRF1, LM0, LM1, T, OMR 1..15, BAR;
     only the long words that are not 0: the configuration cleared them), the L1BM and the L2BM when
     the member has them (from the host's copy), and the MV tag counts (m words with mmode 111 that do
     nothing but count their tag);
  3. the words of the segment run (RUN split at the d / r lines, d set -> WR_MEM, d get -> RD_MEM, as
     mnhost.execute_program; the L1BM / L2BM of a member without them is the host's copy);
  4. at the end of the segment the host reads the state the next member needs (the 4 PEs; the L1BM /
     L2BM when they may have changed and this member has them).
The DRAM and PDM are in the SDRAM: mn_top_multi clears them on RESET only, not on a configuration. The
SDRAM is not refreshed while the FPGA is configured, though, and a few bits of the DRAM decay in that
time (WP38 report: 3 bits of 12.6 Mbit after one reload), so the host keeps its PDM / DRAM lines (d set,
r, d get) in order until a segment that has MV words, or the end of the program, and runs them on a
member with the SDRAM just before; when the PDM / DRAM hold nothing but the zeros of the clear, that
member is RESET first (before the state is written back) so that they are 0 again. The DRAM then has to
outlive a switch only when an MV word or a write put data into it before the switch (no program of the
M2 regression does so before a later segment that runs).
The first segment starts with RESET (the PEs, L1BM, L2BM, MV tags, DRAM and PDM are 0, like the official
emulator). A stop (E_RANGE, E_UNSUPPORTED, E_DECODE) ends the program; WAIT ends the RUNs (the d gets
still read), like mnhost.py run. When no member can run some word (or the hidden state is live across
every switch point before it), the member that gets furthest runs the rest and the board stops at that
word with E_UNSUPPORTED.

`regress` runs the programs of `run.py --m2` (WP37; the official / reduced-Rust runs of
mncore/sim/regress/build/m2/<name>/ must exist) and classifies them like fpga/top_m2/hwrun.py: pass b,
pass c, E_RANGE as rust, E_UNSUPPORTED ..., mismatch; "as rtl" compares with the RTL simulation of the
core with every unit (mncore/sim/regress/results_m2.tsv). Take the board lock first (contract 06
section 9): C:\\wgkz\\nano20k\\mncore\\.board.lock.
"""
from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
import mnhost  # noqa: E402
import mnplan  # noqa: E402
from mnisa import codec  # noqa: E402

LOCK = Path(r"C:\wgkz\nano20k\mncore\.board.lock")
PE_LOCS = [mnhost.loc_code(p=p) for p in range(4)]
# the PE state the host carries over (space, first long word / entry, count)
PE_STATE = [("GRF0", 0, 256), ("GRF1", 0, 256), ("LM0", 0, 256), ("LM1", 0, 256), ("T", 0, 8),
            ("OMR", 1, 15), ("BAR", 0, 2)]
UNIT_DEPTH = {"L1BM": 1024, "L2BM": 2048}
UNIT_CAP = {"L1BM": "L1", "L2BM": "L2"}
WINDOW = 4096                                   # pipelined reads / writes (mnhost._pipeline)


def nop_m_word(tag: int) -> int:
    """An m word that does nothing but count its tag (mmode 111, WP33 / WP37)."""
    bits = codec.encode({"valid": 1, "mmode": 0b111, "mvid": tag}, "m")
    return mnhost.imem_entry("m", int(bits, 2))


def nz_runs(vals: list[int], base: int = 0):
    """(first address, values) of the runs of long words that are not 0."""
    run_a, run = None, []
    for i, v in enumerate(vals):
        if v:
            if run_a is None:
                run_a = base + i
            run.append(v)
        elif run:
            yield run_a, run
            run_a, run = None, []
    if run:
        yield run_a, run


@dataclass
class Stats:
    switches: int = 0
    loads: int = 0                  # bitstream loads (also the first one of a program)
    t_load: float = 0.0             # openFPGALoader + reconnect + baud
    t_save: float = 0.0             # state read at the end of a segment
    t_restore: float = 0.0          # state written at the start of a segment
    t_run: float = 0.0              # the program's own RUNs, d / r lines
    segments: list = field(default_factory=list)   # (a, b, member name)

    def as_dict(self):
        return {"switches": self.switches, "loads": self.loads, "t_load": round(self.t_load, 2),
                "t_save": round(self.t_save, 2), "t_restore": round(self.t_restore, 2),
                "t_run": round(self.t_run, 2)}


class Board:
    """The board with one member of the set loaded at a time."""

    def __init__(self, members: list[mnplan.Member], port: str = "auto", baud: int = 2000000, log=print,
                 verbose: bool = False):
        self.members = members
        self.port = port
        self.baud = baud
        self.log = log
        self.verbose = verbose
        self.dev: mnhost.Device | None = None
        self.cur: mnplan.Member | None = None

    # -- connection
    def connect(self) -> mnhost.Device:
        link = mnhost.Link.open(self.port, 1000000, timeout=0.2)
        dev = mnhost.Device(link)
        try:
            link.flush_input(0.05)
            try:
                inf = dev.info()
            except (mnhost.ProtocolError, mnhost.DeviceError):
                link.flush_input(0.3)
                inf = dev.info(refresh=True)
            self.cur = self.identify(inf)
            if self.baud and self.baud != 1000000:
                dev.set_baud(self.baud)
        except Exception:
            try:
                link.ser.close()
            except Exception:
                pass
            raise
        self.dev = dev
        return dev

    def identify(self, inf: mnhost.Info):
        """The member that is loaded, from INFO (design ID, flags, the L1BM / L2BM / DRAM depths)."""
        for m in self.members:
            if (inf.design_id == m.design_id and inf.flags == m.flags and
                    bool(inf.space_depth.get(mnhost.SPACES["L1BM"])) == ("L1" in m.caps) and
                    bool(inf.space_depth.get(mnhost.SPACES["L2BM"])) == ("L2" in m.caps) and
                    bool(inf.space_depth.get(mnhost.SPACES["DRAM"])) == ("SDRAM" in m.caps)):
                return m
        return None

    def close(self):
        if self.dev is not None:
            try:
                if self.dev.link.baudrate != 1000000:
                    self.dev.set_baud(1000000)
            except (mnhost.ProtocolError, mnhost.DeviceError):
                pass
            try:
                self.dev.link.ser.close()
            except Exception:
                pass
        self.dev = None

    def load(self, m: mnplan.Member, st: Stats | None = None):
        if not m.fs.exists():
            raise SystemExit(f"bitstream of {m.name} not built: {m.fs} (mncore/fpga/multi/build.py --member {m.name})")
        t0 = time.monotonic()
        self.close()
        r = subprocess.run(["openFPGALoader", "-b", "tangnano20k", str(m.fs)], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(f"openFPGALoader {m.fs}: rc {r.returncode}\n{r.stdout[-800:]}{r.stderr[-800:]}")
        time.sleep(0.3)
        for attempt in range(4):
            try:
                self.connect()
                break
            except (mnhost.ProtocolError, mnhost.DeviceError):
                self.close()
                time.sleep(0.5)
        else:
            raise SystemExit(f"no answer from {m.name} after loading it")
        if self.cur is not m:
            raise SystemExit(f"loaded {m.name} but INFO says design 0x{self.dev.info().design_id:02x} "
                             f"flags 0x{self.dev.info().flags:02x}")
        dt = time.monotonic() - t0
        if st is not None:
            st.loads += 1
            st.t_load += dt
        if self.verbose:
            self.log(f"#   loaded {m.name} in {dt:.2f} s")

    def ensure(self):
        if self.dev is None:
            try:
                self.connect()
            except (mnhost.ProtocolError, mnhost.DeviceError):
                self.close()
                self.cur = None


# ----------------------------------------------------------------------------------------- one program
class ProgramRun:
    """One program across the members (see the module doc)."""

    def __init__(self, board: Board, prog: mnhost.AsmProgram, log=print, verbose: bool = False):
        self.b = board
        self.prog = prog
        self.log = log
        self.verbose = verbose
        self.words = mnplan.analyze_entries(prog.entries)
        self.res = mnhost.RunResult(stats={"runs": 0, "steps": 0, "windows": 0, "dropped": 0, "gets": 0,
                                           "sets": 0, "skipped_d": 0, "rlines": len(prog.rlines),
                                           "read_words": 0})
        self.st = Stats()
        self.blocked = False
        self.pe: dict = {}                     # (space, loc) -> long words (between segments)
        self.shadow: dict = {}                 # "L1BM" / "L2BM" -> host copy while the member lacks it
        self.dirty = {"L1BM": False, "L2BM": False}   # may be non-zero on the device
        self.tags: dict = {}                   # MV tag -> completed, not yet waited for (0..2)
        self.plan = None
        self.win = None
        # the PDM / DRAM (see the module doc): their d set / r / d get lines wait here, in order, until a
        # segment with MV words or the end (nothing else reaches the PDM / DRAM, so the order is kept)
        self.dq: list = []
        self.dram_fresh = False      # the loaded member's RESET cleared them (no configuration since)
        self.dram_dirty = False      # they may hold something else than the zeros of the clear
        self.dram_now = False        # this segment runs its PDM / DRAM lines at once (it has MV words)

    # -- helpers
    @property
    def dev(self) -> mnhost.Device:
        return self.b.dev

    @property
    def member(self) -> mnplan.Member:
        return self.b.cur

    def has(self, space: str) -> bool:
        if space in UNIT_CAP:
            return UNIT_CAP[space] in self.member.caps
        if space in ("PDM", "DRAM"):
            return "SDRAM" in self.member.caps
        return True

    def shadow_of(self, space: str) -> list:
        if space not in self.shadow:
            self.shadow[space] = [0] * UNIT_DEPTH[space]
        return self.shadow[space]

    # -- state hand-over
    def save(self, nxt: mnplan.Member | None):
        """At the end of a segment: read what the next member needs."""
        t0 = time.monotonic()
        dev = self.dev
        for loc in PE_LOCS:
            for sp, a0, n in PE_STATE:
                self.pe[(sp, loc)] = dev.read(mnhost.SPACES[sp], loc, a0, n, window=WINDOW)
        for sp in ("L1BM", "L2BM"):
            if self.has(sp) and self.dirty[sp]:
                self.shadow[sp] = dev.read(mnhost.SPACES[sp], self.unit_loc(sp), 0, UNIT_DEPTH[sp], window=WINDOW)
        self.st.t_save += time.monotonic() - t0

    def restore(self):
        """At the start of a segment on a freshly loaded member (its state is 0)."""
        t0 = time.monotonic()
        dev = self.dev
        for (sp, loc), vals in self.pe.items():
            base = 1 if sp == "OMR" else 0
            for a, run in nz_runs(vals, base):
                dev.write(mnhost.SPACES[sp], loc, a, run, window=WINDOW)
        for sp in ("L1BM", "L2BM"):
            if self.has(sp) and sp in self.shadow:
                for a, run in nz_runs(self.shadow.pop(sp)):
                    dev.write(mnhost.SPACES[sp], self.unit_loc(sp), a, run, window=WINDOW)
                self.dirty[sp] = True
        if "MV" in self.member.caps:
            ents = [nop_m_word(t) for t, k in sorted(self.tags.items()) for _ in range(k)]
            if ents:
                dev.write_imem(0, ents)
                dev.run(0, len(ents))
                s = dev.wait_idle(10.0)
                if s.reason != 0:
                    raise SystemExit(f"restoring the MV tags failed: {s.reason_name} info {s.info}")
                if self.verbose:
                    self.log(f"#   restored MV tags {self.tags}")
        self.st.t_restore += time.monotonic() - t0

    @staticmethod
    def unit_loc(space: str) -> int:
        return 0                                     # L1BM n0c0b0, L2BM n0c0

    # -- the tag counts of the words that ran
    def account(self, a: int, b: int):
        for w in self.words[a:b]:
            if w.kind == "m" and "MV" in w.needs:
                self.dram_dirty = True                   # an MV may have written the PDM / DRAM
            if w.kind == "m" and w.tag_issue:
                self.tags[w.tag_issue] = min(self.tags.get(w.tag_issue, 0) + 1, 2)
            if w.kind == "j" and w.tag_wait and not w.stop:
                self.tags[w.tag_wait] = 0
            if "L1" in w.needs or "L2" in w.needs:
                self.dirty["L1BM"] = True
            if "L2" in w.needs or "MV" in w.needs:
                self.dirty["L2BM"] = True

    # -- RUN of entries [a, b) of the program on the member
    def run_range(self, a: int, b: int) -> bool:
        dev = self.dev
        depth = dev.info().imem_depth
        while a < b and not self.blocked:
            if self.win is None or not (self.win <= a < self.win + depth):
                dev.write_imem(0, self.prog.entries[a:a + depth])
                self.win = a
                self.res.stats["windows"] += 1
            n = min(b, self.win + depth) - a
            dev.run(a - self.win, n)
            s = dev.wait_idle(120.0)
            self.res.stats["runs"] += 1
            self.res.stats["steps"] += s.steps
            if s.reason == 4:
                self.res.stop, self.res.stop_entry = s, self.win + s.pc
                self.res.stats["wait_word"] = self.win + s.pc
                self.account(a, self.win + s.pc)
                self.blocked = True
                return True
            if s.reason != 0:
                self.res.stop, self.res.stop_entry = s, self.win + s.pc
                if s.reason == 1:
                    self.res.stats["e_range_word"] = self.win + s.info
                return False
            self.account(a, a + n)
            a += n
        return True

    # -- the PDM / DRAM (see the module doc)
    def dram_reclear(self) -> bool:
        """On a member with the SDRAM, before its state is written back: RESET when the PDM / DRAM should
        hold only the zeros of the clear but a configuration came since (bits may have decayed)."""
        if "SDRAM" in self.member.caps and not self.dram_fresh and not self.dram_dirty:
            self.dev.reset()
            self.dram_fresh = True
            return True
        return False

    def dram_flush(self):
        """Run the waiting PDM / DRAM lines on this member (it has the SDRAM)."""
        q, self.dq = self.dq, []
        now, self.dram_now = self.dram_now, True
        for d in q:
            self.event(d)
        self.dram_now = now

    # -- d / r lines
    def event(self, d: mnhost.DOp):
        topo = mnhost.Topology(self.dev.info().topo)
        smap = mnhost.SpaceMap(self.dev.info())
        space = d.space
        if space in ("PDM", "DRAM"):
            if self.blocked and d.op == "set":
                return
            if not (self.dram_now and self.has(space)):
                self.dq.append(d)
                return
            if d.op == "set":
                self.dram_dirty = True
        dep = UNIT_DEPTH[space] if space in UNIT_DEPTH else smap.depth(space)
        if space in UNIT_DEPTH:
            locs = [{"n": 0, "c": 0, "b": 0}] if space == "L1BM" else [{"n": 0, "c": 0}]
            locs = [f for f in locs if all(d.loc.get(k, f[k]) == f[k] for k in f)]
        else:
            locs = topo.locations(space, d.loc) if dep else []
        if not locs or (self.blocked and d.op == "set"):
            if not d.text.startswith("r "):
                self.res.stats["skipped_d"] += 1
            return
        on_dev = self.has(space)
        for f in locs:
            if d.op == "set":
                self.res.stats["sets"] += 1
                words = mnhost.long_words(d)
                keep = [w for w in words if w[0] < dep]
                self.res.stats["dropped"] += len(words) - len(keep)
                if space in UNIT_DEPTH:
                    self.dirty[space] = True
                for run in mnhost._runs(keep):
                    if on_dev:
                        sp, lc, a0 = smap.target(space, f, run[0][0]) if space not in UNIT_DEPTH else \
                            (mnhost.SPACES[space], 0, run[0][0])
                        self.dev.write(sp, lc, a0, [v for _, v, _ in run], mask=run[0][2])
                    else:
                        sh = self.shadow_of(space)
                        for a, v, m in run:
                            bm = sum(0xFF << (8 * i) for i in range(8) if (m >> i) & 1)
                            sh[a] = (sh[a] & ~bm) | (v & bm)
            else:
                self.res.stats["gets"] += 1
                units = mnhost.get_units(d)
                vals: dict = {}
                for run in mnhost._addr_runs(lw for _, _, lw, _ in units if lw is not None and lw < dep):
                    if on_dev:
                        sp, lc, a0 = smap.target(space, f, run[0]) if space not in UNIT_DEPTH else \
                            (mnhost.SPACES[space], 0, run[0])
                        got = self.dev.read(sp, lc, a0, len(run), window=WINDOW)
                    else:
                        sh = self.shadow_of(space)
                        got = [sh[a] for a in run]
                    self.res.stats["read_words"] += len(run)
                    vals.update(zip(run, got))
                lt = mnhost.loc_text(space, f)
                for sp2, addr, lw, how in units:
                    if lw is None:
                        self.res.records[(sp2, lt, addr)] = how
                    elif lw in vals:
                        self.res.records[(sp2, lt, addr)] = mnhost._unit_value(how, vals[lw])

    # -- the whole program
    def execute(self) -> mnhost.RunResult:
        b = self.b
        b.ensure()
        members = b.members
        first = b.cur if b.cur in members else None
        self.plan = p = mnplan.plan(self.words, members, first)
        if not p.segments:                                   # no words: the d lines only
            p.segments = [mnplan.Segment(0, 0, first or members[0])]
        self.st.segments = [(s.a, s.b, s.member.name) for s in p.segments]
        n = len(self.prog.entries)
        events = list(self.prog.events)
        ei = 0
        for k, seg in enumerate(p.segments):
            # a segment with MV words runs its PDM / DRAM lines at once (after the waiting ones)
            mv_seg = "SDRAM" in seg.member.caps and any("MV" in w.needs for w in self.words[seg.a:seg.b])
            if k == 0:
                if b.cur is not seg.member:
                    b.load(seg.member, self.st)
                t0 = time.monotonic()
                self.dev.reset()
                self.dram_fresh = "SDRAM" in seg.member.caps
                self.st.t_run += time.monotonic() - t0
            else:
                if self.blocked:
                    break
                self.save(seg.member)
                b.load(seg.member, self.st)
                self.dram_fresh = False
                self.st.switches += 1
                if mv_seg:
                    self.dram_reclear()              # before the state is written back
                self.restore()
            if mv_seg:
                self.dram_flush()
            self.dram_now = mv_seg
            if self.verbose:
                self.log(f"#   segment {k}: words {seg.a}..{seg.b - 1} on {seg.member.name}"
                         + (f" ({seg.note})" if seg.note else ""))
            self.win = None
            t0 = time.monotonic()
            pc = seg.a
            last = k == len(p.segments) - 1
            ok = True
            # the d / r lines of the segment; after a WAIT (blocked) every later one too (d gets read)
            while ei < len(events) and (events[ei][0] < seg.b or last or self.blocked):
                pos, d = events[ei]
                if pos > pc:
                    if not self.run_range(pc, min(pos, n)):
                        ok = False
                        break
                    pc = pos
                self.event(d)
                ei += 1
            if ok and pc < seg.b:
                ok = self.run_range(pc, seg.b)
            self.st.t_run += time.monotonic() - t0
            if not ok or self.blocked:
                break
        stopped = self.res.stop is not None and self.res.stop.reason != 4
        if not stopped and any(d.op == "get" for d in self.dq):
            # the waiting PDM / DRAM d gets: on this member if it has the SDRAM, else on one more member
            if "SDRAM" not in self.member.caps:
                nxt = next(m for m in members if "SDRAM" in m.caps)
                b.load(nxt, self.st)
                self.dram_fresh = False
                self.st.switches += 1
                self.st.segments.append((n, n, nxt.name + " (PDM / DRAM d get)"))
            self.dram_reclear()                      # the other d gets were read already
            self.dram_flush()
        self.res.stats.update(self.st.as_dict())
        self.res.stats["segments"] = self.st.segments
        return self.res


# ----------------------------------------------------------------------------------------- regression
def regress_main(a, board: Board, log) -> int:
    sys.path.insert(0, str(ROOT / "mncore" / "sim" / "regress"))
    import run as regress  # noqa: E402
    import ndmp  # noqa: E402
    regress.configure(4, m2=True)
    rows = corpus_rows()
    paths = list(a.programs)
    if a.list:
        for line in Path(a.list).read_text(encoding="utf-8").splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                paths.append(line)
    if a.all:
        paths += sorted(rows)
    if a.only:
        paths = [p for p in paths if a.only in p]
    if not paths:
        raise SystemExit("no programs (give paths, --list or --all)")
    rtl = {}
    rt = ROOT / "mncore" / "sim" / "regress" / ("results_m2_replica.tsv" if a.rule == "replica" else "results_m2.tsv")
    with open(rt, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            rtl[r["path"]] = r
    replica = a.rule == "replica"
    log(f"# mnrun regress {time.strftime('%Y-%m-%d %H:%M:%S')}: {len(paths)} programs, rule {a.rule}, members "
        + ", ".join(f"{m.name} ({'+'.join(sorted(m.caps))})" for m in board.members)
        + f", {board.baud} baud, rtl table {rt.name}")
    results = []
    t_all = time.monotonic()
    for i, path in enumerate(paths, 1):
        job = regress.BUILD / regress.prog_name(path)
        res = {"path": path, "groups": rows.get(path, {}).get("groups", ""), "words": "", "steps": 0,
               "compared": 0, "result": "", "cls": "", "detail": "", "seconds": 0.0, "switches": 0,
               "loads": 0, "segments": "", "t_load": 0, "t_save": 0, "t_restore": 0, "t_run": 0}
        if regress.gl.read_status(job) != "ok":
            res["result"] = res["cls"] = "official_fail"
            results.append(res)
            continue
        prog = mnhost.parse_asm((job / "official.asm").read_text(encoding="utf-8"))
        res["words"] = len(prog.entries)
        t0 = time.monotonic()
        try:
            pr = ProgramRun(board, prog, log, a.verbose)
            r = pr.execute()
            res["plan"] = "complete" if pr.plan.complete else pr.plan.problem
        except (mnhost.ProtocolError, mnhost.DeviceError) as e:
            res["result"] = res["cls"] = "error"
            res["detail"] = str(e)
            results.append(res)
            log(f"[{i}/{len(paths)}] error {path} {e}")
            board.close()
            continue
        res["seconds"] = round(time.monotonic() - t0, 2)
        res["steps"] = r.stats["steps"]
        for k in ("switches", "loads", "t_load", "t_save", "t_restore", "t_run"):
            res[k] = r.stats[k]
        res["segments"] = " ".join(f"{s_a}-{s_b - 1}:{nm}" for s_a, s_b, nm in r.stats["segments"])
        rst = (job / "rust.status").read_text().strip() if (job / "rust.status").exists() else "missing"
        if r.stop is not None and r.stop.reason != 4:
            s = r.stop
            entries = [("j" if (e >> 446) == mnhost.IMEM_TYPE_J else "m", e & ((1 << 426) - 1)) for e in prog.entries]
            idx = r.stop_entry if r.stop_entry is not None and r.stop_entry < len(entries) else None
            res["result"], what = regress.classify_stop(s.reason, s.info, entries[idx] if idx is not None else None)
            word = r.stats.get("e_range_word", idx)
            res["detail"] = (what + " " if what else "") + f"at word {word}"
            res["cls"] = "E_RANGE as rust" if (s.reason == 1 and rst == f"range {word}" and not replica) else res["result"]
        else:
            if r.stop is not None:
                res["detail"] = f"WAIT at word {r.stats.get('wait_word')}; "
            hw = ndmp.canonical((s_, l_, a_, v_) for (s_, l_, a_), v_ in r.records.items())
            off, _ = ndmp.read(str(job / "official.ndmp"))
            A = {k: v for k, v in off.items() if regress.keep_record(k)}
            B = {k: v for k, v in hw.items() if regress.keep_record(k)}
            (job / f"mnrun{'_rep' if replica else ''}.ndmp").write_text(
                ndmp.dumps(hw, {"producer": "board mnrun (" + res["segments"] + ")", "src": path}), encoding="utf-8")
            mism, oa, ob = regress.diff(A, B)
            res["compared"] = len(A.keys() & B.keys())
            if mism or oa or ob:
                res["result"] = "mismatch(" + ",".join(sorted({k[0] for k in mism + oa + ob})) + ")"
                res["detail"] += f"{len(mism)} differ, {len(oa)} only official, {len(ob)} only board"
            else:
                res["result"] = "pass"
            if replica:
                res["cls"] = res["result"]
            else:
                tmp: dict = {}
                regress.m2_compare(tmp, job, A, B, "_mnrun")
                res["cls"] = tmp.get("cls", res["result"])
                res["detail"] += f" rust {tmp.get('rust')} off_rust {tmp.get('off_rust')} vs_rust {tmp.get('vs_rust')}"
        e = rtl.get(path)
        if e is None:
            res["vs_rtl"] = "no rtl result"
        else:
            ecls = e.get("cls", e["result"]) if not replica else e["result"]
            same = res["cls"] == ecls and (res["cls"].startswith("pass") or
                                           res["detail"].split(" at word")[-1][:12] == e["detail"].split(" at word")[-1][:12])
            res["vs_rtl"] = "as rtl" if same else f"rtl: {ecls} {e['detail']}".strip()
            # what the plan expects: the RTL with every unit, or E_UNSUPPORTED at the word no member runs
            # (when the RTL does not stop before it)
            m_r = re.search(r"at word (\d+)", e["detail"])
            rstop = int(m_r.group(1)) if (e["result"].startswith("E_") and m_r) else None
            m_p = re.search(r"word (\d+)", res.get("plan", "")) if res.get("plan") != "complete" else None
            pstop = int(m_p.group(1)) if m_p else None
            if pstop is not None and (rstop is None or pstop < rstop):
                res["expect"] = f"E_UNSUPPORTED at word {pstop}"
                ok = res["cls"].startswith("E_UNSUPPORTED") and res["detail"].endswith(f"at word {pstop}")
            else:
                res["expect"] = ecls
                ok = same
            res["as_expect"] = "yes" if ok else "NO"
        results.append(res)
        log(f"[{i}/{len(paths)}] {res['cls']:<26} expected:{res.get('as_expect', '-'):<3} {res['vs_rtl']:<8} "
            f"{res['words']!s:>4} words {res['steps']:>5} steps "
            f"{res['compared']:>5} lw sw {res['switches']} {res['seconds']:>6.2f} s  {path} [{res['segments']}] {res['detail']}")
    st = board.dev.status() if board.dev else None
    total = time.monotonic() - t_all
    if st:
        log(f"# {len(paths)} programs in {total:.0f} s; link: crc_err {st.crc_err} frame_err {st.frame_err} "
            f"overrun {st.overrun} timeout {st.timeout}, host retries {board.dev.link.stats['retries']}")
    npass = sum(1 for r in results if r["cls"].startswith("pass"))
    nas = sum(1 for r in results if r.get("vs_rtl") == "as rtl")
    nexp = sum(1 for r in results if r.get("as_expect") == "yes")
    nsw = sum(r["switches"] for r in results)
    nld = sum(r["loads"] for r in results)
    log(f"# pass {npass}/{len(results)}; as the RTL with every unit {nas}/{len(results)}; as the plan expects "
        f"{nexp}/{len(results)}; switches {nsw} "
        f"(in {sum(1 for r in results if r['switches'])} programs), bitstream loads {nld}, "
        f"load time {sum(r['t_load'] for r in results):.0f} s, save {sum(r['t_save'] for r in results):.0f} s, "
        f"restore {sum(r['t_restore'] for r in results):.0f} s")
    if a.output:
        cols = ["path", "groups", "words", "steps", "compared", "result", "cls", "vs_rtl", "expect", "as_expect",
                "switches", "loads", "segments", "seconds", "t_load", "t_save", "t_restore", "t_run", "plan", "detail"]
        with open(a.output, "w", encoding="utf-8", newline="\n") as f:
            f.write("\t".join(cols) + "\n")
            for r in results:
                f.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")
    return 0


def corpus_rows() -> dict:
    """The programs of run.py --m2 (WP37): left out of pe1 for the l1bm / l2bm / mv groups only."""
    rows = {}
    lm_only = {"lm_dyn", "lm_max>=256"}
    with open(ROOT / "mncore" / "tools" / "golden" / "corpus.tsv", encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            reasons = set(filter(None, r.get("pe1_reason", "").split(";")))
            groups, rest = set(), set()
            for x in reasons:
                if x.startswith("groups:"):
                    groups |= set(x.split(":", 1)[1].split("+"))
                else:
                    rest.add(x)
            if (r.get("official") == "ok" and groups and groups <= {"l1bm", "l2bm", "mv"} and rest <= lm_only
                    and groups & {"l1bm", "l2bm", "mv"}):
                rows[r["path"]] = r
    return rows


# ----------------------------------------------------------------------------------------- SDRAM test
def sdram_hold(a, board: Board, log) -> int:
    """Does the DRAM / PDM survive loading another member (no refresh during the configuration)?
    Writes a pseudo-random pattern into DRAM and PDM ranges, loads --via (or the same member), waits
    --seconds, loads the first member back and compares."""
    import random
    rng = random.Random(a.seed)
    m0 = next(m for m in board.members if m.name == a.member) if a.member else board.members[0]
    via = next(m for m in board.members if m.name == a.via) if a.via else m0
    if board.cur is not m0:
        board.load(m0)
    dev = board.dev
    dev.reset()
    ranges = [("DRAM", 0, a.words), ("DRAM", (1 << 19) - a.words, a.words), ("PDM", 0, a.words)]
    pats = {}
    t0 = time.monotonic()
    for sp, base, n in ranges:
        pats[(sp, base)] = [rng.getrandbits(64) for _ in range(n)]
        dev.write(mnhost.SPACES[sp], 0, base, pats[(sp, base)], window=WINDOW)
    log(f"# wrote {sum(n for _, _, n in ranges)} long words in {time.monotonic() - t0:.1f} s on {m0.name}")
    t1 = time.monotonic()
    board.load(via)
    time.sleep(a.seconds)
    if via is not m0:
        board.load(m0)
    dt = time.monotonic() - t1
    bad = 0
    for sp, base, n in ranges:
        got = board.dev.read(mnhost.SPACES[sp], 0, base, n, window=WINDOW)
        e = sum(1 for x, y in zip(got, pats[(sp, base)]) if x != y)
        bits = sum(bin(x ^ y).count("1") for x, y in zip(got, pats[(sp, base)]))
        bad += e
        log(f"#   {sp} {base:#x} +{n}: {e} long words differ ({bits} bits)")
    log(f"# {'PASS' if not bad else 'FAIL'}: the DRAM / PDM kept their content across {m0.name} -> {via.name}"
        f"{' -> ' + m0.name if via is not m0 else ''} ({dt:.1f} s without the first member, {a.seconds} s waited)")
    board.dev.reset()
    board.dev.read(mnhost.SPACES["DRAM"], 0, 0, 4)
    z = board.dev.read(mnhost.SPACES["DRAM"], 0, 0, 64)
    log(f"# after RESET: DRAM 0..63 {'all 0' if not any(z) else 'NOT cleared'}")
    return 1 if bad or any(z) else 0


# ----------------------------------------------------------------------------------------- CLI
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", default=str(mnplan.SET_JSON))
    ap.add_argument("--rule", choices=["zero", "replica"], default="zero")
    ap.add_argument("--port", default=os.environ.get("MNHOST_PORT", "auto"))
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--log")
    ap.add_argument("--no-lock-check", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("asm")
    p.add_argument("-o", "--output")
    p = sub.add_parser("regress")
    p.add_argument("programs", nargs="*")
    p.add_argument("--all", action="store_true")
    p.add_argument("--list")
    p.add_argument("--only")
    p.add_argument("-o", "--output")
    p = sub.add_parser("plan")
    p.add_argument("asm")
    p = sub.add_parser("load")
    p.add_argument("member")
    p = sub.add_parser("sdram-hold")
    p.add_argument("--member")
    p.add_argument("--via")
    p.add_argument("--seconds", type=float, default=5.0)
    p.add_argument("--words", type=int, default=4096)
    p.add_argument("--seed", type=int, default=1)
    a = ap.parse_args(argv)

    logf = open(a.log, "a", encoding="utf-8") if a.log else None

    def log(s=""):
        print(s, flush=True)
        if logf:
            logf.write(s + "\n")
            logf.flush()

    members = mnplan.load_set(Path(a.set), a.rule)
    if a.cmd == "plan":
        return mnplan.main([a.asm, "--set", a.set, "--rule", a.rule] + (["-v"] if a.verbose else []))
    if not a.no_lock_check and not LOCK.exists():
        raise SystemExit(f"take the board lock first: {LOCK} (WP number, start time)")
    if shutil.which("openFPGALoader") is None:
        oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
        os.environ["PATH"] = os.pathsep.join([str(oss / "bin"), str(oss / "lib"), os.environ.get("PATH", "")])
    board = Board(members, a.port, a.baud, log, a.verbose)
    try:
        if a.cmd == "load":
            m = next((m for m in mnplan.load_set(Path(a.set)) if m.name == a.member), None)
            if m is None:
                raise SystemExit(f"no member {a.member}")
            board.members = [m]
            board.load(m)
            inf = board.dev.info()
            log(f"loaded {m.name}: design 0x{inf.design_id:02x} flags 0x{inf.flags:02x}")
            return 0
        if a.cmd == "sdram-hold":
            board.members = mnplan.load_set(Path(a.set))
            return sdram_hold(a, board, log)
        if a.cmd == "regress":
            return regress_main(a, board, log)
        prog = mnhost.parse_asm(Path(a.asm).read_text(encoding="utf-8"))
        t0 = time.monotonic()
        pr = ProgramRun(board, prog, log, a.verbose)
        r = pr.execute()
        lines = r.lines()
        out = "# ndmp v1\n# producer: mnrun (" + " ".join(f"{x}-{y - 1}:{nm}" for x, y, nm in r.stats["segments"]) + \
              f")\n# src: {a.asm}\n" + "".join(l + "\n" for l in lines)
        if a.output:
            Path(a.output).write_text(out, encoding="utf-8", newline="\n")
        else:
            sys.stdout.write(out)
        s = r.stats
        log(f"# {len(prog.entries)} entries, {len(pr.plan.segments)} segments "
            f"({', '.join(f'{x}..{y - 1} {nm}' for x, y, nm in s['segments'])}), {s['switches']} switches, "
            f"{s['loads']} loads, {s['runs']} RUNs, {s['steps']} steps, {len(lines)} ndmp lines, "
            f"{time.monotonic() - t0:.1f} s (load {s['t_load']} s, save {s['t_save']} s, restore {s['t_restore']} s)")
        if not pr.plan.complete:
            log(f"# the plan is incomplete: {pr.plan.problem}")
        if r.stop is not None and r.stop.reason == 4:
            log(f"# WAIT at entry {r.stop_entry} (tag {r.stop.info})")
        elif r.stop is not None:
            extra = f" (word {s.get('e_range_word')})" if r.stop.reason == 1 else f" info {r.stop.info:#x}"
            log(f"# STOPPED: {r.stop.reason_name} at entry {r.stop_entry}{extra}")
            return 2
        return 0
    finally:
        board.close()


if __name__ == "__main__":
    sys.exit(main())

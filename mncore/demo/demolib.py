#!/usr/bin/env python3
"""Shared code of the demos (WP41): hello.py and fizzbuzz.py.

A demo runs one program of the MN-Core 2 challenge on the Tang Nano 20K and shows its output:

  1. the program: the official assembler (assemble3, WSL) assembles the solution and the official
     emulator (gpfn3_package_main) runs it with its testcase (mncore/tools/golden/goldenlib.py). Without
     the official tools the assembled solution committed in demo/programs/ is used, composed with the
     same testcase lines, and the official output recorded in demo/programs/ is the reference;
  2. the bitstreams that the program needs are built when they are missing: the members of the set
     (mncore/fpga/multi/build.py, set.json) or V64 (mncore/fpga/top_vpe/build.py), 15 to 120 minutes each;
  3. the board lock is taken (contract 06 section 9), and the program runs: across the members with
     mncore/tools/host/mnrun.py (it loads each member into the FPGA SRAM with openFPGALoader -b tangnano20k,
     never the Flash, hands the state over between them and reads the d get lines), or on one bitstream
     with mnhost.execute_program;
  4. the demo prints what the board computed, and whether it matches the official emulator.

Nothing here changes the RTL or the tools; it imports mnhost / mnplan / mnrun / goldenlib.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

DEMO = Path(__file__).resolve().parent
ROOT = DEMO.parents[1]
BUILD = DEMO / "build"                  # git-ignored (**/build/)
PROGRAMS = DEMO / "programs"
for _p in (ROOT / "mncore" / "tools" / "host", ROOT / "mncore" / "tools" / "golden", ROOT / "mncore" / "tools"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))
import mnhost  # noqa: E402
import mnplan  # noqa: E402
import mnrun  # noqa: E402
import goldenlib as gl  # noqa: E402
import ndmp  # noqa: E402

# nextpnr seeds to try. M2aR is at the limit (LUT4 75 %): with the RTL of 2026-11-26 seeds 1, 2, 4, 5 reach
# only 26.1..26.7 MHz of the 27 MHz core clock, seed 3 reaches 28.2 MHz (WP41); WP38's RTL passed with seed 2
SEEDS = {"M2aR": "3,2,1,4,5,6,7,8"}
LOCK_STALE_S = 2 * 3600                 # contract 06 section 9


# ----------------------------------------------------------------------------------------- output
class Out:
    """Print to the terminal and, with a log file, to the log."""

    def __init__(self, log_path: str | None = None):
        self.f = None
        if log_path:
            Path(log_path).parent.mkdir(parents=True, exist_ok=True)
            self.f = open(log_path, "w", encoding="utf-8", newline="\n")

    def __call__(self, s: str = ""):
        print(s, flush=True)
        if self.f:
            self.f.write(s + "\n")
            self.f.flush()

    def close(self):
        if self.f:
            self.f.close()
            self.f = None


def rel(p: Path) -> str:
    try:
        return Path(p).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(p)


def oss_on_path():
    """OSS CAD Suite on PATH (openFPGALoader, yosys, nextpnr), as mnrun.py / simrun.py do."""
    if shutil.which("openFPGALoader") is None:
        oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
        os.environ["PATH"] = os.pathsep.join([str(oss / "bin"), str(oss / "lib"), os.environ.get("PATH", "")])


# ----------------------------------------------------------------------------------------- programs
@dataclass
class Demo:
    """One program to run: the solution, its testcase text, and where the committed copies are."""
    name: str                       # file stem in demo/programs and demo/build
    solution: Path                  # the .vsm the official assembler assembles
    testcase: str                   # the testcase text (with the VSM_HERE marker)
    asm_name: str = ""               # stem of the committed machine code (default: name)


@dataclass
class Prepared:
    asm_text: str                   # what the board runs: testcase prefix + assembled solution + d lines
    main_asm: str                   # the assembled solution (j / m / d lines)
    official: dict | None           # (space, loc, addr) -> value of the official emulator, or None
    official_src: str               # "official emulator (WSL)", "recorded ...", or "none"
    words: int = 0
    notes: list = field(default_factory=list)


def main_asm_path(d: Demo) -> Path:
    return PROGRAMS / f"{d.asm_name or d.name}.main.asm"


def recorded_path(d: Demo) -> Path:
    return PROGRAMS / f"{d.name}.official.ndmp"


def official_tools() -> bool:
    """The official assembler and emulator are reachable in WSL."""
    test = f"test -x {gl.EMU_DIR_WSL}/assemble3 && test -x {gl.EMU_DIR_WSL}/gpfn3_package_main"
    cmd = ["wsl", "-d", gl.WSL_DISTRO, "--", "bash", "-lc", test] if os.name == "nt" else ["bash", "-lc", test]
    if not shutil.which(cmd[0]):
        return False
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=60)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def split_testcase(text: str):
    """(prefix, suffix d lines) of a testcase: the suffix may hold only d lines and comments (it is
    then what assemble3 would pass through)."""
    prefix, suffix, output = gl.split_testcase(text)
    dl = []
    for raw in (suffix + "\n" + output).splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if not line.startswith("d "):
            raise SystemExit("the testcase has code after the solution: the official assembler is needed "
                             "(run with WSL)")
        dl.append(line)
    return prefix, dl


def compose(d: Demo, main_asm: str) -> str:
    """The board's program without the official tools: testcase prefix, assembled solution, d lines."""
    prefix, dl = split_testcase(d.testcase)
    keep = [ln for ln in main_asm.splitlines() if ln[:2] in ("j ", "m ", "d ", "r ")]
    return prefix.rstrip("\n") + "\n" + "\n".join(keep) + "\n" + "\n".join(dl) + "\n"


def prepare(d: Demo, out: Out, use_official: bool = True, update: bool = False) -> Prepared:
    """Assemble and run on the official emulator (WSL), or fall back to the committed files."""
    job = BUILD / d.name
    job.mkdir(parents=True, exist_ok=True)
    committed = main_asm_path(d)
    if use_official and official_tools():
        tc = job / "testcase.vsm"
        tc.write_text(d.testcase, encoding="utf-8", newline="\n")
        prog = gl.load_program(d.solution, testcase=str(tc), probe="none")
        gl.write_official_job(prog, job)
        t0 = time.monotonic()
        lines: list = []
        gl.run_official_jobs([job], parallel=1, keep=True, timeout=1800, on_line=lines.append)
        st = gl.read_status(job)
        if st != "ok":
            log = (job / "official.log").read_text(encoding="utf-8", errors="replace") if (job / "official.log").exists() else ""
            raise SystemExit(f"official tools failed on {rel(d.solution)}: {st}\n{log[-2000:]}")
        main_asm = (job / "main.asm").read_text(encoding="utf-8")
        off, _ = ndmp.read(str(job / "official.ndmp"))
        p = Prepared(asm_text=(job / "official.asm").read_text(encoding="utf-8"), main_asm=main_asm,
                     official=off, official_src="official emulator gpfn3_package_main (WSL)")
        p.notes.append(f"assemble3 + gpfn3_package_main: {time.monotonic() - t0:.1f} s")
        if not committed.exists() or committed.read_text(encoding="utf-8") != main_asm:
            if update or not committed.exists():
                committed.parent.mkdir(parents=True, exist_ok=True)
                committed.write_text(main_asm, encoding="utf-8", newline="\n")
                p.notes.append(f"wrote {rel(committed)}")
            else:
                p.notes.append(f"NOTE: assemble3 output differs from {rel(committed)} (--update rewrites it)")
        rec = recorded_path(d)
        if update or not rec.exists():
            keep = {k: v for k, v in off.items() if implemented_chip_part(k[1])}
            ndmp.write(str(rec), keep, {"producer": "official emulator gpfn3_package_main (recorded by "
                                                    "mncore/demo, d get lines of the testcase)",
                                        "src": rel(d.solution), "kept": "locations n0c0b0m0..15 (64 PEs) and n0"})
            p.notes.append(f"wrote {rel(rec)}")
    else:
        if not committed.exists():
            raise SystemExit(f"no official tools and no committed program {rel(committed)}")
        main_asm = committed.read_text(encoding="utf-8")
        rec = recorded_path(d)
        off, src = None, "none (no official tools; --no-official or WSL missing)"
        if rec.exists():
            off, _ = ndmp.read(str(rec))
            src = f"recorded official emulator output {rel(rec)}"
        p = Prepared(asm_text=compose(d, main_asm), main_asm=main_asm, official=off, official_src=src)
    p.words = sum(1 for ln in p.main_asm.splitlines() if ln[:2] in ("j ", "m "))
    return p


def implemented_chip_part(loc: str) -> bool:
    """The part of the chip any board design implements (at most L1B n0c0b0: 16 MABs, 64 PEs)."""
    f = ndmp.loc_parts(loc)
    return all(f.get(k, 0) == 0 for k in "ncb")


# ----------------------------------------------------------------------------------------- bitstreams
def needed_members(asm_text: str, rule: str) -> tuple[list, object]:
    """The members of the set the program runs on (mnplan), and the plan."""
    prog = mnhost.parse_asm(asm_text)
    members = mnplan.load_set(mnplan.SET_JSON, rule)
    words = mnplan.analyze_entries(prog.entries)
    p = mnplan.plan(words, members, None)
    need = []
    for s in p.segments:
        if s.member not in need:
            need.append(s.member)
    dram_get = any(d.op == "get" and d.space in ("PDM", "DRAM") for _, d in prog.events)
    if dram_get and (not p.segments or "SDRAM" not in p.segments[-1].member.caps):
        m = next(m for m in members if "SDRAM" in m.caps)
        if m not in need:
            need.append(m)
    return need, p


@dataclass
class Bitstream:
    name: str
    fs: Path
    cmd: list                       # the build command (arguments of python, from the repository root)


def member_bitstream(m) -> Bitstream:
    """A member of the set (mncore/fpga/multi/set.json)."""
    return Bitstream(m.name, m.fs, ["mncore/fpga/multi/build.py", "--member", m.name,
                                    "--seeds", SEEDS.get(m.name, "1,2,3")])


# the virtual-PE design of WP34 with 64 PEs and the integer ALU only (design 0x06)
VPE_DESIGN = 0x06
V64 = Bitstream("V64", ROOT / "mncore" / "fpga" / "top_vpe" / "build" / "V64" / "top_vpe.fs",
                ["mncore/fpga/top_vpe/build.py", "--tag", "V64", "--seeds", "1,2,3"])


def ensure_bitstreams(bits: list, out: Out, build: bool = True, report_only: bool = False) -> None:
    """Build the bitstreams that are missing (their build.py, in parallel)."""
    bits = [b if isinstance(b, Bitstream) else member_bitstream(b) for b in bits]
    missing = [b for b in bits if not b.fs.exists()]
    for b in bits:
        if b.fs.exists():
            out(f"          bitstream {b.name:6s} {rel(b.fs)} (built "
                f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(b.fs.stat().st_mtime))})")
        else:
            out(f"          bitstream {b.name:6s} missing: python {' '.join(b.cmd)}")
    if not missing or report_only:
        return
    names = ", ".join(b.name for b in missing)
    if not build:
        raise SystemExit(f"bitstreams missing: {names} (build them as above, or run without --no-build)")
    out(f"          building {names} (yosys + nextpnr, 15 to 120 minutes each, in parallel) ...")
    BUILD.mkdir(parents=True, exist_ok=True)
    procs = []
    t0 = time.monotonic()
    for b in missing:
        lp = BUILD / f"build_{b.name}.log"
        lf = open(lp, "w", encoding="utf-8")
        out(f"          python {' '.join(b.cmd)}  (log {rel(lp)})")
        procs.append((b, subprocess.Popen([sys.executable] + b.cmd, cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT), lf))
    bad = []
    for b, pr, lf in procs:
        rc = pr.wait()
        lf.close()
        ok = not rc and b.fs.exists()
        if not ok:
            bad.append(b.name)
        out(f"          {b.name}: {'built' if ok else f'FAILED rc {rc}'} ({(time.monotonic() - t0) / 60:.0f} min)")
    if bad:
        raise SystemExit(f"building {', '.join(bad)} failed (logs in {rel(BUILD)})")


# ----------------------------------------------------------------------------------------- board lock
class BoardLock:
    """contract 06 section 9: C:\\wgkz\\nano20k\\mncore\\.board.lock with the WP number and the start time.
    On another checkout (the lock's directory does not exist) there is nothing to lock."""

    def __init__(self, who: str, out: Out, path: Path = mnrun.LOCK, force: bool = False):
        self.who, self.out, self.path, self.force = who, out, path, force
        self.held = False

    def __enter__(self):
        if not self.path.parent.is_dir():
            return self
        if self.path.exists():
            age = time.time() - self.path.stat().st_mtime
            text = self.path.read_text(encoding="utf-8", errors="replace").strip()
            if text.split()[:1] == self.who.split()[:1] and age < LOCK_STALE_S:
                self.out(f"          the board lock is ours already ({text!r}); it stays")
                return self                      # e.g. "WP41 ..." held around several demo runs
            if age < LOCK_STALE_S and not self.force:
                raise SystemExit(f"the board is in use: {self.path} says {text!r} ({age / 60:.0f} min old). "
                                 f"Try again later (a lock older than 2 hours is stale; --force-lock takes it).")
            self.out(f"  taking over a stale board lock ({text!r}, {age / 60:.0f} min old)")
        self.path.write_text(f"{self.who} {time.strftime('%Y-%m-%d %H:%M:%S')}\n", encoding="utf-8")
        self.held = True
        return self

    def __exit__(self, *exc):
        if self.held:
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass
            self.held = False
        return False


# ----------------------------------------------------------------------------------------- the board
@dataclass
class BoardRun:
    records: dict
    stop: object
    stop_entry: int | None
    stats: dict
    seconds: float
    segments: list
    info: object = None


def detect_board() -> bool:
    oss_on_path()
    try:
        r = subprocess.run(["openFPGALoader", "--detect", "-b", "tangnano20k"], capture_output=True, text=True,
                           timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "GW2A" in (r.stdout + r.stderr)


class FreshBoard(mnrun.Board):
    """mnrun's board that does not reuse the design already in the FPGA: the demo always loads the
    first member itself (bitstream preparation, loading and running in one command)."""

    def ensure(self):
        pass


def run_board(asm_text: str, rule: str, out: Out, port: str = "auto", baud: int = 2000000,
              verbose: bool = False, reuse: bool = False) -> BoardRun:
    """mnrun.py run on the board (the same ProgramRun as `mnrun.py --rule <rule> run`)."""
    oss_on_path()
    members = mnplan.load_set(mnplan.SET_JSON, rule)
    board = (mnrun.Board if reuse else FreshBoard)(members, port, baud, out, verbose)
    prog = mnhost.parse_asm(asm_text)
    t0 = time.monotonic()
    try:
        pr = mnrun.ProgramRun(board, prog, out, verbose)
        r = pr.execute()
        info = board.dev.info() if board.dev else None
    finally:
        board.close()
    return BoardRun(records=dict(r.records), stop=r.stop, stop_entry=r.stop_entry, stats=dict(r.stats),
                    seconds=time.monotonic() - t0, segments=list(r.stats.get("segments", [])), info=info)


def run_board_single(asm_text: str, bit: Bitstream, design_id: int, out: Out, port: str = "auto",
                     baud: int = 2000000, verbose: bool = False) -> BoardRun:
    """One bitstream for the whole program (e.g. V64): load it into the SRAM (openFPGALoader -b tangnano20k,
    never the Flash), check INFO, and run with mnhost.execute_program (RESET, IMEM, RUN, d set / d get)."""
    oss_on_path()
    prog = mnhost.parse_asm(asm_text)
    t0 = time.monotonic()
    r = subprocess.run(["openFPGALoader", "-b", "tangnano20k", str(bit.fs)], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"openFPGALoader {bit.fs}: rc {r.returncode}\n{r.stdout[-800:]}{r.stderr[-800:]}")
    time.sleep(0.3)
    dev = inf = None
    for _ in range(4):
        link = mnhost.Link.open(port, 1000000, timeout=0.2)
        try:
            link.flush_input(0.05)
            dev = mnhost.Device(link)
            inf = dev.info(refresh=True)
            break
        except (mnhost.ProtocolError, mnhost.DeviceError):
            link.ser.close()
            dev = None
            time.sleep(0.5)
    if dev is None:
        raise SystemExit(f"no answer from {bit.name} after loading it")
    try:
        if inf.design_id != design_id:
            raise SystemExit(f"loaded {bit.name} but INFO says design 0x{inf.design_id:02x} (expected 0x{design_id:02x})")
        if baud and baud != 1000000:
            dev.set_baud(baud)
        t_load = time.monotonic() - t0
        if verbose:
            out(f"#   loaded {bit.name} in {t_load:.2f} s: topology {inf.topo}, flags 0x{inf.flags:02x}")
        t1 = time.monotonic()
        res = mnhost.execute_program(dev, prog, mnhost.Topology(inf.topo), run_timeout=600.0)
        t_run = time.monotonic() - t1
    finally:
        try:
            if dev.link.baudrate != 1000000:
                dev.set_baud(1000000)
        except (mnhost.ProtocolError, mnhost.DeviceError):
            pass
        dev.link.ser.close()
    stats = dict(res.stats)
    stats.update({"loads": 1, "t_load": round(t_load, 2), "t_save": 0.0, "t_restore": 0.0, "t_run": round(t_run, 2)})
    return BoardRun(records=dict(res.records), stop=res.stop, stop_entry=res.stop_entry, stats=stats,
                    seconds=time.monotonic() - t0, segments=[(0, len(prog.entries), bit.name)], info=inf)


def describe_segments(segs) -> str:
    return ", ".join(f"words {a}-{b - 1} on {nm}" if b > a else f"then {nm}" for a, b, nm in segs)


def timing_line(br: BoardRun) -> str:
    s = br.stats
    return (f"{br.seconds:.1f} s on the board: {s.get('loads', 0)} bitstream load(s) {s.get('t_load', 0):.1f} s, "
            f"state hand-over {s.get('t_save', 0) + s.get('t_restore', 0):.2f} s, "
            f"RUN / d lines {s.get('t_run', 0):.2f} s ({s.get('steps', 0)} steps, {s.get('runs', 0)} RUNs)")


def compare(board: dict, official: dict | None) -> tuple[int, list]:
    """(long words compared, [(key, board, official)] that differ) over the board's d get records."""
    if official is None:
        return 0, []
    diff = []
    n = 0
    for k, v in sorted(board.items()):
        if k not in official:
            diff.append((k, v, None))
            continue
        n += 1
        if official[k] != v:
            diff.append((k, v, official[k]))
    return n, diff


def stop_text(br: BoardRun) -> str | None:
    if br.stop is None or br.stop.reason == 4:
        return None
    return f"{br.stop.reason_name} at word {br.stop_entry} (info {br.stop.info:#x})"


def common_args(ap):
    ap.add_argument("--no-official", action="store_true",
                    help="do not run the official tools in WSL (use demo/programs/*.main.asm and the recorded output)")
    ap.add_argument("--update", action="store_true",
                    help="rewrite demo/programs/ from the official tools")
    ap.add_argument("--no-build", action="store_true", help="fail instead of building missing bitstreams")
    ap.add_argument("--port", default=os.environ.get("MNHOST_PORT", "auto"), help="UART (default: auto, e.g. COM6)")
    ap.add_argument("--baud", type=int, default=2000000)
    ap.add_argument("--log", help="also write the output to this file")
    ap.add_argument("--force-lock", action="store_true", help="take the board lock even if it is fresh")
    ap.add_argument("--reuse", action="store_true",
                    help="keep the member already in the FPGA when the plan starts with it (default: load it)")
    ap.add_argument("--dry-run", action="store_true", help="prepare and plan only, do not use the board")
    ap.add_argument("-v", "--verbose", action="store_true")
    return ap


def hexwords(vals) -> str:
    return " ".join(f"{v:016x}" for v in vals)


def ascii_of(vals, n: int) -> str:
    b = b"".join(v.to_bytes(8, "big") for v in vals)[:n]
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b)

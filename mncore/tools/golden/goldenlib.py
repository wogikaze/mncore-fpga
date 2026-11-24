"""Shared helpers for the golden tools (WP02): program composition, probes, paths, WSL calls.

A *program* is what one comparison runs, built from one ``.vsm`` file:

- ``testcase``: a judge testcase (contains the ``YOUR VSM WILL BE INSERTED HERE`` marker); it
  runs with an empty solution.
- ``solution``: a solution of a known problem. It is wrapped like ``judge.py`` does:
  testcase prefix (raw ``d set`` / ``r`` lines) + assembled solution + assembled testcase suffix
  + testcase output ``d get`` lines.
- ``standalone``: anything else, run as it is.

``--testcase auto`` (the default) picks the testcase from the path: a ``testcase.vsm`` next to
the file, otherwise a path component (file stem first, then parent directories) that equals a
problem name under ``third_party/mncore/problems`` (``10.sumrow``, ``challenge`` problems too).

A *probe* is a list of ``d get`` lines appended at the very end, so that the final state is
dumped even when the program has no ``d get`` of its own.
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

GOLDEN_DIR = Path(__file__).resolve().parent
ROOT = GOLDEN_DIR.parents[2]
MNCORE = ROOT / "third_party" / "mncore"
PROBLEMS = MNCORE / "problems"
BUILD = GOLDEN_DIR / "build"
CACHE = BUILD / "cache"

# Official tools inside WSL. Override with MNCORE_EMU_DIR_WSL (a path inside WSL).
EMU_DIR_WSL = os.environ.get("MNCORE_EMU_DIR_WSL", "~/wgkz/mncore/judge/judge-py/mncore2_emuenv")
WSL_DISTRO = os.environ.get("MNCORE_WSL_DISTRO", "Ubuntu")

VSM_HERE = "# ======= YOUR VSM WILL BE INSERTED HERE ======="
GET_OUTPUT = "# ======= Output ======="

# ---------------------------------------------------------------------------------------------
# probes

# Implemented PEs of the reduced topology come first (contract 06 section 3): n0c0b0m0p0..p3.
MAB0 = [f"n0c0b0m0p{p}" for p in range(4)]
REMOTE = ["n1c1b5m9p2", "n3c1b7m15p3"]


def _pe_probe(pe: str) -> List[str]:
    return [
        f"d get $lm0{pe} 2048",
        f"d get $ln0{pe} 2048",
        f"d get $lr0{pe} 256",
        f"d get $ls0{pe} 256",
        f"d get $llt{pe} 4",
        f"d get $omr1{pe} 15",
    ]


def probe_lines(name: str) -> List[str]:
    """``none``: nothing. ``pe``: all of PE n0c0b0m0p0 (LM0/LM1/GRF0/GRF1/T/OMR).
    ``mab``: the four PEs of MAB 0, L1BM n0c0b0 and L2BM n0c0.
    ``wide``: ``mab`` plus two remote PEs and L1BM n2c1b5 (default, used by the sweep)."""
    if name == "none":
        return []
    if name == "pe":
        return _pe_probe(MAB0[0])
    if name in ("mab", "wide"):
        out: List[str] = []
        pes = MAB0 + (REMOTE if name == "wide" else [])
        for pe in pes:
            out += _pe_probe(pe)
        out.append("d get $lb0n0c0b0 8192")
        if name == "wide":
            out.append("d get $lb0n2c1b5 8192")
        out.append("d get $lc0n0c0 32768")
        return out
    raise ValueError(f"unknown probe {name!r} (none, pe, mab, wide)")


PROBES = ("none", "pe", "mab", "wide")
DEFAULT_PROBE = "wide"

# ---------------------------------------------------------------------------------------------
# programs


def sanitize_vsm(text: str) -> str:
    """judge.py removes everything after `#` or `!` on each line before assembling."""
    return re.sub(r"[#!].*$", "", text, flags=re.MULTILINE)


def is_testcase_text(text: str) -> bool:
    return VSM_HERE in text


def split_testcase(text: str):
    """(prefix, suffix code, output section), split like judge.py.

    94 of the 115 testcases in third_party/mncore have no ``# ======= Output =======`` line
    (judge.py would stop on them). Then everything after the VSM_HERE marker is the suffix: it is
    assembled like the solution, and assemble3 passes its ``d get`` lines through unchanged."""
    if VSM_HERE + "\n" not in text:
        raise ValueError("testcase has no VSM_HERE marker line")
    prefix, rest = text.split(VSM_HERE + "\n", 1)
    if GET_OUTPUT + "\n" in rest:
        suffix, output = rest.split(GET_OUTPUT + "\n", 1)
    else:
        suffix, output = rest, ""
    return prefix, suffix, output


_problem_index: Optional[Dict[str, Path]] = None


def problem_index() -> Dict[str, Path]:
    """Problem name -> testcase.vsm, for problems/* and problems/challenge/*."""
    global _problem_index
    if _problem_index is None:
        idx: Dict[str, Path] = {}
        for top in (PROBLEMS, PROBLEMS / "challenge"):
            if not top.is_dir():
                continue
            for d in sorted(top.iterdir()):
                tc = d / "testcase.vsm"
                if d.is_dir() and tc.is_file():
                    idx.setdefault(d.name, tc)
        _problem_index = idx
    return _problem_index


def resolve_testcase(vsm: Path, mode: str = "auto", text: Optional[str] = None) -> Optional[Path]:
    """The testcase to wrap ``vsm`` with, or None (standalone, or ``vsm`` is a testcase)."""
    if mode == "none":
        return None
    if mode != "auto":
        return Path(mode).resolve()
    if text is None:
        text = vsm.read_text(encoding="utf-8", errors="replace")
    if is_testcase_text(text):
        return None
    sib = vsm.parent / "testcase.vsm"
    if sib.is_file() and sib.resolve() != vsm.resolve():
        return sib.resolve()
    idx = problem_index()
    for name in [vsm.stem] + [p.name for p in vsm.resolve().parents]:
        if name in idx:
            return idx[name].resolve()
    return None


def rel(p: Optional[Path]) -> str:
    """Path relative to the repository root, with forward slashes ('-' for None)."""
    if p is None:
        return "-"
    p = Path(p).resolve()
    try:
        return p.relative_to(ROOT).as_posix()
    except ValueError:
        return p.as_posix()


def safe_name(vsm: Path) -> str:
    """A directory name for a program: its path below third_party/mncore (or the repo)."""
    p = vsm.resolve()
    for base in (MNCORE, ROOT):
        try:
            r = p.relative_to(base)
            break
        except ValueError:
            continue
    else:
        r = Path(p.name)
    s = r.with_suffix("").as_posix().replace("/", "__")
    return re.sub(r"[^A-Za-z0-9_.+-]", "_", s)


@dataclass
class Program:
    src: Path
    kind: str  # testcase | solution | standalone
    testcase: Optional[Path]
    probe: str
    main_vsm: str = ""  # sanitized, assembled by assemble3
    prefix: str = ""  # raw, fed to the emulator as is
    suffix_vsm: str = ""  # sanitized, assembled by assemble3
    output: str = ""  # raw testcase output `d get` lines
    probe_text: str = ""
    meta: Dict[str, str] = field(default_factory=dict)

    def rust_source(self) -> str:
        """The whole program as VSM for the Rust simulator, in the emulator's order."""
        parts = [self.prefix, self.main_vsm, self.suffix_vsm, self.output, self.probe_text]
        return "".join(p if p.endswith("\n") or not p else p + "\n" for p in parts)


_split_cache: Dict[tuple, tuple] = {}


def load_testcase(tc: Path):
    """(prefix, sanitized suffix, output) of a testcase file, cached."""
    st = tc.stat()
    key = (str(tc), st.st_size, st.st_mtime_ns)
    if key not in _split_cache:
        prefix, suffix, output = split_testcase(tc.read_text(encoding="utf-8", errors="replace"))
        _split_cache[key] = (prefix, sanitize_vsm(suffix), output)
    return _split_cache[key]


def load_program(vsm: Path, testcase: str = "auto", probe: str = DEFAULT_PROBE) -> Program:
    vsm = Path(vsm).resolve()
    text = vsm.read_text(encoding="utf-8", errors="replace")
    probe_text = "".join(line + "\n" for line in probe_lines(probe))
    if is_testcase_text(text) and testcase in ("auto", "none"):
        prefix, suffix, output = load_testcase(vsm)
        prog = Program(vsm, "testcase", vsm, probe, "", prefix, suffix, output, probe_text)
    else:
        tc = resolve_testcase(vsm, testcase, text)
        if tc is None:
            prog = Program(vsm, "standalone", None, probe, sanitize_vsm(text), probe_text=probe_text)
        else:
            prefix, suffix, output = load_testcase(tc)
            prog = Program(vsm, "solution", tc, probe, sanitize_vsm(text), prefix, suffix, output, probe_text)
    prog.meta = {"src": rel(prog.src), "kind": prog.kind, "testcase": rel(prog.testcase), "probe": probe}
    return prog


# ---------------------------------------------------------------------------------------------
# WSL


def to_wsl(p: Path) -> str:
    """C:\\x\\y -> /mnt/c/x/y. Paths must be on a Windows drive."""
    s = str(Path(p).resolve())
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", s)
    if not m:
        if s.startswith("/"):
            return s
        raise ValueError(f"not a drive path: {s}")
    return f"/mnt/{m.group(1).lower()}/" + m.group(2).replace("\\", "/")


def wsl_cmd(script: Path, args: List[str]) -> List[str]:
    """Command line that runs a bash script file in WSL. The script is passed as a file path;
    passing paths inline through Git Bash mangles them."""
    if os.name == "nt":
        return ["wsl", "-d", WSL_DISTRO, "--", "bash", to_wsl(script)] + args
    return ["bash", str(script)] + args


def wsl_path_arg(p: Path) -> str:
    return to_wsl(p) if os.name == "nt" else str(Path(p).resolve())


def _cache_part(tc: Path, kind: str, text: str) -> Path:
    st = tc.stat()
    h = hashlib.sha1(f"{tc}|{st.st_size}|{st.st_mtime_ns}|{kind}".encode()).hexdigest()[:16]
    CACHE.mkdir(parents=True, exist_ok=True)
    p = CACHE / f"{tc.parent.name}.{h}.{kind}.asm"
    if not p.exists():
        tmp = p.with_suffix(".tmp")
        tmp.write_text(text, encoding="utf-8", newline="\n")
        os.replace(tmp, p)
    return p


def write_official_job(prog: Program, job: Path) -> None:
    """Writes the inputs of one official run for wsl_official.sh into ``job``.

    parts.txt lists what is concatenated into the emulator input, in order:
    a WSL path of a raw part, ``@main`` (assembled main.vsm) or ``@suffix`` (assembled suffix.vsm).
    """
    job.mkdir(parents=True, exist_ok=True)
    for stale in ("status", "official.ndmp", "official.log", "official.asm", "official.dmp", "main.asm"):
        (job / stale).unlink(missing_ok=True)
    (job / "main.vsm").write_text(prog.main_vsm, encoding="utf-8", newline="\n")
    (job / "suffix.vsm").write_text(prog.suffix_vsm, encoding="utf-8", newline="\n")
    (job / "probe.asm").write_text(prog.probe_text, encoding="utf-8", newline="\n")
    parts: List[str] = []
    if prog.prefix:
        parts.append(wsl_path_arg(_cache_part(prog.testcase, "prefix", prog.prefix)))
    parts.append("@main")
    parts.append("@suffix")
    if prog.output:
        parts.append(wsl_path_arg(_cache_part(prog.testcase, "output", prog.output)))
    parts.append(wsl_path_arg(job / "probe.asm"))
    (job / "parts.txt").write_text("".join(p + "\n" for p in parts), encoding="utf-8", newline="\n")
    meta = dict(prog.meta)
    meta["producer"] = "official"
    (job / "meta.txt").write_text("".join(f"{k}: {v}\n" for k, v in meta.items()), encoding="utf-8",
                                  newline="\n")


def run_official_jobs(jobs: List[Path], parallel: int = 1, keep: bool = False, timeout: int = 1800,
                      on_line=None) -> int:
    """Runs wsl_official.sh over job directories. Returns its exit code.
    ``on_line`` gets each progress line (``<status> <job>``)."""
    BUILD.mkdir(parents=True, exist_ok=True)
    lst = BUILD / f"joblist.{os.getpid()}.txt"
    lst.write_text("".join(wsl_path_arg(j) + "\n" for j in jobs), encoding="utf-8", newline="\n")
    args = ["-j", str(parallel), "-t", str(timeout), "-e", EMU_DIR_WSL]
    if keep:
        args.append("-k")
    args += ["-l", wsl_path_arg(lst)]
    cmd = wsl_cmd(GOLDEN_DIR / "wsl_official.sh", args)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace")
    assert proc.stdout is not None
    for line in proc.stdout:
        if on_line:
            on_line(line.rstrip("\n"))
        else:
            sys.stderr.write(line)
    rc = proc.wait()
    lst.unlink(missing_ok=True)
    return rc


def read_status(job: Path) -> str:
    p = job / "status"
    return p.read_text(encoding="utf-8").strip() if p.exists() else "missing"


# ---------------------------------------------------------------------------------------------
# Rust

GOLDEN_RS = ROOT / "mncore" / "golden_rs"


def golden_dump_exe() -> Path:
    exe = "golden_dump.exe" if os.name == "nt" else "golden_dump"
    return GOLDEN_RS / "target" / "release" / exe


def cargo() -> str:
    if os.name == "nt":
        p = Path(os.environ.get("USERPROFILE", "")) / ".cargo" / "bin" / "cargo.exe"
        if p.exists():
            return str(p)
    return "cargo"


def build_rust(quiet: bool = True) -> Path:
    """cargo build --release of mncore/golden_rs (a no-op when it is up to date)."""
    cmd = [cargo(), "build", "--release", "--manifest-path", str(GOLDEN_RS / "Cargo.toml")]
    if quiet:
        cmd.append("--quiet")
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("golden_rs build failed")
    return golden_dump_exe()


@dataclass
class RustResult:
    status: str  # ok | unsupported | parse_error | timeout | error<rc>
    body: str  # canonical ndmp lines from golden_dump (sorted, deduplicated), no header
    words: Optional[int]
    message: str

    def write(self, path: Path, meta: Dict[str, str]) -> None:
        head = "# ndmp v1\n" + "".join(f"# {k}: {v}\n" for k, v in meta.items())
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(head + self.body)


def run_rust_program(prog: Program, exe: Optional[Path] = None, threads: Optional[int] = None,
                     timeout: int = 1800) -> RustResult:
    exe = exe or golden_dump_exe()
    env = dict(os.environ)
    if threads:
        env["RAYON_NUM_THREADS"] = str(threads)
    try:
        r = subprocess.run([str(exe), "-"], input=prog.rust_source().encode("utf-8"), capture_output=True,
                           env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return RustResult("timeout", "", None, f"timeout after {timeout} s")
    err = r.stderr.decode("utf-8", "replace")
    words = None
    m = re.search(r"^words=(\d+)", err, flags=re.MULTILINE)
    if m:
        words = int(m.group(1))
    if r.returncode != 0:
        status = {2: "unsupported", 3: "parse_error"}.get(r.returncode, f"error{r.returncode}")
        return RustResult(status, "", words, err.strip())
    return RustResult("ok", r.stdout.decode("utf-8").replace("\r\n", "\n"), words, "")


def count_words(asm_path: Path) -> Optional[int]:
    """Number of `j` and `m` lines (the judge's score) in an assembled file."""
    if not asm_path.exists():
        return None
    n = 0
    with open(asm_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("j ") or line.startswith("m "):
                n += 1
    return n

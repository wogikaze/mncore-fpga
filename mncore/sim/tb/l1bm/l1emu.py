#!/usr/bin/env python3
"""WP31: run small programs on the official assembler and emulator (WSL) and read the results.

    from l1emu import run_programs
    res = run_programs({"name": "vsm text", ...}, workdir)
    res["name"].ok, .asm_err, .words (list of ('j'|'m', bits)), .dump {(space, loc, addr): value}

The official binaries are only called (emu_batch.sh), never copied (contract section 9).
The dump is normalized with mncore/tools/golden/norm_gpfn3.py (contract section 4 units:
LM/GRF long word addresses, T = 2 * cycle + k, L1BM long words).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "mncore" / "tools" / "golden"))
import norm_gpfn3  # noqa: E402

WSL_DISTRO = "Ubuntu"


def to_wsl(p: Path) -> str:
    s = str(Path(p).resolve())
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", s)
    if not m:
        return s
    return f"/mnt/{m.group(1).lower()}/" + m.group(2).replace("\\", "/")


@dataclass
class Result:
    name: str
    ok: bool = False
    asm_err: str = ""
    emu_rc: Optional[int] = None
    emu_out: str = ""
    words: List[Tuple[str, str]] = field(default_factory=list)   # ('j' | 'm', bit string)
    dlines: List[str] = field(default_factory=list)              # 'd' lines of the asm, in order
    seq: List[Tuple[str, str]] = field(default_factory=list)     # asm lines in order: (kind, text)
    dump: Dict[Tuple[str, str, int], int] = field(default_factory=dict)


def parse_asm(text: str):
    words, dl, seq = [], [], []
    for raw in text.splitlines():
        ln = raw.strip()
        if not ln or ln.startswith("#"):
            continue
        k = ln[0]
        if k in "jm" and len(ln) > 2 and ln[1] == " ":
            bits = ln[2:].strip()
            words.append((k, bits))
            seq.append((k, bits))
        elif k == "d":
            dl.append(ln)
            seq.append(("d", ln))
        elif k == "r":
            seq.append(("r", ln))
    return words, dl, seq


def _finished(b: Path) -> bool:
    """The assembler ran, and when it accepted the program the emulator finished too."""
    arc = b.with_suffix(".arc")
    if not arc.exists() or not arc.read_text().strip():
        return False
    if arc.read_text().strip() != "0":
        return True
    erc = b.with_suffix(".erc")
    # 137: killed (SIGKILL, e.g. out of memory) - not a result of the program
    return erc.exists() and erc.read_text().strip() not in ("", "137")


def run_programs(progs: Dict[str, str], workdir: Path, jobs: int = 8, clean: bool = True,
                 asm: Optional[Dict[str, str]] = None, reuse: bool = False) -> Dict[str, Result]:
    """progs: name -> .vsm text (assembled, then run). asm: name -> assembler output text that is
    run as it is (hand-edited words). reuse: only read the results of an earlier run in workdir."""
    workdir = Path(workdir)
    asm = asm or {}
    if not reuse:
        if clean and workdir.exists():
            shutil.rmtree(workdir)
        workdir.mkdir(parents=True, exist_ok=True)
        for name, text in progs.items():
            (workdir / f"{name}.vsm").write_text(text.rstrip("\n") + "\n", encoding="utf-8", newline="\n")
        for name, text in asm.items():
            (workdir / f"{name}.asmin").write_text(text.rstrip("\n") + "\n", encoding="utf-8", newline="\n")
        # a program whose run did not finish (no exit code: WSL restarted, a process was killed)
        # is run again, at most twice
        names = list(progs) + list(asm)
        for attempt in range(3):
            run_dir = workdir if attempt == 0 else workdir / f"retry{attempt}"
            if attempt:
                missing = [n for n in names if not _finished(workdir / n)]
                if not missing:
                    break
                sys.stderr.write(f"[l1emu] {len(missing)} unfinished runs, again: {' '.join(missing[:8])}\n")
                if run_dir.exists():
                    shutil.rmtree(run_dir)
                run_dir.mkdir()
                for n in missing:
                    src = workdir / (f"{n}.vsm" if n in progs else f"{n}.asmin")
                    shutil.copyfile(src, run_dir / src.name)
            cmd = ["wsl", "-d", WSL_DISTRO, "--", "bash", to_wsl(HERE / "emu_batch.sh"), to_wsl(run_dir), str(jobs)]
            if os.name != "nt":
                cmd = ["bash", str(HERE / "emu_batch.sh"), str(run_dir), str(jobs)]
            r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
            if r.returncode != 0 and r.stderr.strip():
                sys.stderr.write(r.stderr[-2000:])
            if attempt:
                for f in run_dir.iterdir():
                    if f.suffix in (".asm", ".arc", ".aerr", ".dmp", ".erc", ".eout"):
                        shutil.copyfile(f, workdir / f.name)
    progs = dict(progs)
    progs.update({k: "" for k in asm})
    out: Dict[str, Result] = {}
    for name in progs:
        res = Result(name)
        b = workdir / name
        arc = (b.with_suffix(".arc")).read_text().strip() if b.with_suffix(".arc").exists() else "?"
        if arc != "0":
            res.asm_err = (b.with_suffix(".aerr").read_text(errors="replace") if b.with_suffix(".aerr").exists()
                           else "no assembler output")
            out[name] = res
            continue
        res.words, res.dlines, res.seq = parse_asm(b.with_suffix(".asm").read_text(errors="replace"))
        erc = b.with_suffix(".erc")
        res.emu_rc = int(erc.read_text().strip()) if erc.exists() else None
        res.emu_out = b.with_suffix(".eout").read_text(errors="replace") if b.with_suffix(".eout").exists() else ""
        dmp = b.with_suffix(".dmp")
        if dmp.exists():
            res.dump, _ = norm_gpfn3.normalize_file(str(dmp))
        res.ok = res.emu_rc == 0
        out[name] = res
    return out


# ------------------------------------------------------------------------------------- fields
sys.path.insert(0, str(ROOT / "mncore" / "tools"))
from mnisa.codec import decode_bits  # noqa: E402


def fields(bits: str) -> Dict[str, int]:
    return {k: int(v, 2) for k, v in decode_bits(bits, "j").items()}


_SCHEMA = None


def set_fields(bits: str, changes: Dict[str, int]) -> str:
    """Returns the j word with the given fields replaced (pos 0 = leftmost character)."""
    global _SCHEMA
    if _SCHEMA is None:
        from mnisa.schema import load
        _SCHEMA = {f.name: f for f in load("j").fields}
    b = list(bits)
    for name, v in changes.items():
        fd = _SCHEMA[name]
        s = format(v, f"0{fd.width}b")
        assert len(s) == fd.width, (name, v)
        b[fd.pos:fd.pos + fd.width] = list(s)
    return "".join(b)


def l1fields(bits: str) -> Dict[str, int]:
    f = fields(bits)
    return {k: v for k, v in f.items() if k.startswith("l1bm") or k in ("ll",)}

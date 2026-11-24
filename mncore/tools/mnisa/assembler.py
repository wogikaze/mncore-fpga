"""Run the official assemble3 through assemble_corpus.sh (WSL on Windows, bash elsewhere).

The binary is only called, never copied (contract section 9). Its location can be overridden with
the ASSEMBLE3 environment variable on the Linux side.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "assemble_corpus.sh"
WSL_DISTRO = os.environ.get("MNISA_WSL_DISTRO", "Ubuntu")


def to_wsl_path(p) -> str:
    """C:\\a\\b -> /mnt/c/a/b (identity on non-Windows hosts)."""
    s = str(Path(p).resolve())
    if os.name != "nt":
        return s
    s = s.replace("\\", "/")
    if len(s) > 1 and s[1] == ":":
        return f"/mnt/{s[0].lower()}{s[2:]}"
    raise ValueError(f"cannot map {p} to a WSL path")


def run_script(list_file, out_dir, modes: str = "flat", jobs: int | None = None,
               keep_data: bool = False) -> subprocess.CompletedProcess:
    """Assemble every '<id>\\t<path>' of list_file into out_dir (see assemble_corpus.sh)."""
    args = [to_wsl_path(SCRIPT), to_wsl_path(list_file), to_wsl_path(out_dir), modes]
    env = ([] if jobs is None else [f"JOBS={jobs}"]) + (["KEEP_DATA=1"] if keep_data else [])
    env_prefix = ["env"] + env if env else []
    if os.name == "nt":
        cmd = ["wsl", "-d", WSL_DISTRO, "-e"] + env_prefix + ["bash"] + args
    else:
        cmd = env_prefix + ["bash"] + args
    return subprocess.run(cmd, capture_output=True, text=True)


def assemble_sources(sources: dict[str, str], work_dir, modes: str = "flat", keep_data: bool = True) -> Path:
    """Write {id: vsm text} into work_dir, assemble them, return the output directory.

    Per id the directory holds <id>.flat.{asm,csv,err,rc} (see assemble_corpus.sh).
    """
    work = Path(work_dir)
    src = work / "src"
    out = work / "out"
    src.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    lst = work / "list.txt"
    with open(lst, "w", encoding="utf-8", newline="\n") as fh:
        for k, text in sources.items():
            p = src / f"{k}.vsm"
            p.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8", newline="\n")
            fh.write(f"{k}\t{to_wsl_path(p)}\n")
    r = run_script(lst, out, modes, keep_data=keep_data)
    if r.returncode:
        raise RuntimeError(f"assemble_corpus.sh failed ({r.returncode}): {r.stderr.strip()[:500]}")
    return out

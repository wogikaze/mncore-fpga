"""Synthesis resources of the WP12 modules (yosys synth_gowin, no I/O pads).

    python mncore/sim/tb/fpu_tools/synth_stat.py [unit ...]     (default: fpu_fp fpu_mau)

Reads the RTL list and rtl_top of mncore/sim/tb/<unit>/files.txt, runs
`synth_gowin -family gw2a -noiopads` and prints the cell counts (LUT, ALU, DFF, MULT).
The netlist is written to mncore/sim/tb/<unit>/build/stat.json for place-and-route.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
if shutil.which("yosys") is None:
    _oss = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "oss-cad-suite"
    os.environ["PATH"] = os.pathsep.join([str(_oss / "bin"), str(_oss / "lib"), os.environ.get("PATH", "")])


def files_of(unit):
    rtl, top = [], None
    for raw in (ROOT / "mncore" / "sim" / "tb" / unit / "files.txt").read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("rtl_top:"):
            top = line.split(":", 1)[1].strip()
        elif ":" in line.split()[0]:
            continue
        elif not Path(line).name.startswith("tb_"):
            rtl.append(line)
    return rtl, top


def stat(unit):
    rtl, top = files_of(unit)
    build = ROOT / "mncore" / "sim" / "tb" / unit / "build"
    build.mkdir(parents=True, exist_ok=True)
    reads = " ".join(f"read_verilog {f};" for f in rtl)
    script = f"{reads} synth_gowin -family gw2a -noiopads -top {top} -json {build.as_posix()}/stat.json; stat"
    r = subprocess.run(["yosys", "-p", script], cwd=ROOT, text=True, capture_output=True)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-3000:])
        sys.exit(f"{unit}: yosys failed")
    text = r.stdout
    # the last `stat` (after synth_gowin flattened the design) is the one of the script
    sect = text[text.rfind("Printing statistics"):]
    (build / "stat.log").write_text(sect, encoding="utf-8")
    cells = {}
    for m in re.finditer(r"^\s+(\d+)\s+([A-Z][A-Z0-9_]+)\s*$", sect, re.M):
        cells[m.group(2)] = cells.get(m.group(2), 0) + int(m.group(1))
    lut = sum(v for k, v in cells.items() if re.fullmatch(r"LUT[1-4]", k))
    print(f"{unit} (top {top}):")
    print(f"  LUT {lut}  ALU {cells.get('ALU', 0)}  DFF {sum(v for k, v in cells.items() if k.startswith('DFF'))}"
          f"  MULT18X18 {cells.get('MULT18X18', 0)}  MULT36X36 {cells.get('MULT36X36', 0)}"
          f"  MULT9X9 {cells.get('MULT9X9', 0)}  MUX2 {sum(v for k, v in cells.items() if k.startswith('MUX2'))}")
    print("  " + ", ".join(f"{k} {v}" for k, v in sorted(cells.items())))


if __name__ == "__main__":
    for u in sys.argv[1:] or ["fpu_fp", "fpu_mau"]:
        stat(u)

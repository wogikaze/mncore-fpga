"""Reading `.vec` files (mncore/vecgen/FORMAT.md) for the WP12 tools."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


class VecFile:
    def __init__(self, path):
        self.path = Path(path)
        lines = self.path.read_text(encoding="utf-8").splitlines()
        head = lines[0]
        if not head.startswith("# vec v1 "):
            raise ValueError(f"{path}: not a vec v1 file")
        meta, cols = head[len("# vec v1 "):].split(" cols: ", 1)
        self.meta = dict(kv.split("=", 1) for kv in meta.split())
        cin, cout = cols.split(" | ")
        self.cols_in = cin.split()
        self.cols_out = cout.split()
        self.rows = []
        for ln in lines[1:]:
            if not ln.strip():
                continue
            left, right = ln.split(" | ")
            self.rows.append(([int(x, 16) for x in left.split()], [int(x, 16) for x in right.split()]))

    def get(self, k, default=None):
        return self.meta.get(k, default)


def vec_dir(unit, prefer_full=True):
    """mncore/sim/vectors/<unit> if generated, else mncore/sim/vectors_fixed/<unit>."""
    full = ROOT / "mncore" / "sim" / "vectors" / unit
    if prefer_full and full.is_dir() and any(full.glob("*.vec")):
        return full
    return ROOT / "mncore" / "sim" / "vectors_fixed" / unit

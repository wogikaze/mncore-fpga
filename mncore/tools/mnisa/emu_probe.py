#!/usr/bin/env python3
"""Emulator experiments behind spec/isa (run inside WSL; stdlib only).

    wsl -d Ubuntu -e python3 /mnt/c/.../mncore/tools/mnisa/emu_probe.py

Each experiment assembles a tiny program with assemble3 (flat), edits bits of one j word, runs
gpfn3_package_main and compares the 'd get' dumps. The official binaries are only called.
  ll       the 2 leading bits: 01 normal, 11 noforward, 00 nop, 10 rejected
  l1bm     j[187..190] is the MAB number and j[191..194] the reduction opcode
  rsv      j[162..165] (rsv_162 / rsv_164) do not change the result
"""
import os
import subprocess
import sys
import tempfile

ENV = os.path.expanduser(os.environ.get("MNCORE_EMUENV", "~/wgkz/mncore/judge/judge-py/mncore2_emuenv"))
A, EMU = f"{ENV}/assemble3", f"{ENV}/gpfn3_package_main"


def assemble(src, d):
    with open(f"{d}/p.vsm", "w") as fh:
        fh.write(src)
    r = subprocess.run([A, "--instruction-mode", "flat", "--disable-packer", "p.vsm"], cwd=d, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"assemble3 failed: {r.stderr[:300]}")
    return r.stdout.splitlines()


def run(lines, d):
    with open(f"{d}/v.asm", "w") as fh:
        fh.write("\n".join(lines) + "\n")
    if os.path.exists(f"{d}/v.dmp"):
        os.remove(f"{d}/v.dmp")
    r = subprocess.run([EMU, "-i", "v.asm", "-d", "v.dmp"], cwd=d, capture_output=True, text=True)
    dump = open(f"{d}/v.dmp").read() if os.path.exists(f"{d}/v.dmp") else ""
    vals = [ln.split("v:")[1].split(")")[0] for ln in dump.splitlines() if "v:" in ln]
    return r.returncode, r.stderr.strip().splitlines()[:1], vals


def edit(lines, nth_j, edits):
    """edits: {pos: '0101'} applied to the nth j word."""
    out, k = list(lines), -1
    for i, ln in enumerate(out):
        if ln.startswith("j "):
            k += 1
            if k == nth_j:
                b = list(ln[2:])
                for p, v in edits.items():
                    b[p:p + len(v)] = list(v)
                out[i] = "j " + "".join(b)
    return out


def exp_ll(d):
    src = ("d set $lr0n0c0b0m0p0 1 1111111111111111\nd set $lr2n0c0b0m0p0 1 2222222222222222\n"
           "d set $lr16n0c0b0m0p0 1 9999999999999999\n"
           "ipassa $lr0 $nowrite\nipassa $lr2 $lr16\nipassa $aluf $lr32\nnop\nnop\n"
           "d get $lr16n0c0b0m0p0 1\nd get $lr32n0c0b0m0p0 1\n")
    base = assemble(src, d)
    print("ll: second word 'ipassa $lr2 $lr16' with ll = ... -> [$lr16, $lr32 (= $aluf)]")
    for ll in ("01", "11", "00", "10"):
        rc, err, vals = run(edit(base, 1, {0: ll}), d)
        print(f"  ll={ll}: rc={rc} {vals} {err[0][:90] if rc else ''}")


def exp_l1bm(d):
    pre = "".join(f"d set $lr0n0c0b0m{m}p0 1 {m:02x}{m:02x}{m:02x}{m:02x}000000{m:02x}\n" for m in range(16))
    post = "nop\nnop\nnop\nnop\nd get $lb0n0c0b0 1\n"
    print("l1bm: first L1BM word of the result")
    for ins, mods in (("l1bmm@2 $lr0 $lb0", ({187: "0101"}, {191: "0101"})),
                      ("l1bmrsbor $lr0 $lb0", ({187: "0000"}, {191: "0000"}))):
        base = assemble(pre + ins + "\n" + post, d)
        rc, _, ref = run(base, d)
        print(f"  {ins}: {ref}")
        for m in mods:
            rc, err, vals = run(edit(base, 0, m), d)
            print(f"    set {m}: {'same' if vals == ref else vals}")


def exp_rsv(d):
    pre = ("d set $lr0n0c0b0m0p0 2 0123456789abcdef1111222233334444\n"
           "d set $lm0n0c0b0m0p0 2 2023456789abcdef3111222233334444\n")
    post = "nop\nnop\nd get $lr32n0c0b0m0p0 2\nd get $ln32n0c0b0m0p0 2\nd get $lm32n0c0b0m0p0 2\n"
    print("rsv: j[162..165] set to 11 11")
    for ins in ("lpassa $lr0v $lm32v", "lpassa $lm0v $ln32v", "iadd $lm0v $lr0v $ln32v", "fvadd $lm0v $lr0v $lr32v"):
        base = assemble(pre + ins + "\n" + post, d)
        _, _, ref = run(base, d)
        rc, _, vals = run(edit(base, 0, {162: "1111"}), d)
        print(f"  {ins}: {'same' if (rc, vals) == (0, ref) else ('rc=%d' % rc, vals)}")


if __name__ == "__main__":
    which = sys.argv[1:] or ["ll", "l1bm", "rsv"]
    with tempfile.TemporaryDirectory() as tmp:
        for w in which:
            globals()[f"exp_{w}"](tmp)

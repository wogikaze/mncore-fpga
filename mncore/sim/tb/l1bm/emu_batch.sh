#!/bin/bash
# emu_batch.sh <dir> [jobs]   (WP31; after sim/tb/pemem/emu_batch.sh)
#   For every <dir>/<id>.vsm: assemble with the official assemble3 (flat, no packer) and run the
#   official emulator gpfn3_package_main. Writes <id>.asm, <id>.arc (assembler exit code),
#   <id>.aerr, <id>.dmp (emulator 'd get' dump), <id>.erc (emulator exit code), <id>.eout.
#   For every <dir>/<id>.asmin (an edited assembler output): only the emulator runs, on it.
#   The binaries are only called, never copied (contract section 9).
#   Each job works in its own directory under /tmp and copies the results back: the emulator
#   writes its dump in many small writes, which are slow on the Windows drive (/mnt/c).
set -u
# the assembler aborts (SIGABRT) on the words it rejects; without core files WSL does not spend
# minutes capturing each crash (1, not 0: a piped core_pattern ignores 0, 1 skips the dump)
ulimit -c 1
E=${MNCORE_EMUENV:-$HOME/wgkz/mncore/judge/judge-py/mncore2_emuenv}
cd "$1" || exit 1
JOBS=${2:-8}
one() {
  f=$1
  out=$PWD
  t=$(mktemp -d /tmp/wp31emu.XXXXXX)
  case "$f" in
    *.vsm)
      b=${f%.vsm}
      tr -d '\r' < "$f" > "$t/$b.lf"
      (cd "$t" && "$E/assemble3" --instruction-mode flat --disable-packer "$b.lf" > "$b.asm" 2> "$b.aerr"
       echo $? > "$b.arc") ;;
    *.asmin)
      b=${f%.asmin}
      tr -d '\r' < "$f" > "$t/$b.asm"
      : > "$t/$b.aerr"
      echo 0 > "$t/$b.arc" ;;
  esac
  rm -f "$out/$b.dmp" "$out/$b.erc"
  if [ "$(cat "$t/$b.arc")" = 0 ]; then
    (cd "$t" && "$E/gpfn3_package_main" --offchip-memory-init zero -i "$b.asm" -d "$b.dmp" > "$b.eout" 2>&1
     echo $? > "$b.erc")
  fi
  for x in asm arc aerr dmp erc eout; do
    [ -f "$t/$b.$x" ] && cp "$t/$b.$x" "$out/$b.$x"
  done
  rm -rf "$t"
}
export -f one
export E
ls | grep -E '\.(vsm|asmin)$' | xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {}

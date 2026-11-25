#!/bin/bash
# emu_batch.sh <dir> [jobs] [timeout]   (WP34, runs inside WSL; mncore/sim/tb/core/emu_batch.sh with one
#   OpenMP thread per emulator and a longer timeout: the 64-PE tests set and get 50,000 long words)
#   For every <dir>/<id>.vsm: assemble with the official assemble3 (flat, no packer) and, if that
#   worked, run the official emulator gpfn3_package_main. Writes <id>.asm, <id>.arc (assembler exit
#   code), <id>.aerr, <id>.dmp ('d get' dump), <id>.erc (emulator exit code), <id>.eout. The binaries
#   are only called (contract 06 section 9).
set -u
E=${MNCORE_EMUENV:-$HOME/wgkz/mncore/judge/judge-py/mncore2_emuenv}
cd "$1" || exit 1
JOBS=${2:-8}
TMO=${3:-900}
one() {
  b=${1%.vsm}
  tr -d '\r' < "$1" > "$b.lf"
  "$E/assemble3" --instruction-mode flat --disable-packer "$b.lf" > "$b.asm" 2> "$b.aerr"
  echo $? > "$b.arc"
  rm -f "$b.dmp" "$b.erc"
  if [ "$(cat "$b.arc")" = 0 ]; then
    t=$(mktemp -d /tmp/vpeemu.XXXXXX)
    OMP_THREAD_LIMIT=1 timeout "$TMO" "$E/gpfn3_package_main" --offchip-memory-init zero -i "$b.asm" \
        -d "$t/out.dmp" > "$b.eout" 2>&1
    echo $? > "$b.erc"
    [ -f "$t/out.dmp" ] && cp "$t/out.dmp" "$b.dmp"
    rm -rf "$t"
  fi
}
export -f one
export E TMO
ls *.vsm | xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {} 2>/dev/null

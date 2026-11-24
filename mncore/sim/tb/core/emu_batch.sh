#!/bin/bash
# emu_batch.sh <dir> [jobs]   (WP20, runs inside WSL)
#   For every <dir>/<id>.vsm: assemble with the official assemble3 (flat, no packer) and, if that
#   worked and <dir>/<id>.noemu does not exist, run the official emulator gpfn3_package_main.
#   Writes <id>.asm, <id>.arc (assembler exit code), <id>.aerr, <id>.dmp ('d get' dump),
#   <id>.erc (emulator exit code), <id>.eout. The binaries are only called (contract section 9).
set -u
E=${MNCORE_EMUENV:-$HOME/wgkz/mncore/judge/judge-py/mncore2_emuenv}
cd "$1" || exit 1
JOBS=${2:-8}
one() {
  b=${1%.vsm}
  tr -d '\r' < "$1" > "$b.lf"
  "$E/assemble3" --instruction-mode flat --disable-packer "$b.lf" > "$b.asm" 2> "$b.aerr"
  echo $? > "$b.arc"
  rm -f "$b.dmp" "$b.erc"
  if [ "$(cat "$b.arc")" = 0 ] && [ ! -e "$b.noemu" ]; then
    timeout 120 "$E/gpfn3_package_main" --offchip-memory-init zero -i "$b.asm" -d "$b.dmp" > "$b.eout" 2>&1
    echo $? > "$b.erc"
  fi
}
export -f one
export E
ls *.vsm | xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {} 2>/dev/null

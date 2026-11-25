#!/bin/bash
# emu_asm_batch.sh <dir> [jobs]   (WP36, runs inside WSL)
#   For every <dir>/<id>.vsm: assemble with the official assemble3 (flat, no packer) unless
#   <dir>/<id>.asm.in exists (then that edited assembler output is the emulator input), and, unless
#   <dir>/<id>.noemu exists, run the official emulator gpfn3_package_main on it.
#   Writes <id>.asm, <id>.arc (assembler exit code), <id>.aerr, <id>.dmp ('d get' dump), <id>.erc
#   (emulator exit code), <id>.eout. The binaries are only called (contract section 9).
set -u
E=${MNCORE_EMUENV:-$HOME/wgkz/mncore/judge/judge-py/mncore2_emuenv}
cd "$1" || exit 1
JOBS=${2:-8}
one() {
  b=$1
  if [ -e "$b.asm.in" ]; then
    tr -d '\r' < "$b.asm.in" > "$b.asm"; echo 0 > "$b.arc"; : > "$b.aerr"
  else
    tr -d '\r' < "$b.vsm" > "$b.lf"
    "$E/assemble3" --instruction-mode flat --disable-packer "$b.lf" > "$b.asm" 2> "$b.aerr"
    echo $? > "$b.arc"
  fi
  rm -f "$b.dmp" "$b.erc"
  if [ "$(cat "$b.arc")" = 0 ] && [ ! -e "$b.noemu" ]; then
    timeout 1800 "$E/gpfn3_package_main" --offchip-memory-init zero -i "$b.asm" -d "$b.dmp" > "$b.eout" 2>&1
    echo $? > "$b.erc"
  fi
}
export -f one
export E
ls | grep -E '\.(vsm|asm\.in)$' | sed -E 's/\.(vsm|asm\.in)$//' | sort -u | xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {} 2>/dev/null

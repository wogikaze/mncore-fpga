#!/bin/bash
# Runs the official assembler and emulator on every VSM file of a directory (WSL / Linux).
#
# Usage: run_official.sh <dir> [emu_dir]
#   <name>.vsm         flat assembly (--instruction-mode flat --disable-packer) -> <name>.asm,
#                      then the emulator -> <name>.dmp (debug dump of the `d get` statements)
#   <name>.fields.vsm  auto_stride CSV (--print-csv) -> <name>.fields.csv and flat assembly
#                      -> <name>.fields.asm, both with the hazard checker disabled
#                      (only used to read the instruction fields, never executed)
#
# emu_dir defaults to $MNCORE_EMU_DIR, then ~/wgkz/mncore/judge/judge-py/mncore2_emuenv.
# The official binaries are only called here; they are never copied into the repository.
#
# The work happens in a Linux temporary directory: the emulator writes its dump in small
# pieces, which is about 20 times slower on a Windows drive mounted in WSL (/mnt/c).
set -u
# A failing emulator run aborts; do not spend time writing core files.
ulimit -c 0
DIR="$1"
EMU="${2:-${MNCORE_EMU_DIR:-$HOME/wgkz/mncore/judge/judge-py/mncore2_emuenv}}"
JOBS="${VECGEN_JOBS:-8}"
if [ ! -x "$EMU/assemble3" ] || [ ! -x "$EMU/gpfn3_package_main" ]; then
  echo "official tools not found in $EMU" >&2
  exit 2
fi
export EMU

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
find "$DIR" -maxdepth 1 -name '*.vsm' -exec cp {} "$TMP"/ \;

one() {
  f="$1"
  b="${f%.vsm}"
  case "$f" in
    *.fields.vsm)
      "$EMU/assemble3" --disable-packer --disable-hazard-checker --print-csv "$f" > "$b.csv" 2> "$b.csv.err" \
        || echo "CSV_FAIL $(basename "$f")"
      "$EMU/assemble3" --instruction-mode flat --disable-packer --disable-hazard-checker "$f" > "$b.asm" 2> "$b.asm.err" \
        || echo "FLAT_FAIL $(basename "$f")"
      ;;
    *)
      if "$EMU/assemble3" --instruction-mode flat --disable-packer "$f" > "$b.asm" 2> "$b.asm.err"; then
        "$EMU/gpfn3_package_main" --offchip-memory-init zero -i "$b.asm" -d "$b.dmp" > "$b.emu.out" 2> "$b.emu.err" \
          || echo "EMU_FAIL $(basename "$f")"
      else
        echo "ASM_FAIL $(basename "$f")"
      fi
      ;;
  esac
}
export -f one

find "$TMP" -maxdepth 1 -name '*.vsm' -print0 | xargs -0 -r -P "$JOBS" -I{} bash -c 'one "$1"' _ {}
find "$TMP" -maxdepth 1 -type f ! -name '*.vsm' -exec cp {} "$DIR"/ \;
echo "run_official: done"

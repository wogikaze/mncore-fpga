#!/bin/bash
# Assemble a list of .vsm files with the official assemble3 (WSL side).
# Called by verify_corpus.py; can also be run by hand:
#
#   bash assemble_corpus.sh LIST OUTDIR [MODES]
#
#   LIST    text file, one "<id><TAB><path>" per line (paths as seen from WSL)
#   OUTDIR  output directory (created)
#   MODES   space separated subset of "flat auto_stride" (default: "flat")
#
# For each id and mode M (flat -> tag "flat", auto_stride -> tag "as") it writes
#   <id>.<tag>.asm   normal output, without the 'd' and 'r' data lines (they can be huge;
#                    set KEEP_DATA=1 to keep them)
#   <id>.<tag>.csv   --print-csv output, without the 'd' and 'r' lines (same switch)
#   <id>.<tag>.err   stderr of the normal run
#   <id>.<tag>.rc    exit status of the normal run
# plus OUTDIR/VERSION with the assembler revision.
#
# Sources are fed with CR stripped: a Windows checkout (core.autocrlf=true)
# has CRLF line endings, which assemble3 rejects ("Trailing letter after location").
# The assembler binary is only called, never copied (contract section 9).
set -u
ulimit -c 0
A=${ASSEMBLE3:-$HOME/wgkz/mncore/judge/judge-py/mncore2_emuenv/assemble3}
LIST=$1
OUT=$2
MODES=${3:-flat}
JOBS=${JOBS:-$(nproc)}
KEEP_DATA=${KEEP_DATA:-0}
[ -x "$A" ] || { echo "assemble3 not found: $A" >&2; exit 2; }
mkdir -p "$OUT"
echo 'nop' | "$A" --print-asm-version --instruction-mode flat --disable-packer 2>/dev/null \
  | sed -n 's/^# ! assembler version : //p' > "$OUT/VERSION"
if [ "$KEEP_DATA" = 1 ]; then DROP_ASM='^$'; DROP_CSV='^$'; else DROP_ASM='^(d|r) '; DROP_CSV='^(d,|r )'; fi
export A OUT MODES DROP_ASM DROP_CSV

one() {
  local line=$1 id f m tag tmp rc
  id=${line%%$'\t'*}
  f=${line#*$'\t'}
  tmp=$(mktemp)
  tr -d '\r' < "$f" > "$tmp"
  for m in $MODES; do
    case $m in flat) tag=flat ;; auto_stride) tag=as ;; *) echo "bad mode $m" >&2; continue ;; esac
    # assemble3 aborts (SIGABRT) on a parse error; the subshell keeps bash's
    # "Aborted (core dumped)" notice out of the terminal.
    ( "$A" --instruction-mode "$m" --disable-packer "$tmp" > "$tmp.out" 2> "$OUT/$id.$tag.err" ) 2>/dev/null
    rc=$?
    echo $rc > "$OUT/$id.$tag.rc"
    grep -v -E "$DROP_ASM" "$tmp.out" > "$OUT/$id.$tag.asm"
    if [ $rc -eq 0 ]; then
      "$A" --instruction-mode "$m" --disable-packer --print-csv "$tmp" 2>/dev/null | grep -v -E "$DROP_CSV" > "$OUT/$id.$tag.csv"
    else
      : > "$OUT/$id.$tag.csv"
    fi
  done
  rm -f "$tmp" "$tmp.out"
}
export -f one
tr -d '\r' < "$LIST" | xargs -d '\n' -P "$JOBS" -I{} bash -c 'one "$1"' _ {}

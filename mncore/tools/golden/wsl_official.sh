#!/bin/bash
# Runs the official assembler and emulator for golden job directories (WP02). Runs inside WSL.
#
#   wsl_official.sh [-j N] [-t SEC] [-e EMU_DIR] [-k] (-l JOBLIST | JOBDIR...)
#
# A job directory is written by goldenlib.write_official_job:
#   main.vsm    solution (comment-stripped), assembled with assemble3 flat, no packer
#   suffix.vsm  testcase suffix code, assembled the same way (may be empty)
#   parts.txt   emulator input, in order: a path of a raw part, @main or @suffix
#   meta.txt    "key: value" lines for the ndmp header
# Results in the job directory:
#   main.asm, suffix.asm  assembler output, only the j / m / d lines (what the judge keeps, plus d)
#   words.txt             number of j + m words of main + suffix
#   official.ndmp         normalized d get output (norm_gpfn3.py)
#   official.log          assembler / emulator messages when something failed
#   status                ok | asm_fail <rc> | suffix_asm_fail <rc> | emu_fail <rc> | timeout | norm_fail
#   official.asm, official.dmp   only with -k (the full emulator input and its debug dump)
# One progress line "<status> <jobdir>" is printed per job.
set -u

jobs=1
timeout_s=1800
keep=0
list=""
emu=~/wgkz/mncore/judge/judge-py/mncore2_emuenv
while getopts "j:t:e:kl:" opt; do
    case "$opt" in
        j) jobs=$OPTARG ;;
        t) timeout_s=$OPTARG ;;
        e) emu=$OPTARG ;;
        k) keep=1 ;;
        l) list=$OPTARG ;;
        *) echo "usage: $0 [-j N] [-t SEC] [-e EMU_DIR] [-k] (-l JOBLIST | JOBDIR...)" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
emu=${emu/#\~/$HOME}
here=$(cd "$(dirname "$0")" && pwd)

if [ ! -x "$emu/assemble3" ] || [ ! -x "$emu/gpfn3_package_main" ]; then
    echo "error: official tools not found in $emu" >&2
    exit 2
fi

run_job() {
    local job=$1
    local tmp
    tmp=$(mktemp -d /tmp/golden.XXXXXX)
    local st=ok
    local rc
    : > "$job/official.log"
    : > "$job/main.asm"
    : > "$job/suffix.asm"
    # The tools run in subshells whose stderr is dropped: when they abort, bash prints
    # "Aborted (core dumped)" there instead of on the progress stream. (An abort is slow on WSL,
    # because the crash goes through /wsl-capture-crash.)
    if grep -q '[^[:space:]]' "$job/main.vsm" 2>/dev/null; then
        ("$emu/assemble3" --instruction-mode flat --disable-packer "$job/main.vsm" > "$tmp/main.raw" \
            2> "$tmp/asm.err"; exit $?) 2>/dev/null
        rc=$?
        if [ $rc != 0 ]; then
            st="asm_fail $rc"
            cat "$tmp/asm.err" >> "$job/official.log"
        fi
        grep -E '^[jmd] ' "$tmp/main.raw" > "$job/main.asm"
    fi
    if [ "$st" = ok ] && grep -q '[^[:space:]]' "$job/suffix.vsm" 2>/dev/null; then
        ("$emu/assemble3" --instruction-mode flat --disable-packer "$job/suffix.vsm" > "$tmp/suffix.raw" \
            2> "$tmp/sasm.err"; exit $?) 2>/dev/null
        rc=$?
        if [ $rc != 0 ]; then
            st="suffix_asm_fail $rc"
            cat "$tmp/sasm.err" >> "$job/official.log"
        fi
        grep -E '^[jmd] ' "$tmp/suffix.raw" > "$job/suffix.asm"
    fi
    cat "$job/main.asm" "$job/suffix.asm" | grep -cE '^[jm] ' > "$job/words.txt"
    if [ "$st" = ok ]; then
        while IFS= read -r part || [ -n "$part" ]; do
            case "$part" in
                @main) cat "$job/main.asm" ;;
                @suffix) cat "$job/suffix.asm" ;;
                "") ;;
                *) cat "$part"; [ -n "$(tail -c1 "$part")" ] && echo ;;
            esac
        done < "$job/parts.txt" > "$tmp/full.asm"
        (OMP_THREAD_LIMIT=1 timeout "$timeout_s" "$emu/gpfn3_package_main" --offchip-memory-init zero \
            -i "$tmp/full.asm" -d "$tmp/out.dmp" > "$tmp/emu.out" 2>&1; exit $?) 2>/dev/null
        rc=$?
        if [ $rc = 124 ]; then
            st=timeout
        elif [ $rc != 0 ]; then
            st="emu_fail $rc"
            tail -n 40 "$tmp/emu.out" >> "$job/official.log"
        fi
    fi
    if [ "$st" = ok ]; then
        if ! PYTHONDONTWRITEBYTECODE=1 python3 "$here/norm_gpfn3.py" "$tmp/out.dmp" -o "$job/official.ndmp" \
                --meta-file "$job/meta.txt" 2>> "$job/official.log"; then
            st=norm_fail
        fi
    fi
    if [ "$keep" = 1 ]; then
        [ -f "$tmp/full.asm" ] && cp "$tmp/full.asm" "$job/official.asm"
        [ -f "$tmp/out.dmp" ] && cp "$tmp/out.dmp" "$job/official.dmp"
    fi
    echo "$st" > "$job/status"
    rm -rf "$tmp"
    echo "$st $job"
}
export -f run_job
export emu timeout_s keep here

if [ -n "$list" ]; then
    tr -d '\r' < "$list" | grep -v '^$' | xargs -d '\n' -P "$jobs" -I{} bash -c 'run_job "$1"' _ {}
else
    printf '%s\n' "$@" | xargs -d '\n' -P "$jobs" -I{} bash -c 'run_job "$1"' _ {}
fi

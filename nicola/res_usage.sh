#!/bin/bash
# Registers, stack and local memory (spills) of every GPU kernel in the binary.
# Reads the compiled binary only: no job, no GPU, no profiling permissions.
#
# Run it directly on the login node:
#   cd nicola && ./res_usage.sh                       # install_v100 build of this repo
#   cd nicola && ./res_usage.sh /path/to/spa  label   # any other build
#
# Output under nicola/results/res_usage[_label]/:
#   res_usage_full.txt     raw cuobjdump output
#   res_usage_summary.txt  one line per kernel, sorted by registers

NICOLA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"
SPARTA_EXE="${1:-${SPARTA_EXE:-$REPO_ROOT/install_v100/bin/spa_kokkos_cuda}}"
OUT="$NICOLA/results/res_usage${2:+_$2}"

if [ ! -e "$SPARTA_EXE" ]; then
    echo "MISSING: $SPARTA_EXE" >&2
    exit 1
fi
mkdir -p "$OUT"

# A script does not always inherit the module function from the login shell.
if ! command -v cuobjdump >/dev/null 2>&1; then
    if ! type module >/dev/null 2>&1; then
        for f in /etc/profile.d/modules.sh /usr/share/Modules/init/bash; do
            [ -r "$f" ] && . "$f" && break
        done
    fi
    module load cuda12.8/toolkit/12.8.1
fi

cuobjdump -res-usage "$SPARTA_EXE" > "$OUT/res_usage_full.txt" || exit 1

# cuobjdump prints "Function <mangled>:" followed by a line of resources.
# Pair them, demangle, keep only the SPARTA tag of each kernel.
{
    printf "%4s %6s %6s  %s\n" REG STACK LOCAL KERNEL
    awk '/Function /{n=$2; sub(/:$/,"",n); getline; r=$0; gsub(/^ +/,"",r); print r "|" n}' \
        "$OUT/res_usage_full.txt" \
    | c++filt \
    | awk -F'|' '{
        reg=0; st=0; lo=0
        if (match($1,/REG:[0-9]+/))   reg=substr($1,RSTART+4,RLENGTH-4)
        if (match($1,/STACK:[0-9]+/)) st =substr($1,RSTART+6,RLENGTH-6)
        if (match($1,/LOCAL:[0-9]+/)) lo =substr($1,RSTART+6,RLENGTH-6)
        # the tag appears more than once in the demangled name: keep the first
        if (match($2,/Tag[A-Za-z0-9_]+(<[-0-9, ]*>)?/)) tag=substr($2,RSTART,RLENGTH)
        else tag=substr($2,1,110)
        printf "%4d %6d %6d  %s\n", reg, st, lo, tag
      }' \
    | sort -k1,1nr
} > "$OUT/res_usage_summary.txt"

echo "kernels: $(($(wc -l < "$OUT/res_usage_summary.txt") - 1))"
echo
echo "== TagUpdateMove (the move kernel) =="
head -1 "$OUT/res_usage_summary.txt"
grep TagUpdateMove "$OUT/res_usage_summary.txt"
echo
echo "== top 15 by registers =="
head -16 "$OUT/res_usage_summary.txt"
echo
echo "written to $OUT"

#!/bin/bash
# Weak scaling: constant work per unit (node, or GPU with -g), one job per
# unit count. Run on the login node, it calls qsub itself:
#
#   ./submit_weak.sh <arch> [-g] COUNT...
#
#   arch   cpu | v100 | h200 (see submit_common.sh)
#   COUNT  nodes, whole and exclusive; with -g, GPUs of one shared node
#
#   ./submit_weak.sh cpu 1 2 4 8
#   ./submit_weak.sh v100 1 2 4
#   ./submit_weak.sh h200 -g 1 2 4
#
# With k units: fnum = FNUM_1 / k and NPART_PER_UNIT * k particles, created at
# the steady-state count (25.7M with the deck's fnum, results/pre623/long/),
# then WARMUP steps not measured and NSTEPS measured (the last Loop time).
#
# Environment: NPART_PER_UNIT (25700000), FNUM_1 (1.8339e+08), WARMUP (2000),
#   NSTEPS (1000), WALLTIME (00:30:00), BUILD=<tag>, GPU_AWARE=0
#
# Results: results/weak/<arch>[_<tag>]_{n<nodes>|g<gpus>}_<job>/

NPART_PER_UNIT="${NPART_PER_UNIT:-25700000}"
FNUM_1="${FNUM_1:-1.8339e+08}"
WARMUP="${WARMUP:-2000}"
NSTEPS="${NSTEPS:-1000}"
WALLTIME="${WALLTIME:-00:30:00}"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"
. ./submit_common.sh

ARCH="$1"; shift 2>/dev/null
arch_setup "$ARCH" || usage "$SELF"
BY_GPU=0; [ "$1" = -g ] && { BY_GPU=1; shift; }
[ "$ARCH" = cpu ] && [ "$BY_GPU" = 1 ] && { echo "-g is for v100 and h200 only" >&2; exit 1; }
[ $# -ge 1 ] || usage "$SELF"
check_build "$ARCH" "$BUILD"

for N in "$@"; do
    resources "$ARCH" "$BY_GPU" "$N"
    NAME="wk_${ARCH}${UNIT_TAG}${BUILD:+_$BUILD}"
    printf "%-4s %-4s %d particles: " "$ARCH" "$UNIT_TAG" "$(( NPART_PER_UNIT * N ))"
    qsub -N "${NAME:0:15}" -q "$QUEUE" -l "$SELECT" -l "place=$PLACE" -l "walltime=$WALLTIME" \
         -v "ARCH=$ARCH,NODES=$NODES${GPUS:+,GPUS=$GPUS},UNIT=$UNIT${BUILD:+,BUILD=$BUILD},NPART_PER_UNIT=$NPART_PER_UNIT,FNUM_1=$FNUM_1,WARMUP=$WARMUP,NSTEPS=$NSTEPS${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}" \
         weak_job.sh
done

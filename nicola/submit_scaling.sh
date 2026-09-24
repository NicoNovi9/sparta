#!/bin/bash
# Strong scaling: the deck as given, one job per node or GPU count.
# Run on the login node, it calls qsub itself:
#
#   ./submit_scaling.sh <arch> [-g] COUNT...
#
#   arch   cpu | v100 | h200 (see submit_common.sh)
#   COUNT  nodes, whole and exclusive; with -g, GPUs of one shared node
#
#   ./submit_scaling.sh cpu 1 2 4 8
#   ./submit_scaling.sh v100 1 2 4
#   ./submit_scaling.sh h200 -g 1 2 4
#
# Environment: NPART (120000000), NSTEPS (1000), WALLTIME (00:30:00),
#   BUILD=<tag>, BALANCE=part|dyn|time (BAL_EVERY 1000), RANKS_PER_GPU (1),
#   GPU_AWARE=0; a quick run: NPART=30000000 NSTEPS=200 ./submit_scaling.sh h200 -g 1
#
# Results: results/scaling/<arch>[_<tag>]_{n<nodes>|g<gpus>}[...]_<job>/

NSTEPS="${NSTEPS:-1000}"
NPART="${NPART:-120000000}"
WALLTIME="${WALLTIME:-00:30:00}"
RANKS_PER_GPU="${RANKS_PER_GPU:-1}"

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
    resources "$ARCH" "$BY_GPU" "$N" "$RANKS_PER_GPU"
    NAME="sc_${ARCH}${UNIT_TAG}${BUILD:+_$BUILD}"
    printf "%-4s %-4s: " "$ARCH" "$UNIT_TAG"
    qsub -N "${NAME:0:15}" -q "$QUEUE" -l "$SELECT" -l "place=$PLACE" -l "walltime=$WALLTIME" \
         -v "ARCH=$ARCH,NODES=$NODES${GPUS:+,GPUS=$GPUS}${BUILD:+,BUILD=$BUILD},NSTEPS=$NSTEPS,NPART=$NPART,RANKS_PER_GPU=$RANKS_PER_GPU${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}${BALANCE:+,BALANCE=$BALANCE}${BAL_EVERY:+,BAL_EVERY=$BAL_EVERY}" \
         scaling_job.sh
done

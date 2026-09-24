#!/bin/bash
# Saturation: one node (or G GPUs of one node with -g G) with 1..16 times the
# steady-state particles, one job per factor. Does the GPU overtake the CPU
# once it has enough work? Run on the login node, it calls qsub itself:
#
#   ./submit_saturation.sh <arch> [-g G] SCALE...
#
#   arch   cpu | v100 | h200 (see submit_common.sh)
#   SCALE  work factor s: fnum = FNUM_1 / s, NPART_PER_UNIT * s particles
#          per unit (the node, or each of the G GPUs)
#
#   ./submit_saturation.sh cpu 1 2 4 8 16
#   ./submit_saturation.sh v100 1 2 4 8 16
#   ./submit_saturation.sh h200 -g 1 1 2 4 8 16
#
# GPU memory: about 190 bytes per particle plus 0.5 GB per GPU (V100: s = 16
# on a node, 103M particles per GPU, takes 19.2 GB of 32).
#
# Environment: NPART_PER_UNIT (25700000), FNUM_1 (1.8339e+08), WARMUP (2000),
#   NSTEPS (1000), WALLTIME (from 00:30:00 at s <= 4 to 02:00:00 at s = 16),
#   BUILD=<tag>, GPU_AWARE=0
#
# Results: results/saturation/<arch>[_<tag>]_{n1|g<G>}[_x<s>]_<job>/

NPART_PER_UNIT="${NPART_PER_UNIT:-25700000}"
FNUM_1="${FNUM_1:-1.8339e+08}"
WARMUP="${WARMUP:-2000}"
NSTEPS="${NSTEPS:-1000}"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"
. ./submit_common.sh

ARCH="$1"; shift 2>/dev/null
arch_setup "$ARCH" || usage "$SELF"
BY_GPU=0; COUNT=1
if [ "$1" = -g ]; then BY_GPU=1; COUNT="$2"; shift 2; fi
[ "$ARCH" = cpu ] && [ "$BY_GPU" = 1 ] && { echo "-g is for v100 and h200 only" >&2; exit 1; }
[ $# -ge 1 ] || usage "$SELF"
check_build "$ARCH" "$BUILD"
resources "$ARCH" "$BY_GPU" "$COUNT"

for S in "$@"; do
    case "$S" in
        1|2|4) WT=00:30:00 ;;
        8)     WT=01:00:00 ;;
        *)     WT=02:00:00 ;;
    esac
    NAME="sat_${ARCH}${UNIT_TAG}x${S}${BUILD:+_$BUILD}"
    printf "%-4s %-4s x%-2d: " "$ARCH" "$UNIT_TAG" "$S"
    qsub -N "${NAME:0:15}" -q "$QUEUE" -l "$SELECT" -l "place=$PLACE" -l "walltime=${WALLTIME:-$WT}" \
         -v "ARCH=$ARCH,NODES=$NODES${GPUS:+,GPUS=$GPUS},UNIT=$UNIT,SCALE=$S,STUDY=saturation${BUILD:+,BUILD=$BUILD},NPART_PER_UNIT=$NPART_PER_UNIT,FNUM_1=$FNUM_1,WARMUP=$WARMUP,NSTEPS=$NSTEPS${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}" \
         weak_job.sh
done

#!/bin/bash
# A/B regression check: SPARTA's own regression driver (tools/testing/
# regression.py) on every example deck, with a build under test against a
# reference build of the same architecture. Run on the login node, it calls
# qsub itself:
#
#   ./submit_regression.sh <arch>
#
#   arch   cpu (4 ranks) | v100 | h200 (one GPU of a shared node)
#
#   ./submit_regression.sh v100                       # current vs pre623
#   BUILD=mytest REF_BUILD= ./submit_regression.sh cpu    # install_cpu_mytest vs install_cpu
#
# Environment: BUILD (the build under test, default install_<arch>),
#   REF_BUILD (the reference, default pre623: install_<arch>_pre623),
#   ONLY=axi:circle (example dirs), SKIP (decks to leave out, see
#   regression_job.sh), TOL (0.05), WALLTIME (03:00:00)
#
# Results: results/regression/<arch>[_<tag>]_vs_<ref>_<job>/, summary.txt
# first; the logs of every run stay in ../regression_runs/, outside the repo.

REF_BUILD="${REF_BUILD-pre623}"
TOL="${TOL:-0.05}"
WALLTIME="${WALLTIME:-03:00:00}"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"
. ./submit_common.sh

ARCH="$1"
arch_setup "$ARCH" || usage "$SELF"
if [ "$BUILD" = "$REF_BUILD" ]; then
    echo "BUILD and REF_BUILD are the same build (install_${ARCH}${BUILD:+_$BUILD})" >&2; exit 1
fi
check_build "$ARCH" "$BUILD"
check_build "$ARCH" "$REF_BUILD"

if [ "$ARCH" = cpu ]; then
    QUEUE=amd; SELECT="select=1:ncpus=4:mpiprocs=4:mem=100GB:cpu_type=genoaX"
else
    QUEUE=gpu; SELECT="select=1:ncpus=1:mpiprocs=1:mem=100GB:ngpus=1:cpu_type=${CPU_TYPE}:gpu_type=${ARCH}"
fi
NAME="rg_${ARCH}${BUILD:+_$BUILD}"
printf "%-4s install_%s vs install_%s: " "$ARCH" "${ARCH}${BUILD:+_$BUILD}" "${ARCH}${REF_BUILD:+_$REF_BUILD}"
qsub -N "${NAME:0:15}" -q "$QUEUE" -l "$SELECT" -l "walltime=$WALLTIME" \
     -v "ARCH=$ARCH,BUILD=$BUILD,REF_BUILD=$REF_BUILD,TOL=$TOL${ONLY:+,ONLY=$ONLY}${SKIP:+,SKIP=$SKIP}" \
     regression_job.sh

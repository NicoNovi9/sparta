#!/bin/bash
# Submit the A/B regression check of a test build against the build of master,
# with SPARTA's own regression driver on every example deck. Run it on the
# login node, it calls qsub itself:
#
#   cd nicola && ./submit_regression.sh          # CPU and V100, test build pr623
#   cd nicola && ./submit_regression.sh gpu      # one architecture
#
# Optional, from the environment:
#   TEST_BUILD=pr623   the build under test: install_<arch>_<TEST_BUILD>
#   REF_BUILD=         the reference build: install_<arch>[_<REF_BUILD>]
#   ONLY=axi:circle:chem     restrict to these example directories
#   TOL=0.05           relative tolerance per stats column (L1 norm)
#   WALLTIME=03:00:00
#
# Results: nicola/results/regression/<arch>_<test build>_<jobid>/, summary.txt
# first. The logs of every run stay in ../regression_runs/, outside the repo.

ARCHS=(cpu gpu)
TEST_BUILD="${TEST_BUILD:-pr623}"
REF_BUILD="${REF_BUILD:-}"
TOL="${TOL:-0.05}"
WALLTIME="${WALLTIME:-03:00:00}"

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"

if [ $# -ge 1 ]; then
    case "$1" in cpu|gpu) ARCHS=("$1") ;; *) echo "usage: $0 [cpu|gpu]" >&2; exit 1 ;; esac
fi

for ARCH in "${ARCHS[@]}"; do
    case "$ARCH" in
        gpu) INSTALL=install_v100; QUEUE=gpu
             SELECT="select=1:ncpus=1:mpiprocs=1:mem=100GB:ngpus=1:cpu_type=skylake:gpu_type=v100" ;;
        cpu) INSTALL=install_cpu; QUEUE=amd
             SELECT="select=1:ncpus=4:mpiprocs=4:mem=100GB:cpu_type=genoaX" ;;
    esac
    # check both builds before queueing anything
    for b in "$INSTALL${REF_BUILD:+_$REF_BUILD}" "${INSTALL}_$TEST_BUILD"; do
        if [ ! -f "$REPO_ROOT/$b/BUILD_INFO" ]; then
            echo "no build $b: build it first" >&2; exit 1
        fi
    done
    printf "%-4s %s vs %s: " "$ARCH" "${INSTALL}_$TEST_BUILD" "$INSTALL${REF_BUILD:+_$REF_BUILD}"
    qsub -N "rg_${ARCH}_${TEST_BUILD:0:6}" -q "$QUEUE" -l "$SELECT" -l "walltime=$WALLTIME" \
         -v "ARCH=$ARCH,TEST_BUILD=$TEST_BUILD,REF_BUILD=$REF_BUILD,TOL=$TOL${ONLY:+,ONLY=$ONLY}" \
         regression_job.sh
done

#!/bin/bash
# Submit the strong-scaling study: the deck as given, one configuration per
# job. Run it on the login node, it calls qsub itself:
#
#   ./submit_scaling.sh <arch> [-g] COUNT...
#
#   arch   cpu   genoaX node, 192 ranks (one per core)
#          v100  node with 4 V100, one rank per GPU
#          h200  node with 8 H200, one rank per GPU
#   COUNT  number of nodes, whole and exclusive;
#          with -g (v100, h200): number of GPUs on one node, shared with
#          other jobs (whole H200 nodes are almost never free)
#
#   ./submit_scaling.sh cpu 1 2 4 8
#   ./submit_scaling.sh v100 1 2 4
#   ./submit_scaling.sh h200 -g 1 2 4
#
# Optional, from the environment:
#   NPART=120000000 NSTEPS=1000 WALLTIME=00:30:00   (defaults)
#   BALANCE=part|dyn|time   rebalance by particles once / every BAL_EVERY
#                           steps / by measured time every BAL_EVERY steps
#   BUILD=<tag>             use install_<arch>_<tag>, e.g. BUILD=pre623
#   RANKS_PER_GPU=2         two ranks share each GPU
#   GPU_AWARE=0             if GPU runs fail inside MPI calls
#   NPART=30000000 NSTEPS=200 ./submit_scaling.sh h200 -g 1   # a quick run
#
# Results: nicola/results/scaling/<arch>[_<tag>]_{n<nodes>|g<gpus>}[...]_<job>/
# (summary.txt first).

NSTEPS="${NSTEPS:-1000}"
NPART="${NPART:-120000000}"
WALLTIME="${WALLTIME:-00:30:00}"
RANKS_PER_GPU="${RANKS_PER_GPU:-1}"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
usage() { sed -n '5,17p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 1; }

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"

ARCH="$1"; shift || usage
BY_GPU=0
if [ "$1" = -g ]; then BY_GPU=1; shift; fi
[ $# -ge 1 ] || usage

case "$ARCH" in
    cpu)  BUILD_CMD="compile/compile_sparta_mpi.sh"
          [ "$BY_GPU" = 1 ] && { echo "-g is for v100 and h200 only" >&2; exit 1; } ;;
    v100) PER_NODE=4; CPU_TYPE=skylake; BUILD_CMD="compile/compile_sparta_cuda.sh v100" ;;
    h200) PER_NODE=8; CPU_TYPE=turin;   BUILD_CMD="compile/compile_sparta_cuda.sh h200" ;;
    *)    usage ;;
esac
BUILD_CMD="${BUILD:+TAG=$BUILD }$BUILD_CMD"

git_head() {
    local d="$1/.git" h
    h=$(cat "$d/HEAD" 2>/dev/null) || return 1
    case "$h" in
        ref:*) cat "$d/${h#ref: }" 2>/dev/null ;;
        *)     echo "$h" ;;
    esac
}

# Check the binary before queueing anything: a missing or stale build would
# only show up once the jobs start.
INSTALL="$REPO_ROOT/install_${ARCH}${BUILD:+_$BUILD}"
if [ ! -f "$INSTALL/BUILD_INFO" ]; then
    echo "no build $INSTALL, run: $BUILD_CMD" >&2; exit 1
fi
if grep -q "^reduce *1" "$INSTALL/BUILD_INFO"; then
    echo "$INSTALL is a reduce build, the scaling study uses the base one" >&2; exit 1
fi
BUILT="$(awk '/^commit/{print $2}' "$INSTALL/BUILD_INFO")"
HEAD_COMMIT="$(git_head "$REPO_ROOT")"
if [ "$BUILT" != "$HEAD_COMMIT" ]; then
    echo "WARNING: $INSTALL built from ${BUILT:0:8}, checkout is ${HEAD_COMMIT:0:8}."
    echo "         Rebuild ($BUILD_CMD) if src/ changed since."
fi

for N in "$@"; do
    if [ "$ARCH" = cpu ]; then
        NODES=$N; GPUS=; UNIT="node(s)"
        SELECT="select=${N}:ncpus=192:mpiprocs=192:mem=1400GB:cpu_type=genoaX"
        QUEUE=amd; PLACE=scatter:excl
    elif [ "$BY_GPU" = 1 ]; then
        # N GPUs of one node, shared with other jobs
        NODES=1; GPUS=$N; UNIT="GPU(s), 1 node"
        R=$(( N * RANKS_PER_GPU ))
        SELECT="select=1:ncpus=${R}:mpiprocs=${R}:mem=250GB:ngpus=${N}:cpu_type=${CPU_TYPE}:gpu_type=${ARCH}"
        QUEUE=gpu; PLACE=pack
    else
        # N whole nodes, no other jobs on them: timings must not be shared
        NODES=$N; GPUS=$PER_NODE; UNIT="node(s)"
        R=$(( PER_NODE * RANKS_PER_GPU ))
        SELECT="select=${N}:ncpus=${R}:mpiprocs=${R}:mem=250GB:ngpus=${PER_NODE}:cpu_type=${CPU_TYPE}:gpu_type=${ARCH}"
        QUEUE=gpu; PLACE=scatter:excl
    fi
    # job names stay under 15 characters, the limit on older PBS versions
    NAME="sc_${ARCH}$([ "$BY_GPU" = 1 ] && echo g || echo n)${N}${BUILD:+_${BUILD:0:5}}"
    printf "%-4s %2d %s: " "$ARCH" "$N" "$UNIT"
    qsub -N "${NAME:0:15}" -q "$QUEUE" \
         -l "$SELECT" -l "place=$PLACE" -l "walltime=$WALLTIME" \
         -v "ARCH=$ARCH,NODES=$NODES${GPUS:+,GPUS=$GPUS}${BUILD:+,BUILD=$BUILD},NSTEPS=$NSTEPS,NPART=$NPART,RANKS_PER_GPU=$RANKS_PER_GPU${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}${BALANCE:+,BALANCE=$BALANCE}${BAL_EVERY:+,BAL_EVERY=$BAL_EVERY}" \
         scaling_job.sh
done

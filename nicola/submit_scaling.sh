#!/bin/bash
# Submit the strong-scaling study: same deck on CPU and GPU nodes, 1..N nodes.
# Run it on the login node, it calls qsub itself:
#
#   cd nicola && ./submit_scaling.sh          # every ARCH x NODES below
#   cd nicola && ./submit_scaling.sh gpu 2    # a single run
#
# Optional, from the environment:
#   BALANCE=part ./submit_scaling.sh cpu 8  # rebalance by particles
#   GPU_AWARE=0  ./submit_scaling.sh gpu 1  # if GPU runs fail inside MPI
#
# Results: nicola/results/scaling/<arch>_n<nodes>_<jobid>/ (summary.txt first).
# Build both binaries first: compile/compile_sparta_cuda.sh v100 and
# compile/compile_sparta_mpi.sh.

ARCHS=(cpu gpu)
NODE_COUNTS=(1 2 4)
NSTEPS=1000
NPART=120000000
WALLTIME=00:30:00
# One chunk per host, and no other jobs on it: timings must not be shared.
PLACE=scatter:excl

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"

if [ $# -eq 2 ]; then
    ARCHS=("$1"); NODE_COUNTS=("$2")
elif [ $# -ne 0 ]; then
    echo "usage: $0 [cpu|gpu NODES]" >&2; exit 1
fi

git_head() {
    local d="$1/.git" h
    h=$(cat "$d/HEAD" 2>/dev/null) || return 1
    case "$h" in
        ref:*) cat "$d/${h#ref: }" 2>/dev/null ;;
        *)     echo "$h" ;;
    esac
}
HEAD_COMMIT="$(git_head "$REPO_ROOT")"

# Check the binaries before queueing anything: a missing or stale build would
# only show up once the jobs start.
for ARCH in "${ARCHS[@]}"; do
    case "$ARCH" in
        gpu) INSTALL="$REPO_ROOT/install_v100"; BUILD_CMD="compile/compile_sparta_cuda.sh v100" ;;
        cpu) INSTALL="$REPO_ROOT/install_cpu";  BUILD_CMD="compile/compile_sparta_mpi.sh" ;;
        *)   echo "unknown arch: $ARCH" >&2; exit 1 ;;
    esac
    if [ ! -f "$INSTALL/BUILD_INFO" ]; then
        echo "no $ARCH build found, run: $BUILD_CMD" >&2; exit 1
    fi
    BUILT="$(awk '/^commit/{print $2}' "$INSTALL/BUILD_INFO")"
    if [ "$BUILT" != "$HEAD_COMMIT" ]; then
        echo "WARNING: $ARCH binary built from ${BUILT:0:8}, checkout is ${HEAD_COMMIT:0:8}."
        echo "         Rebuild ($BUILD_CMD) if src/ changed since."
    fi
done

for ARCH in "${ARCHS[@]}"; do
    for N in "${NODE_COUNTS[@]}"; do
        case "$ARCH" in
            gpu) QUEUE=gpu
                 SELECT="select=${N}:ncpus=4:mpiprocs=4:mem=250GB:ngpus=4:cpu_type=skylake:gpu_type=v100" ;;
            cpu) QUEUE=amd
                 SELECT="select=${N}:ncpus=192:mpiprocs=192:mem=1400GB:cpu_type=genoaX" ;;
        esac
        printf "%-4s %d node(s): " "$ARCH" "$N"
        qsub -N "scal_${ARCH}_n${N}${BALANCE:+_b}" -q "$QUEUE" \
             -l "$SELECT" -l "place=$PLACE" -l "walltime=$WALLTIME" \
             -v "ARCH=$ARCH,NODES=$N,NSTEPS=$NSTEPS,NPART=$NPART${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}${BALANCE:+,BALANCE=$BALANCE}" \
             scaling_job.sh
    done
done

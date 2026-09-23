#!/bin/bash
# Submit the weak-scaling study: constant work per node, CPU and GPU, 1..N nodes.
# Run it on the login node, it calls qsub itself:
#
#   cd nicola && ./submit_weak.sh            # every ARCH x NODES below
#   cd nicola && ./submit_weak.sh gpu 2      # a single run
#   cd nicola && ./submit_weak.sh cpu 1 8    # one arch, chosen node counts
#
# With k nodes: fnum = FNUM_1 / k and NPART_PER_NODE * k particles, created
# directly at the steady-state count (25.7M per node with the deck's fnum,
# from results/long/long_1215014). WARMUP steps are run first and not measured.
#
# Base versions only: deck balancing, atomics GPU build (install_v100), CPU
# build (install_cpu), one rank per GPU or per core.
#
# Optional, from the environment:
#   WARMUP=5000 NSTEPS=1000 ./submit_weak.sh
#   NPART_PER_NODE=25700000 FNUM_1=1.8339e+08 ./submit_weak.sh
#   GPU_AWARE=0 WALLTIME=01:00:00 ./submit_weak.sh gpu 4
#
# Results: nicola/results/weak/<arch>_n<nodes>_<jobid>/ (summary.txt first).

ARCHS=(cpu gpu)
NODE_COUNTS=(1 2 4)
NPART_PER_NODE="${NPART_PER_NODE:-25700000}"
FNUM_1="${FNUM_1:-1.8339e+08}"
WARMUP="${WARMUP:-2000}"
NSTEPS="${NSTEPS:-1000}"
WALLTIME="${WALLTIME:-00:30:00}"
# One chunk per host, and no other jobs on it: timings must not be shared.
PLACE=scatter:excl

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"

if [ $# -ge 1 ]; then
    case "$1" in cpu|gpu) ;; *) echo "usage: $0 [cpu|gpu [NODES...]]" >&2; exit 1 ;; esac
    ARCHS=("$1")
    [ $# -ge 2 ] && NODE_COUNTS=("${@:2}")
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
    if grep -q "^reduce *1" "$INSTALL/BUILD_INFO"; then
        echo "$INSTALL is a reduce build, the weak scaling uses the base one" >&2; exit 1
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
        # job names stay under 15 characters, the limit on older PBS versions
        printf "%-4s %d node(s), %d particles: " "$ARCH" "$N" "$(( NPART_PER_NODE * N ))"
        qsub -N "wk_${ARCH}${N}" -q "$QUEUE" \
             -l "$SELECT" -l "place=$PLACE" -l "walltime=$WALLTIME" \
             -v "ARCH=$ARCH,NODES=$N,NPART_PER_NODE=$NPART_PER_NODE,FNUM_1=$FNUM_1,WARMUP=$WARMUP,NSTEPS=$NSTEPS${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}" \
             weak_job.sh
    done
done

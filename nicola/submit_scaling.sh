#!/bin/bash
# Submit the strong-scaling study: same deck on CPU and GPU nodes, 1..N nodes.
# Run it on the login node, it calls qsub itself:
#
#   cd nicola && ./submit_scaling.sh          # every ARCH x NODES below
#   cd nicola && ./submit_scaling.sh gpu 2    # a single run
#   cd nicola && ./submit_scaling.sh cpu 1 4  # one arch, chosen node counts
#   cd nicola && ./submit_scaling.sh h200     # 8x H200 per node, base build
#   cd nicola && ./submit_scaling.sh h200g 1 2  # 1 node, 1 and 2 H200 (numbers = GPUs)
#   BUILD=pr623 ./submit_scaling.sh h200g 1 4   # same with install_h200_pr623
#   BUILD=pr623 ./submit_scaling.sh cpu 1       # any arch: install_<arch>_pr623
#
# Optional, from the environment:
#   BALANCE=part ./submit_scaling.sh cpu 8  # rebalance by particles
#   BALANCE=dyn  ./submit_scaling.sh cpu 8  # same, plus rebalancing every 1000 steps
#   BALANCE=time ./submit_scaling.sh cpu 8  # rebalancing by measured compute time
#   GPU_AWARE=0  ./submit_scaling.sh gpu 1  # if GPU runs fail inside MPI
#   NSTEPS=10000 WALLTIME=01:00:00 ./submit_scaling.sh cpu 1 4
#   NPART=30000000 NSTEPS=200 ./submit_scaling.sh h200g 1   # a single quick run
#   RANKS_PER_GPU=2 ./submit_scaling.sh gpu 1   # two ranks share each GPU
#
# Results: nicola/results/scaling/<arch>_n<nodes>_<jobid>/ (summary.txt first).
# Build both binaries first: compile/compile_sparta_cuda.sh v100 and
# compile/compile_sparta_mpi.sh.

ARCHS=(cpu gpu)
NODE_COUNTS=(1 2 4)
NSTEPS="${NSTEPS:-1000}"
NPART="${NPART:-120000000}"
WALLTIME="${WALLTIME:-00:30:00}"
# gpu runs: MPI ranks per GPU, 4 GPUs per node
RANKS_PER_GPU="${RANKS_PER_GPU:-1}"
# One chunk per host, and no other jobs on it: timings must not be shared.
PLACE=scatter:excl

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"

if [ $# -ge 1 ]; then
    case "$1" in cpu|gpu|h200|h200g) ;; *) echo "usage: $0 [cpu|gpu|h200 [NODES...] | h200g [GPUS...]]" >&2; exit 1 ;; esac
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
        gpu) INSTALL="$REPO_ROOT/install_v100${BUILD:+_$BUILD}"; BUILD_CMD="${BUILD:+TAG=$BUILD }compile/compile_sparta_cuda.sh v100" ;;
        h200|h200g) INSTALL="$REPO_ROOT/install_h200${BUILD:+_$BUILD}"; BUILD_CMD="${BUILD:+TAG=$BUILD }compile/compile_sparta_cuda.sh h200" ;;
        cpu) INSTALL="$REPO_ROOT/install_cpu${BUILD:+_$BUILD}";  BUILD_CMD="${BUILD:+TAG=$BUILD }compile/compile_sparta_mpi.sh" ;;
        *)   echo "unknown arch: $ARCH" >&2; exit 1 ;;
    esac
    if [ ! -f "$INSTALL/BUILD_INFO" ]; then
        echo "no $ARCH build found, run: $BUILD_CMD" >&2; exit 1
    fi
    if grep -q "^reduce *1" "$INSTALL/BUILD_INFO"; then
        echo "$INSTALL is a reduce build, the scaling study uses the base one" >&2; exit 1
    fi
    BUILT="$(awk '/^commit/{print $2}' "$INSTALL/BUILD_INFO")"
    if [ "$BUILT" != "$HEAD_COMMIT" ]; then
        echo "WARNING: $ARCH binary built from ${BUILT:0:8}, checkout is ${HEAD_COMMIT:0:8}."
        echo "         Rebuild ($BUILD_CMD) if src/ changed since."
    fi
done

for ARCH in "${ARCHS[@]}"; do
    for N in "${NODE_COUNTS[@]}"; do
        JOB_ARCH=$ARCH; JOB_NODES=$N; EXTRA=; JOB_PLACE=$PLACE
        case "$ARCH" in
            gpu) QUEUE=gpu
                 R=$(( 4 * RANKS_PER_GPU ))
                 SELECT="select=${N}:ncpus=${R}:mpiprocs=${R}:mem=250GB:ngpus=4:cpu_type=skylake:gpu_type=v100" ;;
            h200) QUEUE=gpu
                 R=$(( 8 * RANKS_PER_GPU ))
                 SELECT="select=${N}:ncpus=${R}:mpiprocs=${R}:mem=250GB:ngpus=8:cpu_type=turin:gpu_type=h200" ;;
            h200g) QUEUE=gpu   # N = H200 GPUs on one node, which other jobs share
                 R=$(( N * RANKS_PER_GPU ))
                 SELECT="select=1:ncpus=${R}:mpiprocs=${R}:mem=250GB:ngpus=${N}:cpu_type=turin:gpu_type=h200"
                 JOB_ARCH=h200; JOB_NODES=1; EXTRA=",GPUS=$N"; JOB_PLACE=pack ;;
            cpu) QUEUE=amd
                 SELECT="select=${N}:ncpus=192:mpiprocs=192:mem=1400GB:cpu_type=genoaX" ;;
        esac
        # job names stay under 15 characters, the limit on older PBS versions
        printf "%-5s %d %s: " "$ARCH" "$N" "$([ "$ARCH" = h200g ] && echo "GPU(s), 1 node" || echo "node(s)")"
        qsub -N "sc_${ARCH}${N}${BUILD:+_${BUILD:0:5}}$([ "$RANKS_PER_GPU" != 1 ] && echo "r$RANKS_PER_GPU")${BALANCE:+${BALANCE:0:1}}$([ "$NSTEPS" != 1000 ] && echo "_$((NSTEPS/1000))k")" -q "$QUEUE" \
             -l "$SELECT" -l "place=$JOB_PLACE" -l "walltime=$WALLTIME" \
             -v "ARCH=$JOB_ARCH,NODES=$JOB_NODES$EXTRA${BUILD:+,BUILD=$BUILD},NSTEPS=$NSTEPS,NPART=$NPART${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}${BALANCE:+,BALANCE=$BALANCE}${BAL_EVERY:+,BAL_EVERY=$BAL_EVERY},RANKS_PER_GPU=$RANKS_PER_GPU" \
             scaling_job.sh
    done
done

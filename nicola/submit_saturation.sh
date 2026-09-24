#!/bin/bash
# Submit the saturation study: 1 node, CPU vs GPU, with a steady-state particle
# count 1, 2, 4, 8 and 16 times the deck's (25.7M, from results/long/). Does
# the GPU node overtake the CPU node once it has enough work?
# Run it on the login node, it calls qsub itself:
#
#   cd nicola && ./submit_saturation.sh           # every ARCH x SCALE below
#   cd nicola && ./submit_saturation.sh gpu 16    # a single run
#   cd nicola && ./submit_saturation.sh cpu 8 16  # one arch, chosen scales
#
# SCALE s: fnum = 1.8339e8 / s and 25.7M * s particles, created directly at the
# steady-state count. Same job body as the weak scaling (weak_job.sh): 2000
# warm-up steps, then 1000 measured steps.
#
# GPU memory: about 190 bytes per particle plus 0.5 GB per V100 (measured), so
# SCALE 16 (411M particles, 103M per GPU) needs about 20 GB of the 32 GB.
#
# Base versions only: deck balancing, atomics GPU build (install_v100), CPU
# build (install_cpu), one rank per GPU or per core.
#
# Optional, from the environment:
#   WARMUP=5000 NSTEPS=1000 WALLTIME=03:00:00 ./submit_saturation.sh gpu 16
#   BUILD=pr623 ./submit_saturation.sh gpu 16   # with install_v100_pr623
#
# Results: nicola/results/saturation/<arch>_n1[_x<scale>]_<jobid>/ (summary.txt first).

ARCHS=(cpu gpu)
SCALES=(1 2 4 8 16)
NPART_PER_NODE="${NPART_PER_NODE:-25700000}"
FNUM_1="${FNUM_1:-1.8339e+08}"
WARMUP="${WARMUP:-2000}"
NSTEPS="${NSTEPS:-1000}"
PLACE=scatter:excl

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # qsub from nicola/
REPO_ROOT="$(cd .. && pwd)"

if [ $# -ge 1 ]; then
    case "$1" in cpu|gpu) ;; *) echo "usage: $0 [cpu|gpu [SCALE...]]" >&2; exit 1 ;; esac
    ARCHS=("$1")
    [ $# -ge 2 ] && SCALES=("${@:2}")
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

# Check the binaries before queueing anything.
for ARCH in "${ARCHS[@]}"; do
    case "$ARCH" in
        gpu) INSTALL="$REPO_ROOT/install_v100${BUILD:+_$BUILD}"; BUILD_CMD="${BUILD:+TAG=$BUILD }compile/compile_sparta_cuda.sh v100" ;;
        cpu) INSTALL="$REPO_ROOT/install_cpu${BUILD:+_$BUILD}";  BUILD_CMD="${BUILD:+TAG=$BUILD }compile/compile_sparta_mpi.sh" ;;
        *)   echo "unknown arch: $ARCH" >&2; exit 1 ;;
    esac
    if [ ! -f "$INSTALL/BUILD_INFO" ]; then
        echo "no $ARCH build found, run: $BUILD_CMD" >&2; exit 1
    fi
    if grep -q "^reduce *1" "$INSTALL/BUILD_INFO"; then
        echo "$INSTALL is a reduce build, this study uses the base one" >&2; exit 1
    fi
    BUILT="$(awk '/^commit/{print $2}' "$INSTALL/BUILD_INFO")"
    if [ "$BUILT" != "$HEAD_COMMIT" ]; then
        echo "WARNING: $ARCH binary built from ${BUILT:0:8}, checkout is ${HEAD_COMMIT:0:8}."
        echo "         Rebuild ($BUILD_CMD) if src/ changed since."
    fi
done

for ARCH in "${ARCHS[@]}"; do
    for S in "${SCALES[@]}"; do
        case "$ARCH" in
            gpu) QUEUE=gpu
                 SELECT="select=1:ncpus=4:mpiprocs=4:mem=250GB:ngpus=4:cpu_type=skylake:gpu_type=v100" ;;
            cpu) QUEUE=amd
                 SELECT="select=1:ncpus=192:mpiprocs=192:mem=1400GB:cpu_type=genoaX" ;;
        esac
        # about 21 ms per step at SCALE 1 on either node, growing with SCALE,
        # plus creating the particles; generous, the queue does not charge it
        case "$S" in
            1|2|4) WT=00:30:00 ;;
            8)     WT=01:00:00 ;;
            *)     WT=02:00:00 ;;
        esac
        printf "%-4s x%-2d %d particles: " "$ARCH" "$S" "$(( NPART_PER_NODE * S ))"
        qsub -N "sat_${ARCH}${S}${BUILD:+_${BUILD:0:5}}" -q "$QUEUE" \
             -l "$SELECT" -l "place=$PLACE" -l "walltime=${WALLTIME:-$WT}" \
             -v "ARCH=$ARCH,NODES=1,SCALE=$S,STUDY=saturation,NPART_PER_NODE=$NPART_PER_NODE,FNUM_1=$FNUM_1,WARMUP=$WARMUP,NSTEPS=$NSTEPS${BUILD:+,BUILD=$BUILD}${GPU_AWARE:+,GPU_AWARE=$GPU_AWARE}" \
             weak_job.sh
    done
done

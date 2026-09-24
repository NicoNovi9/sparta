#!/bin/bash
#PBS -j oe

# Job body of the weak-scaling study: the work per node is kept constant.
#
# Do not qsub this directly: submit_weak.sh builds the qsub line and passes
# ARCH, NODES, NPART_PER_NODE, FNUM_1, WARMUP and NSTEPS with -v.
# submit_saturation.sh uses the same body on 1 node, with SCALE and STUDY.
#
# With k nodes the deck runs with fnum = FNUM_1 / k, so the steady-state
# particle count is k times the 1-node one (same gas, each particle stands for
# k times fewer molecules), and
# creates NPART_PER_NODE * k particles: already the steady-state count, so the
# particles only have to redistribute in space, not drain away.
# The run is split in two: WARMUP steps (not measured), then NSTEPS steps whose
# "Loop time" is the measurement.
#
# Base versions only: the deck's own balancing (rcb cell), one rank per GPU
# (install_v100, atomics), one rank per core (install_cpu).
#
#   ARCH=gpu  4 ranks per node, one per V100
#   ARCH=cpu  192 ranks per node (genoaX)

# ---------------------------------------------------------------- paths ----
# qsub is run from nicola/ by submit_weak.sh, so that is $PBS_O_WORKDIR.
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

# Only the files the deck reads (species, collision model, geometry) come from
# the ASML case directory, a sibling checkout that cannot be published.
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"
INPUT_FILE="${INPUT_FILE:-$NICOLA/input/in.sparta.gpu}"

ARCH="${ARCH:-gpu}"
NODES="${NODES:-1}"
NPART_PER_NODE="${NPART_PER_NODE:-25700000}"
FNUM_1="${FNUM_1:-1.8339e+08}"
WARMUP="${WARMUP:-2000}"
NSTEPS="${NSTEPS:-1000}"
# SPARTA assumes GPU-aware MPI by default and does not check. Set 0 if the
# GPU runs crash inside MPI calls: buffers are then staged through the host.
GPU_AWARE="${GPU_AWARE:-1}"

# SCALE multiplies the work per node on top of that (submit_saturation.sh:
# 1 node, 1..16 times the particles). The weak-scaling study keeps SCALE=1.
SCALE="${SCALE:-1}"
# BUILD selects another build, install_<arch>_<BUILD> (e.g. a test branch).
BUILD="${BUILD:-}"
STUDY="${STUDY:-weak}"
K=$(( NODES * SCALE ))
NPART=$(( NPART_PER_NODE * K ))
FNUM=$(awk -v f="$FNUM_1" -v k="$K" 'BEGIN { printf "%.6e", f / k }')

case "$ARCH" in
    gpu) SPARTA_EXE="$REPO_ROOT/install_v100${BUILD:+_$BUILD}/bin/spa_kokkos_cuda"
         RANKS_PER_NODE=4
         KOKKOS_ARGS=(-k on g 4 -sf kk)
         [ "$GPU_AWARE" = 0 ] && KOKKOS_ARGS+=(-pk kokkos gpu/aware no) ;;
    cpu) SPARTA_EXE="$REPO_ROOT/install_cpu${BUILD:+_$BUILD}/bin/spa_kokkos_mpi_only"
         RANKS_PER_NODE=192
         KOKKOS_ARGS=(-k on -sf kk) ;;
    *)   echo "unknown ARCH=$ARCH" >&2; exit 1 ;;
esac
NRANKS=$(( NODES * RANKS_PER_NODE ))
BUILD_INFO="$(dirname "$SPARTA_EXE")/../BUILD_INFO"

SCALE_TAG=; [ "$SCALE" != 1 ] && SCALE_TAG="_x$SCALE"
RUNDIR="$NICOLA/results/$STUDY/${ARCH}${BUILD:+_$BUILD}_n${NODES}${SCALE_TAG}_${PBS_JOBID%%.*}"
mkdir -p "$RUNDIR"
exec > >(tee "$RUNDIR/job.out") 2>&1

for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        exit 1
    fi
done
CASE_DIR="$(cd "$CASE_DIR" && pwd)"

# ---------------------------------------------------------- patched deck ----
# The versioned deck is not modified: fnum is an "equal" variable there, which
# -var cannot override, so the copy gets the value written in. The warm-up run
# goes right before the deck's own run.
DECK="$RUNDIR/in.deck"
sed -e "s/^variable        nP equal .*/variable        nP equal $FNUM     # fnum \/ $K ($STUDY)/" \
    -e "/^run /i run              $WARMUP" \
    "$INPUT_FILE" > "$DECK"
if [ "$(grep -c "^variable        nP equal $FNUM " "$DECK")" != 1 ] ||
   [ "$(grep -c '^run ' "$DECK")" != 2 ]; then
    echo "could not patch the deck" >&2; exit 1
fi

# module purge removes git (it comes from the bitbucket module), so read the
# ref straight out of .git instead of shelling out to git.
git_head() {
    local d="$1/.git" h
    h=$(cat "$d/HEAD" 2>/dev/null) || return 1
    case "$h" in
        ref:*) cat "$d/${h#ref: }" 2>/dev/null ;;
        *)     echo "$h" ;;
    esac
}

# Run from the case directory: the paths written inside the deck are relative
# to it.
cd "$CASE_DIR" || exit 1

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
[ "$ARCH" = gpu ] && module load cuda12.8/toolkit/12.8.1

export OMP_NUM_THREADS=1

{
    echo "job        $PBS_JOBID"
    echo "date       $(date -Is)"
    echo "study      $STUDY"
    echo "scale      $SCALE (work per node x $SCALE)"
    echo "arch       $ARCH"
    echo "nodes      $NODES"
    echo "ranks      $NRANKS ($RANKS_PER_NODE per node)"
    echo "fnum       $FNUM (= $FNUM_1 / $K)"
    echo "npart      $NPART ($(( NPART / NODES )) per node)"
    echo "warmup     $WARMUP steps (not measured)"
    echo "nsteps     $NSTEPS (measured)"
    echo "gpu_aware  $GPU_AWARE"
    echo "balance    deck (rcb cell)"
    echo "input      $INPUT_FILE (patched copy: $DECK)"
    echo "commit     $(git_head "$REPO_ROOT")"
    echo "build      $(tr '\n' ' ' < "$BUILD_INFO" 2>/dev/null)"
    echo "exe        $SPARTA_EXE"
    echo "hosts      $(sort -u "$PBS_NODEFILE" 2>/dev/null | tr '\n' ' ')"
} | tee "$RUNDIR/meta.txt"

# GPU utilisation and power, sampled on the first node only.
SMI_PID=
if [ "$ARCH" = gpu ]; then
    nvidia-smi -L
    nvidia-smi -q | grep -iE "driver version|cuda version"
    nvidia-smi \
      --query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.used,power.draw \
      --format=csv -l 1 > "$RUNDIR/gpu_metrics.csv" &
    SMI_PID=$!
fi

mpirun \
  --mca pml ucx \
  --hostfile "$PBS_NODEFILE" \
  --bind-to core \
  --map-by "ppr:${RANKS_PER_NODE}:node" \
  -np "$NRANKS" \
  "$SPARTA_EXE" \
  "${KOKKOS_ARGS[@]}" \
  -in "$DECK" \
  -var npart "$NPART" \
  -var nsteps "$NSTEPS" \
  -log "$RUNDIR/log.sparta"
STATUS=$?
echo "sparta exit status: $STATUS"

[ -n "$SMI_PID" ] && kill "$SMI_PID" 2>/dev/null

# log.sparta is git-ignored upstream; keep what the plots need in a file that
# is committed. There are two runs: the warm-up and the measured one, whose
# "Loop time" and timing breakdown are the last ones in the file.
{
    cat "$RUNDIR/meta.txt"
    echo
    grep -E '^Created [0-9]+ particles' "$RUNDIR/log.sparta"
    sed -n '/^ *Step /,/^Loop time/p'           "$RUNDIR/log.sparta"
    sed -n '/MPI task timing breakdown/,/^$/p'   "$RUNDIR/log.sparta"
    grep -E '^(Particle moves|Particles:|Cells:)' "$RUNDIR/log.sparta"
} > "$RUNDIR/summary.txt" 2>/dev/null

exit "$STATUS"

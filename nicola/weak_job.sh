#!/bin/bash
#PBS -j oe

# Job body of the weak-scaling study: the work per unit (a node, or a GPU
# with UNIT=gpu) is kept constant.
#
# Do not qsub this directly: submit_weak.sh builds the qsub line and passes
# ARCH, NODES, GPUS, UNIT, NPART_PER_UNIT, FNUM_1, WARMUP and NSTEPS with -v.
# submit_saturation.sh uses the same body on one node, with SCALE and STUDY.
#
# With k units the deck runs with fnum = FNUM_1 / k, so the steady-state
# particle count is k times the one-unit one (same gas, each particle stands
# for k times fewer molecules), and creates NPART_PER_UNIT * k particles:
# already the steady-state count, so the particles only have to redistribute
# in space, not drain away. The run is split in two: WARMUP steps (not
# measured), then NSTEPS steps whose "Loop time" is the measurement.
#
# The deck's own balancing (rcb cell), one rank per GPU or per core.
#
#   ARCH=cpu  192 ranks per node (genoaX), install_cpu binary
#   ARCH=v100 one rank per V100, 4 per node, install_v100 binary
#   ARCH=h200 one rank per H200, 8 per node, install_h200 binary
#   GPUS      GPUs used per node (default: all); fewer = part of one node

# ---------------------------------------------------------------- paths ----
# qsub is run from nicola/ by submit_weak.sh, so that is $PBS_O_WORKDIR.
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

# Only the files the deck reads (species, collision model, geometry) come from
# the ASML case directory, a sibling checkout that cannot be published.
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"
INPUT_FILE="${INPUT_FILE:-$NICOLA/input/in.sparta.gpu}"

ARCH="${ARCH:-v100}"
NODES="${NODES:-1}"
GPUS="${GPUS:-}"
UNIT="${UNIT:-node}"                # node or gpu: what the work is constant per
NPART_PER_UNIT="${NPART_PER_UNIT:-25700000}"
FNUM_1="${FNUM_1:-1.8339e+08}"
WARMUP="${WARMUP:-2000}"
NSTEPS="${NSTEPS:-1000}"
# SPARTA assumes GPU-aware MPI by default and does not check. Set 0 if the
# GPU runs crash inside MPI calls: buffers are then staged through the host.
GPU_AWARE="${GPU_AWARE:-1}"

# SCALE multiplies the work per unit on top of that (submit_saturation.sh:
# one node, 1..16 times the particles). The weak-scaling study keeps SCALE=1.
SCALE="${SCALE:-1}"
# BUILD selects another build, install_<arch>_<BUILD> (e.g. BUILD=pre623).
BUILD="${BUILD:-}"
STUDY="${STUDY:-weak}"

case "$ARCH" in
    v100|h200)
         SPARTA_EXE="$REPO_ROOT/install_${ARCH}${BUILD:+_$BUILD}/bin/spa_kokkos_cuda"
         PER_NODE=$([ "$ARCH" = v100 ] && echo 4 || echo 8)
         GPUS="${GPUS:-$PER_NODE}"
         RANKS_PER_NODE=$GPUS
         KOKKOS_ARGS=(-k on g "$GPUS" -sf kk)
         [ "$GPU_AWARE" = 0 ] && KOKKOS_ARGS+=(-pk kokkos gpu/aware no) ;;
    cpu) SPARTA_EXE="$REPO_ROOT/install_cpu${BUILD:+_$BUILD}/bin/spa_kokkos_mpi_only"
         RANKS_PER_NODE=192
         KOKKOS_ARGS=(-k on -sf kk) ;;
    *)   echo "unknown ARCH=$ARCH" >&2; exit 1 ;;
esac
NRANKS=$(( NODES * RANKS_PER_NODE ))
BUILD_INFO="$(dirname "$SPARTA_EXE")/../BUILD_INFO"

# k: the units the work is multiplied by
if [ "$UNIT" = gpu ]; then UNITS=$GPUS; UNIT_TAG="g$GPUS"; else UNITS=$NODES; UNIT_TAG="n$NODES"; fi
K=$(( UNITS * SCALE ))
NPART=$(( NPART_PER_UNIT * K ))
FNUM=$(awk -v f="$FNUM_1" -v k="$K" 'BEGIN { printf "%.6e", f / k }')

SCALE_TAG=; [ "$SCALE" != 1 ] && SCALE_TAG="_x$SCALE"
RUNDIR="$NICOLA/results/$STUDY/${ARCH}${BUILD:+_$BUILD}_${UNIT_TAG}${SCALE_TAG}_${PBS_JOBID%%.*}"
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
[ "$ARCH" != cpu ] && module load cuda12.8/toolkit/12.8.1

export OMP_NUM_THREADS=1

{
    echo "job        $PBS_JOBID"
    echo "date       $(date -Is)"
    echo "study      $STUDY"
    echo "scale      $SCALE (work per $UNIT x $SCALE)"
    echo "arch       $ARCH"
    echo "nodes      $NODES${GPUS:+, $GPUS GPUs per node}"
    echo "unit       $UNIT (k = $K)"
    echo "ranks      $NRANKS ($RANKS_PER_NODE per node)"
    echo "fnum       $FNUM (= $FNUM_1 / $K)"
    echo "npart      $NPART ($(( NPART / UNITS )) per $UNIT)"
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
if [ "$ARCH" != cpu ]; then
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

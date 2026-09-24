#!/bin/bash
#PBS -j oe

# Job body of the strong-scaling study (fixed problem, 1..N nodes, CPU vs GPU).
#
# Do not qsub this directly: the resources depend on ARCH and NODES, so
# submit_scaling.sh builds the qsub line and passes ARCH, NODES, NSTEPS,
# NPART (and optionally GPU_AWARE) with -v.
#
#   ARCH=gpu  4 ranks per node, one per V100, install_v100 binary
#   ARCH=h200 8 ranks per node, one per H200, install_h200 binary
#   ARCH=cpu  192 ranks per node (genoaX), install_cpu binary

# ---------------------------------------------------------------- paths ----
# qsub is run from nicola/ by submit_scaling.sh, so that is $PBS_O_WORKDIR.
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

# Only the files the deck reads (species, collision model, geometry) come from
# the ASML case directory, a sibling checkout that cannot be published.
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"
INPUT_FILE="${INPUT_FILE:-$NICOLA/input/in.sparta.gpu}"

ARCH="${ARCH:-gpu}"
NODES="${NODES:-1}"
NSTEPS="${NSTEPS:-1000}"
NPART="${NPART:-120000000}"
# SPARTA assumes GPU-aware MPI by default and does not check. Set 0 if the
# GPU runs crash inside MPI calls: buffers are then staged through the host.
GPU_AWARE="${GPU_AWARE:-1}"
# MPI ranks per GPU (gpu runs only); 2 means two ranks share each GPU
RANKS_PER_GPU="${RANKS_PER_GPU:-1}"
# H200 GPUs used per node (h200 only). Full H200 nodes are rarely free, so
# submit_scaling.sh h200g runs 1 node with GPUS=1, 2, ... instead.
GPUS="${GPUS:-8}"
# BUILD selects another build, install_<arch>_<BUILD> (compile with
# TAG=<BUILD>), e.g. a test branch; the run directory is tagged with it.
BUILD="${BUILD:-}"
# BALANCE=part rebalances the grid by particle count right after
# create_particles. The deck only balances by cell count, before particles
# exist, which leaves ranks that own only non-flow cells idle. The deck in
# nicola/input is not modified: a patched copy is written to the run dir.
BALANCE="${BALANCE:-}"
# BALANCE=dyn also rebalances by particles every BAL_EVERY steps during the run.
BAL_EVERY="${BAL_EVERY:-1000}"

case "$ARCH" in
    gpu) SPARTA_EXE="$REPO_ROOT/install_v100${BUILD:+_$BUILD}/bin/spa_kokkos_cuda"
         # 4 V100 per node. RANKS_PER_GPU > 1 oversubscribes each GPU: SPARTA
         # assigns devices as local_rank % ngpus, so the extra ranks share.
         RANKS_PER_NODE=$(( 4 * RANKS_PER_GPU ))
         KOKKOS_ARGS=(-k on g 4 -sf kk)
         [ "$GPU_AWARE" = 0 ] && KOKKOS_ARGS+=(-pk kokkos gpu/aware no) ;;
    h200) SPARTA_EXE="$REPO_ROOT/install_h200${BUILD:+_$BUILD}/bin/spa_kokkos_cuda"
         # up to 8 H200 per node, same device assignment as above
         RANKS_PER_NODE=$(( GPUS * RANKS_PER_GPU ))
         KOKKOS_ARGS=(-k on g "$GPUS" -sf kk)
         [ "$GPU_AWARE" = 0 ] && KOKKOS_ARGS+=(-pk kokkos gpu/aware no) ;;
    cpu) SPARTA_EXE="$REPO_ROOT/install_cpu${BUILD:+_$BUILD}/bin/spa_kokkos_mpi_only"
         RANKS_PER_NODE=192
         KOKKOS_ARGS=(-k on -sf kk) ;;
    *)   echo "unknown ARCH=$ARCH" >&2; exit 1 ;;
esac
NRANKS=$(( NODES * RANKS_PER_NODE ))
BUILD_INFO="$(dirname "$SPARTA_EXE")/../BUILD_INFO"

# Non-default step counts go in the name, so 1000-step and longer runs of the
# same configuration are not mixed up.
STEPS_TAG=; [ "$NSTEPS" != 1000 ] && STEPS_TAG="_s$NSTEPS"
NP_TAG=; [ "$NPART" != 120000000 ] && NP_TAG="_np$(( NPART / 1000000 ))M"
RPG_TAG=; [ "$RANKS_PER_GPU" != 1 ] && RPG_TAG="_r$RANKS_PER_GPU"
# a partial H200 node is named by its GPU count: h200_g2 = 2 H200 on 1 node
NODE_TAG="n$NODES"; [ "$ARCH" = h200 ] && [ "$GPUS" != 8 ] && NODE_TAG="g$GPUS"
RUNDIR="$NICOLA/results/scaling/${ARCH}${BUILD:+_$BUILD}_${NODE_TAG}${BALANCE:+_bal$BALANCE}${STEPS_TAG}${NP_TAG}${RPG_TAG}_${PBS_JOBID%%.*}"
mkdir -p "$RUNDIR"
exec > >(tee "$RUNDIR/job.out") 2>&1

for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        exit 1
    fi
done
CASE_DIR="$(cd "$CASE_DIR" && pwd)"

case "$BALANCE" in
    "") ;;
    part)
        sed '/^create_particles/a balance_grid     rcb part' "$INPUT_FILE" > "$RUNDIR/in.deck"
        if [ "$(grep -c '^balance_grid     rcb part' "$RUNDIR/in.deck")" != 1 ]; then
            echo "could not patch the deck for BALANCE=part" >&2; exit 1
        fi
        INPUT_FILE="$RUNDIR/in.deck" ;;
    dyn)
        # as "part", plus periodic rebalancing during the run: every
        # BAL_EVERY steps, if the busiest rank exceeds the average particle
        # count by more than 10%
        sed -e '/^create_particles/a balance_grid     rcb part'             -e "/^run /i fix              rebal balance $BAL_EVERY 1.1 rcb part"             "$INPUT_FILE" > "$RUNDIR/in.deck"
        if [ "$(grep -c '^balance_grid     rcb part' "$RUNDIR/in.deck")" != 1 ] ||
           [ "$(grep -c '^fix              rebal balance' "$RUNDIR/in.deck")" != 1 ]; then
            echo "could not patch the deck for BALANCE=dyn" >&2; exit 1
        fi
        INPUT_FILE="$RUNDIR/in.deck" ;;
    time)
        # as "dyn", but rebalancing weighs each rank's cells by the compute
        # time it measured (move+sort+collide+modify) since the last check,
        # spread over its cells by particle count. The initial balance stays
        # by particles: no timing exists yet at create_particles.
        sed -e '/^create_particles/a balance_grid     rcb part'             -e "/^run /i fix              rebal balance $BAL_EVERY 1.1 rcb time"             "$INPUT_FILE" > "$RUNDIR/in.deck"
        if [ "$(grep -c '^balance_grid     rcb part' "$RUNDIR/in.deck")" != 1 ] ||
           [ "$(grep -c '^fix              rebal balance .* rcb time' "$RUNDIR/in.deck")" != 1 ]; then
            echo "could not patch the deck for BALANCE=time" >&2; exit 1
        fi
        INPUT_FILE="$RUNDIR/in.deck" ;;
    *)  echo "unknown BALANCE=$BALANCE" >&2; exit 1 ;;
esac

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
    echo "arch       $ARCH"
    echo "nodes      $NODES"
    echo "ranks      $NRANKS ($RANKS_PER_NODE per node$([ "$ARCH" != cpu ] && echo ", $RANKS_PER_GPU per GPU"))"
    echo "nsteps     $NSTEPS"
    echo "npart      $NPART"
    echo "gpu_aware  $GPU_AWARE"
    echo "balance    ${BALANCE:-deck (rcb cell)}$(case "$BALANCE" in dyn|time) echo ", every $BAL_EVERY steps";; esac)"
    echo "input      $INPUT_FILE"
    echo "commit     $(git_head "$REPO_ROOT")"
    echo "build      $(tr '\n' ' ' < "$BUILD_INFO" 2>/dev/null)"
    echo "exe        $SPARTA_EXE"
    echo "hosts      $(sort -u "$PBS_NODEFILE" 2>/dev/null | tr '\n' ' ')"
} | tee "$RUNDIR/meta.txt"

# GPU utilisation and power, sampled on the first node only.
SMI_PID=
if [ "$ARCH" != cpu ]; then
    nvidia-smi -L
    nvidia-smi -q | grep -iE "driver version|cuda version|addressing mode"   # HMM/ATS or not
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
  -in "$INPUT_FILE" \
  -var npart "$NPART" \
  -var nsteps "$NSTEPS" \
  -log "$RUNDIR/log.sparta"
STATUS=$?
echo "sparta exit status: $STATUS"

[ -n "$SMI_PID" ] && kill "$SMI_PID" 2>/dev/null

# log.sparta is git-ignored upstream; keep what the plots need in a file that
# is committed: the per-interval stats (tpcpu = seconds per step over the
# interval) and the timing breakdown.
{
    cat "$RUNDIR/meta.txt"
    echo
    sed -n '/^ *Step /,/^Loop time/p'           "$RUNDIR/log.sparta"
    sed -n '/MPI task timing breakdown/,/^$/p'   "$RUNDIR/log.sparta"
    grep -E '^(Particle moves|Particles:|Cells:)' "$RUNDIR/log.sparta"
} > "$RUNDIR/summary.txt" 2>/dev/null

exit "$STATUS"

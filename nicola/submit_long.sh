#!/bin/bash
#PBS -N sparta_long
#PBS -q gpu
#PBS -l select=1:ncpus=4:mpiprocs=4:mem=250GB:ngpus=4:cpu_type=skylake:gpu_type=v100
#PBS -l walltime=03:00:00
#PBS -j oe

# Long run to find the steady-state particle count of the deck.
#
#   cd nicola && qsub submit_long.sh
#   qsub -v NSTEPS=200000 submit_long.sh        # if 100k steps are not enough
#
# The deck creates its particles with "create_particles H2 n 120000000", which
# with its fnum is about 37 Pa, while the inlet is at 10 Pa and the outlet at
# 5 Pa, so the count drifts down for tens of thousands of steps. Here it is
# created with n 0 instead: SPARTA derives it from nrho and fnum (10 Pa), close
# to the steady state, and the run goes on until the count stops changing.
#
# The versioned deck is not modified; a patched copy goes to the run dir:
#   - stats also print f_X_in[1] and f_X_out[1], particles emitted on that step
#     by the inlet and outlet: at steady state they level off together with np
#   - balance as the best CPU runs: rcb part after create_particles, then
#     fix balance every 1000 steps by measured time (rcb time)
#   - write_restart at the end, so later runs can start from steady state
#   - the grid dumps (velocity, pressure, every 10000 steps) go to OUTDIR
#
# Restart and dumps are large, so they go outside the repository (OUTDIR).
# Everything that gets committed is under results/long/<job>/.

# ---------------------------------------------------------------- paths ----
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"
INPUT_FILE="${INPUT_FILE:-$NICOLA/input/in.sparta.gpu}"

GPU_ARCH="${GPU_ARCH:-v100}"
SPARTA_EXE="${SPARTA_EXE:-$REPO_ROOT/install_$GPU_ARCH/bin/spa_kokkos_cuda}"
BUILD_INFO="$(dirname "$SPARTA_EXE")/../BUILD_INFO"

NSTEPS="${NSTEPS:-100000}"
NPART="${NPART:-0}"              # 0 = from nrho and fnum
BAL_EVERY="${BAL_EVERY:-1000}"
NGPUS=4

JOB="${PBS_JOBID%%.*}"
RUNDIR="$NICOLA/results/long/long_${JOB:-local}"
OUTDIR="${OUTDIR:-$REPO_ROOT/../long_runs/long_${JOB:-local}}"
mkdir -p "$RUNDIR" "$OUTDIR"
exec > >(tee "$RUNDIR/job.out") 2>&1

for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        case "$p" in
            "$SPARTA_EXE") echo "build it first:  nicola/compile/compile_sparta_cuda.sh v100" >&2 ;;
        esac
        exit 1
    fi
done
CASE_DIR="$(cd "$CASE_DIR" && pwd)"
OUTDIR="$(cd "$OUTDIR" && pwd)"

# ---------------------------------------------------------- patched deck ----
DECK="$RUNDIR/in.deck"
sed -e '/^create_particles/a balance_grid     rcb part' \
    -e "/^run /i fix              rebal balance $BAL_EVERY 1.1 rcb time" \
    -e "/^run /a write_restart    $OUTDIR/steady.restart" \
    -e '/^stats_style/s/c_temp/c_temp f_X_in[1] f_X_out[1]/' \
    -e "/^dump /s#output/#$OUTDIR/#" \
    "$INPUT_FILE" > "$DECK"

check() {  # pattern, expected count
    if [ "$(grep -c "$1" "$DECK")" != "$2" ]; then
        echo "could not patch the deck: expected $2 line(s) matching '$1'" >&2
        exit 1
    fi
}
check '^balance_grid     rcb part' 1
check '^fix              rebal balance .* rcb time' 1
check '^write_restart' 1
check '^stats_style.*f_X_in\[1\] f_X_out\[1\]' 1
check "^dump .*$OUTDIR/" 2

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
module load cuda12.8/toolkit/12.8.1

export OMP_NUM_THREADS=1

{
    echo "job        $PBS_JOBID"
    echo "date       $(date -Is)"
    echo "host       $(hostname)"
    echo "gpus       $NGPUS, one rank each"
    echo "nsteps     $NSTEPS"
    echo "npart      $NPART$([ "$NPART" = 0 ] && echo " (from nrho and fnum)")"
    echo "balance    rcb part, then rcb time every $BAL_EVERY steps"
    echo "input      $INPUT_FILE (patched copy: $DECK)"
    echo "outdir     $OUTDIR"
    echo "commit     $(git_head "$REPO_ROOT")"
    echo "build      $(tr '\n' ' ' < "$BUILD_INFO" 2>/dev/null)"
    echo "exe        $SPARTA_EXE"
} | tee "$RUNDIR/meta.txt"

nvidia-smi -L
nvidia-smi \
  --query-gpu=timestamp,index,utilization.gpu,memory.used,power.draw \
  --format=csv -l 10 > "$RUNDIR/gpu_metrics.csv" &
SMI_PID=$!

mpirun \
  --mca pml ucx \
  --hostfile "$PBS_NODEFILE" \
  --bind-to core \
  --map-by "ppr:${NGPUS}:node" \
  -np "$NGPUS" \
  "$SPARTA_EXE" \
  -k on g "$NGPUS" -sf kk \
  -in "$DECK" \
  -var npart "$NPART" \
  -var nsteps "$NSTEPS" \
  -log "$RUNDIR/log.sparta"
STATUS=$?
echo "sparta exit status: $STATUS"

kill "$SMI_PID" 2>/dev/null

# log.sparta is git-ignored upstream; keep the stats history (the convergence
# curve) and the timing breakdown in a file that is committed.
{
    cat "$RUNDIR/meta.txt"
    echo
    grep -E '^Created|^  Created|particles$' "$RUNDIR/log.sparta" | head -5
    sed -n '/^ *Step /,/^Loop time/p'           "$RUNDIR/log.sparta"
    sed -n '/MPI task timing breakdown/,/^$/p'   "$RUNDIR/log.sparta"
    grep -E '^(Particle moves|Particles:|Cells:)' "$RUNDIR/log.sparta"
} > "$RUNDIR/summary.txt" 2>/dev/null

ls -la "$OUTDIR"
exit "$STATUS"

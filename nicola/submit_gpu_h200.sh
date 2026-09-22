#!/bin/bash

#PBS -N sparta_h200
#PBS -q gpu
#PBS -l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:cpu_type=turin:gpu_type=h200
#PBS -l walltime=01:00:00
#PBS -j oe

# Plain run (no profiler) on one H200. Copy of submit_gpu.sh with H200
# resources and defaults: by default the 30M-particle case that failed with
# BadAlloc on collide:nn_last_partner, run for 10,000 steps, since the
# failure was also seen only after a few thousand steps.
#   qsub submit_gpu_h200.sh
#   qsub -v NPART=120000000,NSTEPS=5000 submit_gpu_h200.sh
# Build first: compile/compile_sparta_cuda.sh h200

# ---------------------------------------------------------------- paths ----
# Submit from inside this directory:   cd nicola && qsub submit_gpu_h200.sh
# PBS copies the script to a spool directory, so $0 points nowhere useful.
# $PBS_O_WORKDIR is the directory qsub was run from, i.e. nicola/.
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

# Only the files the deck reads (species, collision model, geometry) come from
# the ASML case directory, a sibling checkout that cannot be published. The
# deck is versioned in nicola/input/, and the binary is built inside this
# repository by nicola/compile/compile_sparta_cuda.sh. Override if it moved:
#   qsub -v CASE_DIR=/path/to/case submit_gpu_h200.sh
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"

# Binary built from this checkout: install_h200 (compile_sparta_cuda.sh h200).
GPU_ARCH="${GPU_ARCH:-h200}"
NPART="${NPART:-30000000}"
NSTEPS="${NSTEPS:-10000}"
SPARTA_EXE="${SPARTA_EXE:-$REPO_ROOT/install_$GPU_ARCH/bin/spa_kokkos_cuda}"
BUILD_INFO="$(dirname "$SPARTA_EXE")/../BUILD_INFO"
INPUT_FILE="${INPUT_FILE:-$NICOLA/input/in.sparta.gpu}"

# Results land under nicola/, so a commit brings them back with git.
RUNDIR="$NICOLA/results/${PBS_JOBNAME:-local}_${PBS_JOBID%%.*}"
mkdir -p "$RUNDIR"

# Capture everything this script prints into the run directory too,
# independently of where PBS drops its own copy of stdout.
exec > >(tee "$RUNDIR/job.out") 2>&1

if [ ! -x "$SPARTA_EXE" ]; then
    echo "MISSING binary: $SPARTA_EXE" >&2
    echo "build it first:  nicola/compile/compile_sparta_cuda.sh $GPU_ARCH" >&2
    exit 1
fi

# Fail loudly rather than letting mpirun report a confusing error.
for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        echo "override with:  qsub -v CASE_DIR=...,SPARTA_EXE=...,INPUT_FILE=... submit_gpu_h200.sh" >&2
        exit 1
    fi
done
CASE_DIR="$(cd "$CASE_DIR" && pwd)"

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
# to it, exactly as when this was submitted by hand from there.
cd "$CASE_DIR" || exit 1

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
module load cuda12.8/toolkit/12.8.1

export OMP_NUM_THREADS=1

echo "HOST=$(hostname)"
echo "COMMIT=$(git_head "$REPO_ROOT")"
echo "EXE=$SPARTA_EXE"
echo "BUILD=$(tr '
' ' ' < "$BUILD_INFO" 2>/dev/null)"
echo "INPUT=$INPUT_FILE"
echo "RUNDIR=$RUNDIR"
echo "NPART=$NPART NSTEPS=$NSTEPS"

nvidia-smi -L

nvidia-smi \
--query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw \
--format=csv \
-l 1 > "$RUNDIR/gpu_metrics.csv" &

SMI_PID=$!

mpirun \
  --mca pml ucx \
  --bind-to core \
  --map-by ppr:1:node \
  -np 1 \
  "$SPARTA_EXE" \
  -k on g 1 \
  -sf kk \
  -in "$INPUT_FILE" \
  -var npart "$NPART" \
  -var nsteps "$NSTEPS" \
  -log "$RUNDIR/log.sparta"

kill ${SMI_PID}

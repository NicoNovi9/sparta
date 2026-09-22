#!/bin/bash

# #PBS -N sparta_cpu_genoax
# #PBS -l select=1:ncpus=72:mpiprocs=72:mem=200GB:cpu_type=icelake
# #PBS -l walltime=00:10:00
# #PBS -j oe

#PBS -N sparta_cpu_genoax
#PBS -l select=1:ncpus=192:mpiprocs=192:mem=1400GB:cpu_type=genoaX
#PBS -l walltime=00:10:00
#PBS -q amd
#PBS -j oe

# ---------------------------------------------------------------- paths ----
# Submit from inside this directory:   cd nicola && qsub submit_cpu.sh
# PBS copies the script to a spool directory, so $0 points nowhere useful.
# $PBS_O_WORKDIR is the directory qsub was run from, i.e. nicola/.
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

# Only the files the deck reads (species, collision model, geometry) come from
# the ASML case directory, a sibling checkout that cannot be published. The
# deck is versioned in nicola/input/, and the binary is built inside this
# repository by nicola/compile/compile_sparta_mpi.sh. Override if it moved:
#   qsub -v CASE_DIR=/path/to/case submit_cpu.sh
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"

SPARTA_EXE="${SPARTA_EXE:-$REPO_ROOT/install_cpu/bin/spa_kokkos_mpi_only}"
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
    echo "build it first:  nicola/compile/compile_sparta_mpi.sh" >&2
    exit 1
fi

# Fail loudly rather than letting mpirun report a confusing error.
for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        echo "override with:  qsub -v CASE_DIR=...,SPARTA_EXE=...,INPUT_FILE=... submit_cpu.sh" >&2
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

export OMP_NUM_THREADS=1

echo "HOST=$(hostname)"
echo "COMMIT=$(git_head "$REPO_ROOT")"
echo "EXE=$SPARTA_EXE"
echo "BUILD=$(tr '
' ' ' < "$BUILD_INFO" 2>/dev/null)"
echo "INPUT=$INPUT_FILE"
echo "RUNDIR=$RUNDIR"

lscpu | grep "Model name"

mpirun \
  --mca pml ucx \
  --bind-to core \
  --map-by ppr:192:node \
  -np 192 \
  "$SPARTA_EXE" \
  -k on \
  -sf kk \
  -in "$INPUT_FILE" \
  -log "$RUNDIR/log.sparta"

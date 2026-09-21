#!/bin/bash
#PBS -N sparta_ncu_v100
#PBS -q gpu
#PBS -l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:cpu_type=skylake:gpu_type=v100
#PBS -l walltime=01:00:00
#PBS -j oe

# ---------------------------------------------------------------- paths ----
# Submit from inside this directory:   cd nicola && qsub submit_gpu_profiling.sh
# PBS copies the script to a spool directory, so $0 points nowhere useful.
# $PBS_O_WORKDIR is the directory qsub was run from, i.e. nicola/.
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

# The binary and the files the deck reads (species, collision model, geometry)
# live in the ASML case directory, a sibling checkout of this repository.
# The deck itself is versioned here, in nicola/input/. Override if it moved:
#   qsub -v CASE_DIR=/path/to/case submit_gpu_profiling.sh
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"

SPARTA_EXE="${SPARTA_EXE:-$CASE_DIR/spa_kokkos_cuda_volta}"
INPUT_FILE="${INPUT_FILE:-$NICOLA/input/in.sparta.gpu}"

# Results land under nicola/, so a commit brings them back with git.
RUNDIR="$NICOLA/results/${PBS_JOBNAME:-local}_${PBS_JOBID%%.*}"
mkdir -p "$RUNDIR"

# Capture everything this script prints into the run directory too,
# independently of where PBS drops its own copy of stdout.
exec > >(tee "$RUNDIR/job.out") 2>&1

# Fail loudly rather than letting mpirun report a confusing error.
for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        echo "override with:  qsub -v CASE_DIR=...,SPARTA_EXE=...,INPUT_FILE=... submit_gpu_profiling.sh" >&2
        exit 1
    fi
done
CASE_DIR="$(cd "$CASE_DIR" && pwd)"

# Run from the case directory: the paths written inside the deck are relative
# to it, exactly as when this was submitted by hand from there.
cd "$CASE_DIR" || exit 1

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
module load cuda12.8/toolkit/12.8.1
module load cuda12.8/nsight/12.8.1

REPORT="$RUNDIR/ncu_report"

echo "JOB_ID=$PBS_JOBID"
echo "HOST=$(hostname)"
echo "COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo "EXE=$SPARTA_EXE"
echo "INPUT=$INPUT_FILE"
echo "RUNDIR=$RUNDIR"

module list
nvidia-smi
ncu --version

ncu \
  --target-processes all \
  --kernel-name-base demangled \
  --kernel-name "regex:.*UpdateKokkos.*" \
  --launch-skip 10 \
  --launch-count 1 \
  --kill yes \
  --set full \
  --export "$REPORT" \
  "$SPARTA_EXE" \
  -k on g 1 \
  -sf kk \
  -in "$INPUT_FILE"

NCU_STATUS=$?
echo "Nsight Compute exit status: $NCU_STATUS"

# The .ncu-rep is binary and large, so it is not what travels back through git.
# Re-import it into plain text next to it: that is the readable artifact.
if [ -f "${REPORT}.ncu-rep" ]; then
    ls -lh "${REPORT}.ncu-rep"
    ncu --import "${REPORT}.ncu-rep" --page details          > "$RUNDIR/ncu_details.txt"  2>&1
    ncu --import "${REPORT}.ncu-rep" --page details --csv    > "$RUNDIR/ncu_details.csv"  2>&1
else
    echo "no report produced at ${REPORT}.ncu-rep"
fi

exit "$NCU_STATUS"

#!/bin/bash
#PBS -N sparta_nsys_v100
#PBS -q gpu
#PBS -l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:cpu_type=skylake:gpu_type=v100
#PBS -l walltime=02:00:00
#PBS -j oe

# Nsight Systems profile + post-processing in one job.
#
# Unlike Nsight Compute, nsys does not need GPU performance-counter
# permissions, so it works without the ERR_NVGPUCTRPERM fix from IT.
#
# Everything readable is left as text under nicola/results/<jobname>_<jobid>/,
# so the numbers come back through git without moving the .nsys-rep itself.

# ---------------------------------------------------------------- paths ----
# Submit from inside this directory:   cd nicola && qsub submit_gpu_nsys.sh
# PBS copies the script to a spool directory, so $0 points nowhere useful.
# $PBS_O_WORKDIR is the directory qsub was run from, i.e. nicola/.
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

# Only the files the deck reads (species, collision model, geometry) come from
# the ASML case directory, a sibling checkout that cannot be published. The
# deck is versioned in nicola/input/, and the binary is built inside this
# repository by nicola/compile/compile_sparta_cuda.sh. Override if it moved:
#   qsub -v CASE_DIR=/path/to/case submit_gpu_nsys.sh
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"

# Binary built from this checkout: install_v100 (compile_sparta_cuda.sh v100);
# GPU_ARCH=v100_pr623 etc. for a tagged build. On an H200: submit_gpu_nsys_h200.sh
GPU_ARCH="${GPU_ARCH:-v100}"
SPARTA_EXE="${SPARTA_EXE:-$REPO_ROOT/install_$GPU_ARCH/bin/spa_kokkos_cuda}"
BUILD_INFO="$(dirname "$SPARTA_EXE")/../BUILD_INFO"
INPUT_FILE="${INPUT_FILE:-$NICOLA/input/in.sparta.gpu}"

# Deck knobs, forwarded with -var. Defaults match the deck.
#   qsub -v NPART=30000000,REORDER=100 submit_gpu_nsys.sh
NPART="${NPART:-120000000}"
REORDER="${REORDER:-0}"

# Free-form tag for the build being profiled, e.g. LABEL=base or LABEL=mb2.
LABEL="${LABEL:-}"

NRANKS="${NRANKS:-1}"
NGPUS="${NGPUS:-1}"

# Profile window. Default captures the whole job, setup included: create_particles
# alone took ~100 s in the last run, which is worth seeing once. To skip setup
# and capture only the time loop:
#   qsub -v NSYS_DELAY=120,NSYS_DURATION=60 submit_gpu_nsys.sh
NSYS_DELAY="${NSYS_DELAY:-0}"
NSYS_DURATION="${NSYS_DURATION:-0}"

# The knobs go in the directory name so A/B runs are told apart at a glance.
RUNDIR="$NICOLA/results/${PBS_JOBNAME:-local}_${PBS_JOBID%%.*}_np${NPART}_ro${REORDER}${LABEL:+_$LABEL}"
mkdir -p "$RUNDIR"
exec > >(tee "$RUNDIR/job.out") 2>&1

if [ ! -x "$SPARTA_EXE" ]; then
    echo "MISSING binary: $SPARTA_EXE" >&2
    echo "build it first:  nicola/compile/compile_sparta_cuda.sh $GPU_ARCH" >&2
    exit 1
fi

for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        echo "override with:  qsub -v CASE_DIR=...,SPARTA_EXE=... submit_gpu_nsys.sh" >&2
        exit 1
    fi
done
CASE_DIR="$(cd "$CASE_DIR" && pwd)"

# ----------------------------------------------------------- provenance ----
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
COMMIT="$(git_head "$REPO_ROOT" || echo unknown)"

cd "$CASE_DIR" || exit 1

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
module load cuda12.8/toolkit/12.8.1
module load cuda12.8/nsight/12.8.1

# Kokkos warns that OMP_PROC_BIND is unset; this only affects host-side code
# but costs nothing to fix.
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=spread
export OMP_PLACES=threads

{
    echo "job        $PBS_JOBID"
    echo "host       $(hostname)"
    echo "date       $(date -Is)"
    echo "commit     $COMMIT"
    echo "exe        $SPARTA_EXE"
    echo "build      $(tr '
' ' ' < "$BUILD_INFO" 2>/dev/null)"
    echo "input      $INPUT_FILE"
    echo "ranks      $NRANKS"
    echo "gpus       $NGPUS"
    echo "npart      $NPART"
    echo "reorder    $REORDER"
    echo "label      $LABEL"
    echo "nsys delay $NSYS_DELAY  duration $NSYS_DURATION"
} | tee "$RUNDIR/meta.txt"

nvidia-smi -L
nvidia-smi -q | grep -iE "driver version|cuda version|addressing mode"   # HMM/ATS or not
nsys --version

# --------------------------------------------------------- sample power ----
nvidia-smi \
  --query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.used,power.draw \
  --format=csv -l 1 > "$RUNDIR/gpu_metrics.csv" &
SMI_PID=$!
trap 'kill $SMI_PID 2>/dev/null' EXIT

# -------------------------------------------------------------- profile ----
NSYS_OPTS=(
    --trace=cuda,nvtx,mpi,osrt
    --sample=process-tree
    --cuda-memory-usage=true
    --force-overwrite=true
)
[ "$NSYS_DELAY"    -gt 0 ] && NSYS_OPTS+=(--delay "$NSYS_DELAY")
[ "$NSYS_DURATION" -gt 0 ] && NSYS_OPTS+=(--duration "$NSYS_DURATION")

# nsys sits inside mpirun, one report per rank, so this also works unchanged
# for the multi-GPU scaling runs.
mpirun \
  --mca pml ucx \
  --bind-to core \
  --map-by "ppr:${NRANKS}:node" \
  -np "$NRANKS" \
  nsys profile "${NSYS_OPTS[@]}" \
    -o "$RUNDIR/nsys_rank%q{OMPI_COMM_WORLD_RANK}" \
    "$SPARTA_EXE" \
    -k on g "$NGPUS" \
    -sf kk \
    -in "$INPUT_FILE" \
    -var npart "$NPART" \
    -var reorder "$REORDER" \
    -log "$RUNDIR/log.sparta"

SPARTA_STATUS=$?
echo "sparta exit status: $SPARTA_STATUS"

kill $SMI_PID 2>/dev/null
trap - EXIT

# ------------------------------------------------------- post-processing ----
# Which reports this nsys version actually has, so a renamed one is visible
# rather than silently missing.
nsys stats --help-reports > "$RUNDIR/nsys_available_reports.txt" 2>&1

REPORTS=(
    cuda_gpu_kern_sum       # kernels ranked by GPU time -- the hot kernels
    cuda_gpu_mem_time_sum   # memcpy time by direction -- the DtoH sync
    cuda_gpu_mem_size_sum   # memcpy volume by direction
    cuda_api_sum            # host-side CUDA API cost
    osrt_sum                # host blocking calls
    mpi_event_sum
    nvtx_sum
)

for REP in "$RUNDIR"/nsys_rank*.nsys-rep; do
    [ -e "$REP" ] || { echo "no .nsys-rep produced"; break; }
    BASE="$(basename "$REP" .nsys-rep)"
    ls -lh "$REP"
    for R in "${REPORTS[@]}"; do
        # A report missing on this version must not abort the others.
        nsys stats --report "$R" --format column "$REP" \
            > "$RUNDIR/${BASE}_${R}.txt" 2>&1 \
            || echo "report $R unavailable"
        nsys stats --report "$R" --format csv "$REP" \
            > "$RUNDIR/${BASE}_${R}.csv" 2>&1 \
            || true
    done
done

# ------------------------------------------------------------- summary ----
# One short file with everything needed to judge the bottleneck, so it can be
# read on screen without opening anything else.
{
    echo "=============== SPARTA timing ==============="
    sed -n '/Loop time of/,/^$/p'            "$RUNDIR/log.sparta" 2>/dev/null
    sed -n '/MPI task timing breakdown/,/^$/p' "$RUNDIR/log.sparta" 2>/dev/null
    echo
    echo "=============== SPARTA counters ==============="
    grep -E '^(Particle moves|Cells touched|SurfColl checks|SurfColl occurs|Collide attempts|Collide occurs)' \
        "$RUNDIR/log.sparta" 2>/dev/null
    grep -E '/particle/step:' "$RUNDIR/log.sparta" 2>/dev/null
    echo
    echo "=============== top GPU kernels ==============="
    head -25 "$RUNDIR"/nsys_rank0_cuda_gpu_kern_sum.txt 2>/dev/null
    echo
    echo "=============== memcpy time by direction ==============="
    head -15 "$RUNDIR"/nsys_rank0_cuda_gpu_mem_time_sum.txt 2>/dev/null
    echo
    echo "=============== memcpy volume by direction ==============="
    head -15 "$RUNDIR"/nsys_rank0_cuda_gpu_mem_size_sum.txt 2>/dev/null
    echo
    echo "=============== GPU utilisation / power ==============="
    awk -F, 'NR>1 {n++; gsub(/[^0-9.]/,"",$3); gsub(/[^0-9.]/,"",$6);
                   u+=$3; p+=$6; if($3+0>mu)mu=$3+0; if($6+0>mp)mp=$6+0}
             END {if(n) printf "samples %d   util avg %.1f%% max %.0f%%   power avg %.0f W max %.0f W\n",
                                n, u/n, mu, p/n, mp}' \
        "$RUNDIR/gpu_metrics.csv" 2>/dev/null
} > "$RUNDIR/summary.txt" 2>&1

echo
cat "$RUNDIR/summary.txt"
echo
echo "artifacts in $RUNDIR:"
ls -lh "$RUNDIR"

exit "$SPARTA_STATUS"

#!/bin/bash
#PBS -N h200_diag
#PBS -q gpu
#PBS -l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:cpu_type=turin:gpu_type=h200
#PBS -l walltime=01:00:00
#PBS -j oe

# One-shot diagnosis of the H200 BadAlloc: is the GPU memory filled by
# SPARTA, or by something else on the node?
#
#   cd nicola && qsub submit_h200_diag.sh
#
# Phases, with GPU memory and the processes on the GPU sampled ~4 times a
# second throughout:
#   1. snapshot of the node: GPU processes, compute mode, driver, GPU
#      monitoring daemons, other jobs, driver (Xid) messages
#   2. IDLE_S seconds with the GPU idle, SPARTA not started
#   3. SPARTA, 30M particles, until the BadAlloc (or NSTEPS), with the Kokkos
#      allocation / free-memory log carrying wall-clock times
#   4. POST_S seconds after SPARTA has exited
#   5. snapshot again, and diag_summary.txt: every moment the GPU was
#      (nearly) full, in which phase, and which processes were on the GPU
# A full GPU in phase 2 or 4 means something other than SPARTA fills it.
#
# Results: nicola/results/h200_diag_<jobid>/, read diag_summary.txt first.

IDLE_S="${IDLE_S:-300}"
POST_S="${POST_S:-60}"
NPART="${NPART:-30000000}"
NSTEPS="${NSTEPS:-10000}"
FULL_MIB="${FULL_MIB:-20000}"   # samples above this count as "filled"

NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"
CASE_DIR="${CASE_DIR:-$REPO_ROOT/../sparta-dsmc-asml/examples/rectangular_duct_with_reservoir_ztest}"
SPARTA_EXE="$REPO_ROOT/install_h200/bin/spa_kokkos_cuda"
INPUT_FILE="$NICOLA/input/in.sparta.gpu"

RUNDIR="$NICOLA/results/h200_diag_${PBS_JOBID%%.*}"
mkdir -p "$RUNDIR"
exec > >(tee "$RUNDIR/job.out") 2>&1

for p in "$CASE_DIR" "$SPARTA_EXE" "$INPUT_FILE"; do
    [ -e "$p" ] || { echo "MISSING: $p" >&2; exit 1; }
done
CASE_DIR="$(cd "$CASE_DIR" && pwd)"

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
module load cuda12.8/toolkit/12.8.1
export OMP_NUM_THREADS=1

now() { date +%H:%M:%S.%3N; }
phase() { echo "$(now) $1" | tee -a "$RUNDIR/phases.txt"; }

# ------------------------------------------------------------------ build ----
# Rebuild the Kokkos Tools logger here, so no separate step is needed.
bash "$NICOLA/tools/build_kp_big_alloc.sh" || { echo "logger build failed" >&2; exit 1; }
export KOKKOS_TOOLS_LIBS="$NICOLA/tools/kp_big_alloc.so" KP_BIG_ALLOC_MB=100 KP_MEMWATCH_GB=1

# --------------------------------------------------------------- snapshot ----
snapshot() {
    local f="$RUNDIR/node_$1.txt"
    {
        echo "== $1  $(date -Is)  $(hostname)"
        echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
        echo; echo "== nvidia-smi"; nvidia-smi
        echo; echo "== driver / modes"
        nvidia-smi -q | grep -iE "driver version|cuda version|addressing mode|persistence mode|compute mode|mig mode" -A1
        echo; echo "== nvidia-smi -q -d PIDS,MEMORY"; nvidia-smi -q -d PIDS,MEMORY
        echo; echo "== GPU-related processes on the node (all users)"
        ps -eo user,pid,ppid,etime,args | grep -iE "dcgm|hostengine|nvidia|nv-|nhc|health|gpu|exporter|prometheus|telegraf|collectd" | grep -v grep
        echo; echo "== jobs on this node"; pbsnodes "$(hostname -s)" 2>&1 | grep -iE "state|jobs|resources_assigned.ngpus|resources_available.ngpus"
        echo; echo "== driver messages (Xid / NVRM)"; (dmesg -T 2>&1 || journalctl -k 2>&1) | grep -iE "xid|nvrm" | tail -30
        echo; echo "== load / host memory"; uptime; free -g
    } > "$f" 2>&1
    echo "snapshot -> $f"
}

phase snapshot
snapshot start

# --------------------------------------------------------------- monitors ----
# device-wide memory: includes every process on this GPU, not only SPARTA
nvidia-smi --query-gpu=timestamp,memory.used,memory.total,utilization.gpu \
           --format=csv,noheader,nounits -lms 250 > "$RUNDIR/gpu_mem.csv" &
MON1=$!
# which processes hold memory on this GPU, and how much
(
    while true; do
        ts=$(now)
        out=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory \
                         --format=csv,noheader,nounits 2>&1)
        if [ -z "$out" ]; then echo "$ts, -, none, 0"; else echo "$out" | sed "s/^/$ts, /"; fi
        sleep 0.25
    done
) > "$RUNDIR/gpu_apps.csv" &
MON2=$!
trap 'kill $MON1 $MON2 2>/dev/null' EXIT

# ------------------------------------------------------------------- idle ----
phase idle
echo "GPU idle for ${IDLE_S}s, SPARTA not running"
sleep "$IDLE_S"

# ----------------------------------------------------------------- sparta ----
cd "$CASE_DIR" || exit 1
phase sparta
mpirun \
  --mca pml ucx \
  --bind-to core \
  --map-by ppr:1:node \
  -x KOKKOS_TOOLS_LIBS -x KP_BIG_ALLOC_MB -x KP_MEMWATCH_GB \
  -np 1 \
  "$SPARTA_EXE" \
  -k on g 1 \
  -sf kk \
  -in "$INPUT_FILE" \
  -var npart "$NPART" \
  -var nsteps "$NSTEPS" \
  -log "$RUNDIR/log.sparta"
STATUS=$?
phase "post (sparta exit status $STATUS)"

# ------------------------------------------------------------------- post ----
echo "GPU monitored for ${POST_S}s more, SPARTA gone"
sleep "$POST_S"
phase end
kill $MON1 $MON2 2>/dev/null
trap - EXIT
sleep 1

snapshot end

# ---------------------------------------------------------------- summary ----
# Group the samples above FULL_MIB into episodes, label each with its phase
# and list the processes seen on the GPU during it.
awk -v full="$FULL_MIB" -v phases="$RUNDIR/phases.txt" -v apps="$RUNDIR/gpu_apps.csv" '
function secs(t,   a) { split(t, a, ":"); return a[1]*3600 + a[2]*60 + a[3] }
BEGIN {
    FS = ", *"
    np = 0
    while ((getline line < phases) > 0) { split(line, p, " "); pt[np] = secs(p[1]); pn[np] = p[2]; np++ }
    na = 0
    while ((getline line < apps) > 0) {
        n = split(line, f, ", *"); at[na] = secs(f[1]); ad[na] = f[2] " " f[3] " " f[4] " MiB"; na++
    }
    ne = 0; inep = 0
}
{
    split($1, d, " "); t = secs(d[2]); used = $2 + 0
    if (used > full) {
        if (!inep) { ne++; es[ne] = t; ets[ne] = d[2]; emax[ne] = 0; inep = 1 }
        ee[ne] = t; ete[ne] = d[2]; if (used > emax[ne]) emax[ne] = used
    } else inep = 0
}
END {
    printf "samples above %d MiB grouped into %d episode(s)\n\n", full, ne
    for (i = 1; i <= ne; i++) {
        ph = "before snapshot"
        for (k = 0; k < np; k++) if (es[i] >= pt[k]) ph = pn[k]
        printf "episode %d: %s -> %s  max %d MiB  phase: %s\n", i, ets[i], ete[i], emax[i], ph
        delete seen
        for (j = 0; j < na; j++)
            if (at[j] >= es[i] - 0.5 && at[j] <= ee[i] + 0.5 && !(ad[j] in seen)) {
                seen[ad[j]] = 1; printf "    on GPU: %s\n", ad[j]
            }
    }
    printf "\nphases:\n"
    for (k = 0; k < np; k++) printf "  %s\n", pn[k]
}' "$RUNDIR/gpu_mem.csv" > "$RUNDIR/diag_summary.txt"

{
    echo
    echo "phase times:"; cat "$RUNDIR/phases.txt"
    echo
    echo "free-memory jumps seen inside SPARTA (kp):"
    grep "^\[kp\] ====" "$RUNDIR/job.out"
    echo
    echo "SPARTA end:"
    grep -E "BadAlloc|what\(\)|Loop time" "$RUNDIR/job.out"
} >> "$RUNDIR/diag_summary.txt"

echo
cat "$RUNDIR/diag_summary.txt"

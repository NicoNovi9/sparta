#!/bin/bash
#PBS -j oe

# Job body of the A/B regression check: SPARTA's own regression driver
# (tools/testing/regression.py) on every examples/*/in.* deck, with a
# reference build and a test build of the same architecture.
#
# Do not qsub this directly: submit_regression.sh passes ARCH, REF_BUILD,
# TEST_BUILD, ONLY and TOL with -v.
#
# regression.py writes a gold-standard log the first time it meets a deck and
# compares every later run with it, column by column of the stats output. So:
#   pass 1, reference build: writes the gold logs, then runs each deck again
#           and compares -> how far two runs of the same build differ
#   pass 2, test build:      compared with the reference gold logs
# DSMC is stochastic and the two builds draw random numbers in a different
# order, so the comparison uses a relative tolerance (TOL, L1 norm), and the
# failures of pass 2 are read next to those of pass 1.
#
# The examples are copied outside the repository, where the logs of every run
# stay for inspection; what gets committed is under results/regression/.

# ---------------------------------------------------------------- paths ----
NICOLA="${PBS_O_WORKDIR:-$PWD}"
REPO_ROOT="$(cd "$NICOLA/.." && pwd)"

ARCH="${ARCH:-gpu}"
REF_BUILD="${REF_BUILD:-}"          # "" = install_<arch>, the build of master
TEST_BUILD="${TEST_BUILD:-pr623}"   # install_<arch>_<TEST_BUILD>
ONLY="${ONLY:-}"                    # example dirs to restrict to, ":" separated
TOL="${TOL:-0.05}"

case "$ARCH" in
    gpu) EXE=spa_kokkos_cuda; INSTALL=install_v100
         LAUNCH_ARGS="-np 1"; KOKKOS_ARGS="-k on g 1 -sf kk" ;;
    cpu) EXE=spa_kokkos_mpi_only; INSTALL=install_cpu
         LAUNCH_ARGS="-np 4"; KOKKOS_ARGS="-k on -sf kk" ;;
    *)   echo "unknown ARCH=$ARCH" >&2; exit 1 ;;
esac
REF_EXE="$REPO_ROOT/${INSTALL}${REF_BUILD:+_$REF_BUILD}/bin/$EXE"
TEST_EXE="$REPO_ROOT/${INSTALL}_${TEST_BUILD}/bin/$EXE"

JOB="${PBS_JOBID%%.*}"
RUNDIR="$NICOLA/results/regression/${ARCH}_${TEST_BUILD}_${JOB:-local}"
WORK="$REPO_ROOT/../regression_runs/${ARCH}_${TEST_BUILD}_${JOB:-local}"
mkdir -p "$RUNDIR" "$WORK"
exec > >(tee "$RUNDIR/job.out") 2>&1

for p in "$REF_EXE" "$TEST_EXE" "$REPO_ROOT/tools/testing/regression.py"; do
    if [ ! -e "$p" ]; then
        echo "MISSING: $p" >&2
        exit 1
    fi
done

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
build_info() { tr '\n' ' ' < "$(dirname "$1")/../BUILD_INFO" 2>/dev/null; }

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
[ "$ARCH" = gpu ] && module load cuda12.8/toolkit/12.8.1
export OMP_NUM_THREADS=1

# a fresh copy of the examples: the gold logs are made by pass 1 of this job
rm -rf "$WORK/examples"
cp -r "$REPO_ROOT/examples" "$WORK/examples"

{
    echo "job        $PBS_JOBID"
    echo "date       $(date -Is)"
    echo "host       $(hostname)"
    echo "arch       $ARCH ($LAUNCH_ARGS, $KOKKOS_ARGS)"
    echo "reference  $REF_EXE"
    echo "           $(build_info "$REF_EXE")"
    echo "test       $TEST_EXE"
    echo "           $(build_info "$TEST_EXE")"
    echo "tolerance  $TOL relative, L1 norm per stats column"
    echo "only       ${ONLY:-all examples}"
    echo "commit     $(git_head "$REPO_ROOT")"
    echo "work dir   $WORK/examples"
} | tee "$RUNDIR/meta.txt"
[ "$ARCH" = gpu ] && nvidia-smi -L

OPTS=(-logread "$REPO_ROOT/tools/testing" olog
      -error_norm L1 -relative_error True -tolerance "$TOL")
[ -n "$ONLY" ] && OPTS+=(-only ${ONLY//:/ })

run_pass() {  # name, executable
    echo "==== pass $1: $2"
    python3 "$REPO_ROOT/tools/testing/regression.py" ab \
        "mpirun $LAUNCH_ARGS --bind-to core $2 $KOKKOS_ARGS" \
        "$WORK/examples" "${OPTS[@]}" > "$RUNDIR/$1.out" 2>&1
    grep -cE "^\*\*\* test .* passed" "$RUNDIR/$1.out" | sed "s/^/passed: /"
    grep -cE "^!!! test .* FAILED" "$RUNDIR/$1.out" | sed "s/^/failed: /"
}

run_pass ref  "$REF_EXE"
run_pass test "$TEST_EXE"

# one line per deck: result of the reference against itself, and of the test
# build against the reference, with the worst column of each
python3 - "$RUNDIR/ref.out" "$RUNDIR/test.out" > "$RUNDIR/summary.txt" <<'EOF'
import re, sys

def parse(path):
    res, test, worst = {}, None, (0.0, "")
    for line in open(path, errors="replace"):
        m = re.match(r"test = (\S+)", line)
        if m:
            test, worst = m.group(1), (0.0, "")
            continue
        m = re.match(r"(\S+)\s+error (\S+) wrt norm", line)
        if m and test and "CPU" not in m.group(1):   # timing columns
            e = float(m.group(2))
            if e > worst[0]:
                worst = (e, m.group(1))
        m = re.match(r"(\*\*\*|!!!) test (\S+) (passed|FAILED)", line)
        if m:
            res[m.group(2)] = (m.group(3), worst)
    return res

ref, tst = parse(sys.argv[1]), parse(sys.argv[2])
print(f"{'deck':42s} {'ref vs ref':>22s} {'test vs ref':>22s}")
for t in sorted(set(ref) | set(tst)):
    cell = lambda r: "missing" if r is None else f"{r[0]:6s} {r[1][0]:8.2%} {r[1][1][:6]}"
    flag = "  <--" if tst.get(t, ("",))[0] == "FAILED" and ref.get(t, ("",))[0] == "passed" else ""
    print(f"{t:42s} {cell(ref.get(t)):>22s} {cell(tst.get(t)):>22s}{flag}")
nr = sum(1 for r in ref.values() if r[0] == "passed")
nt = sum(1 for r in tst.values() if r[0] == "passed")
print(f"\npassed: reference {nr}/{len(ref)}, test {nt}/{len(tst)}")
print("<-- : passes against itself with the reference build, fails with the test build")
EOF
cat "$RUNDIR/summary.txt"

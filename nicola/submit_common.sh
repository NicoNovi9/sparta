# Shared by the submit_*.sh launchers: architectures, PBS resources and build
# checks. Sourced, not run; the caller has cd'ed to nicola/ and set REPO_ROOT.
#
# Every launcher takes the same arguments:
#
#   ./submit_<study>.sh <arch> [-g] ...
#
#   arch   cpu   genoaX node, 192 ranks (one per core)
#          v100  node with 4 V100, one rank per GPU
#          h200  node with 8 H200, one rank per GPU
#   -g     (v100, h200) count GPUs of one node, shared with other jobs,
#          instead of whole exclusive nodes: whole H200 nodes are almost
#          never free
#   BUILD=<tag>   use install_<arch>_<tag> instead of install_<arch>

# arch_setup ARCH -> PER_NODE, CPU_TYPE, COMPILE (the build command)
arch_setup() {
    case "$1" in
        cpu)  PER_NODE=;  CPU_TYPE=genoaX;  COMPILE="compile/compile_sparta_mpi.sh" ;;
        v100) PER_NODE=4; CPU_TYPE=skylake; COMPILE="compile/compile_sparta_cuda.sh v100" ;;
        h200) PER_NODE=8; CPU_TYPE=turin;   COMPILE="compile/compile_sparta_cuda.sh h200" ;;
        *)    return 1 ;;
    esac
}

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

# check_build ARCH [TAG]: stop if install_<arch>[_<tag>] is missing or is a
# reduce build, warn if it was built from another commit than the checkout.
# Call after arch_setup.
check_build() {
    local inst="$REPO_ROOT/install_$1${2:+_$2}" cmd="${2:+TAG=$2 }$COMPILE" built
    if [ ! -f "$inst/BUILD_INFO" ]; then
        echo "no build $inst, run: $cmd" >&2; exit 1
    fi
    if grep -q "^reduce *1" "$inst/BUILD_INFO"; then
        echo "$inst is a reduce build, the studies use the base one" >&2; exit 1
    fi
    built="$(awk '/^commit/{print $2}' "$inst/BUILD_INFO")"
    if [ "$built" != "$(git_head "$REPO_ROOT")" ]; then
        echo "WARNING: $inst built from ${built:0:8}, checkout is $(git_head "$REPO_ROOT" | cut -c1-8)."
        echo "         Rebuild ($cmd) if src/ changed since."
    fi
}

# resources ARCH BY_GPU N [RANKS_PER_GPU] -> NODES, GPUS, UNIT, UNIT_TAG,
#   QUEUE, SELECT, PLACE
# N whole nodes, exclusive (timings must not be shared), or with BY_GPU=1
# N GPUs of one node, shared. Call after arch_setup.
resources() {
    local arch=$1 by_gpu=$2 n=$3 rpg=${4:-1} r
    if [ "$arch" = cpu ]; then
        NODES=$n; GPUS=; UNIT=node; UNIT_TAG="n$n"
        QUEUE=amd; PLACE=scatter:excl
        SELECT="select=${n}:ncpus=192:mpiprocs=192:mem=1400GB:cpu_type=genoaX"
    elif [ "$by_gpu" = 1 ]; then
        NODES=1; GPUS=$n; UNIT=gpu; UNIT_TAG="g$n"
        r=$(( n * rpg ))
        QUEUE=gpu; PLACE=pack
        SELECT="select=1:ncpus=${r}:mpiprocs=${r}:mem=250GB:ngpus=${n}:cpu_type=${CPU_TYPE}:gpu_type=${arch}"
    else
        NODES=$n; GPUS=$PER_NODE; UNIT=node; UNIT_TAG="n$n"
        r=$(( PER_NODE * rpg ))
        QUEUE=gpu; PLACE=scatter:excl
        SELECT="select=${n}:ncpus=${r}:mpiprocs=${r}:mem=250GB:ngpus=${PER_NODE}:cpu_type=${CPU_TYPE}:gpu_type=${arch}"
    fi
}

# usage FILE: print the comment block at the top of FILE (after the shebang)
usage() {
    sed -n '2,/^[^#]/p' "$1" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 1
}

#!/usr/bin/env bash
# Build SPARTA (Kokkos/CUDA) from THIS checkout, on the login node.
#
#   cd nicola/compile
#   ./compile_sparta_cuda.sh v100          # incremental: only changed files
#   ./compile_sparta_cuda.sh h200
#   ./compile_sparta_cuda.sh v100 clean    # wipe the build and start over
#   REDUCE=1 ./compile_sparta_cuda.sh v100 # counters by parallel_reduce, into
#                                          # build_v100_reduce/install_v100_reduce
#
# Nothing is cloned and nothing outside this repository is touched.
# Each architecture has its own build and install tree at the repo root:
#
#   build_<arch>/                          cmake build tree
#   install_<arch>/bin/spa_kokkos_cuda     the binary the submit scripts use
#   install_<arch>/BUILD_INFO              commit and date of the build

set -euo pipefail

ARCH="${1:-}"
MODE="${2:-}"

case "$ARCH" in
    v100) KOKKOS_ARCH="-DKokkos_ARCH_VOLTA70=ON" ;;
    h200) KOKKOS_ARCH="-DKokkos_ARCH_HOPPER90=ON" ;;
    *)    echo "usage: $0 {v100|h200} [clean]" >&2; exit 1 ;;
esac
case "$MODE" in
    ""|clean) ;;
    *) echo "usage: $0 {v100|h200} [clean]" >&2; exit 1 ;;
esac

# ---------- Modules ----------
HPCX_MODULE="hpcx/2.17.1-gcc-8.5.0"
CUDA_MODULE="cuda12.8/toolkit/12.8.1"
CMAKE_MODULE="cmake/3.27.7-gcc-8.5.0"
GCC_MODULE="gcc/13.1.0"

# ---------- Layout ----------
# Anchored on this script's location, so it works from any directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# REDUCE=1 builds the variant in which the move kernel collects its per-step
# counters with a parallel_reduce instead of atomics on a few shared counters
# (the path SPARTA uses on AMD MI300). It goes to its own trees, so the normal
# build stays in place for comparison.
REDUCE="${REDUCE:-0}"
EXTRA_ARGS=()
SUFFIX=""
if [ "$REDUCE" = 1 ]; then
    SUFFIX="_reduce"
    EXTRA_ARGS=(-DCMAKE_CXX_FLAGS=-DSPARTA_KOKKOS_REDUCE_ARCH=1)
fi

BUILD_DIR="${REPO_ROOT}/build_${ARCH}${SUFFIX}"
INSTALL_DIR="${REPO_ROOT}/install_${ARCH}${SUFFIX}"
BIN="${INSTALL_DIR}/bin/spa_kokkos_cuda"

info () { printf "\n[INFO] %s\n" "$*"; }
die  () { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

[ -f "${REPO_ROOT}/cmake/CMakeLists.txt" ] || die "not a SPARTA checkout: ${REPO_ROOT}"

# ---------- Load modules ----------
info "Loading modules"

module purge
module load "${GCC_MODULE}"
module load "${HPCX_MODULE}"
module load "${CUDA_MODULE}"
module load "${CMAKE_MODULE}"

command -v nvcc >/dev/null 2>&1 || die "nvcc not found"

info "Compiler versions"
gcc --version | head -1
nvcc --version | tail -1

# ---------- Compiler wrapper ----------
NVCC_WRAPPER="${REPO_ROOT}/lib/kokkos/bin/nvcc_wrapper"
chmod +x "${NVCC_WRAPPER}"
export OMPI_CXX="${NVCC_WRAPPER}"

# ---------- Build dirs ----------
if [ "$MODE" = clean ]; then
    info "Clean build: removing ${BUILD_DIR} and ${INSTALL_DIR}"
    rm -rf "${BUILD_DIR}" "${INSTALL_DIR}"
fi
mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}"
cd "${BUILD_DIR}"

# ---------- Configure ----------
# Re-running cmake on an existing tree is cheap and keeps it in sync with any
# change to the options below; only the sources that changed get recompiled.
info "Configuring for ${ARCH}${SUFFIX}"

# CMAKE_DISABLE_FIND_PACKAGE_Git: SPARTA's CMakeLists turns the current commit
# hash into a compile definition on every source file, so each pull changes
# the flags of all objects and forces a full rebuild. The commit is recorded
# in BUILD_INFO below instead.
cmake   -DCMAKE_DISABLE_FIND_PACKAGE_Git=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DCMAKE_C_COMPILER=mpicc \
  -DCMAKE_CXX_COMPILER=mpicxx \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_CXX_EXTENSIONS=OFF \
  -DBUILD_MPI=ON \
  -DPKG_KOKKOS=ON \
  -DBUILD_KOKKOS=ON \
  -DKokkos_ENABLE_CUDA=ON \
  -DKokkos_ENABLE_CUDA_LAMBDA=ON \
  ${KOKKOS_ARCH} \
  "${EXTRA_ARGS[@]}" \
  -DSPARTA_MACHINE=kokkos_cuda \
  "${REPO_ROOT}/cmake"

# ---------- Build ----------
info "Building"
make -j"$(nproc)"

# ---------- Install ----------
info "Installing"
make install

[ -x "${BIN}" ] || die "Binary not found: ${BIN}"

# Which commit the binary was built from. The submit scripts print it next to
# the checkout commit, so a forgotten rebuild after a pull is visible.
# module purge removed git, so read the ref from .git directly.
HEAD_REF="$(cat "${REPO_ROOT}/.git/HEAD")"
case "$HEAD_REF" in
    ref:*) COMMIT="$(cat "${REPO_ROOT}/.git/${HEAD_REF#ref: }" 2>/dev/null || echo unknown)" ;;
    *)     COMMIT="$HEAD_REF" ;;
esac
{
    echo "arch    ${ARCH}${SUFFIX}"
    echo "reduce  ${REDUCE}"
    echo "commit  ${COMMIT}"
    echo "date    $(date -Is)"
} > "${INSTALL_DIR}/BUILD_INFO"

info "Done"
cat "${INSTALL_DIR}/BUILD_INFO"
echo
echo "SPARTA binary:"
echo "${BIN}"

#!/usr/bin/env bash
# Build SPARTA (Kokkos, Serial backend, MPI only) from THIS checkout, on the
# login node. CPU counterpart of compile_sparta_cuda.sh.
#
#   cd nicola/compile
#   ./compile_sparta_mpi.sh          # incremental: only changed files
#   ./compile_sparta_mpi.sh clean    # wipe the build and start over
#   TAG=pr623 ./compile_sparta_mpi.sh  # another checkout (a test branch), into
#                                      # build_cpu_pr623/install_cpu_pr623
#
# Nothing is cloned and nothing outside this repository is touched.
#
#   build_cpu/                              cmake build tree
#   install_cpu/bin/spa_kokkos_mpi_only     the binary the cpu runs use
#   install_cpu/BUILD_INFO                  commit and date of the build
#
# Tuned for the genoaX nodes (AMD EPYC 9684X, Zen4), as the CUDA build is tuned
# for its GPU. The binary uses Zen4 instructions: it will not run on older
# CPUs, e.g. the icelake queue.

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    ""|clean) ;;
    *) echo "usage: $0 [clean]" >&2; exit 1 ;;
esac

# ---------- Modules ----------
HPCX_MODULE="hpcx/2.17.1-gcc-8.5.0"
CMAKE_MODULE="cmake/3.27.7-gcc-8.5.0"
GCC_MODULE="gcc/13.1.0"

# ---------- Layout ----------
# Anchored on this script's location, so it works from any directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# TAG names a build of a different checkout (a test branch), so it gets its
# own trees and never overwrites the build of master.
TAG="${TAG:-}"
BUILD_DIR="${REPO_ROOT}/build_cpu${TAG:+_$TAG}"
INSTALL_DIR="${REPO_ROOT}/install_cpu${TAG:+_$TAG}"
BIN="${INSTALL_DIR}/bin/spa_kokkos_mpi_only"

info () { printf "\n[INFO] %s\n" "$*"; }
die  () { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

[ -f "${REPO_ROOT}/cmake/CMakeLists.txt" ] || die "not a SPARTA checkout: ${REPO_ROOT}"

# ---------- Load modules ----------
info "Loading modules"

module purge
module load "${GCC_MODULE}"
module load "${HPCX_MODULE}"
module load "${CMAKE_MODULE}"

info "Compiler versions"
gcc --version | head -1

# A previous CUDA build in the same shell would leave this set.
unset OMPI_CXX

# ---------- Build dirs ----------
if [ "$MODE" = clean ]; then
    info "Clean build: removing ${BUILD_DIR} and ${INSTALL_DIR}"
    rm -rf "${BUILD_DIR}" "${INSTALL_DIR}"
fi
mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}"
cd "${BUILD_DIR}"

# ---------- Configure ----------
# CMAKE_DISABLE_FIND_PACKAGE_Git: SPARTA's CMakeLists turns the current commit
# hash into a compile definition on every source file, so each pull changes
# the flags of all objects and forces a full rebuild. The commit is recorded
# in BUILD_INFO below instead.
info "Configuring for cpu (Zen4)"

cmake \
  -DCMAKE_DISABLE_FIND_PACKAGE_Git=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DCMAKE_C_COMPILER=mpicc \
  -DCMAKE_CXX_COMPILER=mpicxx \
  -DCMAKE_CXX_STANDARD=20 \
  -DCMAKE_CXX_EXTENSIONS=OFF \
  -DBUILD_MPI=ON \
  -DPKG_KOKKOS=ON \
  -DBUILD_KOKKOS=ON \
  -DKokkos_ENABLE_SERIAL=ON \
  -DKokkos_ENABLE_OPENMP=OFF \
  -DKokkos_ENABLE_CUDA=OFF \
  -DKokkos_ARCH_ZEN4=ON \
  -DSPARTA_MACHINE=kokkos_mpi_only \
  "${REPO_ROOT}/cmake"

# ---------- Build ----------
info "Building"
make -j"$(nproc)"

# ---------- Install ----------
info "Installing"
make install

[ -x "${BIN}" ] || die "Binary not found: ${BIN}"

# Which commit the binary was built from; the job scripts print it next to the
# checkout commit. module purge removed git, so read the ref from .git.
HEAD_REF="$(cat "${REPO_ROOT}/.git/HEAD")"
case "$HEAD_REF" in
    ref:*) COMMIT="$(cat "${REPO_ROOT}/.git/${HEAD_REF#ref: }" 2>/dev/null || echo unknown)" ;;
    *)     COMMIT="$HEAD_REF" ;;
esac
{
    echo "arch    cpu-zen4${TAG:+_$TAG}"
    echo "branch  $(sed 's#^ref: refs/heads/##' "${REPO_ROOT}/.git/HEAD")"
    echo "commit  ${COMMIT}"
    echo "date    $(date -Is)"
} > "${INSTALL_DIR}/BUILD_INFO"

info "Done"
cat "${INSTALL_DIR}/BUILD_INFO"
echo
echo "SPARTA binary:"
echo "${BIN}"

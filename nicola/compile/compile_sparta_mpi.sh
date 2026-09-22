#!/usr/bin/env bash

set -euo pipefail

# ---------- Modules ----------
HPCX_MODULE="hpcx/2.17.1-gcc-8.5.0"
CMAKE_MODULE="cmake/3.27.7-gcc-8.5.0"
GCC_MODULE="gcc/13.1.0"

# ---------- Layout ----------
ROOT="${PWD}"
SPARTA_DIR="${ROOT}/sparta"
BUILD_DIR="${SPARTA_DIR}/build_kokkos_mpi_only"
INSTALL_DIR="${SPARTA_DIR}/install_kokkos_mpi_only"

info () { printf "\n[INFO] %s\n" "$*"; }
die  () { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

# ---------- Load modules ----------
info "Loading modules"

module purge
module load bitbucket
module load "${GCC_MODULE}"
module load "${HPCX_MODULE}"
module load "${CMAKE_MODULE}"

info "Compiler versions"

gcc --version | head -1
g++ --version | head -1

# ---------- Clone ----------
info "Cloning SPARTA"

rm -rf "${SPARTA_DIR}"

git clone \
    --branch master \
    --depth 1 \
    https://github.com/sparta/sparta.git \
    "${SPARTA_DIR}"

# ---------- Build dirs ----------
rm -rf "${BUILD_DIR}" "${INSTALL_DIR}"

mkdir -p "${BUILD_DIR}"
mkdir -p "${INSTALL_DIR}"

cd "${BUILD_DIR}"

# ---------- Configure ----------
info "Configuring"

cmake \
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
  -DSPARTA_MACHINE=kokkos_mpi_only \
  ../cmake

# ---------- Build ----------
info "Building"

make -j"$(nproc)"

# ---------- Install ----------
info "Installing"

make install

BIN="${INSTALL_DIR}/bin/spa_kokkos_mpi_only"

[ -x "${BIN}" ] || die "Binary not found: ${BIN}"

info "Done"

echo
echo "SPARTA binary:"
echo "${BIN}"
#!/usr/bin/env bash

set -euo pipefail

# ---------- Modules ----------
HPCX_MODULE="hpcx/2.17.1-gcc-8.5.0"
CUDA_MODULE="cuda12.8/toolkit/12.8.1"
CMAKE_MODULE="cmake/3.27.7-gcc-8.5.0"
GCC_MODULE="gcc/13.1.0"

# ---------- Layout ----------
ROOT="${PWD}"
SPARTA_DIR="${ROOT}/sparta"
BUILD_DIR="${SPARTA_DIR}/build_kokkos_cuda"
INSTALL_DIR="${SPARTA_DIR}/install_kokkos_cuda"

info () { printf "\n[INFO] %s\n" "$*"; }
die  () { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

# ---------- Load modules ----------
info "Loading modules"

module purge
module load bitbucket
module load "${GCC_MODULE}"
module load "${HPCX_MODULE}"
module load "${CUDA_MODULE}"
module load "${CMAKE_MODULE}"

command -v nvcc >/dev/null 2>&1 || die "nvcc not found"

info "Compiler versions"
gcc --version | head -1
g++ --version | head -1
nvcc --version | tail -1

# ---------- Clone ----------
info "Cloning SPARTA"

rm -rf "${SPARTA_DIR}"

git clone \
    --branch master \
    --depth 1 \
    https://github.com/NicoNovi9/sparta.git \
    "${SPARTA_DIR}"

SPARTA_ABS="$(readlink -f "${SPARTA_DIR}")"

NVCC_WRAPPER="${SPARTA_ABS}/lib/kokkos/bin/nvcc_wrapper"

chmod +x "${NVCC_WRAPPER}"

export OMPI_CXX="${NVCC_WRAPPER}"
export PATH="$(dirname "${NVCC_WRAPPER}"):${PATH}"

info "OMPI_CXX=${OMPI_CXX}"
mpicxx --showme:command || true

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
  -DKokkos_ENABLE_CUDA=ON \
  -DKokkos_ENABLE_CUDA_LAMBDA=ON \
  -DKokkos_ARCH_VOLTA70=ON \
  -DSPARTA_MACHINE=kokkos_cuda \
  ../cmake

# -DKokkos_ARCH_VOLTA70=ON \
# -DKokkos_ARCH_HOPPER90=ON \


# ---------- Build ----------
info "Building"

make -j"$(nproc)"

# ---------- Install ----------
info "Installing"

make install

BIN="${INSTALL_DIR}/bin/spa_kokkos_cuda"

[ -x "${BIN}" ] || die "Binary not found: ${BIN}"

info "Done"

echo
echo "SPARTA binary:"
echo "${BIN}"
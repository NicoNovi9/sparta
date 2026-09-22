#!/bin/bash
# Submit the H200 test: the 30M-particle case that failed with BadAlloc on
# collide:nn_last_partner after 10-20 steps, rebuilt with Kokkos 5.2.2.
# Runs under Nsight Systems, so a crash still leaves the allocation history.
#
#   cd nicola && ./submit_h200_test.sh
#   NPART=120000000 ./submit_h200_test.sh     # other particle count
#
# Build first: compile/compile_sparta_cuda.sh h200

NPART="${NPART:-30000000}"

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1   # qsub from nicola/

if [ ! -x ../install_h200/bin/spa_kokkos_cuda ]; then
    echo "no H200 build found, run: compile/compile_sparta_cuda.sh h200" >&2
    exit 1
fi

# -l select replaces the V100 request written in submit_gpu_nsys.sh
qsub -N sparta_nsys_h200 \
     -v "GPU_ARCH=h200,NPART=$NPART,LABEL=h200" \
     -l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:gpu_type=h200 \
     submit_gpu_nsys.sh

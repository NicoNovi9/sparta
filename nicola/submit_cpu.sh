#!/bin/bash

# #PBS -N sparta_cpu_genoax
# #PBS -l select=1:ncpus=72:mpiprocs=72:mem=200GB:cpu_type=icelake
# #PBS -l walltime=00:10:00
# #PBS -j oe

#PBS -N sparta_cpu_genoax
#PBS -l select=1:ncpus=192:mpiprocs=192:mem=1400GB:cpu_type=genoaX
#PBS -l walltime=00:10:00
#PBS -q amd
#PBS -j oe

cd "$PBS_O_WORKDIR"

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0

export OMP_NUM_THREADS=1

echo "HOST=$(hostname)"

lscpu | grep "Model name"

mpirun \
  --mca pml ucx \
  --bind-to core \
  --map-by ppr:192:node \
  -np 192 \
  ./spa_kokkos_mpi_only \
  -k on \
  -sf kk \
  -in GPU_files/in.sparta.gpu
#!/bin/bash

#PBS -N sparta_v100_4gpu
#PBS -q gpu
#PBS -l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:cpu_type=skylake:gpu_type=v100
#PBS -l walltime=01:00:00
#PBS -j oe
#PBS -o output_gpu/

cd "$PBS_O_WORKDIR"

mkdir -p output_gpu

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
module load cuda12.8/toolkit/12.8.1

export OMP_NUM_THREADS=1

echo "HOST=$(hostname)"

nvidia-smi \
--query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw \
--format=csv \
-l 1 > output_gpu/gpu_metrics_$PBS_JOBID.csv &

SMI_PID=$!

mpirun \
  --mca pml ucx \
  --bind-to core \
  --map-by ppr:1:node \
  -np 1 \
  ./spa_kokkos_cuda_volta \
  -k on g 1 \
  -sf kk \
  -in GPU_files/in.sparta.gpu

  kill ${SMI_PID}
#!/bin/bash
#PBS -N sparta_ncu_v100
#PBS -q gpu
#PBS -l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:cpu_type=skylake:gpu_type=v100
#PBS -l walltime=01:00:00
#PBS -j oe

cd "$PBS_O_WORKDIR" || exit 1

module purge
module load gcc/13.1.0
module load hpcx/2.17.1-gcc-8.5.0
module load cuda12.8/toolkit/12.8.1
module load cuda12.8/nsight/12.8.1

echo "JOB_ID=$PBS_JOBID"
echo "HOST=$(hostname)"
echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"

module list
nvidia-smi
ncu --version

SPARTA_EXE="$PBS_O_WORKDIR/spa_kokkos_cuda_volta"
INPUT_FILE="GPU_files/in.sparta.gpu"
REPORT_NAME="sparta_v100_update_${PBS_JOBID}"

echo "SPARTA executable: $SPARTA_EXE"
echo "Input file: $INPUT_FILE"
echo "NCU report: $REPORT_NAME"

ncu \
  --target-processes all \
  --kernel-name-base demangled \
  --kernel-name "regex:.*UpdateKokkos.*" \
  --launch-skip 10 \
  --launch-count 1 \
  --kill yes \
  --set full \
  --export "$REPORT_NAME" \
  "$SPARTA_EXE" \
  -k on g 1 \
  -sf kk \
  -in "$INPUT_FILE"

NCU_STATUS=$?

echo "Nsight Compute exit status: $NCU_STATUS"
echo "Generated report: ${REPORT_NAME}.ncu-rep"

ls -lh "${REPORT_NAME}.ncu-rep" 2>/dev/null

exit "$NCU_STATUS"
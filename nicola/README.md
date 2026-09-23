# nicola/ — memo

Run everything on the cluster, from `/hpc/data/cfd-students/nnoventa/sparta`.
`sparta-dsmc-asml` is only used for the case files (species, vhs, geom).

## 1. Update
```
module load bitbucket
git pull
```

## 2. Build (login node)
```
cd nicola/compile
./compile_sparta_cuda.sh v100          # or h200
./compile_sparta_cuda.sh v100 clean    # from scratch, if something breaks
./compile_sparta_mpi.sh                # CPU build (genoaX / Zen4), also takes clean
```
Binaries: `install_v100/bin/spa_kokkos_cuda`, `install_cpu/bin/spa_kokkos_mpi_only`. Rebuild after every pull that touches `src/`.

## 3. Run (from `nicola/`)
| What | Command |
|---|---|
| plain run | `qsub submit_gpu.sh` |
| plain run, CPU | `qsub submit_cpu.sh` |
| plain run, H200 (10k steps) | `qsub submit_gpu_h200.sh` |
| nsys profile | `qsub submit_gpu_nsys.sh` |
| nsys profile on H200 | `qsub submit_gpu_nsys_h200.sh` |
| ncu (needs IT permission) | `qsub submit_gpu_profiling.sh` |
| registers per kernel | `./res_usage.sh` (no qsub) |
| scaling study, all runs | `./submit_scaling.sh` (no qsub, it calls it) |
| scaling study, one run | `./submit_scaling.sh gpu 2` |
| long run to steady state (4 V100, reduce build, 100k steps) | `qsub submit_long.sh` |

Useful parameters, via `qsub -v`:
`NPART=30000000`, `REORDER=100`, `LABEL=name`, `GPU_ARCH=h200`.
The deck also takes `nsteps` (default 200; the scaling runs use 1000).
For H200 also add `-l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:gpu_type=h200`.

The deck is `input/in.sparta.gpu`.

## 4. Send results back
```
cd ..
git add nicola/results
git commit -m "..."
git push
```
Results go to `results/<job>/` (scaling: `results/scaling/<arch>_n<nodes>_<job>/`): read `summary.txt` first.
In `job.out`, `BUILD` and `COMMIT` must match, otherwise you did not rebuild.

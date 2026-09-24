# nicola/ — memo

Run everything on the cluster, from `/hpc/data/cfd-students/nnoventa/sparta`.
`sparta-dsmc-asml` is only used for the case files (species, vhs, geom).
The deck is `input/in.sparta.gpu`.

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
REDUCE=1 ./compile_sparta_cuda.sh h200 # move counters by reduction: install_h200_reduce
TAG=pr623 ./compile_sparta_cuda.sh h200  # a test branch checked out: install_h200_pr623
```
Binaries: `install_<arch>[_<tag>]/bin/`, with `BUILD_INFO` (commit, branch, date).
Rebuild after every pull that touches `src/`.

## 3. Run (from `nicola/`)
All launchers take the same arguments and call qsub themselves (run them directly):

```
./submit_<study>.sh <arch> [-g] ...
  arch  cpu (genoaX node) | v100 (node of 4) | h200 (node of 8)
  -g    count GPUs of one shared node instead of whole exclusive nodes
```

| What | Command |
|---|---|
| strong scaling | `./submit_scaling.sh cpu 1 2 4 8` · `./submit_scaling.sh v100 1 2 4` · `./submit_scaling.sh h200 -g 1 2 4` |
| weak scaling (constant work per node, or per GPU with -g) | `./submit_weak.sh cpu 1 2 4` · `./submit_weak.sh h200 -g 1 2 4` |
| saturation, 1..16x particles on one node (or G GPUs: `-g G`) | `./submit_saturation.sh v100 1 2 4 8 16` · `./submit_saturation.sh h200 -g 1 1 4 16` |
| regression check, current build vs `pre623` | `./submit_regression.sh v100` |
| quick single run | `NPART=30000000 NSTEPS=200 ./submit_scaling.sh h200 -g 1` |
| long run to steady state (qsub) | `qsub submit_long.sh` |
| nsys profile (qsub) | `qsub submit_gpu_nsys.sh` (V100) / `qsub submit_gpu_nsys_h200.sh` |
| registers per kernel | `./res_usage.sh` |

Common environment knobs: `BUILD=<tag>` (use `install_<arch>_<tag>`, e.g. `BUILD=pre623`
for the code before PR #623), `NPART`, `NSTEPS`, `WALLTIME`, `BALANCE=part|dyn|time`,
`RANKS_PER_GPU`; each script's header lists its own. Shared logic: `submit_common.sh`.
The nsys scripts take `qsub -v NPART=...,REORDER=...,LABEL=...,GPU_ARCH=<build>`.

## 4. Send results back
```
cd ..
git add nicola/results
git commit -m "..."
git push
```
Results go to `results/<study>/<run>_<job>/`: read `summary.txt` first, and
`results/README.md` for what each folder holds. In `meta.txt`, `build` and
`commit` must match, otherwise you did not rebuild.

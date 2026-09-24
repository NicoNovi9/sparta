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
Launchers marked (L) call qsub themselves: run them directly, not with qsub.

| What | Command |
|---|---|
| strong scaling, nodes (L) | `./submit_scaling.sh cpu 1 2 4 8` · `./submit_scaling.sh v100 1 2 4` |
| strong scaling, GPUs of one node (L) | `./submit_scaling.sh h200 -g 1 2 4` · `./submit_scaling.sh v100 -g 1 2 4` |
| single quick run (L) | `NPART=30000000 NSTEPS=200 ./submit_scaling.sh h200 -g 1` |
| weak scaling (L) | `./submit_weak.sh` · one run: `./submit_weak.sh cpu 8` |
| saturation, 1 node, 1..16x particles (L) | `./submit_saturation.sh` · one run: `./submit_saturation.sh gpu 16` |
| long run to steady state | `qsub submit_long.sh` |
| nsys profile, V100 / H200 | `qsub submit_gpu_nsys.sh` / `qsub submit_gpu_nsys_h200.sh` |
| registers per kernel | `./res_usage.sh` |
| regression check of a test build vs master's (L) | `./submit_regression.sh` |

Environment knobs of the launchers: `NPART`, `NSTEPS`, `WALLTIME`, `BALANCE=part|dyn|time`,
`BUILD=<tag>` (use `install_<arch>_<tag>`), `RANKS_PER_GPU`; see the header of each script.
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

# nicola/ — memo

Tutti i comandi vanno lanciati sul cluster, dentro `/hpc/data/cfd-students/nnoventa/sparta`.
`sparta-dsmc-asml` serve solo per i file del caso (species, vhs, geom).

## 1. Aggiornare
```
module load bitbucket
git pull
```

## 2. Compilare (login node)
```
cd nicola/compile
./compile_sparta_cuda.sh v100          # oppure h200
./compile_sparta_cuda.sh v100 clean    # da zero, se qualcosa non va
```
Binario: `install_v100/bin/spa_kokkos_cuda`. Ricompilare dopo ogni pull che tocca `src/`.

## 3. Lanciare (da `nicola/`)
| Cosa | Comando |
|---|---|
| run normale | `qsub submit_gpu.sh` |
| profilo nsys | `qsub submit_gpu_nsys.sh` |
| ncu (serve permesso IT) | `qsub submit_gpu_profiling.sh` |
| registri per kernel | `./res_usage.sh` (niente qsub) |

Parametri utili, con `qsub -v`:
`NPART=30000000`, `REORDER=100`, `LABEL=nome`, `GPU_ARCH=h200`.
Per H200 aggiungere anche `-l select=1:ncpus=1:mpiprocs=1:mem=250GB:ngpus=1:gpu_type=h200`.

Il deck è `input/in.sparta.gpu`.

## 4. Mandare i risultati
```
cd ..
git add nicola/results
git commit -m "..."
git push
```
Risultati in `results/<job>/`: da leggere per primo `summary.txt`.
In `job.out`, `BUILD` e `COMMIT` devono coincidere, altrimenti non hai ricompilato.

# results/

New runs land at this level; move them into the matching folder once read.
`summary.txt` is the file to open first where it exists (`log.sparta` is
git-ignored upstream).

## v100_profile/ — single V100, Nsight Systems, 200 steps

| Run | What |
|---|---|
| `sparta_nsys_v100_1209335` | first profile, 120M particles: Move 75%, `TagUpdateMove` 81% of GPU time |
| `..._1209388_np30000000_ro0` | 30M, no particle reorder (reorder test baseline, old binary) |
| `..._1209389_np30000000_ro100` | 30M, `particle/reorder 100`: no gain |
| `..._1209458_np30000000_ro0_mb2` | 30M, move kernel capped at 128 registers: 20% slower (spills) |
| `..._1209483_np30000000_ro0_base` | 30M, fork build without the cap: same as the old binary |
| `res_usage/` | registers/stack per kernel of the V100 build (`TagUpdateMove<3,1,0,0,1>`: 252 regs) |

## scaling/ — strong scaling, 120M particles at start

Name: `<arch>_n<nodes>[_bal<mode>][_s<steps>]_<job>`; no `_s` means 1000 steps.
Balance modes: none = deck (`rcb cell`), `part` = once by particles,
`dyn` = `fix balance 1000 1.1 rcb part`, `time` = `fix balance 1000 1.1 rcb time`.

| Runs | What |
|---|---|
| `cpu_n{1,2,4,8}_<job>` | genoaX, deck balance, 1000 steps |
| `cpu_n{1,2,4,8}_balpart_<job>` | same, balanced once by particles: 1.4–1.7x on 1–4 nodes |
| `cpu_n{1,4}[_bal{part,dyn,time}]_s10000_<job>` | 10,000 steps: `time` best (4 nodes 65.6 s vs 143.5 s deck) |
| `gpu_n1_1210981` | 4x V100, deck balance, 1000 steps: 78.9 s |

## h200/ — H200 BadAlloc investigation, 30M particles

| Run | What |
|---|---|
| `sparta_nsys_h200_1211770_np30000000_ro0_h200` | 200 steps under nsys: completes; move only 1.09x faster than V100 |
| `sparta_h200_1211776` | 10,000 steps: BadAlloc on `collide:nn_last_partner` at step ~3850; nvidia-smi sees the GPU full just before |
| `sparta_h200_1211801` | same with the Kokkos allocation logger: 4557 alloc/free pairs of 711.9 MB, Kokkos live stays 4.9 GB |
| `sparta_h200_1211844_pmlob1` | without UCX (ob1): still BadAlloc, at step ~5150 |
| `sparta_h200_1211877` | device free-memory watch: GPU goes to 0 free during the move kernel |
| `sparta_nsys_h200_1211918_..._h200` | nsys with unified-memory tracing: no UM activity, Addressing Mode None; GPU goes to 0 free during emit/surf |
| **`../h200_diag_1212041`** | **cause found: `/hpc/shared/bin/cuda_memtest` takes the whole GPU (143 GB) for ~0.75 s, twice, every 5 minutes, also with SPARTA not running. Not a SPARTA bug.** |

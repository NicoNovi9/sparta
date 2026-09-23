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
| `..._1209483_np30000000_ro0_base` | 30M, fork build without the cap: same as the old binary (55.5 ms per move) |
| `..._1214902_np30000000_ro0_reduce` | 30M, counters by `parallel_reduce` instead of atomics (`REDUCE=1` build): move 45.8 ms, loop 14.1 -> 12.3 s |
| `res_usage/` | registers/stack per kernel of the V100 build (`TagUpdateMove<3,1,0,0,1>`: 252 regs) |

## h200/ — H200, 30M particles

| Run | What |
|---|---|
| `h200_diag_1212041` | cause of the out-of-memory failures: `/hpc/shared/bin/cuda_memtest` takes the whole GPU (143 GB) for ~0.75 s, twice, every 5 minutes, also while SPARTA is not running. IT runs it because of ECC errors |
| `sparta_nsys_h200_1211770_np30000000_ro0_h200` | 200 steps under nsys, atomics build: move only 1.09x faster than on V100, sort and collide ~3x |
| `sparta_nsys_h200_1214944_np30000000_ro0_reduce` | same with the reduce build: move 50.8 -> 13.2 ms, loop 11.2 -> 3.8 s; counters match within 0.04% |

The runs that showed the failure itself (jobs 1211776, 1211801, 1211844,
1211877, 1211918, and 1214925 with the reduce build) were removed once the
cause was known; they are in the git history.

## scaling/ — strong scaling, 120M particles at start (draining transient)

Name: `<arch>_n<nodes>[_bal<mode>][_s<steps>][_r<ranks per GPU>]_<job>`; no `_s` means 1000 steps.
Balance modes: none = deck (`rcb cell`), `part` = once by particles,
`dyn` = `fix balance 1000 1.1 rcb part`, `time` = `fix balance 1000 1.1 rcb time`.

| Runs | What |
|---|---|
| `cpu_n{1,2,4,8}_<job>` | genoaX, deck balance, 1000 steps |
| `cpu_n{1,2,4,8}_balpart_<job>` | same, balanced once by particles: 1.4–1.7x on 1–4 nodes |
| `cpu_n{1,4}[_bal{part,dyn,time}]_s10000_<job>` | 10,000 steps: `time` best (4 nodes 65.6 s vs 143.5 s deck) |
| `gpu_n{1,2,4}_<job>` | 4x V100 per node, deck balance, 1000 steps: 78.9 / 44.4 / 23.6 s |
| `gpu_n1[_baldyn]_r2_<job>` | 2 ranks per V100: no gain (91.9 s balanced, 99.7 s not) |

## long/ — steady state

| Run | What |
|---|---|
| `long_1215014` | 100k steps, 4 V100, reduce build, particles from `nrho` (35.9M): steady state 25.7M, within 1% after 67k steps. Restart and grid dumps are outside the repo, in `long_runs/long_1215014/` |

## weak/ — weak scaling, 25.7M particles per node (fnum / nodes)

Name: `<arch>_n<nodes>_<job>`. 2000 warm-up steps, then 1000 measured (the last `Loop time`).
Base builds, deck balance.

| Runs | What |
|---|---|
| `cpu_n{1,2,4}_<job>` | 16.3 / 21.7 / 28.5 s: efficiency 0.75, 0.57 |
| `gpu_n{1,2}_<job>` | 20.9 / 20.9 s: efficiency 1.00 |

## saturation/ — one node, 1..16x the steady-state particles (fnum / s)

Name: `<arch>_n1[_x<s>]_<job>`. Same protocol as weak/.

| Runs | What |
|---|---|
| `{cpu,gpu}_n1[_x{2,4,8,16}]_<job>` | GPU/CPU time 1.27 at 25M, 0.97–0.99 from 200M on; GPU saturated already at 6.4M per V100; 19.2 GB per V100 at 404M |

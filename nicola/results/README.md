# results/

New runs land at this level; move them into the matching folder once read.
**Code version.** `pre623/` holds every study run with the code before upstream PR #623
was merged into master (2026-09-24, merge 9e9aa6da); binaries kept on the cluster as
`install_<arch>_pre623` (`BUILD=pre623`). `pr623/` holds the runs that validated the PR.
New runs, with the current code, land in `scaling/`, `weak/`, `saturation/`, ... again.

`summary.txt` is the file to open first where it exists (`log.sparta` is
git-ignored upstream).

## pre623/v100_profile/ — single V100, Nsight Systems, 200 steps

| Run | What |
|---|---|
| `sparta_nsys_v100_1209335` | first profile, 120M particles: Move 75%, `TagUpdateMove` 81% of GPU time |
| `..._1209388_np30000000_ro0` | 30M, no particle reorder (reorder test baseline, old binary) |
| `..._1209389_np30000000_ro100` | 30M, `particle/reorder 100`: no gain |
| `..._1209458_np30000000_ro0_mb2` | 30M, move kernel capped at 128 registers: 20% slower (spills) |
| `..._1209483_np30000000_ro0_base` | 30M, fork build without the cap: same as the old binary (55.5 ms per move) |
| `..._1214902_np30000000_ro0_reduce` | 30M, counters by `parallel_reduce` instead of atomics (`REDUCE=1` build): move 45.8 ms, loop 14.1 -> 12.3 s |
| `res_usage/` | registers/stack per kernel of the V100 build (`TagUpdateMove<3,1,0,0,1>`: 252 regs) |

## pre623/h200/ — H200, 30M particles

| Run | What |
|---|---|
| `h200_diag_1212041` | cause of the out-of-memory failures: `/hpc/shared/bin/cuda_memtest` takes the whole GPU (143 GB) for ~0.75 s, twice, every 5 minutes, also while SPARTA is not running. IT runs it because of ECC errors |
| `h200_diag_1215492` | the same diagnosis after IT disabled `cuda_memtest`: GPU memory never above 6.2 GB, no foreign process, SPARTA runs past the failure point |
| `sparta_nsys_h200_1211770_np30000000_ro0_h200` | 200 steps under nsys, atomics build: move only 1.09x faster than on V100, sort and collide ~3x |
| `sparta_nsys_h200_1214944_np30000000_ro0_reduce` | same with the reduce build: move 50.8 -> 13.2 ms, loop 11.2 -> 3.8 s; counters match within 0.04% |

The runs that showed the failure itself (jobs 1211776, 1211801, 1211844,
1211877, 1211918, and 1214925 with the reduce build) were removed once the
cause was known; they are in the git history.

## pre623/scaling/ — strong scaling, 120M particles at start (draining transient)

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
| `h200_g{1,2,4}_<job>` | 1, 2 and 4 H200 of a shared node (`submit_scaling.sh h200g`), base build: 199.0 / 105.0 / 82.0 s (91.3 s in a repeat). On 4 GPUs Output takes 30–40 s (whole particle array copied to the host at every stats output); without it 194.4 / 100.7 / 51.6 s. Full node projected linearly: ~25 s. `h200_g1_1215697` is the same point from the former `submit_gpu_h200.sh` (`KP=0`): 201.1 s; ~201 W of 700 W, 23.4 GB |

## pre623/long/ — steady state

| Run | What |
|---|---|
| `long_1215014` | 100k steps, 4 V100, reduce build, particles from `nrho` (35.9M): steady state 25.7M, within 1% after 67k steps. Restart and grid dumps are outside the repo, in `long_runs/long_1215014/` |

## pre623/weak/ — weak scaling, 25.7M particles per node (fnum / nodes)

Name: `<arch>_n<nodes>_<job>`. 2000 warm-up steps, then 1000 measured (the last `Loop time`).
Base builds, deck balance.

| Runs | What |
|---|---|
| `cpu_n{1,2,4}_<job>` | 16.3 / 21.7 / 28.5 s: efficiency 0.75, 0.57 |
| `gpu_n{1,2,4}_<job>` | 20.9 / 20.9 / 21.1 s: efficiency 1.00, 0.99 |

## pre623/saturation/ — one node, 1..16x the steady-state particles (fnum / s)

Name: `<arch>_n1[_x<s>]_<job>`. Same protocol as weak/.

| Runs | What |
|---|---|
| `{cpu,gpu}_n1[_x{2,4,8,16}]_<job>` | GPU/CPU time 1.27 at 25M, 0.97–0.99 from 200M on; GPU saturated already at 6.4M per V100; 19.2 GB per V100 at 404M |

## pr623/ — validation of upstream PR #623 before merging it into master

Test build `install_<arch>_pr623` from branch `try-pr623`; reference: the builds of master
at the time. See the merge commit 9e9aa6da for the summary.

| Runs | What |
|---|---|
| `scaling/cpu_pr623_n1_<job>` | CPU node, deck as given: 84.6 s (before 83.1 s), counters equal |
| `scaling/gpu_pr623_n1_<job>` | 4x V100: 53.4 s (before 78.9 s); collide slower (9.7 vs 7.6 s) |
| `scaling/h200_pr623_g{1,4}_<job>` | 1 and 4 H200: 47.2 / 18.9 s (before 199.0 / 82.0 s); no Output copy |
| `saturation/gpu_pr623_n1_x16_<job>` | 4x V100, 404M particles: 223.0 s (before 307.5 s), peak memory unchanged (19.2 GB per GPU) |
| `regression/cpu_pr623_1217483` | SPARTA's regression.py, every example, CPU 4 ranks: 120 decks bit-identical, 13 fail with both builds (missing packages or input files) |
| `regression/gpu_pr623_1217184` | same on one V100, 146 decks: at the noise level of the build against itself (median error ratio 0.99) |
| `regression/gpu_pr623_{1217312,1217411}` | repeats of `ambi`, `circle` and `surf_collide`: the two decks above 5% are within the noise |

`regression/` files: `summary.txt` (one line per deck: reference vs itself, test vs
reference), `ref.out` / `test.out` (the driver's output); run logs in `../regression_runs/`.
New regression runs land in `results/regression/`.

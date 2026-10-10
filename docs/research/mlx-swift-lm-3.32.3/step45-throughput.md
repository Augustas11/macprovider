# Steps 4-5: throughput on the final #1927 build (2026-10-09/10)

**Status: BLOCKED. No clean before/after table.** During both `bench.sh`
windows, the live `:8080` provider (CLI 1.8.232, another session's canary)
kept admitting buyer requests while it reported `paused_by_operator`. Its
requests then shared the GPU with the lab cells. `bench.sh` checks
`requests_in_flight: 0` only once, at the start of a window, so it cannot
detect load that arrives later. Most cells below were measured next to up to 8
live decode rows. They show the same signature as a known-contaminated
control. I stopped the second run as soon as the sampler showed it. Only the
cells marked clean below are usable.

## Identity

| Field | Value |
| --- | --- |
| Source | `origin/deps/mlx-swift-lm-3.32.3` at `ffd79639b`. The worktree matched it, and it was synced to the Studio tree (`rsync --dry-run` clean). |
| Pins | mlx-swift-lm `5203b732c451344aef936958ef3f765480cf6a9a` (tag `3.32.3-macprovider.5`); mlx-swift `ca2f61d22c5e8afe87170525ebc1769f72da5b41` (tag `0.32.3-macprovider.2`); core MLX `c9196eb7161358f1e4a7f0605182186f8686e5f8` (`v0.32.2-macprovider.2`). The core change from `ff1b948` is `mlx/compile.cpp` and `compile_impl.h` only, so the kernels and metallib are unchanged. |
| New build | `swift build -c release`, SHA-256 `5a681910d5862a2410f7379ddde17098930b464b5646e6721264ff8368360dc1`, reports `1.8.230`; `mlx.metallib` `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` |
| Before build | **1.8.230**, the live binary until 2026-10-09 22:25Z. SHA-256 `40833698604a632e74e94abdf6d6e168e9667dc428ba5f739f4223b8b50b8a35`, identical to the `macprovider.pre-232-*` backup on the Studio; `mlx.metallib` `84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf` (mlx-swift 0.31.4). It was copied into the lab and never run from the live directory. |
| Config, all runs | `build/lab-serve.sh` on loopback 18199 with `--no-join --autotune-candidate --no-idle-prewarm`. Settings: `max_concurrency_override: 8`, `continuous_batch_queue_limit: 16`, hybrid decode window 1 (fixed on `main` and in 1.8.230), paged KV on, `continuous_batching: canary`, `mlx_cache_limit_mb: 2048`, `max_context_override: 200000`, prefill step 512. The control config differs only in the lab accepted tuple's metallib SHA (`84e48718…`). Both runtimes logged `batched-isolation … proven=true`, `paged_kv_decision=attached` and `slots_total=8` before measuring. |
| Load | `depth_sweep.py`, byte-identical to `campaign/1906-cb-depth`: closed loop, unique salted prompts, greedy, streamed, 30 s warmup, 90 s window, depths 1/8/16. Prompt-heavy is 1536 prompt tokens and 256 output; output-heavy is 1800 prompt and 1024 output. Scripts: `build/step45.sh`, `build/rtcmp-332.sh`. |
| 2026-10-09 ours-w1 reference | `campaign/1906-cb-depth` lab build (MLX 0.31.4) with `max_batch` **32** and queue 256. That is a different binary from 1.8.230, and its 16-concurrent cells ran 16 rows. With `max_batch` 8, all cells here run at most 8 rows, so 16 concurrent means 8 active and 8 queued. |

## The live provider was not quiet

`step45-raw/pause-probe-2026-10-10T0008Z/` is a `bench.sh` window with no lab
load. Over 2.5 minutes, live stayed at `in_flight=0`. There was one small
1-row internal burst (34 forward calls) and no new requests.

`step45-raw/run2-2026-10-10T0012Z-aborted/live-sampler.txt` (5 s samples) is
from the second run. Live was paused and drained at 00:12:01Z. From 00:17:58Z,
still `paused_by_operator` with `operator_paused=true`, it went from 0 to 8
in-flight requests and 8 active decode rows within 50 s. `requests_total`
advanced and `shared_forward_calls` grew by about 18/s. It stayed at 8 until I
stopped the run at about 00:20Z.

During the first run, a spot check at about 00:04Z showed the same state: 8
in flight, 8 rows, `requests_total` advancing while paused. The first run had
no sampler, so its contaminated intervals are unknown.

The two control rows below show the effect. Same binary, same cell:

| Cell (1.8.230 control) | Live quiet | Live serving 8 rows while "paused" |
| --- | ---: | ---: |
| Output-heavy, 1 concurrent | 83.1 tok/s, ITL p50 11.4 ms (run 1) | 56.5 tok/s, ITL p50 17.9 ms (run 2, 00:18Z onward) |
| Prompt-heavy, 16 concurrent | 120.8 (run 1) | 100.5, ITL p50 49.1 ms (run 2) |

On 2026-10-09, with 1.8.230 live, a pause stopped admission
(`issue-1906/isolate-2026-10-09`: only already-running requests continued).
Here, new admissions arrive minutes after the pause, so this is new behaviour
of the live 1.8.232 deployment or of its traffic path. I didn't investigate it
further because it belongs to the other session's live canary.

## Results

Aggregate output tok/s. TTFT p95 and ITL p50 are in the raw JSONL.

**Clean** means the cell is confirmed quiet by the run-2 sampler, or ran
before 00:17:58Z in run 2. **Likely clean** means run 1, before the first
observed contamination, with ITL p50 at the quiet single-runtime level and no
sampler proof. **Contaminated** means ITL p50 is 1.4-2x the quiet level for the
same runtime and depth, matching the control's known-contaminated signature.

### Prompt-heavy

| Concurrent | 2026-10-09 ours-w1 (campaign, max 32) | 1.8.230 control | New, fused MoE | New, stock MoE (`MLX_LM_QWEN35_FUSED_MOE=0`) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 74.3 | **73.9 clean** (run 2); 73.2 (run 1) | 80.6 likely clean (ITL 8.8 ms) | 44.8 contaminated (ITL 20.9 ms) |
| 8 | 122.9 | **120.8 clean** (run 2); 121.7 (run 1) | 122.6 likely clean (ITL 36.2 ms) | 100.5 contaminated (ITL 51.7 ms) |
| 16 | 136.3 (16 rows) | 120.8 likely clean (run 1, ITL 37.1 ms); 100.5 contaminated (run 2) | 97.3 contaminated (ITL 50.2 ms) | 94.9 contaminated |

### Output-heavy

| Concurrent | 2026-10-09 ours-w1 | 1.8.230 control | New, fused | New, stock |
| --- | ---: | ---: | ---: | ---: |
| 1 | 88.1 | 83.1 likely clean (run 1, ITL 11.4 ms); 56.5 contaminated (run 2) | 61.3 contaminated (ITL 16.6 ms) | 49.6 contaminated (ITL 20.9 ms) |
| 8 | 171.6 | 167.8 likely clean (run 1, ITL 39.1 ms) | 137.8 contaminated (ITL 52.5 ms) | 136.5 contaminated (ITL 53.2 ms) |
| 16 | 196.0 (16 rows) | 165.3 likely clean (run 1, ITL 39.5 ms) | 137.7 contaminated | 139.0 contaminated (ITL 53.0 ms) |

What can be said:

- **The 1.8.230 control reproduces the 2026-10-09 ours-w1 rows at 1 and 8
  concurrent.** Prompt-heavy: 73.9 against 74.3 and 120.8 against 122.9.
  Output-heavy 8: 167.8 against 171.6. The campaign build and 1.8.230 behave
  the same at 8 rows, so the old table is a valid "before" at 1 and 8.
- **max_batch 8 against 32 at 16 concurrent:** 1.8.230 at max 8 gives 120.8
  prompt-heavy and 165.3 output-heavy (likely clean). The campaign build at
  max 32 gave 136.3 and 196.0. So -11% and -16% at 16 concurrent come from the
  cap alone, before any engine change. At max 8, 16 concurrent adds queueing:
  TTFT p95 is 20.6 s against 4.6 s at 8.
- **New fused against 1.8.230, likely-clean cells only:** prompt-heavy 1 is
  +9.1% (80.6 against 73.9, ITL 8.8 against 9.6 ms). Prompt-heavy 8 is +1.5%
  (122.6 against 120.8). This is consistent with the +7-10% ordinary one-slot
  decode measured in R015 and with prefill-bound cells at 8 rows.
- **Fused against stock:** no clean pair. Every stock cell ran after live
  began serving, so no fused/stock delta is reported. The R015/#1832
  qualification (fused 1.25x at 1 row, about 0.97x at 8) remains the latest
  clean evidence.

## What is needed to finish

A quiet window: the live provider must admit no requests between `bench.sh`'s
pause and resume. That needs the 1.8.232 pause to stop admission, as 1.8.230's
did, or the other session's canary returning live to a provider whose pause
holds. With that in place, rerun `build/step45.sh` under `bench.sh` with
`build/live-sampler.sh` running alongside. Fix the sampler path in
`step45b.sh`, which failed to start in run 2, so I started it separately. Then
keep only cells where the sampler shows `in_flight=0`. About 45 minutes of
pause for the three runtimes.

`bench.sh` could also refuse to measure, or flag cells, when live's
`requests_in_flight` rises after `LIVE_DRAINED`. That is a lab-tooling change
outside this task and was not made.

## Raw data (`step45-raw/`)

- `run1-2026-10-09T2325Z/`: `sweep.jsonl` (18 cells, all three runtimes), the `bench.sh` console, and the serve log for
  each runtime. Live was paused 23:25:02Z-00:08:22Z.
- `run2-2026-10-10T0012Z-aborted/`: `sweep.jsonl` (control, 4 cells), the 5 s
  live sampler, console and serve log. Live was paused 00:12:00Z-00:24:14Z.
- `pause-probe-2026-10-10T0008Z/`: the no-load `bench.sh` window with live
  samples. Live was paused 00:08:40Z-00:11:39Z.

# Hybrid models in the 16-step decode window: Studio evidence (2026-10-10)

SPEC-038 v0.3.15 FR-CB2 moves hybrid models (Qwen3.5/3.6: gated-delta
recurrent layers plus attention layers) from a one-step lockstep decode window
to the same 16-step window as KV-only models, and moves the load-time
isolation and shared-forward parity probes to the serve window. This directory
is the hardware evidence for that change (#1906).

## Evidence header

| Field | Value |
| --- | --- |
| macprovider | `5df809e5d6b1f577acf124187d08186f123f9ec8` on `perf/hybrid-decode-window` (code commits `283dba31b`, `1d2693f78`, `d30206a06`; `5df809e5d` is SPEC-038 text only) |
| mlx-swift-lm fork | `72c4ab082a08f291ba270a7303880e90036742e3` (`3.32.3-macprovider.6`, unchanged from `origin/main`) |
| Serve executable | `swift build -c release --product macprovider-cli`, reports 1.8.232, SHA-256 `a2df4cf76ffa1ed6cbcdaae2acc9e39b49a0ff6ed5c96ea1f3695369cf5a9f3f` |
| Lab-harness executable | same tree with `-Xswiftc -DMACPROVIDER_LAB_HARNESS`, SHA-256 `7d21da5669d431a0995f88812163f3f0c544594c383968a8a5448d3742f626d9` |
| `mlx.metallib` | `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` (unchanged) |
| Build trees | `<studio-home>/lab-hw/serve` and `<studio-home>/lab-hw/lab`, both from `git archive 5df809e5d phase3-binary` |
| Host | Mac15,14, M3 Ultra, 256 GB, macOS 26A434, Swift 6.3.3 (Command Line Tools) |
| Models | served A3B `qwen/qwen3.6-35b-a3b` (`3fed776d…`), `qwen/qwen3.6-27b` (`518ef47c…`, hybrid: `linear_attention` + `full_attention` layers) |
| Live provider | Not stopped, restarted or reconfigured. Paused only by `bench.sh` for the throughput and R015 windows and resumed each time. |

## Run conditions

| Run | UTC | `bench.sh` window | Live `requests_in_flight` sampled | Class |
| --- | --- | --- | --- | --- |
| Exactness A3B fused / stock (§1) | 07:00-07:09 | no, live serving | no | correctness only (token equality); tok/s discarded |
| Startup probes (§2) | 07:09-07:17 | no, live serving | no | correctness only |
| Throughput attempt 1 | 07:17-07:28 | yes | yes, 0 | discarded: another session's lab serve was busy; aborted |
| Throughput, 8 slots (§3) | 07:32-08:05 | yes | yes, every 2 s | clean cells only |
| R015 (§4) | 08:07-09:02 | yes | yes, every 2 s and 10 s | clean |
| Exactness 27B (§1) | 09:02-09:18 | no, live serving | no | correctness only; tok/s discarded |
| Throughput, 32 slots (§3) | 09:19-09:56 | yes | yes, every 2 s | clean cells only |
| Rebased-build self-check serve | after 09:56 | no, live serving | no | contaminated, discarded; it loaded the live box |
| Self-check composition (§5) | 14:56:15-15:20:45 | yes (`bench-norestart.sh`) | yes, every 2 s: 564 at 0, 4 timeouts (`-1`), never nonzero; no other process at 5% CPU or more | clean |

## 1. Exactness: window 16 vs window 1 (`hybrid-window-proof.sh`)

`msb-throughput --scenario hybrid-window`: one fixed greedy batch of 16 rows,
ragged prompts of 1536 to 2091 tokens (every one past the 512-token prefill
chunk), 256 decode tokens per row, decoded through the production backend path
at window 16 and at window 1, 3 runs each. PASS needs the window-1 run to
repeat itself exactly and every row's window-16 tokens to equal its window-1
tokens. These runs did not pause live, so their tok/s are not comparable and
are not reported as throughput.

| Model | Window-16 calls / window-1 calls | Window 1 repeats | Rows exact | Verdict |
| --- | --- | --- | --- | --- |
| A3B, fused MoE (default) | 16 / 256 | yes | 16/16 | PASS |
| A3B, `MLX_LM_QWEN35_FUSED_MOE=0` | 16 / 256 | yes | 16/16 | PASS |
| 27B | 16 / 256 | yes | 16/16 | PASS |

The first 27B attempt (inside the same sequence as the A3B runs) was killed
by SIGKILL before it wrote any output; no unified-log entry names the cause.
The rerun on the same executable, outside any pause window, passed. The
proof now refuses to run below the SPEC-038 bar (fewer than 16 rows, fewer
than 2 runs, a window other than the serve window, or fewer than two full
windows of decode tokens).

## 2. Startup probes at the serve window

Isolated loopback serves (18190-18192, `--no-join`), serve executable. The
isolation probe now decodes its first shared step as one 16-step window
(`decodeA`/`decodeB` below are 16 tokens, each equal to its serial reference),
and the shared-forward parity probe decodes in 16-step windows.

| Probe | Gather parity | Batched isolation (window 16) | `/v1/status` |
| --- | --- | --- | --- |
| A3B fused MoE | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=true`, `paged_kv_decision=attached`, `local_proof_result=passed`, `slots_total=8` |
| A3B `MLX_LM_QWEN35_FUSED_MOE=0` | `established=true`, 640/640 | same | same |
| 27B | `established=true`, 1024/1024 | same (`requiresMoE=false`) | same |

As on the `8875789e7` and `ffd79639b` probes, challenge pairs 0 and 1 do not
distinguish at the first step (both rows' serial first tokens are equal) and
pair 2 distinguishes. Every 16-token window in all three pairs matched the
serial references token for token, and every rejoin step matched.

## 3. Throughput: window 16 vs window 1

The #1906 runtime-compare method (`scripts/lab/cb-studio/depth_sweep.py`:
closed loop, unique salted prompts, greedy, streamed, 30 s warmup, 90 s
window) on an isolated loopback serve of the lab-harness executable. Window 1
is the lab-only `MACPROVIDER_LAB_HYBRID_DECODE_WINDOW=1` override on the same
executable, so both arms run identical code. Both arms ran in one `bench.sh`
window. `build/sampler.sh` sampled the live provider's `requests_in_flight`
and every other inference process's CPU every 2 s; a cell with any nonzero or
unreadable live count, or any other process at 5% CPU or more, was discarded
and rerun. Only clean cells are reported (`tput*/cells.txt`).

**8 slots (the live provider's `max_concurrency_override: 8`, queue 16).** 14 attempts, 2 discarded (each for two unreadable live-status samples, `-1`), 12 clean cells, 0 request errors.

| Shape | Concurrent | Window 1 tok/s (TTFT p95 s, ITL p95 ms) | Window 16 tok/s (TTFT p95 s, ITL p95 ms) | Window 16 / window 1 |
| --- | ---: | --- | --- | ---: |
| prompt-heavy 1536/256 | 1 | 80.9 (0.939, 17.734) | 83.4 (0.951, 16.807) | 1.031 |
| prompt-heavy 1536/256 | 8 | 122.3 (4.719, 247.774) | 139.2 (6.199, 69.08) | 1.138 |
| prompt-heavy 1536/256 | 16 | 121.1 (19.613, 273.467) | 119.7 (19.898, 293.019) | 0.988 |
| output-heavy 1800/1024 | 1 | 93.6 (1.067, 19.996) | 104.5 (1.053, 17.154) | 1.116 |
| output-heavy 1800/1024 | 8 | 175.5 (6.889, 78.272) | 205.5 (7.66, 57.368) | 1.171 |
| output-heavy 1800/1024 | 16 | 174.6 (21.755, 78.568) | 174.3 (20.277, 78.481) | 0.998 |

At 8 slots, 16 concurrent requests queue behind 8 rows, so the 16 column
measures an 8-row batch plus queueing (TTFT p95 about 20 s in both arms); the
window changes nothing there. At 8 concurrent the window gains 14% prompt-heavy
and 17% output-heavy, with ITL p95 down from 248 to 69 ms prompt-heavy.

**32 slots (the #1906 runtime-compare configuration: `max_concurrency_override: 32`, queue 256).** 15 attempts, 3 discarded (unreadable live-status samples, one with another process at 17% CPU), 12 clean cells, 0 request errors. The last column is the #1906 measurement (2026-10-09, lab override on the MLX 0.31 build, `docs/research/issue-1906/runtime-compare-2026-10-09/`).

| Shape | Concurrent | Window 1 tok/s (TTFT p95 s, ITL p95 ms) | Window 16 tok/s (TTFT p95 s, ITL p95 ms) | Window 16 / window 1 | #1906 w1 → w16 |
| --- | ---: | --- | --- | ---: | --- |
| prompt-heavy 1536/256 | 1 | 81.1 (0.941, 17.665) | 83.4 (0.94, 16.754) | 1.028 | 74.3 → 76.8 |
| prompt-heavy 1536/256 | 8 | 124.3 (5.067, 84.727) | 140.0 (6.707, 54.664) | 1.126 | 122.9 → 137.1 |
| prompt-heavy 1536/256 | 16 | 137.6 (8.078, 465.717) | 162.5 (10.289, 377.968) | 1.181 | 136.3 → 149.2 |
| output-heavy 1800/1024 | 1 | 94.2 (1.065, 19.314) | 105.2 (1.068, 17.04) | 1.117 | 88.1 → 96.5 |
| output-heavy 1800/1024 | 8 | 176.1 (5.94, 77.427) | 206.5 (8.197, 56.097) | 1.173 | 171.6 → 207.7 |
| output-heavy 1800/1024 | 16 | 209.5 (11.499, 132.015) | 289.3 (11.811, 93.786) | 1.381 | 196.0 → 269.8 |

The #1906 result reproduces on this build: 16 output-heavy rows go from 209.5
to 289.3 tok/s (+38%; #1906: 196.0 to 269.8, +38%), and 16 prompt-heavy rows
gain 18%. Single requests gain 3% (prompt-heavy) and 12% (output-heavy). TTFT
p95 rises by 0.3 to 2.3 s at 8 and 16 rows, because a prompt now waits up to
one 16-step window to join (FR-CB5), while ITL p95 falls in every multi-row
cell.

## 4. Native-MTP R015 (SPEC-048) on the window-16 build

The hybrid decode path changed, so SPEC-048 R015 ran again (AGENTS.md rule 2:
the changed lines are `servePathDecodeLockstepWindow` and the hybrid window in
`PagedKVSharedForwardBackend.performDecode`). The native-MTP bench and the
hardware E2E inject the real paged backend, which takes the serve-path window
(`ModelRuntime.decodeLockstepWindow(backendOverride:)`,
`PagedKVRuntimeMixedCacheTests.testInjectedPagedBackendUsesServePathDecodeWindow`),
so the ordinary arm decodes hybrid rows in 16-step windows.

Policy `r015/policy.json`, SHA-256
`fc719768cf6d2813f7ae474827f251e5fc0e56d4c6a85d32cc3d2f5b34871467`, was frozen
at 2026-10-10T06:54:11Z, before any request (`r015/policy-freeze.txt`). It is
byte-identical to `002929b3…` (the `8875789e7` PASS policy) except for
`provider_commit` (`5df809e5d…`) and `mlx_fork_revision` (`72c4ab08…`). The
fork revision differs because `origin/main` moved to `3.32.3-macprovider.6`
(#1927) after the `8875789e7` run; this branch does not change it, and the
bench refuses a policy whose fork revision differs from the executable's.
Compiled verify was on (`MLX_LM_QWEN35_COMPILED_VERIFY` unset). Run script
`build/r015.sh`, one `bench.sh` window (live paused 08:07:09, resumed after
09:01:22 UTC).

| Phase | Result |
| --- | --- |
| `native-mtp-hardware-e2e` (serve path) | exit 0, `status: pass`, 3 admissions, batch depth 2, `serve_path_verified=true` (08:08:16Z) |
| `--phase matrix` | exit 0, 133 records (08:30:32Z) |
| `--phase sustained` | exit 0, 1800 s, 215 records in total; JSONL SHA-256 `2b7f363e15414a2dc67892eebe0d5d40b4e2b53bcae53b7345539c4220f9be34` (09:01:22Z) |
| Analyzer | **`overall_status: PASS`** (exit 0), unmodified output in `r015/analysis.{json,md}` |

Gates against the `8875789e7` PASS. Bounds are Holm-corrected, as fractions of
the ordinary arm. Thresholds: one-slot decode LB at least +15% and TTFT UB at
most +10%; gated decode LB at least -5%, TTFT UB at most +5%, TPOT UB at most
+5%.

| Cell | Decode LB 8875789e7 / **now** | TTFT p95 UB 8875789e7 / **now** | TPOT p95 UB now | Gap p99 UB now | Rejection UB now | Status 8875789e7 → **now** |
| --- | --- | --- | ---: | ---: | ---: | --- |
| s1-p1536-o128 | +25.5% / **+27.7%** | +5.0% / **+4.7%** | -21.7% | -7.4% | 0 | PASS → **PASS** |
| s1-p1536-o512 | +24.4% / **+24.9%** | +4.6% / **+5.1%** | -19.9% | -22.3% | 0 | PASS → **PASS** |
| s1-p4096-o128 | +20.6% / **+20.7%** | +7.1% / **+6.1%** | -17.1% | -18.6% | 0 | PASS → **PASS** |
| s1-p4096-o512 | +18.4% / **+18.1%** | +7.7% / **+5.8%** | -15.4% | -18.6% | 0 | PASS → **PASS** |
| s2-p1536-o512 (gated) | -0.5% / **-0.4%** | +4.5% / **+3.1%** | +0.4% | +0.5% | 0 | PASS → **PASS** |
| s8-p1536-o512 (gated) + sustained | -0.1% / **-0.2%** | +2.4% / **+1.3%** | +0.2% | +0.4% | 0 | PASS → **PASS** |

- Parity: 0 mismatches in the matrix and the sustained window. Native
  acceptance ranged from 0.819 to 0.954 across the 44 runs with verify rounds.
- Median decode, ordinary / native (tok/s), `8875789e7` → now: s1-p1536-o128
  121.2 / 154.7 → 119.6 / 153.4, s1-p1536-o512 120.0 / 151.9 → 118.2 / 149.6,
  s1-p4096-o128 116.8 / 146.3 → 116.1 / 146.2, s1-p4096-o512 116.3 / 139.7 →
  116.5 / 139.7, s2 144.0 / 143.6 → 143.4 / 143.3, s8 206.5 / 206.4 → 213.7 /
  213.7. In-process one-row decode gains nothing from the longer window (its
  per-step overhead is already small); the 8-row cell gains 3.5% in both arms.
- Errors, fallbacks and capacity rejections were 0 everywhere. The minimum
  available memory fraction was 0.595.
- Contamination: every readable sample of the live provider's
  `requests_in_flight` was 0 (`r015/contamination.log`: 309 samples at 0,
  3 empty; `r015/samples.log`: 6 status reads timed out, `-1`, in three
  pairs about 15 minutes apart, none nonzero). In `r015/samples.log`, no
  other inference process exceeded 8% CPU: the short-lived ones (one sample
  each, 6-7%) are the run's own contamination sampler (`python3 -c ...`), and
  the idle co-hosted providers blipped at 3% to 4%. No lab load ran beside the
  bench.

## 5. FR-CB10 self-check at the serve window (#1947 composition)

Build: the #1953 head `d74eccdc0` (rebased onto main with #1947), `swift build
-c release --product macprovider-cli` outside the window, SHA-256
`cd27902ebef10de826d4e1218bab77bdef2ec612d8f446fd85752939093a33c4`. One
`bench-norestart.sh` window (live paused 14:56:15, `LIVE_RESUMED` 15:20:45
UTC; that copy of `bench.sh` never restarts live). Isolated loopback serves on
18190/18191 with `--no-join` and without `--autotune-candidate`, so the
self-check runs; lab config with `max_concurrency_override: 8` and
`continuous_batch_queue_limit: 16`. Each model was given 12 minutes
(`build/sc-window.sh`, `build/sc-one.sh`).

The self-check submits through the serve-path scheduler, whose hybrid window
is 16, and compares every row of a k-row batch with that prompt run alone.

| Model | Startup probes (window 16) | Self-check slot counts checked | Conformant | Decision when the cap ended |
| --- | --- | --- | --- | --- |
| A3B, fused MoE | parity 640/640, isolation `proven=true`, 0 divergences | k = 2 to 16 | all 15, no divergent row | `deferred`: every step at k = 17 failed with `backpressure` (see below) |
| 27B | parity 1024/1024, isolation `proven=true`, 0 divergences | k = 2 to 11 | all 10; at k = 8 one row first differed at a near-tie (token 34 of 48, margin 0.000), which FR-CB10 accepts | `pending` (27B steps are slow; the cap ended the run) |

No row diverged at the 16-step window in either model. Neither check reached a
decision inside the cap, so this window proves composition (the self-check
exercises and passes the hybrid window at every k it reached), not a final
grant. The tok/s in these lines are the self-check's own 48-token measurements,
not throughput evidence.

Side finding, not from this branch: with `continuous_batch_queue_limit: 16`
the A3B scheduler had 32 rows (`served_slots action=planned rows=32
configured=8 source=autotune`), and the self-check step at k = 17 is rejected
with `backpressure` every time (6 deferrals, backing off to 320 s), so the
ladder cannot pass 16 under that queue limit. The live config has the same
queue limit.

## Files

Studio home paths are replaced with `<studio-home>`.

- `build/`: the Studio scripts (`lab-serve.sh`, `probe.sh`, `exact.sh`,
  `tput.sh`, `sampler.sh`, `r015.sh`, `seq-c.sh`, `seq-d.sh`, `sc-window.sh`, `sc-one.sh`, `lab-serve-noat.sh`, `bench-norestart.sh`).
- `exact/<model>/`: proof header, log and JSON report.
- `probes/<probe>/`: the probe log lines and the `continuous_batching`
  section of `/v1/status`.
- `tput/` (8 slots) and `tput32/` (32 slots): `sweep.jsonl` (every attempt),
  `cells.txt` (span and verdict per attempt), `samples.log`, `header.txt`.
- `selfcheck/`: window console, live samples, and per model the header,
  probe and self-check log lines, and the `continuous_batching` status section.
- `r015/`: frozen policy and freeze record, status, hardware-e2e and bench
  logs, contamination and sample logs, gzipped JSONL, analyzer output.

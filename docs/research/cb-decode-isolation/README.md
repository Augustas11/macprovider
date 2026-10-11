# Continuous-batching decode isolation: Studio evidence (2026-10-10)

Studio M3 Ultra. The live `:8080` provider was paused with
`lab-cb-sampling/bench.sh` for every GPU run listed as a window. Lab
loopback serves ran on ports 18195-18199. A 2 s sampler recorded the live
provider's `requests_in_flight` and other inference processes' CPU, and a
throughput cell with any nonzero live sample would have been discarded.
None was: every cell below is clean. Studio paths are replaced with
`<studio-home>` / `<studio-tree>`.

## Builds

| Build | Source | Lab-harness release binary SHA-256 | `mlx.metallib` |
| --- | --- | --- | --- |
| main (baseline) | `2bddd66d0` (#1953, 16-step hybrid window) | `89fc69eb…` | `f42aef60…` |
| per-row (window 1-2) | `f39cb1239` | `0706b09b…` | `f42aef60…` |
| narrowed (window 3-4) | `404d51905` | `0839badb…` | `f42aef60…` |
| final (R015) | `3db5fd811` (code identical to `189565ef0`, after the three-lane audit) | `98952ac604cb750082cbb72a775627a99684fd43a363f712717813d78cda4a0a` | `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` |

Pinned forks are unchanged: mlx-swift-lm `3.32.3-macprovider.6`, mlx-swift
`0.32.3-macprovider.2`, MLX core `v0.32.2-macprovider.2`.

## 1. The bug, bitwise (served models)

`CBDecodeIsolationProbeTests` loads the served artifact and prefills rows of
different lengths, each row alone. It then decodes the rows together through
the backend's shared decode step and compares every step's logits, bit for
bit, with the same row decoded alone. `bitwise/` and
`audits/2026-10-10-cb-decode-isolation/probes/` hold the raw lines.

Before (origin/main `0117e6a72` plus the probe only), 5 rows of
600/901/1501/3000/9000 keys, 4 steps:

| Model | Rows under 1024 keys | Rows of 1501+ keys |
| --- | --- | --- |
| A3B fused MoE on | not bitwise, logits up to 0.75 apart | bitwise |
| A3B fused MoE off | not bitwise, up to 0.70 apart | bitwise |
| 27B | not bitwise, up to 0.44 apart | bitwise |

This is the vector-attention route: a short row alone takes one pass, but
beside a row past 1024 keys the padded call takes two passes.

After (narrowed build), 16 rows of 300-16380 keys crossing 1024 and 16384
inside a 16-step serve window, 16 steps, every row and step:

| Model | Capped (11 + 5 rows per forward) | Uncapped (16 rows in one forward) |
| --- | --- | --- |
| A3B fused MoE on | 256/256 bitwise, 0 tokens flipped | 255/256 not bitwise, **31 greedy tokens flipped** |
| A3B fused MoE off | 256/256 bitwise, 0 tokens flipped | 255/256 not bitwise, **38 greedy tokens flipped** |
| 27B | 256/256 bitwise, 0 tokens flipped | 255/255 not bitwise, **30 greedy tokens flipped** |

**The decode row bound is a correctness bound, not only a numeric one.**
At 16 rows every projection whose `get_qmv_batch_limit` is 12 moves from
`qmv` to `qmm`. Rows then emit different greedy tokens from their lone
runs, with logits up to about 32 apart once they diverge. Capped at 11
rows per forward, every row's every logit matches its lone run.

## 2. Packed native-MTP verification

`testServedModelVerifyRowsMatchTheirLoneLogitsBitwise`, A3B fused on, width 2
(one proposal, the hybrid maximum), one forward per round (no bound):

| Rows | Target tokens (M) | Result |
| --- | ---: | --- |
| 2 | 4 | bitwise |
| 5 | 10 | bitwise |
| 8 | 16 (≥ limit 12) | 8/8 rows not bitwise, logits up to 1.1 apart; one row's runner-up token changed |

The backend now verifies a round in consecutive packed forwards of at most 11
target tokens on the Studio (`verifyNativeMTPPackedRound`).

## 3. Startup probes (per-row build, inside window 1)

A3B fused on, A3B fused off, 27B: parity `established=true` (640/640,
640/640, 1024/1024), batched isolation `proven=true rowsDecoded=2
rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true`, CB active,
`paged_kv_decision=attached`, `continuous_batch_decode_row_bound
max_decode_rows_per_forward=11`, grouping 128/128/33 (`startup/`).

## 4. Throughput (aggregate output tok/s, clean cells)

`depth_sweep.py` closed loop, unique salted prompts, greedy, streamed. The
lab config served 16 slots (owner-pinned) with queue 64.

A3B, 1800-token prompts / 1024 output, 20 s warmup + 60 s:

| Rows | main | per-row (all padded rows split) | narrowed (route classes) |
| ---: | ---: | ---: | ---: |
| 1 | 104.6 | 104.4 | - |
| 2 | 138.2 / 138.2 | 137.3 | 137.5 |
| 4 | 175.2 / 179.6 / 178.1 / 174.8 | 161.3 / 171.9 / 172.6 | 174.2 |
| 8 | 219.5 / 217.1 | 222.2 | 219.5 |
| 16 | 258.5 / 258.0 | 247.6 (cap); 257.6 uncapped | 251.6 (cap) |

27B, 512-token prompts / 128 output, 20 s warmup + 90 s:

| Rows | main | narrowed |
| ---: | ---: | ---: |
| 1 | 22.8 | 22.8 |
| 2 | 28.7 | 28.0 |
| 4 | 31.0 | 32.0 |
| 8 | 36.2 | 34.0 |
| 16 | 37.9 | 35.8 |

- Splitting every padded row cost about 4% at 4 A3B rows. The narrowed build
  keeps one padded call for rows on its route and recovers it.
- In these shapes every row sits in one route class (A3B rows 1800-2824
  keys; 27B rows under 1024 keys). So the narrowed build makes the same
  attention calls as main, and the remaining differences up to 16 rows are
  noise.
- At 16 rows the cap splits the forward into 11 + 5 and costs about 2.5-5%.
  Section 1 is why it stays.
- A mixed-length shape (rows straddling 1024 keys), which puts the split
  path itself on record, is listed in the PR as follow-up evidence if no
  window was left for it.
- The window-2 27B cells used the 1800/1024 shape: almost no request
  finished inside 60 s, so they are not reported.

## 5. Native-MTP R015 (SPEC-048), final build

The decode and verify paths changed, so R015 ran again (AGENTS rule 2). The
changed lines are `PagedKVBatchLayerCache.updateAndAttend`, the decode row
split in `ContinuousBatchScheduler.runOrdinaryDecodeStep`, and the packed
verify groups in `PagedKVSharedForwardBackend.verifyNativeMTPPackedRound`.

- **Policy:** `r015/policy.json`, SHA-256
  `75b90e0cc7fb5c08d27275ecf4457c052291bae7c76594c819c137ead2bde087`,
  frozen at 2026-10-10T22:26:23Z before any request
  (`r015/policy-freeze.txt`). It differs from `002929b3…` (the `8875789e7`
  PASS policy) only in `provider_commit` (`3db5fd811`) and
  `mlx_fork_revision` (`72c4ab08…`, the same field #1953's run changed).
  Compiled verify was on.
- **Runs:** two `bench.sh` windows. Window 5: hardware E2E and matrix (live
  paused 22:26:37, resumed 22:50:20 UTC). Window 6: sustained (paused
  22:51:23, resumed 23:22:33 UTC).

| Phase | Result |
| --- | --- |
| `native-mtp-hardware-e2e` (serve path) | exit 0 |
| `--phase matrix` | exit 0, 133 records |
| `--phase sustained` | exit 0, 215 records in total; JSONL SHA-256 `3ddc8fe0978e49dd2f7159242e67003a67ccb3d29ce642f8b7b7c25ad42afb41` |
| Analyzer | **`overall_status: PASS`** (exit 0), `r015/analysis.{json,md}` |

Gates vs `8875789e7` and #1953 (Holm-corrected bounds, fractions of the
ordinary arm):

| Cell | Decode LB 8875789e7 / #1953 / **now** | TTFT p95 UB 8875789e7 / #1953 / **now** | TPOT p95 UB now | Gap p99 UB now | Rejection UB | Status |
| --- | --- | --- | ---: | ---: | ---: | --- |
| s1-p1536-o128 | +25.5% / +27.7% / **+27.4%** | +5.0% / +4.7% / **+4.9%** | -21.5% | -7.9% | 0 | PASS |
| s1-p1536-o512 | +24.4% / +24.9% / **+25.9%** | +4.6% / +5.1% / **+5.0%** | -20.6% | -23.8% | 0 | PASS |
| s1-p4096-o128 | +20.6% / +20.7% / **+22.0%** | +7.1% / +6.1% / **+5.9%** | -18.1% | -18.0% | 0 | PASS |
| s1-p4096-o512 | +18.4% / +18.1% / **+18.5%** | +7.7% / +5.8% / **+6.0%** | -15.6% | -18.7% | 0 | PASS |
| s2-p1536-o512 (gated) | -0.5% / -0.4% / **-0.5%** | +4.5% / +3.1% / **+2.9%** | +0.4% | +0.5% | 0 | PASS |
| s8-p1536-o512 (gated) + sustained | -0.1% / -0.2% / **-0.4%** | +2.4% / +1.3% / **+3.2%** | +0.2% | +0.4% | 0 | PASS |

- **Parity:** 0 hard failures in every cell. Native acceptance rates equal
  #1953's run in every one-slot cell (0.881 / 0.850 / 0.939 / 0.855).
- **Memory:** the minimum available memory fraction was 0.603 (s8).
- **Contamination:**
  - `r015/contamination.log`: every readable `requests_in_flight` sample was
    0 (311 samples; 2 empty).
  - `r015/samples.log`: one unreadable (-1) sample, none nonzero.
- **Superseded:** a part-a run on `ae2b0da63`, before the audit fixes changed
  the decode/verify path, is kept in `r015-superseded-ae2b0da/`.

## 6. FR-CB10 self-check composition (#1947), window 7

A3B fused, 16 owner-pinned slots, lab serve without `--autotune-candidate`,
so the self-check runs (`selfcheck/`). Live was paused 23:24:01 and resumed
23:33:42 UTC; live `requests_in_flight` was 0 in all 210 readable 2 s
samples, and 3 samples were unreadable (-1).

| Build | k checked | Conformant | Divergent rows | Decision |
| --- | --- | --- | --- | --- |
| this branch (decode bound 11) | 2-16 | all | none | granted 16, verified_k 16 |
| main `2bddd66d0` (no bound) | 2-16 | all | two near-ties accepted (k=8 row 2 at token 39/48, k=14 row 13 at token 47/48, margin 0.125) | granted 16, verified_k 16 |

The self-check criterion (48 greedy tokens on short prompts, near-ties up to
1.0 logit accepted) does not catch the uncapped 16-row divergence of
section 1. The decode row bound therefore lives in the scheduler, and the
self-check measures the split execution above 11 rows.

## 7. Mixed-length throughput, window 8

A3B, prompts uniform over 300-2500 tokens per request (`build/mixed_sweep.py`),
256 output tokens, 20 s warmup + 90 s. Rows straddle the 1024-key route
switch, so the narrowed build splits short rows. Live was paused 23:34:31 and
resumed 23:53:15 UTC; all 422 live samples were 0 and every cell was clean.

| Concurrent | main (2 cells) | this branch (2 cells) |
| ---: | ---: | ---: |
| 8 | 155.5 / 138.8 | 134.0 / 135.7 |
| 16 | 156.6 / 150.1 | 139.7 / 145.1 |

Main's own repeats differ by about 11% at 8 and 4% at 16, so this shape is
noisy. Read conservatively, the split path costs roughly 2-13% at 8
concurrent and about 7% at 16, where the 11 + 5 cap split is included.
This is the price of exact row isolation when short and long rows decode
together.

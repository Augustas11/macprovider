# Network benchmark v0.3.1 — post-#249 + #250 baseline (2026-06-29)

Internal. Source: harness scenarios 01-10 against live `api.streamvc.live` at
gateway `v1.6.1-61-g1e598b1` (today's main, includes both [#249](https://github.com/Augustas11/macprovider/pull/249) and [#250](https://github.com/Augustas11/macprovider/pull/250)). 53-minute total wall-clock for 10 scenarios (16:24:31Z → 17:17:05Z UTC). Provider fleet: 2 ready (`augustass-macbook-air` serving Qwen3-32B-4bit; `air5` serving Qwen2.5-Coder-7B-Instruct-4bit).

## What this baseline locks in

This is the first benchmark run with **all three diagnostic-clean layers** in place:

1. **Reconciler attribution is honest.** [#249](https://github.com/Augustas11/macprovider/pull/249) added exact-id matching, account-consensus pinning, by-ID clock-skew recovery, 90s pre-snapshot quiesce, and a forward-only snapshot window. No more false-positive cross-scenario orphans, no fuzzy-match collision, no population-mismatched token sums.
2. **Per-pair drift basis.** [#229 R2](https://github.com/Augustas11/macprovider/pull/229) (basis `per_matched_pair_v2`) replaces aggregate-sum drift that false-fired on fallback-heavy runs.
3. **Per-request provider attribution.** [#250](https://github.com/Augustas11/macprovider/pull/250) surfaces `X-Provider-Id` on every success-path response. B5 (slot utilization) and B6 (provider earnings) **produce real signal for the first time** instead of universal `SKIP`.

Any future regression in money-path billing, fleet behavior, or per-Mac economics can be compared against the numbers here.

## Headline scoreboard

### Hard invariants (I1–I4)

| Scenario | I1 | I2 | I3 | I4 | Note |
|---|---|---|---|---|---|
| 01 happy_path_concurrent | ✅ | ✅ | ✅ | ✅ | |
| 02 capacity_contention | ✅ | ✅ | ✅ | ✅ | |
| 03 sticky_multi_turn | ✅ | ✅ | ✅ | ✅ | |
| 04 wrong_model | ✅ | ✅ | ✅ | ✅ | |
| 05 mid_stream_drop | ❌ | ✅ | ✅ | ✅ | 1 coord 2xx unmatched (F-3 known: SSE undercount on stream_truncated outcome) |
| 06 cold_start_race | ✅ | ✅ | ✅ | ✅ | |
| **07 sustained_throughput** | ❌ | ✅ | ✅ | ✅ | 33 coord 2xx unmatched (background traffic) + **gateway over-billed +16 tok across 3 pairs** (issue #255) |
| 08 cold_warm_compare | ✅ | ✅ | ✅ | ✅ | |
| 09 streaming_ttft_distribution | ❌ | ✅ | ✅ | ✅ | 2 coord 2xx unmatched (F-3 + F-8 known) |
| 10 provider_session_economics | ✅ | ✅ | ✅ | ✅ | |

**7 of 10 clean. 3 I1 fails share one shape: coord saw success, harness undercounted.** This is the pre-existing F-3 (`stream_truncated` outcome) / F-8 (SSE chunk parser undercounts) class — a harness-side gap, not a money-path regression. Money-path I3 (no overcharges) passes on every scenario at the structural level; per-pair DB-level signal carries the real money-path verdict (see #255).

### Benchmark verdicts (B1–B7)

| Scenario | B1 TTFT | B2 TPS | B3 Tail | B4 Err/1k | B5 Util | B6 $/hr | B7 Cold/Warm |
|---|---|---|---|---|---|---|---|
| 07 sustained_throughput | PASS 329ms | FAIL 10.6 tok/s | PASS 2.05 | FAIL 280 err/1k | **FAIL 10.5%** | — | — |
| 08 cold_warm_compare | PASS 353ms | — | — | — | — | — | PASS |
| 09 streaming_ttft_distribution | PASS 317ms | — | PASS | — | — | — | — |
| 10 provider_session_economics | — | — | — | — | **FAIL 4.1%** | **FAIL $0.005/hr** | — |

B5 and B6 carrying real values is the unlock — previous baselines had universal `SKIP` on both.

## Per-provider economic breakdown (scenario 10, 11-min window)

| Provider | Requests | Tokens delivered | Busy time | Slot util | **Earnings** |
|---|---|---|---|---|---|
| `air5` | 50 | 297 | 92.7s | 4.66% | **$0.0057/hr** |
| `augustass-macbook-air` | 12 | 384 | 69.0s | 3.47% | **$0.0023/hr** |
| **aggregate** | | | | **4.06%** | — |

Both providers are **50–150× below the B6 bare-min** ($0.30/hr) — the network is roughly **three orders of magnitude** below sustainable provider economics at current pricing × current fleet TPS. Tracked as [#222](https://github.com/Augustas11/macprovider/issues/222).

## Buyer-side network performance (where it succeeded)

| Metric | Scenario 07 | Scenario 09 | Scenario 10 | Notes |
|---|---|---|---|---|
| TTFT p50 | 329ms | 317ms | 1493ms | tight on small models; 1.5s on Qwen3-32B reflects model load |
| TTFT p95 | 630ms | 523ms | 5807ms | well under bare-min 2500ms on small models |
| TTFT p99 | 674ms | 614ms | 6018ms | |
| Wall p50 (max=64 tok) | 6340ms | 2242ms | 1493ms | |
| Wall p95 | 10216ms | 2465ms | 5807ms | heavy tail on sustained-throughput → effective concurrency exceeds N=3 cap |
| Tail ratio p99/p50 | 2.05 | 1.94 | 4.03 | sc10 tail high because cold/warm mix |
| Streaming TPS p50 | 10.6 tok/s | 4.2 tok/s | — | hardware floor (M4 Air mid-tier); B2 FAIL is fleet-shape problem |
| Error rate per 1k | 280 | 273 | 374 | dominated by 503 (over-cap rejection) |

TTFT solidly under target on the median. The tail (p99 ≈ 10s on scenario 07) is what pushes effective concurrency above the N=3 cap and creates the 28–37% error rate band on saturation scenarios.

## What the data says is broken vs limited vs working

### Working
- **End-to-end identity propagation** is clean. Harness → gateway → coord all carry the same `X-Request-Id` (verified via I1 reconciliation matching exactly on shared id).
- **Mid-stream-drop settlement** lands the `stream_truncated` row correctly (F-3 backend fix verified; the I1 fail is only the harness-side counter, not lost billing).
- **Cold-start race** returns retryable 503 instead of 404 (F-4 fixed).
- **Rate-limit headers** present on 429s — SDKs can self-pace (F-1 fixed).
- **Cold/warm TTFT ratio = 0.97** (B7 PASS) — MLX-on-Apple-Silicon keeps weights resident; cold-start is essentially free after brief idle.

### Real money-path bug surfaced
- **Scenario 07: gateway over-counts streaming completion_tokens by +4 / +5 / +7** on three matched pairs, all hitting `air5` × `Qwen2.5-Coder-7B-Instruct-4bit`. Harness and coord agree on the count; gateway disagrees. Filed as [#255](https://github.com/Augustas11/macprovider/issues/255).

### Hardware/fleet limits
- **Streaming TPS** is hardware-bound on Apple Silicon at 4–17 tok/s for these models. Won't compress without higher-end M-series.
- **Sustained throughput** caps at ~28% error rate on the current 2-provider fleet because wall-time p95 = 10s vs interval = 5s → effective concurrency exceeds N=3 cap on bursts. Providers idle 90%+ of the window between bursts — sticky affinity ([#170](https://github.com/Augustas11/macprovider/issues/170), `enabled: false` in prod) is the highest-leverage near-term move.

### Known harness gaps (deferred)
- **F-8 SSE token undercount.** Harness's SSE chunk parser counts 0 completion tokens for some streaming responses where the gateway settles at the configured max. Surfaces as `harness=0 gw=N coord=0` matched pairs (33 such on scenario 07, drift filtered out by the per-pair signed-cancel logic). Not money-path; harness measurement bug only.
- **No demo-flow coverage.** All scenarios use authenticated bearer-key buyers. The demo path (`SettleDemoReservation`, `demo_usage_events`, composite-PK from #210) is a separate money-handling surface the harness does not exercise.
- **No receipt + payout pipeline e2e.** SPEC-015 v0.3 + SPEC-016 v0.1.21 IMPL ship the USDC-on-Base flow. The harness verifies billing reconciliation but never checks a receipt was signed correctly or that the on-chain credit lands.

## Comparison vs prior baselines

| Metric | 06-29 baseline | 06-29 post-#250 | Δ |
|---|---|---|---|
| Phase-A I1 fully clean | 6/6 | 5/6 (sc05 I1 fail) | -1 (harness F-3 surfaced after #249 reconciler tightening; was masked by aggregate-sum drift before) |
| Phase-B I1 clean | 0/4 (sc07 reconciler bug) | 3/4 (sc07 real money-path bug remains) | +3 |
| B5 verdicts | SKIP everywhere | **FAIL with values** (4–10%) | unlocked |
| B6 verdicts | SKIP everywhere | **FAIL with values** ($0.002–0.006/hr) | unlocked |
| Sc07 non-2xx rate | 42% | 28% | -14pp |
| Sc09 non-2xx rate | 39% | 27% | -12pp |
| Sc07 gateway overbill | +32 (aggregate, partly attribution noise) | +16 (3 pairs, real per-request) | scoped to actual bug |

The error-rate improvements on 07/09 reflect both the re-tune (#227) and the per-provider stability from #195 X-Request-ID propagation landing. The B5/B6 unlock is purely #250.

## What this baseline triggers

The next harness rerun should fire when one of the following lands:

1. **[#170](https://github.com/Augustas11/macprovider/issues/170) sticky affinity** — measure B5 / B7 delta (expect slot util ↑, tail ratio ↓)
2. **[#255](https://github.com/Augustas11/macprovider/issues/255) gateway tokenizer fix** — confirm 0 overbill on `air5 × Qwen2.5-Coder-7B-Instruct-4bit`
3. **Any pricing change** on coord — measure B6 delta
4. **Any fleet change** (new provider joins, existing one drops, hardware upgrade) — re-baseline B5/B6 per-provider

No reason to keep iterating the harness itself. Comparable post-trigger reruns should produce a `BENCHMARK_BASELINE_2026-MM-DD-post-issNNN.md` companion doc.

## Artifact bundles

All under `test/network-harness/artifacts/` on branch `chore/v0-3-rerun-post-iss250`:

- `01_happy_path_concurrent-20260629T162432Z/`
- `02_capacity_contention-20260629T162639Z/`
- `03_sticky_multi_turn-20260629T162843Z/`
- `04_wrong_model-20260629T163104Z/`
- `05_mid_stream_drop-20260629T163303Z/`
- `06_cold_start_race-20260629T163527Z/`
- `07_sustained_throughput-20260629T163727Z/` ← contains `ledger_reconcile.json` with the 3 overbill pair details for #255
- `08_cold_warm_compare-20260629T164550Z/`
- `09_streaming_ttft_distribution-20260629T165730Z/`
- `10_provider_session_economics-20260629T170333Z/` ← contains `benchmark_summary.json` with per-provider economics

Each bundle contains: `per_request.jsonl`, `metrics_summary.json`, `ledger_reconcile.json`, `invariants.json`, `benchmark_summary.json`, `benchmark_verdict.json`, `run_meta.json`, `scenario.yaml`.

# SPEC-NETWORK-BENCHMARK v0.1 — phase-B network performance benchmark

Status: DRAFT. Audience: harness maintainers + ops + investors-facing demo.
Source of truth: this file. Last updated: 2026-06-28.

## 1. Purpose

The phase-A hard invariants (I1-I4) prove the money-path is correct —
"the network does not lie." This SPEC extends the harness with a
**performance benchmark suite** that answers the orthogonal question:

> Is the network FAST and ECONOMICALLY VIABLE — for buyers AND for
> providers — at the volumes we'd want to ship to?

Phase-A is pass/fail. The benchmark is **quantitative + comparative**:
each metric has a numeric value, a target threshold, and a baseline
artifact that future runs compare against.

## 2. The two audiences

### 2.1 Buyer-side ("is the network fast enough that I'd pay for it?")

A buyer SDK author or end-user cares about:

- **TTFT** — time to first token. Threshold for "feels instant": p50 ≤ 800ms.
- **Streaming throughput** — tokens/sec sustained during streaming.
  Threshold for "comfortable reading speed": ≥ 30 tok/s p50.
- **End-to-end wall time** — full request lifecycle. Threshold for
  "doesn't feel laggy": p95 ≤ 8s for short completions.
- **Tail latency** — p99 to p50 ratio. Threshold for "feels reliable":
  ≤ 3× (so p50=2s → p99 ≤ 6s).
- **Error budget** — non-2xx per 1000 reqs at sustained load.
  Threshold: ≤ 5/1000 (0.5%) under nominal concurrency.

### 2.2 Provider-side ("is it worth running my Mac on this network?")

A provider operator cares about:

- **Requests/min admitted** — net of refusals/queue rejections.
- **Slot utilization %** — fraction of time at least one of the
  provider's slots is actively processing a request.
- **Mean session duration** — uninterrupted WS-connected window.
  Threshold for "stable": ≥ 4 hours mean.
- **Effective TPS delivered** — tokens-served/wall-second over a window.
- **Earnings/hour** — at current tier-2 pricing × delivered tokens.
  Threshold for "M-series viable": $1.00/hr (covers electricity + amortized hw).
- **Connection reliability** — disconnect events/24h.
  Threshold: ≤ 1/24h (matches FR-B6 / SPEC-002 expectations).

## 3. Measurement methodology

Every benchmark metric has 3 components: SOURCE, DERIVATION, THRESHOLD.

### 3.1 Sources

- **Harness wire-side** — what the buyer SDK observes: TTFT,
  byte-arrival timestamps, content-length, status code. Already
  captured in `per_request.jsonl` + `buyer.Result.StartUTC/LastByteUTC`.
- **Gateway SQLite** — `usage_events.{prompt_tokens, completion_tokens,
  outcome, created_at}` per request.
- **Coordinator SQLite** — `request_log.{provider_id, status, tokens,
  ts_utc}` per request. Also `provider_log` for session events.
- **Tier-2 pricing manifest** — `tier2-catalog.json` per-model
  per-1000-token rates. Already on Pearl at `/opt/macprovider/`.

### 3.2 Derivations (formulae)

```
TTFT_ms             = (first_byte_utc - request_sent_utc) * 1000
streaming_tps       = completion_tokens_received / (last_byte_utc - first_byte_utc)
wall_time_ms        = (end_utc - start_utc) * 1000
error_rate_per_1k   = 1000 * non_2xx_count / total_requests
requests_per_min    = 60 * total_requests / window_seconds
slot_util_pct       = 100 * busy_provider_seconds / (provider_slots × window_seconds)
earnings_usd_per_hr = 3600 * Σ(tokens_served × $/token) / window_seconds
session_duration_s  = ws_disconnect_ts - ws_connect_ts  (per provider, per session)
```

### 3.3 Thresholds (v0.1 — refine as we collect baselines)

| Metric | Target | Bare-min | Notes |
|---|---|---|---|
| TTFT p50 | ≤ 800ms | ≤ 2000ms | streaming reqs only |
| TTFT p95 | ≤ 2500ms | ≤ 5000ms | |
| TTFT p99 | ≤ 5000ms | ≤ 10000ms | |
| Streaming TPS p50 | ≥ 30 tok/s | ≥ 15 tok/s | post-TTFT |
| Streaming TPS p95 | ≤ TPS_p50 × 0.5 | — | tail floor |
| Wall-time p95 (short) | ≤ 8000ms | ≤ 15000ms | max_tokens ≤ 100 |
| Tail ratio (p99/p50) | ≤ 3.0 | ≤ 5.0 | |
| Error rate per 1k | ≤ 5 | ≤ 25 | under nominal load |
| Slot util % | ≥ 40% | ≥ 15% | over a 5-min steady window |
| Earnings/hr (M-series) | ≥ $1.00 | ≥ $0.30 | at current pricing |
| Session mean | ≥ 4hr | ≥ 1hr | requires longer windows than per-run scenarios |

A scenario PASSES if all its declared metrics hit `Target` or better.
WARN if hits `Bare-min` but misses `Target`. FAIL otherwise.

These are **v0.1** — they should be calibrated against the first 3-5
runs we collect and adjusted upward as the network stabilizes.

### 3.4 Comparability across runs

Two artifacts MUST be produced per benchmark run:

1. `benchmark_summary.json` — numeric values, p-percentiles, derived
   thresholds. Schema below.
2. `benchmark_verdict.json` — per-metric PASS / WARN / FAIL classification.

A separate `baselines/` directory in the harness tree stores the
historical best-known value per scenario per metric. New runs append
to `runs/<ts>/` and the harness emits a `regression_report.md`
comparing new-vs-baseline (Δ%, direction). A regression is any drop
≥ 20% from baseline that survives a 3-run smoothing window (so a
single bad run doesn't trip the alert).

### 3.5 Benchmark invariants (B1-Bn) — orthogonal to hard invariants I1-I4

| ID | Title | Trigger |
|---|---|---|
| B1 | TTFT not regressed | p50 within 20% of baseline |
| B2 | Streaming TPS not regressed | p50 within 20% of baseline |
| B3 | Tail ratio bounded | p99/p50 ≤ 3.0 |
| B4 | Error rate bounded | ≤ 5/1000 |
| B5 | Slot util reasonable | ≥ 15% over 5-min window |
| B6 | Earnings/hr viable | ≥ $0.30/hr at current pricing |
| B7 | Cold/warm TTFT ratio bounded | cold p50 / warm p50 ≤ 2.0 (scenario 08) |
| B8 | Sticky cache-reuse retention | median cached_prompt_tokens / prompt_tokens ≥ 0.40 on warm turns (scenario 16, provider prefix-cache probe) |
| B9 | Cached-turn latency advantage | cached vs uncached full-response p50 latency ratio ≤ 0.90 (scenario 16) |

Like I1-I4, each invariant produces a structured verdict (PASS / WARN /
FAIL + supporting evidence). Unlike I1-I4, WARN does not block the run —
and neither does a benchmark FAIL: benchmark verdicts are **advisory**,
they do not change the harness exit code. A continuous/phase-C gate must
parse `benchmark_verdict.json` and act on B8/B9 itself.

B8/B9 **SKIP** rather than FAIL in every inconclusive case — the gateway
omitted the usage frame (spec-strict path), the scenario did not run the
`sticky_cache` pattern, every request failed, a provider reported an
impossible `cached_prompt_tokens > prompt_tokens`, or fewer than 3 valid
warm samples were measured — so a missing or untrustworthy measurement is
never mistaken for a regression.

B8/B9 are **calibration-pending**: the 0.40 floor and 0.90 ratio are
provisional and were NOT calibrated against a positive baseline — the
2026-07-22 scenario-16 prod run measured ~0 reuse on the live pool (both
served models report `cached_prompt_tokens = 0`; the ~0.64 figure from
2026-07-09, #376, was a different provider/prefix context). While
`benchmark.cache_calibration_pending` is true the invariants record the
measured value but SKIP the PASS/WARN/FAIL, so an unsupported-capability
pool is not mistaken for a regression. Arm the gate (flip the flag to
false and transcribe the floor from the real median, with headroom) once
a reuse-capable provider is in the pool. B9 is a full-response latency
ratio (these turns are non-streaming, so not TTFT) and carries a known
cold-turn connection-setup bias to calibrate out before arming.

## 4. New scenarios (07-10)

### 4.1 `07_sustained_throughput`
- **What**: 5-min steady load at N=2 concurrent buyers, max_tokens=64.
- **Measures**: streaming TPS distribution, wall-time distribution,
  error rate, slot utilization.
- **Invariants**: B1, B2, B3, B4, B5.

### 4.2 `08_cold_warm_compare`
- **What**: 10 pairs of (cold, warm) requests under the `cold_warm_pairs`
  buyer pattern. Each pair sleeps `inter_pair_idle_seconds` (60s default)
  before firing the "cold" request, then fires the "warm" request
  immediately after.
- **Measures**: TTFT cold (post-idle) vs TTFT warm (immediately after).
  Reports both distributions, the cold-warm gap, and the p50 ratio.
- **Invariants**: B1 (aggregate TTFT vs target), B7 (cold/warm ratio).

### 4.3 `09_streaming_ttft_distribution`
- **What**: 100 short streaming requests, max_tokens=8, sequential
  with 500ms gap.
- **Measures**: TTFT histogram + percentiles.
- **Invariants**: B1, B3.

### 4.4 `10_provider_session_economics`
- **What**: 10-min observation window. Harness fires 1 req every 5s
  (low load) to keep providers warm; measures session continuity +
  delivered tokens.
- **Measures**: requests/min, slot_util, earnings/hr at current
  tier-2 pricing, session_duration.
- **Invariants**: B5, B6 (B7 session-mean deferred — needs >>10-min
  windows).

### 4.5 `16_sticky_cache_reuse`
- **What**: 1 buyer × 8 sequential non-streaming turns under the
  `sticky_cache` pattern (single buyer because the live pool serves each
  model from one single-slot provider — concurrent buyers contend and
  503). The harness prepends a per-run deterministic ~2.7k-token prefix
  (`cache_prefix_lines`, sized under the live 4000-token context cap) to
  every request under a sticky conversation tag. `request_index` 0 is the
  cold uncached first-touch that warms the provider prefix cache;
  `request_index` 1..7 are the warm cached turns that reuse it. Mirrors
  `test/e2e/canary-buyer/probe.mjs`.
- **Measures**: turn-2+ provider prefix-cache reuse (`cached_prompt_tokens
  / prompt_tokens`) and the cached-vs-uncached full-response latency
  advantage.
- **Invariants**: B1 (aggregate TTFT), B8 (cache-reuse retention),
  B9 (cached-turn latency advantage).
- **Phase C — regression-gate instrument**: the eventual guard for the
  #376 reuse win. Intended to be wired as a scheduled/CI run that parses
  `benchmark_verdict.json` (benchmark verdicts are advisory — they do not
  set the exit code). Ships **calibration-pending** (B8/B9 record but SKIP)
  because the 2026-07-22 baseline measured ~0 reuse on the current pool;
  arm it once a reuse-capable provider is present and the floor is
  transcribed from a positive baseline. As a single-provider probe it
  measures the provider prefix cache, not sticky routing — the routing
  dimension needs ≥2 eligible providers plus an affinity assertion.
  Requires sticky routing ON (`routing.sticky_enabled: true` on both
  sides + gateway `auth.key_hash_secret`). Light and prod-safe (~8
  requests, order of cents).

## 5. Artifact schema (`benchmark_summary.json`)

```json
{
  "scenario": "07_sustained_throughput",
  "scenario_version": "v0.1",
  "run_id": "20260628T180000Z",
  "duration_seconds": 300,
  "buyer_metrics": {
    "ttft_ms": {"p50": 612, "p95": 1840, "p99": 3210},
    "streaming_tps": {"p50": 42, "p95": 18},
    "wall_time_ms": {"p50": 2400, "p95": 6800, "p99": 9100},
    "tail_ratio_p99_p50": 2.7,
    "error_rate_per_1k": 3.0,
    "total_requests": 150,
    "non_2xx_breakdown": {"429": 2, "503": 1, "502": 0}
  },
  "provider_metrics": {
    "per_provider": [
      {"provider_id": "air5", "requests_admitted": 72, "tokens_delivered": 4608, "slot_util_pct": 48, "earnings_usd_per_hr": 0.82, "session_duration_s": 290},
      {"provider_id": "macbook-air", "requests_admitted": 78, "tokens_delivered": 4992, "slot_util_pct": 52, "earnings_usd_per_hr": 0.89, "session_duration_s": 300}
    ],
    "aggregate": {"slot_util_pct": 50, "earnings_usd_per_hr": 1.71}
  },
  "pricing_source": "tier2-catalog.json @ /opt/macprovider/2026-06-28T16:30:00Z"
}
```

## 6. Out of scope (phase B+)

- Multi-region buyers (Pearl is single-NYC).
- Tier-2 attested receipt verification benchmarks (separate harness).
- Buyer SDK fairness across competing accounts (already covered by I3 — overcharge — in phase-A).
- Long-window session-mean (B7) — needs orchestration outside per-run scenarios.

## 7. Open questions

- Should benchmark scenarios share `provider_log` SSH-snapshot tooling
  with phase-A scenarios, or pull a dedicated provider-side feed?
- How do we surface benchmark trends to operators — a Grafana board,
  or a static HTML report committed to the repo?
- Do we want a "synthetic stress" mode that pushes past `Bare-min`
  thresholds intentionally (chaos/capacity exploration), or is the
  steady-state benchmark sufficient for v0.1?

## 8. Acceptance for v0.1

- [ ] Schemas + invariants implemented in harness.
- [ ] 4 new scenarios run successfully against live Pearl.
- [ ] First-run baseline committed under `baselines/`.
- [ ] `benchmark_summary.json` artifact produced per run.
- [ ] Documentation in `test/network-harness/README.md` covers
      benchmark usage + interpretation.

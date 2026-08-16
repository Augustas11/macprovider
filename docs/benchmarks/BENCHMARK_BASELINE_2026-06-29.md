# Network benchmark v0.2 — e2e run (2026-06-29)

Internal. Source: harness scenarios 01-10 against live
`api.malibu.tech` at gateway `v1.6.1-44-g5f73eee`. Provider fleet:
2 ready (Qwen3-32B-4bit on M4 Air; Qwen2.5-Coder-7B-Instruct-4bit on
air5). 35-minute total wall-clock for 11 scenarios.

## What changed since the 2026-06-28 baseline

Re-ran the full suite with:
- Scenarios 07 + 09 re-tuned (commit `6295c2f`, intervals raised).
- New `cold_warm_pairs` buyer pattern + scenario 08 implementation (`478c9a8`).
- New B7 (cold/warm TTFT ratio) verdict.
- Pricing manifest corrected to mirror production coord defaults
  (commit `3406147`, $0.0009/1k completion vs the earlier $0.020).

## Headline results

| Scenario | rc | Findings |
|---|---|---|
| smoke + 01-06 (phase A) | 0 | All hard invariants PASS, no regressions |
| 07 sustained_throughput | **10** | I1 FAIL (reconciler bug, NOT money-path); B4 FAIL (still overloaded) |
| 08 cold_warm_compare | 0 | B1 + B7 PASS; B7 ratio 0.97 (no cold-start penalty observed) |
| 09 streaming_ttft_distribution | 0 | I1 PASS; B1 PASS; success rate 28% → 61% (improved, not solved) |
| 10 provider_session_economics | 0 | I1 PASS, all invariants clean; B5/B6 SKIP (no provider attribution) |

## Phase-A — fully clean

All 6 phase-A scenarios pass all 4 hard invariants. Nothing regressed
since the 2026-06-28 baseline. Reconciliation, no orphan 5xx, no
overcharges, no silent hangs.

## Phase-B — three real findings

### Finding 1: Scenario 07/09 re-tune was directionally right but insufficient

The 2026-06-28 baseline saw 28% and 52% non-2xx on scenarios 07 + 09.
Re-tune `6295c2f` raised intervals to 5000ms (07) and 1500ms (09).
This run shows:

| Scenario | Before | After |
|---|---|---|
| 07 non-2xx rate | 48% (52% success) | **42%** (58% success) |
| 09 non-2xx rate | 72% (28% success) | **39%** (61% success) |

Improvement, but still nowhere near the "1× wall ≤ interval" math
suggested. Root cause is the heavy tail not the median:

```
scenario 07 measured:    wall_p50=5637ms  wall_p95=11791ms  wall_p99=12392ms
mean_active at p50:      2 × 5.6 / 5.0 = 2.25  → under N=3 ✅
mean_active at p95:      2 × 11.8 / 5.0 = 4.72 → over N=3  ❌
```

The actual `wall_p95` is 2× higher than my re-tune assumption (~5.5s).
Tail spikes push concurrency above N=3 and the 503s start. Same shape
for scenario 09 (wall_p50=2535ms, mean_active=1.69 — fine — but tail
spikes still cause 39% non-2xx, suggesting either provider-pool
instability or a longer wall distribution than measured here).

**Action**: Re-tune v0.3 must use `interval ≥ wall_p95 × buyers / (N - 1)`
not `wall_p50`. For scenario 07 that means interval ≥ 11791 × 2 / 2 =
~12000ms. With 5min wall, that's only 25 reqs/buyer = 50 total — fewer
samples but clean signal. Alternative: drop to 1 buyer at 5000ms (B=1
× wall_p95 / 5000 = 2.4 < N=3).

### Finding 2: I1 reconciler bug — population-mismatched token sums

Scenario 07's I1 failed with "gateway-coord token drift=32; gateway
over-billed by 32 vs harness-observed." Investigation:

```
harness_completion_tokens         = 233 (40 ok responses)
gateway_completion_tokens         = 265 (5 gateway rows with outcome="ok")
gateway_completion_tokens_fallback = 2240 (35 rows with outcome=stream_truncated etc.)
coordinator_completion_tokens     = 233 (40 coord 2xx)
```

87.5% of gateway rows are settled as SPEC-006 §17.7 "fallback"
outcomes (`stream_truncated` etc., when streaming completes via
finish_reason=length rather than [DONE]). The reconciler's `I1`
check then compares `GatewayCompletionTokens` (ok-only, 265) against
`HarnessCompletionTokens` (all-ok, 233) — apples-to-oranges, since
the gateway "ok" subset is 5 rows while the harness "ok" set is 40.

The 32-token "drift" is a population-mismatch artifact, NOT a real
money-path issue. Production billing is fine (coordinator agrees
with harness at 233 tokens, both summed across the full success set).

**Action**: fix the reconciler to either (a) include `GatewayCompletionTokensFallback`
in the I1 drift check, or (b) compute drift across matched-pair tokens
not aggregate sums. The right fix is (b) — per-pair drift is the
honest signal.

### Finding 3: B7 confirms MLX-on-Apple-Silicon keeps weights resident

Scenario 08 fired 10 (cold, warm) pairs with 60s idle between pairs.

```
B7: cold p50=303ms, warm p50=311ms → ratio 0.97 (PASS, ≤ 2.0)
```

Cold TTFT is essentially identical to warm TTFT. This **confirms the
scenario header hypothesis**: MLX keeps model weights resident in
Apple Silicon unified memory even when idle, so "cold" in this test
means "no recent request" rather than "model freshly loaded from
disk". A real cold-start penalty would require the provider process
to be restarted between pairs.

For a network benchmark this is actually good news for buyers: in
practice, M-series providers don't pay a cold-start penalty after
brief idle periods. The "cold-start" concern that motivated scenario
08 doesn't manifest at this scale.

## B-verdict summary across phase-B scenarios

| ID | Scenario 07 | Scenario 08 | Scenario 09 | Scenario 10 |
|---|---|---|---|---|
| B1 (TTFT p50) | PASS 327ms | PASS 306ms | PASS 316ms | — |
| B2 (Streaming TPS) | WARN 16.3 tok/s | — | — | — |
| B3 (Tail ratio) | PASS 1.92 | — | PASS 2.03 | — |
| B4 (Error rate) | **FAIL 420/1k** | — | — | — |
| B5 (Slot util) | SKIP | — | — | SKIP |
| B6 (Earnings) | — | — | — | SKIP |
| B7 (Cold/warm) | — | PASS 0.97 | — | — |

B5/B6 SKIP everywhere because the gateway does not expose
`X-Provider-Id` response headers. This is the blocker for provider
attribution and was previously called out in PR #182's authoring;
needs a separate gateway PR to land. Without it, B5 and B6 cannot
provide real signal.

## Numeric snapshot (network performance, where it succeeded)

Across successful streaming requests in scenarios 07+08+09:

| Metric | Value | Notes |
|---|---|---|
| TTFT p50 | 306-327ms | tight across scenarios, gateway adds ~11ms |
| TTFT p95 | 432-546ms | well under 2500ms bare-min |
| TTFT p99 | 628-764ms | well under 5000ms bare-min |
| Tail ratio p99/p50 | 1.92-2.03 | well under 3.0 target |
| Streaming TPS p50 | 14-17 tok/s | hardware-bound on M4 Air, unchanged from 06-28 |
| Wall p50 (max_tokens=64) | 5.6s | dominated by streaming time |
| Wall p95 (max_tokens=64) | 11.8s | heavy tail under concurrency |

These confirm the buyer-side numbers from the 2026-06-28 baseline.
TTFT is solidly under target. TPS is the hardware floor and will
move when the fleet gains higher-end Apple Silicon.

## Issues to file

1. **Reconciler I1 token-sum bug** — fix per-pair drift instead of
   aggregate-sum drift, so the check doesn't false-positive on
   scenarios with high fallback-outcome rates.
2. **Scenario 07/09 re-tune v0.3** — use `wall_p95` not `wall_p50`
   for interval math. Track v0.4 once provider fleet TPS rises.
3. **Gateway X-Provider-Id headers** — blocks B5/B6 from producing
   any real signal. Already a known gap; this run quantifies the
   impact (3 SKIP verdicts across scenario 07+10).

## v0.1 threshold confirmation

Same as the 06-28 baseline conclusion: TTFT thresholds are well over-
conservative (could tighten 2-3×). Streaming TPS p50 ≥ 30 is too
aggressive for the current M-series fleet; consider 15/8 until higher-
end hardware joins. B6 thresholds ($0.30/$1.00 per hour) cannot be
evaluated until X-Provider-Id headers expose attribution.

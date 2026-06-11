# Provider Economics & Lifecycle Reference

**Scope.** This document answers the questions a prospective or current provider
needs answered before and after joining the Mac Provider network. All numbers are
extracted directly from source; none are rounded or paraphrased.

Audience: Mac owners running `macprovider-cli`. For buyer-facing network limits
see `phase5-gateway/internal/router/templates/docs.md:130` ("provider availability
can change as Macs sleep, wake, or disconnect from the network").

---

## 1. What will I earn?

### Credit formula

Every request that reaches your Mac produces a `BilledRow` computed by
`ComputeCredits` in `phase4-coordinator/internal/billing/formula.go:86-175`.
The formula in steps:

```
grossCredits = RoundHalfEven(
    (promptTokens × promptRatePerMtok  +  completionTokens × completionRatePerMtok)
    × globalMultiplierPPM
    ÷ (1_000_000 × 1_000_000)
)

providerCredits = RoundHalfEven(grossCredits × providerShareBps ÷ 10_000)

operatorCredits = grossCredits − providerCredits
```

Constants (same file, lines 5-16):

| Symbol | Value | Meaning |
|---|---|---|
| `tokensPerMillion` | 1,000,000 | Rate card denominator |
| `globalMultiplierDenom` | 1,000,000 | PPM denominator |
| `providerShareDenom` | 10,000 | Basis-points denominator |
| `maxBillableTokens` | 10,000,000 | Per-field overflow guard |

**Default rate card** (`phase4-coordinator/internal/config/config.go:328-333`):

| Token type | Rate |
|---|---|
| Prompt | 500,000 credits per 1 M tokens |
| Completion | 1,000,000 credits per 1 M tokens |

The operator may override rates per model or add model-specific entries in
`coordinator.yaml` under `rewards.rate_card`.

**Global multiplier** (`config.go:326`): default `1.0` (i.e., 1,000,000 PPM —
no markup or discount).

**Banker's rounding.** Both `grossCredits` and `providerCredits` are computed
with `RoundHalfEven` (`formula.go:54-81`): ties (remainder × 2 == denominator)
round to the nearest even quotient, eliminating systematic bias across a large
volume of small requests.

**Token sourcing.** When the provider reports completion token counts the
coordinator uses them directly; when only byte-length is available it estimates
via `bytes/4` and clamps to the byte-estimate ceiling. Requests faulted as
`breaker_qualifying` or `null_usage_error` produce zero credits
(`formula.go:112-128`).

### Worked example

A request with 1,000 prompt tokens and 500 completion tokens at default rates
and default 90% provider share:

```
grossCredits = RoundHalfEven(
    (1000 × 500000 + 500 × 1000000) × 1000000
    ÷ (1000000 × 1000000)
) = RoundHalfEven(1,000,000,000,000,000 ÷ 1,000,000,000,000)

More clearly:
promptNumerator   = 1000 × 500,000    = 500,000,000
completionNumerator = 500 × 1,000,000 = 500,000,000
baseNumerator     = 1,000,000,000
rateScaled        = 1,000,000,000 × 1,000,000 = 1,000,000,000,000,000
grossCredits      = 1,000,000,000,000,000 ÷ 1,000,000,000,000 = 1000 credits (exact)

providerNumerator = 1000 × 9000       = 9,000,000
providerCredits   = 9,000,000 ÷ 10,000 = 900 credits (exact)
```

(Default share is 0.90 = 9,000 bps. See §2.)

---

## 2. What is the default provider share?

**Default: 0.90 (90%).** Config field: `rewards.provider_share`
(`phase4-coordinator/internal/config/config.go:327`).

Internally this is converted to basis points:
`providerShareBps = round(0.90 × 10,000) = 9,000 bps`
(`formula.go:50-52`).

The operator can override this globally or per-provider/per-model via
`coordinator.yaml`. The earnings endpoint always returns the *current* share bps
from the live config snapshot (see §4).

---

## 3. When do I get paid?

### Minimum payout threshold

Config field: `settlement.min_payout_credits`
(`phase4-coordinator/internal/config/config.go:337`).

Default: **500,000 credits.**

Settlement only produces a payout record for providers whose accumulated
`providerCredits` meets or exceeds this threshold
(`billing/settlement.go:62-66`, `HAVING SUM(provider_credits) >= ?`).

### Settlement cadence

Config field: `settlement.cadence_days`
(`config.go:336`). Default: **7 days.**

`StartWeeklySettlement` (`billing/settlement.go:135-156`) schedules `RunSettlement`
to fire at the next Monday 00:00 UTC, then repeats weekly. Each run covers a
`cadence_days`-wide window ending at that Monday midnight.

`settlement.job_enabled` (`config.go:341`) must be `true` (default) for
the job to execute — it is checked inside the timer loop at
`settlement.go:146-150`.

**In plain language:** credits accumulate all week; at Monday 00:00 UTC the
coordinator sweeps unsettled credits for every provider over the threshold and
marks them `ready` for payout.

**v1 payout boundary (SPEC-005 AC-DOCS-HONESTY / OQ-4).** v1 accrues credits
and emits payout-ready rows; the actual payout rail (USDC settlement) requires
SPEC-007 and an operator decision. Until that lands, "payout" means credits are
queued and visible via the earnings endpoint — not a real-money transfer.

---

## 4. How do I check my balance?

### Endpoint

```
GET /providers/{provider_id}/earnings
Authorization: Bearer <provider_token>
```

Auth: your provider Bearer token — the same token the binary uses to authenticate
to the coordinator WebSocket. The endpoint validates the token subject against the
URL `{provider_id}`; a mismatched subject returns 403
(`billing/endpoints.go:337-344`).

Rate limit: 60 requests per minute per provider (config field
`endpoints.provider_earnings.rate_limit_per_minute`, default 60,
`config.go:344-346`).

### Response shape

Extracted from `billing/endpoints.go:365-379`:

```json
{
  "provider_id":            "<string>",
  "total_credits":          <int64>,
  "current_window_credits": <int64>,
  "last_payout_ready": {
    "window_start_utc": "<RFC3339>",
    "window_end_utc":   "<RFC3339>",
    "provider_credits": <int64>,
    "status":           "<string>"
  },
  "provider_share_bps":  <int64>,
  "models_served":       ["<string>", ...],
  "rate_card_excerpt":   { "<model>": { "PromptCreditsPerMtok": <int64>, "CompletionCreditsPerMtok": <int64> } },
  "fault_count":         <int64>
}
```

The `rate_card_excerpt` field keys (`PromptCreditsPerMtok`, `CompletionCreditsPerMtok`) are the literal JSON-default rendering of the Go struct field names (`RateCardEntry` in `config.go:178-181` carries only `yaml` tags, so `encoding/json` uses PascalCase — not a snake_case API contract).

`last_payout_ready` is `null` if no settlement has run yet for this provider.
`current_window_credits` covers the period since the most recent Monday 00:00 UTC.

An optional day-range filter is accepted: `?from=YYYY-MM-DD&to=YYYY-MM-DD`
(max 31 days). When supplied, `from_utc` and `to_utc` are echoed back
(`billing/endpoints.go:376-378`).

### Example curl

```bash
curl -s -H "Authorization: Bearer $PROVIDER_TOKEN" \
  https://coordinator.streamvc.live/providers/$PROVIDER_ID/earnings
```

---

## 5. Pinning (provisional → pinned)

Newly installed providers join at the **provisional** tier. The coordinator
assigns `TierProvisional`, which carries lower routing weight
(`admission.provisional_tier_weight`, default 0.3) and a cap on provisional
pool size (`admission.provisional_pool_max`, default 100).

**Pinning is operator-discretionary today.** The operator promotes a provider
to `TierPinned` by adding an explicit `provider_id` entry in `coordinator.yaml`
and restarting. There is no automatic promotion trigger. The criteria in practice
are observed pool stability, uptime, and operator review.

Self-serve promotion is on the roadmap but is not implemented.

---

## 6. Lifecycle: why might my Mac drop?

### Sleep assertion

The binary holds a `caffeinate` process for the duration of its run
(`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:66-98`,
`CaffeinateSleepAssertion`). This prevents display sleep and user-idle system
sleep via `caffeinate -dimsu -w <pid>`. It does **not** prevent lid-close
sleep.

**Lid-closed sleep drops the WebSocket connection.** The binary will reconnect
automatically when the Mac wakes, but requests in flight during the sleep are
lost.

### Heartbeat reaping

The coordinator liveness monitor tracks the time since the last inbound frame
from each provider. The config field is `pool.heartbeat_miss_threshold_s`
(`phase4-coordinator/internal/config/config.go:53`, `HeartbeatMissThresholdS`).

Default: **90 seconds** (`config.go:242`).

If no frame (heartbeat or in-flight inference chunk) arrives within this window
the coordinator closes the WebSocket. The comment at `config.go:45-52` explains
the design intent: a provider doing single-threaded MLX inference may not emit a
heartbeat for the full generation duration, but streaming chunks count as
activity. 90 s is 3× the 30 s heartbeat interval.

After a disconnect the binary reconnects automatically; the coordinator issues a
new warmup probe before routing new requests.

### Warmup gate

After reconnect the coordinator holds the provider in a warmup state for up to
`pool.warmup_gate_timeout_s` seconds (default 90 s, `config.go:246`) while it
verifies the provider can handle requests. Requests during warmup are routed
to other pool members.

---

## 7. Consistency cross-link

The buyer-facing availability sentence in the deployed gateway docs
(`phase5-gateway/internal/router/templates/docs.md:130`):

> "Known limitations: provider availability can change as Macs sleep, wake,
> or disconnect from the network."

Buyers are told availability is best-effort. This doc is consistent with that
disclosure: sleep/lid events and heartbeat reaping are the exact mechanisms
behind that sentence.

---

*All values above are extracted from source at the working-tree state audited
on 2026-06-10. If `coordinator.yaml` on the production VPS overrides any default,
the live value takes precedence. File:line citations are stable as of the M3
milestone branch.*

# SPEC-002 v1.4.2 — routing-contract addendum (DRAFT)

**Status:** DRAFT, derived from phase-A network-harness findings 2026-06-27.
**Author intent:** consolidate the routing/error contract the network
**actually exhibits** under live conditions into a single normative
reference so the e2e harness (and external buyer clients) can assert
against it. Where current behavior is defensible, this addendum
**writes it down**. Where it is contradictory or a product call,
items are tagged `[PRODUCT DECISION]` and left to the maintainer.

This addendum proposes bumping SPEC-002 from v1.4.1 → v1.4.2 with the
clauses below. It does **not** yet propose code changes — each clause
is either documenting existing behavior (no code change) or naming a
deviation (code change tracked separately).

Findings narrative lives in
`docs/internal/phase-A-findings-2026-06-27.md` (internal).

## R-clauses (proposed)

Each clause is named `R-N` so harness scenarios can cite
`asserts: [R-3, R-7]` in their YAML (phase C will add these
assertions).

### R-1 — Per-account concurrency limit `[PRODUCT DECISION]`

A single buyer account is limited to N concurrent in-flight requests
across the gateway. Excess attempts receive `HTTP 429
rate_limit_exceeded` with a `Retry-After` header.

**Observed in phase A:** N appears to be very low (≤2). 10 concurrent
buyers from one account → 7×429 in scenario 02.

**Decision needed:** what value of N is the contract? Is it
configurable per-account? Today the limit is undocumented and lower
than the network's nominal capacity.

### R-2 — Capacity-exhaustion error code

When no provider has `slots_free ≥ 1` for a requested model and no
buyer-side rate limit has fired, the gateway returns:

```
HTTP 503
{
  "error": {
    "code": "provider_unavailable",
    "type": "service_unavailable",
    "message": "No provider available"
  }
}
```

**Observed in phase A:** scenarios 02 (capacity_contention) and the
post-warmup 503s in 03 confirm this code is emitted today.

### R-3 — Unknown model error code `[PRODUCT DECISION]`

When the requested model id matches no provider in the routable pool,
the gateway returns:

**Option A** (current code): `HTTP 404 not_found`.
**Option B** (current SPEC-002 FR-B1): `HTTP 503 no_provider_available`.

**Phase-A observation:** code emits Option A; spec says Option B.
**Decision needed:** keep the 404 (matches OpenAI semantics for
"endpoint/model not found") or fix the code to match the spec.

### R-4 — Mid-stream provider drop `[PRODUCT DECISION]`

When a provider's WebSocket dies during streaming inference, the
gateway terminates the SSE stream cleanly:

1. Emits a final `data: [DONE]` marker (so buyer's parser doesn't
   hang).
2. Returns HTTP status 200 (already sent at headers, can't change).

**Phase-A observation:** that's the current behavior. The gap is:

- Buyer receives partial content with no error signal.
- **No `usage_events` row is written** — provider isn't billed,
  buyer isn't charged.

**Decision needed:** one of
- **R-4a** Status quo: explicit contract that mid-stream drop = no
  charge, no provider compensation. Buyer client expected to detect
  truncation via content inspection.
- **R-4b** Settle partial: gateway writes a usage_events row with
  `outcome=stream_truncated` and tokens actually delivered. Buyer
  charged, provider compensated.
- **R-4c** Failover: gateway retries on a different provider with
  `excluded=[failed]`. Stream concatenates / restarts; buyer sees a
  warning header but ultimately gets full output.

### R-5 — Cold-start window `[PRODUCT DECISION]`

When the requested model has a provider connected but in a transient
unready state (model still loading, just-restarted, warming), the
gateway today returns the same code as "model doesn't exist" — see
R-3 deviation. This is indistinguishable to clients.

**Decision needed:** introduce a `model_warming` / `try_again` state
exposed as `HTTP 503 model_warming` with `Retry-After: <seconds>`?
Or accept the conflation as an acceptable simplification.

### R-6 — Request-id space (factual, not a decision)

**Gateway** generates a request id (UUID v4) per inbound request and
returns it via `X-Request-Id` response header. This id is the
authoritative buyer-facing identifier.

**Coordinator** generates an **independent** request id when the
gateway forwards inference traffic over the WS tunnel. This id is
stored in `request_log.request_id`.

**These two ids never overlap.** There is currently no field on
either side that correlates them.

**Implication for reconciliation:** out-of-process auditors (the
network harness, any future SRE audit script) must correlate by
`(ts ± window, model, completion_tokens, account)`, not by request_id.

**Engineering follow-up (separate work item, not this addendum):**
plumb a shared `correlation_id` — see issue #N.

### R-7 — Sticky affinity (default OFF)

`/v1/models` `tier1_disclosure.sticky_affinity.enabled` reports the
authoritative state. Today: `false`. Multi-turn requests with the
same `conversation_key` are NOT preferentially routed to the same
provider; tie-breaking uses the SPEC-002 v1.4.1 § 5 default-objective
(sortCandidates → `SlotsFree` asc, `throughput_tps` desc, random
within epsilon on `requestID`).

**Decision needed for v1.5+:** if sticky becomes enabled, the disclosure
flips and this clause updates. No protocol changes required.

### R-8 — Silent provider disconnection (operational, not protocol)

A provider whose WS dies but whose host process remains alive is
detectable from the coordinator via heartbeat timeout (90s
`provider_inactive_threshold` per current code). The coordinator's
contract is "drop after threshold; do not route to the dead provider"
— this is functioning correctly.

The PROVIDER-SIDE contract obligation is: when the WS dies, the
provider MUST re-establish within a bounded time
(`reconnectGraceNanoseconds`, currently 10s post-drain) OR exit.

**Phase A finding:** a class of bug exists where the Swift WS
reconnect loop wedges silently. Not a routing-contract issue per se,
but operators need either (a) external watchdog (shipped, see
`ops/macprovider-watchdog/`) or (b) Swift-side fix. Tracked as a
separate engineering work item — see issue #M.

### R-9 — Billing settlement on 5xx (factual)

Every 5xx response carries an `X-Request-Id` header. The buyer-side
contract: a 5xx never produces a `usage_events` row that charges the
buyer; the harness's I2 invariant confirms this across all phase-A
scenarios.

The `usage_events` table may, however, contain a `outcome != ok` row
for the same request_id when the gateway logged the failure (e.g.,
`outcome=upstream_error`, `prompt_tokens=0`, `completion_tokens=0`).
That's an **audit row**, not a billed row.

### R-10 — Streaming token billing source `[PRODUCT DECISION]`

When the gateway settles streaming requests in `usage_events`, the
`completion_tokens` count comes from one of:
- the final SSE chunk's `usage.completion_tokens` (provider-reported)
- a gateway-side count of delta content (not currently done)

**Phase-A observation:** the existing `token_source` field already
records this (`provider_reported`, `gateway_estimated`,
`manual_fixture`). Confirmed against the live `usage_events` schema.

**Decision needed:** for mid-stream truncation (R-4), what's the
contract value of `completion_tokens` if R-4b is chosen? Bytes
delivered ÷ avg token length? Last seen chunk's count?

## Open items NOT addressed in this addendum

- The harness's own streaming-token-counter limitation (separate
  harness fix).
- Multi-model routing fairness under sustained load (need higher
  capacity than 2×1 slot to observe meaningfully).
- Sticky-affinity ON behavior (deferred until product decides to
  enable).
- Cross-buyer fairness (need ≥2 buyer accounts to test).

## Change-log entry (proposed, to land at top of `SPEC-002-coordinator.md`)

```
**Change log v1.4.2 (2026-06-27, additive — phase-A harness):**
- R-1..R-10 routing-contract clauses added. R-1, R-3, R-4, R-5, R-10
  flagged [PRODUCT DECISION] — current behavior documented but not
  yet ratified as the contract. R-2, R-6, R-7, R-8, R-9 codify
  existing behavior. See docs/internal/phase-A-findings-2026-06-27.md
  for the empirical evidence behind each clause.
```

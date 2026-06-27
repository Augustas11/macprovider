# SPEC-002 v1.4.2 — routing-contract addendum

**Bumps SPEC-002 from v1.4.1 → v1.4.2.** Five coordinator-side
clauses, each either codifying already-implicit behavior or marking
an empirical observation as a violation of an existing locked
contract.

**Companion**: a parallel SPEC-006 v0.X.Y gateway-contract addendum
(separate PR) covers gateway-side clauses surfaced by the same
review pass (settlement matrix re-affirmation, rate-limit response
headers, observability requirements).

## Audit provenance

This addendum is the result of an internal e2e network-harness pass
against the live `https://api.streamvc.live` stack (2026-06-27),
followed by a three-lane audit:

- **Architect lane (codex via `omc ask codex`)** — 16 findings, 3
  CRITICAL, 8 MAJOR.
- **Architect lane (Claude adversarial verification)** — 13
  findings, 4 CRITICAL, 5 MAJOR.

Both lanes converged on the conclusion that most clauses in an
earlier draft conflated coordinator-vs-gateway scope and contradicted
existing locked spec contracts. This revision focuses on coordinator-
side surface only and re-affirms the existing contracts that empirical
runs observed violations of.

## Change-log entry

> **v1.4.2 (2026-06-27, additive — internal e2e audit):**
> Codifies five coordinator-side observations from internal e2e
> testing against the live `https://api.streamvc.live` stack. R-1,
> R-2, R-3 are **re-affirmations of existing locked contracts**
> (§ 7.2, § 11, FR-B6) that empirical runs observed violations of;
> the violations are filed as separate code-side issues. R-4
> corrects an earlier-draft tie-break misstatement. R-5 disambiguates
> a coordinator-internal error-code drift. No new buyer HTTP
> surface; no routing-algorithm changes.

## R-clauses

### R-1 — `404 model_not_found` vs `503 no_provider_available` split

**Status:** RE-AFFIRMATION of SPEC-002 v1.4.1 § 7.2.

Per § 7.2 (lines 2381-2389):

- `404 model_not_found`: the `model_id` has NEVER appeared in any
  provider's hello/heartbeat history during this coordinator process
  lifetime.
- `503 no_provider_available`: the `model_id` is recognized
  (in pool-lifetime history) but no currently-eligible provider can
  take the request right now.

The buyer-facing semantic distinction (404 = misconfiguration, 503 =
backoff-and-retry) is part of the contract.

**Empirical observation (non-spec content, for triage):** an internal
e2e scenario killed the only Qwen3-32B-4bit provider, then fired a
buyer request <300ms later. The coordinator returned HTTP 404 despite
the model being in pool history. **Filed as code bug
(issue #185). Not a spec change.**

### R-2 — `X-Request-ID` propagation: gateway↔coordinator reconciliation

**Status:** RE-AFFIRMATION + RESHAPE of SPEC-002 v1.4.1 § 11 (lines
2239-2243). Splits the original three-leg §11 mandate into two
clauses (R-2 here, R-2b below) to keep code/spec ownership aligned.

#### R-2 normative — gateway↔coordinator reconciliation column

The buyer-visible request id MUST be persisted on the coordinator
side in a NEW column `request_log.external_request_id` (TEXT NULL).
This is the join key between gateway `usage_events.request_id`,
gateway `audit_events.request_id`, and coordinator
`request_log.external_request_id`.

`request_log.request_id` retains its existing per-attempt
coordinator-generated semantics. SPEC-002 v1.4.1 § 11 line 1291's
prose ("`UUID v4 from inbound X-Request-ID when present`") is now
re-interpreted via this clause: that text described intent rather
than the actual implementation, which has long generated per-attempt
request_ids and verified the property in tests (see
`TestRequestLogBuyerMultiAttemptRows` and
`TestRequestLogBuyerPinnedClientRequestIDDoesNotReuseBillingID`).
v1.4.2 R-2 makes the distinction explicit:

- **`request_id`** — per-attempt coordinator id. One row per
  provider attempt; retries on the same logical request share this
  value on the non-pinned path and differ on the pinned-client path.
- **`external_request_id`** — buyer-facing id propagated through
  gateway. Shared across all attempts of one logical request.
  Reconciliation join.

#### R-2 normative — schema migration

Coordinators MUST ship the migration:

```sql
ALTER TABLE request_log ADD COLUMN external_request_id TEXT NULL;
CREATE INDEX IF NOT EXISTS idx_request_log_external_request_id
    ON request_log(external_request_id) WHERE external_request_id IS NOT NULL;
```

Implementations SHOULD use a partial-NULL index (as above) so
pre-migration rows do not consume index space.

#### R-2 normative — sanitization

Coordinators MUST apply length and control-character bounds to the
inbound header before storage. A reference normalization (see
`sanitizeExternalRequestID` in `phase4-coordinator/internal/buyer/server.go`):

- TrimSpace the inbound value.
- Reject (treat as absent) if empty or > 128 bytes.
- Reject (treat as absent) any byte < 0x20, == 0x7f, or in the
  C1 range 0x80-0x9f.

Rejected values are stored as NULL — the row still logs but is
opted out of reconciliation.

#### R-2b deferred — coordinator↔provider preservation

SPEC-002 v1.4.1 § 11 line 2241 says "When forwarding work to a
provider over the SPEC-001 § 6.6 `inference_request` message,
coordinator MUST preserve the request ID it recorded for the buyer
request." Empirical observation: today the coordinator sends a
per-attempt id to providers, not the buyer-facing one. Existing
tests codify the per-attempt behavior. **R-2b retains the spec
text as the intended end-state but defers implementation to a
follow-up.** Phase-C harness assertions that depend on R-2b MUST
mark themselves dependent until R-2b is resolved.

#### R-2 implementation reference

[PR #195](https://github.com/Augustas11/macprovider/pull/195) closes
[#188](https://github.com/Augustas11/macprovider/issues/188), shipping
R-2 (column + migration + sanitization + plumbing). R-2b is not in
that PR.

#### Phase-C harness expectations

Out-of-process auditors (the internal e2e harness, future SRE audit
scripts, dispute-resolution tooling) MUST detect the
`external_request_id` column via schema introspection. If the column
is absent, the auditor SHOULD report "exact reconciliation
unsupported on legacy coordinator" rather than silently falling back
to fuzzy `(ts, model, completion_tokens)` matching (which is lossy
under concurrent traffic).

#### Glossary (added with this addendum)

- **request_id** — coordinator-generated per-attempt identifier; one
  row per provider attempt in `request_log`. Never equal to any
  inbound header value.
- **external_request_id** — inbound `X-Request-ID` header value
  honored at the coordinator buyer-port ingress. Shared across all
  retry attempts of one logical request. Reconciliation join key
  with gateway-side stores.

### R-3 — Mid-stream provider disconnect SSE error envelope

**Status:** RE-AFFIRMATION of SPEC-002 v1.4.1 FR-B6 (lines 1248-1254).

Per FR-B6, when a provider disconnects mid-stream the coordinator
MUST emit:

```
data: {"error":{"message":"Provider disconnected during streaming","type":"server_error","code":"provider_disconnected"}}

data: [DONE]

```

The error event is REQUIRED before `[DONE]`. The buyer cannot rely
on truncated content alone to detect failure.

**Empirical observation:** an internal e2e scenario killing the
provider mid-stream observed the gateway emitting `data: [DONE]`
with **no preceding error event**. The gateway code path emits
`stream_truncated` instead of `provider_disconnected`. **Filed as
code bug (issue #186), plus a tightly-coupled SPEC-006 §17.7
settlement violation (issue #187 — P0). Not a spec change.**

### R-4 — Default-objective tie-break (correction)

**Status:** CORRECTION to an earlier misstatement; no normative
change.

An earlier review note described the SPEC-002 § 5 default-objective
tie-break as "random within epsilon on `requestID`". Per § 5, the
actual sequence is:

1. Filter by model, RoutingEligible, context capacity, quota.
2. Sort by `(SlotsFree asc, throughput_tps_estimate desc,
   connected_at asc)`.
3. Random epsilon-tie-break is applied ONLY when the configured
   `objective` carries a non-zero `epsilon` (default 0 =
   deterministic).

Apologies for the misstatement; this clause exists to keep downstream
harness assertions from relying on the wrong tie-break shape.

### R-5 — Coordinator-internal 503 error-code drift

**Status:** CLEANUP within SPEC-002 scope.

`phase4-coordinator/internal/buyer/server.go` emits **two distinct
codes** for the same 503 conceptual case:

- `no_provider_available` (matches FR-B4) at lines 3122, 3183,
  3661, 3704 — the routing rejection paths.
- `provider_unavailable` (NOT in FR-B4 enumeration) at lines 1924,
  1952, 2087, 2726, 3989 — the WS-forward / preflight rejection
  paths.

Per FR-B4 (line 1232) and § 7.2, the normative code is
`no_provider_available`. The `provider_unavailable` string is
non-conformant; both paths MUST emit `no_provider_available`.

**Filed as code bug (issue #184). The addendum codifies "all 503
zero-provider scenarios use `no_provider_available`" as the
normative contract.**

## Phase-A audit-pass: clauses considered but withdrawn

To avoid muddling the contract, the following clauses from an earlier
draft were withdrawn after the codex + Claude audit:

| Earlier-draft clause | Disposition | Rationale |
|---|---|---|
| Per-account rate limit | Moved to SPEC-006 addendum | Gateway-side scope, not SPEC-002. |
| Capacity-exhaustion 503 envelope | Absorbed into R-5 | Same root cause as the code-drift cleanup. |
| Mid-stream billing policy | Moved to SPEC-006 §17.7 re-affirmation | §17.7 already specifies the settlement matrix. |
| Cold-start `model_warming` proposal | Withdrawn | SPEC-001 v1.4 R-6.8.4 already defines `503 provider_loading`; no new vocab needed. |
| 5xx never billed | Withdrawn (was incorrect) | Contradicts SPEC-006 §17.7. |
| Streaming token source | Moved to SPEC-006 addendum | Gateway-side settlement, not coordinator routing. |
| Provider WS silent disconnect | Dropped from spec | Operational, not protocol; tracked as engineering issue #189 + #191. |

## Filed companion issues

| Issue | Type | Spec referenced | Severity |
|---|---|---|---|
| [#184](https://github.com/Augustas11/macprovider/issues/184) | code bug | SPEC-002 FR-B4 | high |
| [#185](https://github.com/Augustas11/macprovider/issues/185) | code bug | SPEC-002 § 7.2 | high |
| [#186](https://github.com/Augustas11/macprovider/issues/186) | code bug | SPEC-002 FR-B6 | high |
| [#187](https://github.com/Augustas11/macprovider/issues/187) | code bug | SPEC-006 §17.7 | **P0** |
| [#188](https://github.com/Augustas11/macprovider/issues/188) | code bug | SPEC-002 §11 | **P0** |
| [#189](https://github.com/Augustas11/macprovider/issues/189) | engineering | (operational) | high |
| [#190](https://github.com/Augustas11/macprovider/issues/190) | feat + decision | SPEC-006 R-G2 | medium |
| [#191](https://github.com/Augustas11/macprovider/issues/191) | feat (ops) | n/a | medium |

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

### R-2 — `X-Request-ID` propagation across gateway↔coordinator↔provider

**Status:** RE-AFFIRMATION of SPEC-002 v1.4.1 § 11 (lines 2239-2243).

Per § 11:

- The coordinator MUST honor any inbound `X-Request-ID` header on
  buyer-facing `/v1/*` requests and store it in
  `request_log.request_id`.
- When forwarding work to a provider via the SPEC-001 § 6.6
  `inference_request` message, the coordinator MUST preserve the
  buyer-facing request id.
- Gateway-originated traffic (SPEC-006 v0.3+) uses `X-Request-ID` as
  the join key between gateway `usage_events`, gateway
  `audit_events`, and coordinator `request_log`.

**Empirical observation:** the live gateway and coordinator currently
generate independent UUIDs per request — they never overlap in the
`usage_events` ↔ `request_log` join. This is a § 11 violation and
breaks billing reconciliation for any out-of-process auditor.
**Filed as code bug (issue #188 — P0 blocker for external-buyer
beta). Not a spec change.**

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

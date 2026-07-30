# Build prompt — SPEC-004 Pillar A implementation after SPEC-006 v0.8

> **SUPERSEDED — do NOT execute.** This A-only build prompt was written
> before the operator chose to implement all four SPEC-004 pillars as one
> integrated build. Use `specs/BUILD_SPEC_004_IMPL_PROMPT.md` instead,
> which covers Pillars A + B + C + D with the staged-deploy and per-pillar
> commit discipline. This file is retained as historical context for the
> Pillar A scope/AC; the combined prompt incorporates it.

Operator-paste prompt to implement SPEC-004 v0.2 Pillar A now that
SPEC-006 v0.8 defines the gateway-derived conversation key, internal
transport, disclosure, and sticky-caching guard satisfaction.

This prompt is for implementation only. It does not revise SPEC-001,
SPEC-002, SPEC-003, SPEC-004, or SPEC-006.

---

```
=== BEGIN PROMPT ===

You are implementing SPEC-004 v0.2 Pillar A (sticky session affinity) in the
Mac Provider repo after SPEC-006 v0.8 has been audited ACCEPT.

## Locked corpus

- `specs/SPEC-001.md` / SPEC-001 v1.2.4 provider wire protocol: locked; no
  provider wire change.
- `specs/SPEC-002-coordinator.md` / SPEC-002 v1.3.3: coordinator baseline.
- `specs/SPEC-004-smart-router.md` / SPEC-004 v0.2: routing-side sticky
  contract to implement.
- `specs/SPEC-006-buyer-api.md` / SPEC-006 v0.8: gateway-side derivation,
  transport, disclosure, and sticky guard satisfaction.

## Mission

Implement sticky affinity as a soft coordinator routing preference keyed only
by the gateway-derived internal `routing_internal.conversation_key` in the
reserved `conv:` namespace, plus the SPEC-006 v0.8 gateway derivation,
transport, and reset API needed to supply and invalidate that key.

## Required reading

1. `specs/SPEC-004-smart-router.md`
   - FR-SR-1 default behavior preservation.
   - FR-SR-2 sticky affinity keying.
   - FR-SR-3 sticky affinity is a soft preference.
   - FR-SR-4 hard pin precedence.
   - FR-SR-5 sticky entry lifecycle.
   - FR-SR-6 sticky update timing.
   - § 5 config (`routing.sticky_enabled`, `routing.sticky_ttl_s`,
     `routing.sticky_max_entries`).
   - § 6 gateway-derived internal fields.
   - AC-SR-2, AC-SR-3, AC-SR-4, AC-SR-15.
2. `specs/SPEC-006-buyer-api.md`
   - § 1.3 HMAC derivation and five sticky-caching precondition satisfaction
     clauses.
   - § 1.6 sticky-on disclosure posture.
   - § 5.3.1 `/v1/models tier1_disclosure.sticky_affinity`.
   - § 5.4.1 `X-MacProvider-Conversation`,
     `X-MacProvider-Internal-Conv`, and `DELETE /v1/sticky`.
   - § 19 sticky audit category.
   - § 22 PG-9.
3. Code:
   - `phase4-coordinator/internal/buyer/server.go`
   - `phase4-coordinator/internal/pool/provider.go`
   - `phase4-coordinator/internal/config/config.go`
   - `phase5-gateway/internal/router/server.go`
   - gateway auth/config/storage packages as needed for account identity,
     secret config, and reset plumbing.

## Implementation requirements

### Coordinator

- Add sticky routing config with defaults preserving SPEC-002 behavior:
  `routing.sticky_enabled: false`, `routing.sticky_ttl_s: 1800`,
  `routing.sticky_max_entries: 10000`.
- Accept `X-MacProvider-Internal-Conv` only on the internal
  gateway-to-coordinator path. Treat missing, malformed, non-`conv:` values,
  and buyer-origin paths as no sticky key or rejection according to the
  existing internal-boundary pattern.
- Keep `X-MacProvider-Session` hard-pin-only. A bad session pin MUST still
  return `503 session_ended` and MUST NOT trigger sticky lookup, sticky write,
  fallback, F-4 failover, or retry.
- Implement an in-memory sticky map keyed by `conv:<opaque-id>` storing at
  least `conversation_key`, `provider_id`, model/class scope, `created_at`,
  and `last_used_at`.
- Enforce TTL expiry, `sticky_max_entries`, and LRU eviction. Synchronize map
  reads/writes with a mutex or equivalent.
- On eligible sticky hit, promote the provider as a soft preference only if it
  still passes the full SPEC-002 eligibility filter and remains compatible
  with the requested model/scope.
- On sticky miss, fall back to normal routing and log the miss reason. Sticky
  MUST NOT trap traffic on unavailable, busy, degraded, warming, breaker-held,
  quota-blocked, wrong-model, or context-too-small providers.
- Update sticky only after a request successfully commits to exactly one
  serving provider, per SPEC-004 FR-SR-6. Failed preflight and pre-commit
  failures MUST NOT update sticky.
- Add observability fields for `sticky_result` and `sticky_miss_reason`.

### Gateway

- Add buyer handling for `X-MacProvider-Conversation` on
  `POST /v1/chat/completions`.
- Sanitize tags exactly as SPEC-006 v0.8: trim ASCII whitespace, length
  1..128 bytes, charset `[A-Za-z0-9._:-]`; reject invalid tags with HTTP 400
  `invalid_request_error` / `invalid_conversation_tag`.
- Derive `routing_internal.conversation_key` per SPEC-006 v0.8 § 1.3 steps
  1–7 (HMAC-SHA256 over a pinned scope string, `account_id`, and the
  buyer tag, unpadded base64url, prefixed `conv:`). Use the spec as the
  source of truth — do NOT restate the algorithm in code comments where it
  could drift from a future spec patch.
- Forward only `X-MacProvider-Internal-Conv: conv:<opaque-id>` to the
  coordinator. Never forward raw `X-MacProvider-Conversation`.
- Strip inbound buyer-supplied `X-MacProvider-Internal-*` before auth/routing
  and add audit coverage for attempted injection.
- Implement authenticated `DELETE /v1/sticky`, account-scoped and idempotent,
  returning `{ "purged": true, "entries": N }`. **There is no existing
  gateway→coordinator purge channel**, so the implementer MUST add one. Add a
  new internal endpoint on the coordinator's *internal* listener (NOT the
  public buyer port) — e.g. `DELETE /internal/sticky?account_id=<id>` —
  protected by the same network/auth boundary that prevents
  `X-MacProvider-Internal-Conv` from arriving externally (nginx route gating
  + an operator-only bearer or loopback-only bind). The endpoint MUST iterate
  the coordinator sticky map and remove every entry whose `conversation_key`
  decodes from a `conv:` derived for the given `account_id` (or equivalent
  account-scoped index). Document the chosen scheme in
  `phase4-coordinator/implementation-notes.html` before merging. Do NOT add
  provider wire behavior; no SPEC-001 change.
- Extend `/v1/models tier1_disclosure.sticky_affinity` with `enabled`,
  `ttl_seconds`, and description per SPEC-006 v0.8.

## Tests and verification

- Add default-config regression tests proving `sticky_enabled: false`
  preserves current SPEC-002 provider selection and buyer-visible behavior,
  with no sticky map read/write and no internal conversation header emitted.
- Add derivation tests with fixed `account_id`, buyer tag, and secret proving
  byte-identical HMAC output across gateway instances and different output
  for a different account with the same tag.
- Add sanitization tests for valid, empty, too-long, and invalid-character
  `X-MacProvider-Conversation` values.
- Add coordinator sticky tests for hit, miss, TTL expiry, LRU eviction,
  ineligible sticky provider fallback, wrong-model fallback, and successful
  post-commit update.
- Add hard-pin regression for AC-SR-15: bad `X-MacProvider-Session` returns
  `503 session_ended` and performs no sticky lookup/write/failover/retry.
- Add gateway header-boundary tests proving raw buyer
  `X-MacProvider-Conversation` is not forwarded and buyer-supplied
  `X-MacProvider-Internal-Conv` cannot reach coordinator logic.
- Add `DELETE /v1/sticky` tests for auth requirement, account scoping,
  idempotency, and response shape.
- Run the narrow package tests first, then the relevant full Go test suites.

## Hard rules

- No SPEC-001 provider wire change.
- No SPEC-004 or SPEC-006 spec-text changes in this implementation pass unless
  a blocker proves the accepted specs are internally inconsistent; if so,
  stop and report the contradiction.
- Do not reinterpret `X-MacProvider-Session` as sticky input.
- Do not accept `routing_internal.conversation_key` or
  `X-MacProvider-Internal-Conv` from direct buyer traffic.
- Keep sticky disabled by default.
- Keep changes small, reviewable, and covered by tests.

## Completion report

Report changed files, tests run, any remaining gaps, and explicit evidence for:

- default sticky-off no-op,
- account-scoped HMAC derivation,
- internal-header spoof resistance,
- soft sticky hit/miss routing,
- post-commit sticky update,
- `DELETE /v1/sticky` behavior,
- `/v1/models sticky_affinity` disclosure.

=== END PROMPT ===
```

# SPEC-006 v0.X.Y — gateway contract addendum

**Bumps SPEC-006 (next patch).** Four gateway-side clauses paired
with the parallel SPEC-002 v1.4.2 addendum (separate PR), surfaced
by the same internal e2e network-harness pass and three-lane audit
(2026-06-27).

## Change-log entry

> Codifies four gateway-side observations from internal e2e testing
> against `https://api.streamvc.live`. R-G1 re-affirms §17.7
> settlement matrix against an empirically observed violation. R-G2
> specifies the per-account-rate-limit response header set; the
> numeric N is the only surviving open product decision. R-G3
> specifies observability requirements on routing failures. R-G4
> affirms the SPEC-005 vocabulary for streaming token source.

## R-clauses

### R-G1 — Settlement matrix MUST apply on mid-stream provider drop

**Status:** RE-AFFIRMATION of SPEC-006 v0.6 §17.7.

Per §17.7, when a provider disconnects mid-stream after partial
content delivery, the gateway MUST write a `usage_events` row
according to the streaming row of the matrix:

| Status | Completion tokens | Quota debited |
|---|---:|---|
| 502, partial stream (>0 tokens) | provider-reported actuals if available, else `ceil(bytes_emitted_so_far / 4)` | `prompt + actual_completion` |

The matrix is normative; **no `usage_events` row at all is a
settlement violation, not a refund.**

**Empirical observation:** an internal e2e scenario killed the
provider at t=5s during a streaming Qwen3-32B request. The buyer
received ~13 KB of SSE content followed by `[DONE]`; the gateway
wrote **no `usage_events` row at all**. The buyer was not charged
(✓ from buyer's view); the provider was NOT credited for ~3,000
tokens of delivered inference (✗ — provider works for free under
this failure mode).

**Filed as code bug (issue #187 — P0 money-path).**

### R-G2 — Per-account rate-limit response shape `[PRODUCT DECISION: numeric N only]`

**Status:** NEW NORMATIVE on response shape; numeric N deferred.

**Normative — response shape.** When the gateway denies a request
for per-account-concurrency reasons, the response MUST be:

```
HTTP 429
X-RateLimit-Limit: <N>
X-RateLimit-Remaining: 0
X-RateLimit-Reset: <ISO 8601 ts or seconds-from-now>
Retry-After: <integer seconds>
Content-Type: application/json

{"error":{"message":"...","type":"rate_limit_exceeded","code":"rate_limit_exceeded","param":null}}
```

- Scope: per-API-key, in-flight HTTP requests (not queued).
- The `X-RateLimit-*` triple is REQUIRED on 429; OPTIONAL on 200/4xx
  for client self-pacing.
- `Retry-After` is REQUIRED on 429 and MUST be ≤ the time until
  `X-RateLimit-Reset`.

**Empirical observation:** the live gateway emits 429 with body
`{"error":{"code":"http_429"}}` and **no `X-RateLimit-*` headers**.
OpenAI SDK and similar clients honor `X-RateLimit-Remaining` for
self-pacing; without it they fire blindly until 429 and retry
without backoff signal. **Filed as code bug (issue #190).**

**Open product decision: numeric N.** Recommended N=3 (concurrent
in-flight requests per API key), configurable per subscription tier.
Rationale and alternatives discussed in issue #190.

### R-G3 — Observability requirements on routing failures

**Status:** NEW NORMATIVE.

Every gateway response MUST include `X-Request-ID` (the SPEC-002
§11 propagated id). 4xx and 5xx responses MUST include the error
JSON envelope with `code`, `message`, `type`. 429 MUST include
the rate-limit headers per R-G2.

**Coordinator-side column name (cross-reference).** The gateway
`X-Request-ID` (also stored as gateway `usage_events.request_id` and
request-scoped `audit_events.request_id`) joins to coordinator
`request_log.external_request_id`. **Do NOT join to coordinator
`request_log.request_id`** — that column is coordinator-internal per
SPEC-002 v1.4.2 R-2.

**Per-request forwarding scope.** "Every forwarded buyer request"
includes both `/v1/chat/completions` and `/v1/models`. The gateway
MUST set `X-Request-ID: <buyer-supplied-or-minted UUID>` on every
upstream coordinator call originating from a buyer-facing path; it
MUST NOT mint a fresh UUID per upstream call.

The gateway audit log MUST record:

- Final HTTP status
- `error.code` (or `"ok"`)
- Whether a provider was reached (`provider_reached: bool`)
- Settlement outcome (`settled / refunded / orphan`)

**Empirical observation:** during the audit, the harness could not
always tell from the response alone which of capacity-exhaustion /
per-account-throttle / provider-unreachable produced a given 429 or
503. The `error.code` enumeration must be expressive enough to
distinguish.

### R-G4 — Streaming token-source vocabulary

**Status:** RE-AFFIRMATION of SPEC-005 v0.3 § 6.9 + SPEC-006 v0.6
§17.7.

`usage_events.token_source` MUST be one of:

- `provider_reported` — provider's `usage` field was present and
  authoritative.
- `byte_estimated` — provider did not report; gateway used
  `ceil(bytes_emitted_so_far / 4)` per §17.7 fallback.
- `null_error` — provider returned a SPEC-001 null-usage error;
  buyer debit is none per §17.7.
- `manual_fixture` — test/CI seeded; not a production path.

An earlier draft proposed inventing `gateway_estimated` and average-
token-length heuristics; these are SUPERSEDED by the existing SPEC-005
vocabulary. No new field added.

## Phase-A audit-pass: clauses considered but resolved

| v1 decision considered | Resolution |
|---|---|
| Per-account rate-limit N value | Surviving — see R-G2; recommendation in issue #190. |
| 404 vs 503 split | Already specified by SPEC-002 § 7.2; no decision needed. |
| Mid-stream billing policy | Already specified by SPEC-006 §17.7 + SPEC-002 FR-B6; no decision needed. |
| Cold-start state vocabulary | Already specified by SPEC-001 R-6.8.4 (`provider_loading`); no decision needed. |
| Streaming token source | Already specified by SPEC-005 §6.9; no decision needed. |

## Filed companion issues

- [#187](https://github.com/Augustas11/macprovider/issues/187) — P0 settlement violation, R-G1.
- [#190](https://github.com/Augustas11/macprovider/issues/190) — rate-limit headers + N value, R-G2.
- [#188](https://github.com/Augustas11/macprovider/issues/188) — X-Request-ID propagation, R-G3 (also SPEC-002 R-2).

# Fix prompt — SPEC-006 v0.1 → v0.2 audit closing

Operator-paste prompt to apply both audit rounds' findings to SPEC-006
and produce v0.2. Cross-model consensus (Codex round 1 + Claude round
2) at `specs/SPEC-006-audit.md` produced:

  1 CRITICAL (both rounds agree)
  21 MAJOR (round 1: 15; round 2 confirmed 13 + reclassified 1 + added 8)
  9 MINOR (round 2 additions; round 1's 5 absorbed where overlapping)
  2 QUESTIONS (operator locks in this fix pass)

Both rounds verdict: READY WITH FIX PASS — architecturally sound; v0.2
closes contract precision, concurrency patterns, operations gaps, and
the single CRITICAL OAuth security finding.

Version bump:
  SPEC-006 v0.1 → v0.2

Run in **Claude Code** or **Codex CLI**. Expected duration: ~2-3 hours
(narrow-but-numerous fixes, no architectural changes). Surgical edits
only; the locked design choices in § 2 remain locked.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying the cross-model audit findings to SPEC-006 v0.1 and
producing v0.2. The audit report is at `specs/SPEC-006-audit.md`. Both
rounds agreed on the verdict (READY WITH FIX PASS) and on the single
CRITICAL. This is targeted closing-fix work, NOT a redesign.

You will edit two files in place:
  /Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md  v0.1 → v0.2
  /Users/augstar/macprovider-poc/phase5-gateway/implementation-notes.html
    (append "Resolved in v0.2" section)

## Critical constraints

**1. Locked design choices remain locked.** § 2 of SPEC-006 (the
operator pre-commitments) is read-only for content; only formatting
changes per M1/M2-2 are permitted. Do NOT reopen the gateway-vs-
coordinator architecture decision, the $500 cap, the 100K quota, the
GitHub-OAuth-primary identity, the B+C feedback lock, the "no
premium positioning" pre-commitment, or the "no Tier-3 deprecation"
clause. Any fix that touches these is REJECTED.

**2. SPEC-001 v1.2.2 and SPEC-002 v1.1.3 stay unchanged.** Do not
propose changes to upstream specs.

**3. d-inference clean-room.** Do not inspect d-inference source.

**4. Surgical scope.** This fix pass addresses 1 CRITICAL + 21 MAJOR
+ 9 MINOR findings. Each has a specific location and a suggested fix
in the audit report. Apply the suggested fixes (or operator-equivalent
alternatives where indicated below). Do NOT add new normative content
beyond what closes findings.

**5. Three operator questions are pre-resolved.** See "Operator
decisions for v0.2" below.

## Required reading

1. `/Users/augstar/macprovider-poc/specs/SPEC-006-audit.md`
   — read fully, both rounds. The "Suggested fix" line under each
   finding is your starting text for that finding's resolution.

2. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.1 — the spec under revision. Read all 20 sections.

3. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_006_PROMPT.md`
   — the locked design choices header. Verify your fixes do not
   contradict this header.

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.2 § 6.2 + § 6.4 — chat request/response shape including
   the OpenAI-compatible fields you'll be adding to SPEC-006 § 5.4
   (n, stream_options, user, logprobs).

5. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/server.go`
   — the coordinator's buyer surface. Read enough to confirm the
   `X-MacProvider-Provider` and `X-MacProvider-Session` headers
   (M2-21) actually exist and what they do.

6. `/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go`
   + `internal/poolz/` — confirm `/poolz` shape so the M2-19
   coordinator-status-bridge fix can reference it accurately.

## Operator decisions for v0.2 (pre-locked, do not relitigate)

The audit surfaced operator questions; the operator has pre-decided:

### Decision D1 (round 1 q1 / round 2 q2-1): v1 is single-instance

**Lock:** SPEC-006 v1 ships as a single gateway instance running
SQLite on Pearl VPS. Multi-instance horizontal scaling requires
migrating the storage layer to PostgreSQL or Cloudflare D1. The
architecture (stateless handlers, abstracted `AuthStore`/`UsageStore`
interfaces, append-only schema) ensures this migration touches only
the storage package — handler code is unchanged. Add this
acknowledgment to § 1.8 and § 14.2.

### Decision D2 (round 2 q2-2): Demo token mechanism is HMAC-SHA256

**Lock:** Demo tokens are HMAC-SHA256-signed by an operator secret in
`gateway.yaml`. Each token embeds: client IP (or IP-prefix for
IPv6 /64), issue timestamp, expiry (max 24h). The gateway validates
signature, expiry, and IP match before honoring the token. Tokens are
issued by `POST /auth/demo-session` which is rate-limited per IP
(default: 10/IP/hour). Static shared secrets are forbidden. Add this
to § 6.8.

### Decision D3 (round 1 q2 / round 2 partial): Streaming + error quota policy

**Lock:** For streaming requests, the gateway MUST reserve
`max_tokens` (or the per-request cap, whichever is smaller) against
the daily quota before forwarding. On successful completion, the
reservation is settled to actual usage. On 502/504/cancellation:

- Zero completion tokens generated → reservation refunded in full;
  no daily quota debited.
- Partial completion → reservation settled to actual tokens
  generated.

Prompt tokens count regardless of outcome (the provider performed
work). Add this to § 7.2 and reflect in § 17.4-17.7. The operator's
rationale: a free-tier service with "real Macs, sometimes asleep"
SHOULD NOT punish buyers for our pool's transient unavailability.

## Findings to fix — by cluster

### CRITICAL

**F-C2.** OAuth callback URL allowlist absent. (Round 1 C2 + Round 2
C2-1, both agree.)

**Locations:** § 5.8 lines 1069-1084; § 6.1 lines 1108-1120.

**Fix:** Add normatively to § 5.8 and § 6.1:

> The GitHub OAuth app MUST be configured with a strict callback URL
> allowlist containing only `https://api.streamvc.live/auth/github/callback`.
> The gateway MUST reject callbacks whose `redirect_uri` does not
> exactly match an allowlisted value. Local development MAY use
> `http://localhost:{port}/auth/github/callback` as a SEPARATE OAuth
> app with its own callback registration. The allowlist MUST be
> defined in `gateway.yaml` under `auth.oauth.callback_allowlist`
> and validated at gateway startup; an empty list MUST cause startup
> failure.

Add AC-26: deterministic test that posts to the callback with a
mismatched `redirect_uri` and verifies rejection.

### Cluster 1 — Precision gaps (text additions)

**F-M1 (round 1 M1, round 2 M2-2): § 2 verbatim quotation.**

Replace § 2's opening with a header note:

> This section reproduces the operator's pre-commitments from
> `specs/BUILD_SPEC_006_PROMPT.md` "Locked design choices." Cross-
> references have been updated to match this document's section
> numbering. Punctuation has been normalized for prose flow.
> Substantive content is unchanged. Any apparent semantic divergence
> from the BUILD prompt is a bug to be fixed in subsequent revisions.

Diff § 2 against the BUILD prompt; flatten any non-cross-reference
divergences.

**F-M2 (M2-1, round-1 C1 reclassified): Missing OpenAI request fields.**

**Location:** § 5.4 supported request fields.

**Fix:** Add to the supported request field list:

- `n` — accepted; MUST be 1 in v1; reject `n > 1` with HTTP 400
  (`type: "invalid_request_error"`, `code: "n_must_be_1"`).
- `stream_options` — accepted and forwarded to provider. Special
  case: `stream_options.include_usage = true` MUST cause the final
  SSE chunk to include a `usage` field (the OpenAI SDK depends on
  this for token accounting on streaming).
- `user` — accepted as opaque diagnostics. Stored in usage events.
  MUST NOT be exposed in buyer-visible responses.
- `logprobs` — accepted syntactically; behavior is model-dependent;
  document that the provider may ignore it.

### F-M3 (round-1 M2 / round-2 M2-3): OAuth scope minimization.

**Location:** § 6.1.

**Fix:** Add:

> The gateway MUST request only the `read:user` GitHub OAuth scope.
> The `user:email` scope MAY be requested if email magic link is
> deferred (otherwise covered by D2's separate flow). Scopes for
> repository, organization, gist, or write access MUST NOT be
> requested. The OAuth app's registered scope list MUST match.

### F-M4 (M3 / M2-4): API key entropy.

**Location:** § 2.3, § 6.4.

**Fix:** Replace "high entropy" with:

> The random portion of every API key MUST contain at least 256
> bits of entropy drawn from a cryptographically secure
> pseudo-random number generator (CSPRNG) before base64url encoding.
> The encoded form MUST preserve at least 256 bits of effective
> entropy (i.e., base64url MUST NOT truncate). The fixed `mp_`
> prefix is in addition to the random portion.

### F-M5 (M4 / M2-5): Token revocation latency bounded.

**Location:** § 6.6, add AC-27.

**Fix:** Add:

> Revocation MUST take effect within 60 seconds across all gateway
> components. Storage-layer revocation MUST be observed by validation
> immediately (next request). Any caches MUST invalidate within 60
> seconds. Multi-instance deployments (post-D1 migration) MUST honor
> the same bound across all instances.

AC-27: deterministic test that revokes a key and verifies a request
within 65s returns 401.

### F-M11 (M11 / M2-11): Feedback schema `scope` field.

**Location:** § 5.7 + § 11.3.

**Fix:** Add `scope` to the request schema for `POST /v1/feedback`:

```json
{
  "rating": 1-4,
  "comment": "optional, 0-2000 bytes",
  "request_id": "optional, references a prior completion",
  "scope": "request" | "session" | "account" | "playground"
}
```

`scope` is optional and defaults to:
- `"request"` if `request_id` is present
- `"account"` otherwise

Reconcile § 11.3 widget contract: the widget call MUST set `scope`
explicitly.

### F-M12 (M12 / M2-12): `/admin/feedback-summary` response shape.

**Location:** § 11.5.

**Fix:** Define the response schema:

```json
{
  "window_start": "ISO 8601",
  "window_end": "ISO 8601",
  "rating_count": int,
  "mean": float (1.0-4.0),
  "distribution": {"1": int, "2": int, "3": int, "4": int},
  "by_scope": {"request": {...}, "account": {...}, "playground": {...}},
  "trend": {
    "7d_share_1_2": float,
    "14d_share_1_2": float,
    "delta_pct": float
  },
  "comment_samples": [
    {"rating": int, "comment": "...", "scope": "...", "timestamp": "..."}
  ]
}
```

Aggregation:
- Window: support `?window=7d` and `?window=14d`; default 7d
- Deduplication: a single account submitting multiple ratings with
  the same `request_id` counts only the most recent (idempotency)
- Weighting: equal weight per distinct rating event
- Comment samples: top 20 most recent non-empty comments

### F-M13 (M13 / M2-13): Iteration trigger numeric threshold.

**Location:** § 2.9, § 11.6.

**Fix:** Replace "shifts toward 1-2 for any 2-week window" with:

> The operator MUST review root cause when the 7-day share of
> ratings 1-2 exceeds 40% in any window containing at least 20
> distinct rating events. This trigger fires automatically (not
> operator discretion) via an `/admin/feedback-summary?window=7d`
> poll executed by the monitoring job at minimum hourly cadence.

### F-M16 (M2-16): 405/413 error types and codes.

**Location:** § 17.

**Fix:** Add to the error code map:

- 405 Method Not Allowed: `type: "invalid_request_error"`,
  `code: "method_not_allowed"`
- 413 Payload Too Large: `type: "invalid_request_error"`,
  `code: "request_too_large"`

### Cluster 2 — Concurrency and lifecycle patterns

### F-M6 (M5 / M2-6): Atomic quota enforcement under concurrency.

**Location:** § 7.2, § 14.4.

**Fix:** Define the quota-reservation pattern:

> Quota enforcement MUST use a reservation ledger to prevent
> concurrent over-spend. For each admitted request, the gateway:
>
> 1. Reads the account's current daily reservation total via a
>    transactional `SELECT ... FOR UPDATE` (or storage-layer
>    equivalent atomic primitive).
> 2. If `current_reserved + max_tokens_for_request <= daily_quota`,
>    inserts a reservation row keyed by `(account_id, request_id)`
>    and commits.
> 3. If the request completes, settles the reservation to actual
>    `prompt_tokens + completion_tokens` and writes an immutable
>    usage event.
> 4. If the request fails per D3 (streaming + error policy), refunds
>    the reservation per the D3 rules.
>
> Minor overshoot up to `max_tokens_per_request` is acceptable in
> the event of system failure between reservation and settlement
> (failed reservations expire and are reclaimed by a reaper job
> within 24h).

The CAS / `FOR UPDATE` semantics MUST be specified per storage
backend. For SQLite v1: use `BEGIN IMMEDIATE` transactions.

### F-M7 (M6 / M2-7): Streaming quota debit + refund.

**Location:** § 5.4, § 7.2, § 17.

**Fix:** Per D3 above. Add normative paragraph to § 7.2:

> For streaming requests (`stream: true`), the gateway reserves
> `max_tokens` (or the configured per-request cap) before
> forwarding. On SSE completion (`[DONE]` chunk received from
> provider), settlement adjusts the reservation to actual usage as
> reported by the provider. On client disconnect, gateway cancels
> the upstream request and settles to actual tokens generated up
> to disconnect. On 502/504 from provider: D3 refund policy
> applies.

### F-M8 (M8 / M2-8): Kill switch latency MUST + persistence.

**Location:** § 9.3, § 15.3.

**Fix:**

1. Upgrade SHOULD → MUST: "Kill switch activation MUST take
   effect within 5 seconds across all in-flight and new requests."
2. Persistence: "Kill switch state MUST persist across gateway
   restarts. The mechanism: admin endpoint mutations write the new
   state to `gateway.yaml` AND update in-memory state. On gateway
   startup, state is read from `gateway.yaml`. SIGHUP triggers
   re-read."
3. Add AC-28: deterministic test that toggles kill switch, restarts
   gateway, verifies state survives.

### F-M9 (M9 / M2-9): Capacity signal measurement specification.

**Location:** § 2.8, § 10.2-10.4, § 16.4.

**Fix:** Add a signal measurement table:

| Signal | Source | Sample cadence | Aggregation window | Threshold | Hysteresis |
|--------|--------|---------------:|-------------------:|-----------|-----------|
| CPU | `/proc/stat` (Linux) or `host_processor_info` (macOS) | 10s | rolling 4h mean | 70% | 5% below for de-escalation |
| Memory | `/proc/meminfo` available_kb / total_kb | 10s | rolling 1h mean | 80% | 5% below |
| Bandwidth | nginx access logs `bytes_sent` aggregated | 60s | rolling 24h | 70% of VPS quota | 10% below |
| Provider feedback | `/admin/provider-feedback` POST events | event-driven | 7-day count | 1+ event | manual clear required |
| Cost | sum of (VPS + email + storage projected) vs `capacity.monthly_budget_usd` | hourly | current month | 80%/100% (T1/T3) | 10% below |
| Provider drops | coordinator `/poolz` provider_count series | 60s | rolling 48h | 2+ drops | 48h since last drop |
| Operator load | `/admin/operator-load` POST events | event-driven | 7-day | >70% of any week | manual clear |

Every signal MUST emit an audit event on threshold-cross.

### F-M10 (M10 / M2-10): Tier de-escalation logic.

**Location:** § 10.5.

**Fix:** Add:

> Automatic de-escalation: when ALL signals that triggered a tier
> stop firing for a configurable cooldown (default: 1 hour), the
> monitoring job MUST de-escalate to the previous tier. De-escalation
> from Tier 3 → Tier 2 requires the additional condition that the
> capacity-expansion off-ramp was NOT taken (otherwise direct return
> to Tier 0). Manual de-escalation by the operator is also permitted
> via `/admin/capacity-tier` POST with operator key. Every
> de-escalation MUST emit an audit event with signal state and
> elapsed time below threshold.

### F-M14 (M2-14, D2): Demo token validation mechanism.

Per Decision D2 above. Add full normative spec to § 6.8 including:

- Token format: `{base64url(payload)}.{base64url(hmac)}`
- Payload: `{"v": 1, "ip": "1.2.3.4", "iat": unix_ts, "exp": unix_ts}`
- HMAC computed over payload bytes using `auth.demo.signing_secret`
- Issuance endpoint: `POST /auth/demo-session` rate-limited 10/IP/hour
- Validation: signature, expiry, IP match (or IPv6 /64 prefix)
- Token MAX TTL: 24h
- Rotation: operator MAY rotate signing secret; existing tokens
  invalidate immediately

### F-M15 (M2-15, D3): Quota refund on upstream error.

Per Decision D3 above. Add to § 17.4-17.7 explicit refund matrix:

| Status | Completion tokens | Quota debited |
|--------|-------------------|---------------|
| 200 | as reported | prompt + completion |
| 502 | 0 | prompt only |
| 502 | >0 (partial stream) | prompt + actual completion |
| 503 | 0 | prompt only (note: 503 should generally be 0 since no provider was reached) |
| 504 | 0 | prompt only |
| 504 | >0 (partial stream) | prompt + actual completion |
| Client disconnect | >=0 | prompt + actual completion at disconnect |

### Cluster 3 — Verification and operations

### F-M17 (M2-17): Audit logging for kill switch / quota / blocks.

**Location:** § 14.3.

**Fix:** Add:

> The `audit_events` table MUST record:
> - Every kill switch toggle (which switch, new state, actor)
> - Every quota configuration change (account_id, old, new, actor)
> - Every key revocation and regeneration (account_id, key_hash_prefix, actor)
> - Every account block / unblock
> - Every capacity tier transition (signal state, audit-event chain)
> - Every budget cap mutation
>
> Events are append-only, immutable, and queryable via
> `/admin/audit-log` (operator-keyed).

### F-M18 (M2-18, D1): v1 single-instance acknowledgment.

Per Decision D1. Add explicit acknowledgment to:

- § 1.8: "v1 deploys as a single gateway instance with SQLite. The
  stateless-handlers requirement preserves multi-instance
  feasibility but is not exercised in v1. See § 14.2 for the
  storage layer's role in this constraint."
- § 14.2: "SQLite is the v1 concrete implementation. Multi-instance
  horizontal scaling requires migrating the `AuthStore` /
  `UsageStore` / `FeedbackStore` interface implementations to a
  multi-writer-safe backend (PostgreSQL, Cloudflare D1, or
  similar). Handler code requires zero changes for this migration."

### F-M19 (M14 / M2-19): Coordinator status data bridge.

**Location:** § 5.6, § 12.2.

**Fix:** Add normative subsection:

> The gateway sources pool status for `/v1/status` by consuming
> the coordinator's internal `/poolz` endpoint at
> `http://127.0.0.1:{coordinator_provider_port}/poolz` (typically
> `:8444`). This is an internal contract; the gateway MUST NOT
> proxy raw `/poolz` content to buyers. The gateway MUST redact:
> - `provider_id` and `hostname` fields
> - Per-provider RAM/CPU specs
> - Operator identity metadata
>
> The gateway MAY aggregate counts (ready, draining, unavailable),
> per-model slot totals, and degraded-state booleans. Cache TTL
> for `/poolz` polling: 10 seconds.
>
> If the coordinator's `/poolz` shape is insufficient for the
> aggregation rules above, file a SPEC-002 v1.1.4 follow-up (do
> NOT extend SPEC-002 in this fix pass).

### F-M20 (M2-20): Stored XSS defense on feedback comments.

**Location:** § 5.7.

**Fix:** Add:

> The `comment` field MUST be treated as untrusted input. Storage
> writes preserve raw UTF-8 bytes. Rendering surfaces (dashboard,
> account page, admin views) MUST escape HTML entities at output
> time. The gateway's JSON responses MUST NOT include pre-rendered
> HTML for feedback content. Comments MAY contain newlines; clients
> rendering as text MUST preserve them.

### F-M21 (M2-21, NEW from coordinator code review): Strip provider-pinning headers.

**Location:** § 5.4 request handling, § 8 provider transparency.

**Finding rationale:** The coordinator accepts
`X-MacProvider-Provider` and `X-MacProvider-Session` inbound headers
for explicit provider pinning. SPEC-006 v0.1 only requires stripping
these from RESPONSES. A buyer who guesses a stable provider ID
could submit one of these headers and pin requests to a specific
provider, bypassing the transparency invariant ("buyers see only
aggregates").

**Fix:** Add to § 5.4 and § 8:

> The gateway MUST strip the following headers from inbound buyer
> requests before forwarding to the coordinator:
> - `X-MacProvider-Provider`
> - `X-MacProvider-Session`
> - any header starting with `X-MacProvider-` not on a documented
>   allowlist
>
> Stripping MUST occur before authentication so that a malicious
> buyer cannot influence provider selection by header injection.
> The gateway MAY emit an audit event when an inbound request
> carried these headers (to detect probing).

### Minor cleanups

Apply these in a single batch (each is one or two lines):

- **F-m1:** `X-Request-ID` MUST not SHOULD on all responses.
- **F-m2:** Add literal "Donations" to the out-of-scope list § 1.3.
- **F-m3:** SQLite encryption-at-rest: state "v1 does NOT require
  encryption at rest (operator-only VPS); multi-tenant migration
  MUST require it."
- **F-m4:** Audit log tamper resistance: defer with rationale —
  "v0.2 records append-only events; v0.3 SHOULD add hash-chain
  tamper-evidence if attack surface grows."
- **F-m5:** Capacity expansion budget change MUST emit audit event
  with old/new values.
- **F-M7 → demoted to MINOR (round-2 disagreement):** rate-limit
  pre/post-decrement: specify "MUST reflect post-decision remaining
  quota" in § 5.1.
- **F-m2-1:** "median, p50, and p95" → "median (p50) and p95" in § 2.11.
- **F-m2-2:** `X-RateLimit-Reset` MUST be Unix timestamp (not RFC
  3339) for OpenAI SDK compatibility.
- **F-m2-3:** rate-limit headers MUST reflect post-request remaining
  quota (overlaps F-M7-demoted).
- **F-m2-4:** OAuth state MUST be at least 128 bits from CSPRNG,
  bound to user session.
- **F-m2-5:** key regeneration MUST NOT affect usage history, quota
  state, or feedback history.
- **F-m2-6:** the gateway MUST install panic recovery middleware
  returning HTTP 500 in the OpenAI error envelope.
- **F-m2-7:** v1 does not require encryption at rest (covers m3 +
  m2-7; deduplicate).
- **F-m2-8:** audit trail tamper evidence deferred to v0.3 (covers
  m4 + m2-8; deduplicate).
- **F-m2-9:** SSE chunks MUST be framed as `data: {json}\n\n` per
  OpenAI streaming spec.

### F-M15 (AC coverage gap): Add focused ACs.

**Location:** § 18.

**Fix:** Add the following acceptance criteria:

- **AC-26:** OAuth callback URL allowlist enforcement (per F-C2)
- **AC-27:** Token revocation latency under 60s (per F-M5)
- **AC-28:** Kill switch persistence across restart (per F-M8)
- **AC-29:** OAuth state CSRF defense (deterministic test with
  forged state)
- **AC-30:** OAuth scope minimization (test that gateway rejects
  callbacks with elevated scopes)
- **AC-31:** Key rotation preserves usage history
- **AC-32:** Capacity tier de-escalation (per F-M10)
- **AC-33:** Feedback summary aggregation shape (per F-M12)
- **AC-34:** Provider-pinning header strip (per F-M21)
- **AC-35:** Demo token forgery rejected (per F-M14)
- **AC-36:** Quota refund on 504 with zero completion tokens (per D3)
- **AC-37:** Streaming quota reservation + settlement (per D3, F-M7)

Each new AC follows the existing AC format: precondition, action,
expected outcome, verification command.

## Output requirements

1. SPEC-006 updated in place. Version bumped to v0.2. Change log
   entry at the top summarizing the fix pass (use the AC-001/002/003
   change-log style from those spec headers).

2. § 2 (Locked decisions) revised per F-M1 with the verbatim-quote
   header note.

3. § 5 (Public HTTP API) gains:
   - Missing OpenAI fields in § 5.4 (F-M2)
   - Provider-pinning header strip (F-M21)
   - Feedback `scope` field (F-M11)
   - `X-Request-ID` MUST (F-m1)
   - `X-RateLimit-Reset` Unix timestamp (F-m2-2)
   - Demo token mechanism (F-M14 / D2)

4. § 6 (Identity and auth) gains:
   - OAuth callback URL allowlist (F-C2)
   - OAuth scope minimization (F-M3)
   - API key 256-bit entropy (F-M4)
   - Token revocation latency bound (F-M5)
   - OAuth state CSPRNG entropy (F-m2-4)
   - Key rotation preserves history (F-m2-5)

5. § 7 (Quotas) gains:
   - Atomic reservation pattern (F-M6)
   - Streaming + refund policy (F-M7 / D3)
   - Rate-limit post-decision semantics (F-m2-3)

6. § 9 (Kill switches) gains:
   - Activation latency MUST (F-M8)
   - Persistence (F-M8)

7. § 10 (Capacity burst) gains:
   - Signal measurement table (F-M9)
   - De-escalation logic (F-M10)
   - Budget change audit event (F-m5)

8. § 11 (User feedback) gains:
   - `scope` field schema (F-M11)
   - Summary response shape (F-M12)
   - Iteration trigger threshold (F-M13)

9. § 14 (Storage layer) gains:
   - Audit event coverage (F-M17)
   - v1 single-instance acknowledgment (F-M18 / D1)
   - Encryption-at-rest deferral (F-m3 / F-m2-7)
   - Tamper-evidence deferral (F-m4 / F-m2-8)

10. § 5.6 / § 12.2 (status) gains:
    - Coordinator `/poolz` bridge (F-M19)
    - Redaction rules (F-M19)

11. § 5.7 (feedback) gains:
    - Stored XSS defense (F-M20)

12. § 17 (Failure modes) gains:
    - 405/413 type/code mapping (F-M16)
    - Refund matrix (F-M15 / D3)
    - SSE framing explicit (F-m2-9)
    - Panic recovery middleware (F-m2-6)

13. § 18 (Acceptance criteria) gains AC-26 through AC-37
    (per F-M15 AC-coverage finding).

14. § 1.3 out-of-scope list adds "Donations" literal (F-m2).

15. § 2.11 metric line: median(p50) and p95 (F-m2-1).

16. `phase5-gateway/implementation-notes.html` gains a "Resolved in
    v0.2" section listing each F-* finding with one-line resolution.

## Self-verification checklist

- [ ] SPEC-006 version 0.1 → 0.2 in header.
- [ ] Change log entry references the audit at `specs/SPEC-006-audit.md`
      and counts (1C + 21M + 9m + 2 OQ).
- [ ] § 2 content semantically unchanged from v0.1; only the verbatim
      header note added.
- [ ] All 22 F-* findings (1 CRITICAL + 21 MAJOR) have visible
      resolution text in the spec.
- [ ] All 9 MINOR cleanups applied (some may deduplicate).
- [ ] D1, D2, D3 decisions visibly encoded in the corresponding spec
      sections.
- [ ] 12 new ACs (AC-26 through AC-37) present in § 18.
- [ ] No new normative content beyond what closes findings or
      encodes D1-D3.
- [ ] No proposed changes to SPEC-001 or SPEC-002 (if F-M19 surfaces
      a SPEC-002 gap, file as v1.1.4 follow-up note in implementation
      notes; do NOT edit SPEC-002).
- [ ] No premium positioning, no Tier-3 deprecation clause introduced.
- [ ] `phase5-gateway/implementation-notes.html` has "Resolved in
      v0.2" section.

If your edits exceed ~600 added lines in SPEC-006 or you find yourself
adding "improvements" beyond the audit findings, STOP — those are
scope creep. Defer to v0.3.

When done, print a 200-word handback summary:
- Findings closed by cluster (CRITICAL: 1, Cluster 1: N, Cluster 2: N,
  Cluster 3: N, MINOR: N).
- Any finding you could not close in v0.2 (with rationale).
- The new AC count and where they live.
- Whether SPEC-006 v0.2 is now READY TO LOCK or needs one more audit
  round.

Then stop. Do NOT begin implementation. The operator decides whether
to run a regression-check audit on v0.2 or proceed to
`BUILD_PHASE5_PROMPT.md`.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~30 min):

1. `git diff specs/SPEC-006-buyer-api.md` — confirm version bumped, change log entry present.
2. Verify all 1 CRITICAL + 21 MAJOR findings have visible resolution. Search the diff for each F-* label.
3. Verify D1, D2, D3 encoded in the spec text (single-instance, demo HMAC, streaming refund matrix).
4. Verify § 2 content matches v0.1 (only the header note added).
5. AC count: § 18 should now have 37 ACs (25 from v0.1 + 12 new).
6. No SPEC-001/002 edits. No premium positioning. No Tier-3 deprecation clause.

Then commit. Suggested message:

```
SPEC-006 v0.2: audit closing fixes

Closes 1 CRITICAL + 21 MAJOR + 9 MINOR findings from cross-model
audit (specs/SPEC-006-audit.md). Three operator decisions locked:
D1 v1 single-instance; D2 demo token HMAC mechanism; D3 streaming +
error quota refund policy.

12 new acceptance criteria (AC-26..AC-37) covering OAuth callback
allowlist, token revocation latency, kill switch persistence,
de-escalation, feedback aggregation, provider-pinning header strip,
demo token forgery, quota refund, streaming reservation/settlement.

No upstream spec edits. Locked design choices unchanged.

23/23 findings closed.
```

After commit, decide:

- **Regression audit** (recommended for first product spec): write `AUDIT_SPEC_006_V0_2_PROMPT.md` narrowly scoped to verify the v0.2 changes don't introduce regressions. Codex audits in ~30-45 min. Likely closes with READY TO BUILD verdict.

- **Skip regression, proceed to build**: defensible since v0.1 had no architectural CRITICALs and v0.2 is narrow text additions. Lower risk than after v0.1's audit.

After regression check (if run) clears: SPEC-006 locks at v1.0; draft `BUILD_PHASE5_PROMPT.md` for the gateway implementation. ~7-10 days of focused work per the spec's own estimate.

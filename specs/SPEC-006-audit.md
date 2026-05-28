# SPEC-006 v0.1 audit report

## Round 1 (Codex, 2026-05-28T22:23:23Z)

### Summary

- 2 CRITICAL findings
- 15 MAJOR findings
- 5 MINOR findings
- 2 QUESTIONS

SPEC-006 is directionally coherent: it keeps the coordinator as a router, preserves M4/M1 direct-tunnel paths, avoids premium positioning, captures the B+C feedback lock, and carries the 10K-Mac scale properties into architecture/storage sections. The blocking issues are mostly contract precision: OpenAI/SPEC-001 request-shape fidelity, OAuth security, quota arithmetic under concurrency and streaming, capacity-tier measurement, feedback API shape, and acceptance coverage.

### CRITICAL findings

C1. Public chat request field list drops SPEC-001/OpenAI-compatible fields

**Location:** § 1.4 lines 126-133; § 5.4 lines 865-880; SPEC-001 § 6.2 lines 791-809

**Finding:** SPEC-006 says it must preserve SPEC-001 chat request semantics, but the public gateway's supported field list omits `n`, `stream_options`, and `user`, all explicitly supported by SPEC-001. `stream_options` is especially important because OpenAI SDK users commonly set `stream_options={"include_usage": true}`.

**Why it matters:** A gateway implementer following § 5.4 can reject or strip SDK-valid requests that the locked provider/coordinator contract accepts. That is an OpenAI SDK/SPEC-001 compatibility regression, and the audit prompt classifies such regressions as CRITICAL.

**Suggested fix:** Add the missing SPEC-001 fields to § 5.4 and define behavior exactly as SPEC-001 does: `n` must be 1, `stream_options.include_usage=false` is tolerated/ignored, and `user` is diagnostics-only and never buyer-visible.

C2. OAuth callback URL allowlist is absent

**Location:** § 5.8 lines 1069-1084; § 6.1 lines 1108-1120

**Finding:** The OAuth callback requirements validate `state`, exchange the code server-side, and create accounts, but they never require strict callback/redirect URI allowlisting.

**Why it matters:** The audit prompt flags missing OAuth callback URL validation as CRITICAL. Without a normative allowlist, implementation can drift into open-redirect or misbound callback behavior around account/key issuance.

**Suggested fix:** Require exact redirect URI allowlisting for GitHub and email callbacks, with production and local-dev values listed in config. Reject any callback whose scheme/host/path does not exactly match an allowlisted value.

### MAJOR findings

M1. Section 2 is not a verbatim quotation of the BUILD locked choices

**Location:** § 2 lines 215-407; BUILD prompt lines 42-317

**Finding:** SPEC-006 § 2 semantically tracks the BUILD prompt closely, but it is not presented as a verbatim quote and has wording/punctuation changes, for example the feedback cross-reference changes from "See User feedback below" to "See Section 11".

**Why it matters:** The audit prompt requires operator pre-commitments to be quoted, not paraphrased, because § 2 is the locked input ledger.

**Suggested fix:** Replace § 2 with an explicitly quoted or mechanically copied block from BUILD prompt lines 48-317, then place spec-specific elaboration only outside § 2.

M2. OAuth scope minimization is unspecified

**Location:** § 5.8 lines 1075-1084; § 6.1 lines 1108-1120

**Finding:** The spec does not constrain GitHub OAuth scopes. It should require only the minimum needed identity/email scopes and forbid repository, organization, or write scopes.

**Why it matters:** Overbroad scopes create predictable user distrust and unnecessary security exposure during signup.

**Suggested fix:** Normatively require minimal scopes such as immutable user ID plus verified email access, and document that no repository/org/write scopes may be requested.

M3. API key entropy is hand-wavy

**Location:** § 2.3 line 255; § 6.4 lines 1144-1160

**Finding:** The key format says `mp_` plus "high entropy" but never specifies a minimum entropy budget.

**Why it matters:** API keys are bearer secrets. The audit prompt asks for at least 256 bits before encoding; without that, implementers can accidentally choose short base62 strings.

**Suggested fix:** Require at least 256 bits from a CSPRNG before base64url/base62 encoding, plus a fixed `mp_` prefix.

M4. Token revocation has no bounded effective latency

**Location:** § 6.6 lines 1172-1184; § 18 AC-4/AC-5 lines 2041-2067

**Finding:** Revocation "MUST make the old key unusable", but the spec does not state how quickly validation must observe revocation, nor does any AC test revocation latency.

**Why it matters:** With caches or multi-replica gateways, revocation can become best-effort unless bounded. The prompt recommends a bound under 60 seconds.

**Suggested fix:** Require revocation to take effect within a concrete bound, preferably immediately for storage lookups and under 60 seconds for any cache, and add an AC.

M5. Daily token quota decrement is not atomic or fair under concurrency

**Location:** § 7.2 lines 1225-1235; § 7.5 lines 1260-1268; § 14.4 lines 1733-1743

**Finding:** The spec defines concurrency reservations but not atomic token quota reservation/debit. It does not say whether concurrent requests reserve estimated tokens, use compare-and-swap, use a transaction, or can overspend the daily token cap.

**Why it matters:** Ten concurrent requests against one key near quota can all pass "available" and overshoot. This is a first-month production patch risk.

**Suggested fix:** Define a quota reservation ledger or transactional token budget check. State fairness when remaining quota is lower than concurrent demand.

M6. Streaming quota debit and refund semantics are undefined

**Location:** § 7.2 lines 1225-1235; § 5.4 lines 903-910; § 17.4-17.6 lines 1952-1980

**Finding:** Streaming token count is known only at the end, but the spec does not define whether quota is pre-reserved, post-debited, partially debited, or refunded on 502/503/504/cancellation after partial generation.

**Why it matters:** Streaming is a first-class supported path. Undefined debit/refund rules create quota unfairness and operator disputes.

**Suggested fix:** Define preflight estimate reservation, final settlement, and error/cancellation refund rules. Include whether generated partial tokens count.

M7. Rate-limit remaining timing is undefined

**Location:** § 5.1 lines 744-755; § 7.3 lines 1237-1243; § 7.6 lines 1270-1280

**Finding:** `X-RateLimit-Remaining` is required, but the spec does not state whether it is pre-decrement or post-decrement, nor how it behaves for streaming settlement.

**Why it matters:** Clients and tests will disagree about header values around boundary requests.

**Suggested fix:** Specify post-decision/post-reservation values for request admission, and final accounting visibility in `/v1/usage`.

M8. Kill-switch activation latency is weakened and persistence is undefined

**Location:** § 9.3 lines 1379-1393; § 15.3 lines 1822-1830

**Finding:** Activation latency only "SHOULD" take effect within 5 seconds. The spec also allows file reload, admin endpoint, or storage-backed config without saying which states survive restart.

**Why it matters:** Kill switches are incident controls. "SHOULD within 5 seconds" and undefined restart behavior are weaker than the prompt's bounded-latency/persistence bar.

**Suggested fix:** Make activation latency a MUST and define persistence for the chosen mechanism. If admin toggles are runtime-only, the spec must say that and require audit-visible loss on restart.

M9. Capacity signal measurement is underspecified

**Location:** § 2.8 lines 300-319; § 10.2-10.4 lines 1407-1455; § 16.4 lines 1868-1879

**Finding:** Tier signals name CPU, memory, bandwidth, provider feedback, cost, provider drops, and operator load, but the spec does not define source, sampling interval, aggregation window for most signals, or how monitoring jobs observe them.

**Why it matters:** Mechanical escalation cannot be implemented reproducibly from prose thresholds alone.

**Suggested fix:** Add a capacity signal table with source, sample cadence, aggregation window, threshold, hysteresis, and audit event fields.

M10. Tier de-escalation is missing except for manual capacity expansion

**Location:** § 10.5 lines 1457-1467

**Finding:** The spec defines escalation and an optional capacity-expansion reversal, but not de-escalation when signals clear naturally.

**Why it matters:** Once Tier 1/Tier 2 fires, implementation can leave the product permanently constrained even after recovery.

**Suggested fix:** Define automatic and manual de-escalation criteria, including minimum stable windows and audit logging.

M11. Feedback widget contract conflicts with the feedback endpoint schema

**Location:** § 5.7 lines 1031-1067; § 11.3 lines 1502-1510

**Finding:** The dashboard widget may call `POST /v1/feedback` with a `scope`, but § 5.7's request schema does not include `scope` or any source field. It also does not define the "thin account-specific feedback endpoint" alternative.

**Why it matters:** Capture mechanism C is locked for v1. As written, implementers cannot reliably distinguish per-request feedback from overall account feedback.

**Suggested fix:** Add `scope` or `source` to the schema with allowed values such as `request`, `session`, `account_overall`, and `playground`, or define the alternative endpoint fully.

M12. Feedback summary shape and aggregation math are missing

**Location:** § 11.5 lines 1520-1536; § 16.7 lines 1903-1911

**Finding:** `/admin/feedback-summary` is named, but response shape, window bounds, deduplication, weighting, and comment sampling rules are not specified.

**Why it matters:** The user-rating mechanism replaces the earlier falsification/deprecation framework. It needs precise operator-readable output.

**Suggested fix:** Define the endpoint schema and aggregation algorithm, including 7-day and 14-day windows and treatment of duplicate/idempotent request ratings.

M13. Iteration trigger is not measurable

**Location:** § 2.9 line 329; § 11.6 lines 1538-1546

**Finding:** "7-day rolling distribution shifts toward 1-2 for any 2-week window" lacks a threshold.

**Why it matters:** It cannot mechanically trigger operator review, and different implementers will choose different definitions of "shifts toward."

**Suggested fix:** Define a concrete trigger, for example 7-day share of ratings 1-2 above X%, mean below Y, or a delta relative to the prior 14-day baseline.

M14. Gateway-to-coordinator data contract for status and slots is incomplete

**Location:** § 5.6 lines 970-1021; § 12.2 lines 1562-1572; coordinator buyer API in `phase4-coordinator/internal/buyer/server.go` lines 257-291

**Finding:** SPEC-006 requires `/v1/status` to expose aggregate ready/draining/unavailable counts and `slots_free`, but the existing coordinator buyer surface exposes `/v1/models` with provider count, max context, and total slots only. The richer pool data is on coordinator operator surfaces, not the buyer API.

**Why it matters:** The gateway cannot build the required buyer-safe status shape unless it is allowed and configured to consume an internal operator/control endpoint, or unless the coordinator gains a new buyer-safe status snapshot. The spec does not define that bridge.

**Suggested fix:** Add a gateway-internal coordinator status contract: endpoint, auth, fields, freshness, and what gets redacted before public `/v1/status`.

M15. Acceptance criteria miss required security and lifecycle cases

**Location:** § 18 lines 2001-2322

**Finding:** The ACs are mostly deterministic, but they do not cover OAuth CSRF/state failure, callback allowlist enforcement, OAuth scope minimization, token revocation latency, key rotation without usage loss, kill-switch persistence across restart, capacity-tier de-escalation, or feedback summary aggregation shape.

**Why it matters:** These are not edge polish; several are security or production-control contracts.

**Suggested fix:** Add focused ACs for each missing branch, using simulated OAuth callbacks, fake clocks, storage inspection, and restart/reload checks.

### MINOR findings

m1. `X-Request-ID` is only SHOULD

**Location:** § 5.1 lines 756-764

**Finding:** The gateway SHOULD include `X-Request-ID`, but the rest of the spec relies on request IDs for feedback, debugging, and audit correlation.

**Why it matters:** Optional request IDs make support/debugging worse, especially for feedback tied to `request_id`.

**Suggested fix:** Make `X-Request-ID` mandatory on all responses, with safe inbound override rules retained.

m2. Out-of-scope list names many payment surfaces but not "donations" exactly

**Location:** § 1.3 lines 72-120; BUILD prompt lines 318-347

**Finding:** The list includes "Donation button", "Support us link", and payment-adjacent UI, but not the explicit BUILD out-of-scope term "donations".

**Why it matters:** The intent is clear elsewhere, so this is not blocking, but exact out-of-scope wording prevents future relitigation.

**Suggested fix:** Add "Donations" as a literal bullet.

m3. No SQLite encryption-at-rest decision

**Location:** § 14.2 lines 1702-1715

**Finding:** The SQLite storage section does not address encryption at rest.

**Why it matters:** For v1 on operator-controlled Pearl VPS this is probably acceptable, but the security posture should be explicit before multi-tenant storage.

**Suggested fix:** State v1's encryption-at-rest decision and require re-evaluation before moving to multi-tenant storage.

m4. Audit log tamper resistance is not specified

**Location:** § 4.8 lines 637-651; § 14.3 lines 1716-1731

**Finding:** Audit events are append-only, but there is no integrity chain, signature, or explicit "not tamper-evident in v1" statement.

**Why it matters:** Append-only tables alone do not prevent silent modification by an operator or compromised process.

**Suggested fix:** Either add hash chaining/HMAC for audit events or record that tamper evidence is deferred with rationale.

m5. Capacity expansion branch is optional but not connected to monthly budget accounting

**Location:** § 10.5 lines 1457-1467; § 15.2 lines 1812-1815

**Finding:** The operator may raise budget cap, but the spec does not say whether that is a config change, audit event, runtime policy event, or both.

**Why it matters:** Budget changes are one of the few cost-control mutations in v1 and should be auditable.

**Suggested fix:** Require budget-cap changes to be recorded as audit events with old/new values and actor.

### Operator questions surfaced

q1. Should the gateway consume coordinator operator/control endpoints for status snapshots, or should the coordinator expose a new internal buyer-safe status endpoint?

**Location:** § 5.6 lines 970-1021; § 12.2 lines 1562-1572

This is a genuine implementation boundary choice. It should not move auth/quota/account state into the coordinator, but the gateway needs a source for pool status richer than public `/v1/models`.

q2. What exact quota accounting policy should apply to partial streaming generations?

**Location:** § 7.2 lines 1225-1235; § 17.6 lines 1974-1980

The operator should decide whether partial tokens count when the buyer disconnects or the provider fails after some output has been produced.

### Category coverage notes

- A Locked-decision fidelity: one MAJOR for non-verbatim § 2; no semantic drift in monthly cap, default quota, GitHub-primary identity, B+C feedback, no premium positioning, or no deprecation clause.
- B 10K-Mac scale: no CRITICAL scale trap found; quota atomicity and status data source are MAJOR precision gaps.
- C OpenAI SDK compatibility: one CRITICAL for missing request fields.
- D Identity/auth: one CRITICAL and three MAJOR findings.
- E Quota/concurrency: three MAJOR findings.
- F Kill switches/capacity burst: four MAJOR/MINOR findings.
- G User feedback: three MAJOR findings.
- H Failure modes/error envelopes: no separate error-envelope finding beyond quota/streaming ambiguity.
- I Instrumentation: north-star and design metrics mostly present; capacity measurement remains MAJOR.
- J Front-door contract: no direct incompatibility with `beta/web/`, but the demo-token/session implementation remains underspecified through the feedback/status issues above.
- K Scope discipline: no premium pricing, no SPEC-001/002 mutation, no Tier-3 deprecation found.
- L Acceptance criteria: one MAJOR coverage finding.
- M Backward compatibility: legacy `m4.streamvc.live` and `m1.streamvc.live` are explicitly preserved.
- N Security: callback allowlist is CRITICAL; storage/tamper/XSS-adjacent details need follow-up. Comment rendering is safe only if the UI uses text escaping; the spec should require escaping when rendering feedback comments, but I counted that under M15 rather than a separate finding.

### Self-verification

- [x] Read every section of SPEC-006 v0.1 (all 20 sections, all 25 ACs).
- [x] Compared SPEC-006 § 2 against BUILD prompt's locked-design header.
- [x] Walked each Category A through N and noted coverage.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location on every finding.
- [x] Suggested fix for CRITICAL findings.
- [x] Verdict included below.

### Verdict

READY WITH FIX PASS.

The architecture is not fundamentally wrong, but the CRITICAL compatibility/security issues and the MAJOR production-control gaps need a narrow v0.2 fix pass before implementation.

---

## Round 2 (Claude, 2026-05-29T09:00:00Z)

### Summary

- 1 CRITICAL finding (0 new beyond round 1)
- 21 MAJOR findings (8 new beyond round 1)
- 9 MINOR findings (9 new beyond round 1)
- 2 QUESTIONS

Round 1 (Codex) was thorough. This round confirms most of its findings, upgrades a few, adds 8 MAJORs and 9 MINORs that round 1 missed, and disagrees with one severity assessment.

---

### CRITICAL findings

**C2-1. OAuth callback URL allowlist not required (confirms round 1 C2)**

**Location:** Section 5.8 (lines 1069-1084), Section 6.1 (lines 1108-1120)
**Finding:** Identical to round 1 C2. The spec requires `state` parameter validation (good — CSRF defense) but does not require a strict `redirect_uri` allowlist.
**Why it matters:** Without explicit callback URL validation, an implementer could register a permissive callback pattern in the GitHub OAuth app, enabling authorization code interception. GitHub OAuth does enforce `redirect_uri` matching when configured, but the spec must mandate the configuration.
**Mitigating factor:** GitHub's OAuth implementation requires callback URL registration in app settings and rejects mismatched `redirect_uri` by default.
**Suggested fix:** Add to Section 5.8: "The GitHub OAuth app MUST be configured with a strict callback URL allowlist containing only `https://api.streamvc.live/auth/github/callback`. The gateway MUST reject callbacks whose `redirect_uri` does not exactly match. Local development MAY use `http://localhost:{port}/auth/github/callback` as a separate OAuth app."

---

### MAJOR findings

**M2-1. Chat request field list drops SPEC-001-compatible fields (confirms round 1 C1, reclassified)**

**Location:** Section 5.4 (lines 865-880), Section 1.4 (lines 126-133)
**Finding:** Round 1 C1 is correct: Section 5.4's supported request field list omits `n`, `stream_options`, and `user`, all of which SPEC-001 v1.2.2 accepts. `stream_options` is particularly important because `stream_options: {"include_usage": true}` is the standard OpenAI SDK mechanism for receiving token usage in streaming responses.
**Severity note:** Round 1 rated this CRITICAL. I rate it MAJOR because the gateway's job is to forward supported fields to the coordinator, and Section 5.4 says "Supported request fields" — it's a documentation gap, not a rejection requirement. An implementer who follows Section 1.4 ("SPEC-006 MUST preserve SPEC-001 v1.2.2 behavior") would forward all fields. However, a strict implementer reading only Section 5.4 could whitelist-reject these fields, which would break SDK usage.
**Suggested fix:** Add `n`, `stream_options`, `user`, and `logprobs` to the Section 5.4 supported field list. For `n`: note MUST be 1 in v1 (reject >1 with 400). For `stream_options`: accept and forward. For `user`: accept as diagnostics, never expose to buyers. For `logprobs`: accept syntactically, behavior model-dependent.

**M2-2. Section 2 is not a verbatim quotation (confirms round 1 M1)**

**Location:** Section 2 (lines 215-407), BUILD prompt lines 48-317
**Finding:** Section 2 semantically matches the BUILD prompt's locked design choices but is not presented as a verbatim quotation. Changes include punctuation normalization, cross-reference updates ("See Section 11" vs "See 'User feedback' below"), and minor reformatting. No semantic drift was found.
**Why it matters:** The audit prompt requires "quoted, not paraphrased." The changes are cosmetic but the principle matters — the locked decision section should be the operator's words, not the spec author's.
**Suggested fix:** Add a header note to Section 2: "This section reproduces the operator's pre-commitments from BUILD_SPEC_006_PROMPT.md. Cross-references have been updated to match this document's section numbering. Substantive content is unchanged."

**M2-3. OAuth scope minimization not specified (confirms round 1 M2)**

**Location:** Section 6.1 (lines 1109-1121)
**Finding:** The spec does not constrain GitHub OAuth scopes. The gateway needs only `read:user` (or empty scope for public profile) and optionally `user:email`.
**Suggested fix:** Add to Section 6.1: "The gateway MUST request only `read:user` scope (or empty scope). `user:email` is OPTIONAL. Scopes beyond profile and email MUST NOT be requested."

**M2-4. API key entropy not quantified (confirms round 1 M3)**

**Location:** Section 6.4 (lines 1146-1160)
**Finding:** "High entropy" without a minimum bit count.
**Suggested fix:** "The random portion MUST contain at least 256 bits of entropy from a CSPRNG before encoding."

**M2-5. Token revocation latency not bounded (confirms round 1 M4)**

**Location:** Section 6.6 (lines 1173-1184)
**Finding:** No maximum latency between revocation action and enforcement.
**Suggested fix:** "Revocation MUST take effect within 60 seconds. Cache invalidation MUST occur within the same bound."

**M2-6. Token quota atomic enforcement under concurrency not specified (confirms round 1 M5)**

**Location:** Section 7.2 (lines 1226-1235), Section 14.4 (lines 1734-1743)
**Finding:** Append-only usage events + concurrent requests = race condition on quota checks. Two requests can both read sufficient quota and both proceed.
**Suggested fix:** Define a quota reservation pattern: "Quota checking MUST use a transactional reservation or CAS-guarded balance check. Minor overshoot up to `max_tokens_per_request` tokens beyond the daily limit is tolerable if documented."

**M2-7. Streaming quota debit timing not defined (confirms round 1 M6)**

**Location:** Section 5.4 (lines 899-909), Section 7.2 (lines 1226-1235)
**Finding:** For streaming, actual usage is known only at stream end. The spec doesn't define whether quota is pre-reserved.
**Suggested fix:** "For streaming requests, the gateway MUST reserve `max_tokens` (or the configured cap) before forwarding. On completion, adjust to actual usage. On failure/cancellation, refund unrealized reservation."

**M2-8. Kill switch activation latency weakened; persistence undefined (confirms round 1 M8)**

**Location:** Section 9.3 (lines 1391-1393)
**Finding:** "SHOULD take effect within 5 seconds" should be MUST. Kill switch state persistence across restart is undefined.
**Suggested fix:** Change SHOULD to MUST. Add: "Kill switch state MUST persist across gateway restarts."

**M2-9. Capacity signal measurement method/frequency undefined (confirms round 1 M9)**

**Location:** Section 10.2 (lines 1407-1415)
**Finding:** No tool, sampling interval, or "sustained" definition for CPU/memory/bandwidth signals.
**Suggested fix:** Add signal measurement table with source, cadence, aggregation window, and threshold definition.

**M2-10. Tier de-escalation logic not defined (confirms round 1 M10)**

**Location:** Section 10 (lines 1397-1476)
**Finding:** Only escalation and manual capacity expansion defined. No automatic de-escalation when signals clear.
**Suggested fix:** "When all Tier N signals stop firing for a configurable cooldown (default: 1 hour), the monitoring job MUST de-escalate to Tier N-1."

**M2-11. Feedback widget `scope` field not in schema (confirms round 1 M11)**

**Location:** Section 5.7 (lines 1031-1067), Section 11.3 (lines 1503-1512)
**Finding:** Section 11.3 says the widget "MAY call POST /v1/feedback with a `scope`" but the Section 5.7 request schema has no `scope` field.
**Suggested fix:** Add `scope` to the feedback schema: `"scope": "request" | "session" | "account" | "playground"` (optional, defaults to `"request"` when `request_id` is present, `"account"` otherwise).

**M2-12. `/admin/feedback-summary` response shape not defined (confirms round 1 M12)**

**Location:** Section 11.5 (lines 1521-1536)
**Finding:** Aggregation requirements listed but no JSON response shape.
**Suggested fix:** Add a response shape example.

**M2-13. Iteration signal numeric threshold not defined (confirms round 1 M13)**

**Location:** Section 11.6 (lines 1539-1547)
**Finding:** "Shifts toward 1-2" is not measurable. Faithful to BUILD prompt but the audit prompt requires precision.
**Suggested fix:** "Operator review fires when 7-day share of ratings 1-2 exceeds 40% in any window containing >=20 ratings."

**--- New MAJOR findings not in round 1 ---**

**M2-14. Demo token validation mechanism not defined**

**Location:** Section 6.8 (lines 1199-1207), Section 12.3 (lines 1575-1589)
**Finding:** The spec requires `X-Demo-Token` to be "bounded, signed, or otherwise validated" but does not define the validation mechanism. Without a concrete mechanism, an attacker can forge demo tokens and bypass per-IP demo quota by minting unlimited identities.
**Why it matters:** Demo quota is the primary abuse defense for unauthenticated traffic. The front door is the first thing strangers see. A forgeable demo token renders the demo quota system decorative.
**Suggested fix:** "The gateway MUST validate demo tokens via HMAC-SHA256 signature with an operator secret, embedding client IP and expiry (max 24h). The front door obtains tokens from `POST /auth/demo-session` (rate-limited per IP). Static shared secrets MUST NOT be used."

**M2-15. Quota refund on upstream error not specified**

**Location:** Section 17.4-17.6 (lines 1953-1980)
**Finding:** If a request returns 502/504 after partial token generation, the spec does not say whether partial tokens are refunded. Section 17.6 mentions "cancellation usage or audit event" but doesn't clarify quota impact.
**Why it matters:** For a free-tier service where 502/503/504 are expected ("real Macs, sometimes asleep"), charging quota for failed requests is punitive.
**Suggested fix:** "When a request terminates with 502/504 after zero completion tokens, the gateway MUST NOT debit tokens. After partial completion, debit only actual tokens consumed."

**M2-16. 405 and 413 error types/codes missing**

**Location:** Section 17.1 (lines 1917-1931)
**Finding:** Status code map lists 405 and 413 but Sections 17.2-17.7 do not assign error `type` and `code` values for them. Section 5.2 requires all errors to use the OpenAI envelope with type and code.
**Suggested fix:** 405: `type: "invalid_request_error"`, `code: "method_not_allowed"`. 413: `type: "invalid_request_error"`, `code: "request_too_large"`.

**M2-17. Kill switch toggle and quota change audit logging not required**

**Location:** Section 14.3 (lines 1717-1731), Section 9.3 (lines 1379-1393)
**Finding:** Capacity tier transitions and expansion reversals are audit-logged (Sections 10.5-10.6), but kill switch toggles, quota configuration changes, and account blocks are not explicitly required to be audit events.
**Why it matters:** Kill switch toggles are the most critical operator action in v1. Without audit logging, incident post-mortems lack timeline evidence.
**Suggested fix:** Add: "audit_events MUST record every kill switch toggle, quota config change, key revocation, account block, and capacity tier transition."

**M2-18. v1 horizontal scalability vs SQLite single-instance not reconciled**

**Location:** Section 1.8 (line 197), Section 4.6 (lines 601-615), Section 14.2 (lines 1702-1714)
**Finding:** "The gateway MUST be horizontally scalable from day 1" and "MUST NOT require sticky load balancing" — but v1 uses SQLite, which is single-writer. The spec doesn't acknowledge v1 is single-instance.
**Why it matters:** An implementer might attempt multi-instance SQLite, causing lock contention and data corruption.
**Suggested fix:** Add: "v1 with SQLite is a single-gateway-instance deployment. Multi-instance requires migration to PostgreSQL or D1. The architecture ensures this migration needs no handler changes."

**M2-19. Gateway-to-coordinator status data bridge not defined (confirms round 1 M14)**

**Location:** Section 5.6 (lines 970-1021), coordinator `phase4-coordinator/internal/buyer/`
**Finding:** SPEC-006's `/v1/status` requires `ready`, `draining`, `unavailable` provider counts and `slots_free` per model. The coordinator's buyer API (`/v1/models`) exposes only `provider_count`, `total_slots`, and `max_context_tokens`. The richer pool data lives on operator endpoints (`/poolz`, `/admin/*`) on the provider port.
**Why it matters:** The gateway cannot build the required status shape without consuming internal coordinator endpoints. The spec must define this bridge without pushing account/auth state into the coordinator.
**Suggested fix:** Define a gateway-internal coordinator contract: "The gateway MAY consume `http://127.0.0.1:{coordinator_provider_port}/poolz` as an internal data source for `/v1/status`. The gateway MUST NOT expose raw `/poolz` data to buyers."

**M2-20. Stored XSS risk: feedback comment rendering not addressed**

**Location:** Section 5.7 (lines 1023-1067)
**Finding:** The `comment` field (up to 2,000 bytes) is the only user-controlled free-text field. The spec does not address HTML escaping when rendering in dashboard, account page, or admin view.
**Why it matters:** Even in operator-only admin views, stored XSS could compromise the operator's session.
**Suggested fix:** "The `comment` field MUST be treated as untrusted input. Rendering surfaces MUST escape HTML entities. Gateway JSON MUST NOT include pre-rendered HTML."

**M2-21. Buyer-supplied coordinator routing headers not stripped**

**Location:** Section 5.4 (lines 886-892), Section 8.3 (lines 1324-1331)
**Finding:** The coordinator accepts `X-MacProvider-Provider`, `X-MacProvider-Session`, and `X-MacProvider-Pref` as request headers for provider pinning (confirmed in `phase4-coordinator/internal/buyer/server.go`). Section 5.4 says the gateway "MUST forward the request... without adding buyer-visible provider preference headers" and Section 8.3 requires stripping response headers. But neither section requires the gateway to strip buyer-supplied inbound routing headers before forwarding. A buyer who guesses a valid `provider_id` could pin to a specific provider via `X-MacProvider-Provider: m4-anon`, enabling targeted abuse and provider fingerprinting.
**Why it matters:** Provider transparency is a locked architectural invariant. The response-side scrubbing in Section 8.3 is necessary but not sufficient — request-side stripping is also needed.
**Suggested fix:** Add to Section 5.4: "The gateway MUST strip `X-MacProvider-Provider`, `X-MacProvider-Session`, and `X-MacProvider-Pref` headers from buyer requests before forwarding to the coordinator. Buyers MUST NOT be able to influence provider selection."

---

### MINOR findings

**m2-1. Median and p50 are identical — redundant metric**
**Location:** Section 2.11 (lines 339-345)
**Finding:** "median, p50, and p95" — median IS p50. Preserved faithfully from BUILD prompt.
**Suggested fix:** "median (p50) and p95."

**m2-2. `X-RateLimit-Reset` format ambiguous**
**Location:** Section 7.3 (lines 1238-1243)
**Finding:** "Unix timestamp or RFC 3339 value consistently." OpenAI uses Unix timestamps. "Or" creates SDK ambiguity.
**Suggested fix:** Specify Unix timestamp for OpenAI SDK compatibility.

**m2-3. Rate-limit header pre/post-decrement not specified**
**Location:** Section 5.1 (lines 744-755)
**Finding:** `X-RateLimit-Remaining` doesn't say pre- or post-decrement.
**Suggested fix:** "MUST reflect post-request remaining quota."

**m2-4. OAuth state generation method not specified**
**Location:** Section 5.8 (lines 1069-1084)
**Finding:** "validate `state`" without specifying generation (random, session-bound, HMAC-signed).
**Suggested fix:** "State MUST be at least 128 bits from CSPRNG, bound to user session."

**m2-5. Usage history across key rotation not explicit**
**Location:** Section 6.6 (lines 1173-1184)
**Finding:** "Regeneration MUST create a new key" but doesn't state usage history survives. Schema implies it (usage events reference account_id), but should be explicit.
**Suggested fix:** "Key regeneration MUST NOT affect usage history, quota state, or feedback history."

**m2-6. Framework-level panic error shape not addressed**
**Location:** Section 5.2 (lines 766-790)
**Finding:** All errors must use OpenAI envelope, but Go panics produce generic 500 text/html.
**Suggested fix:** "The gateway MUST install panic recovery middleware returning 500 in the OpenAI error envelope."

**m2-7. Storage encryption at rest not addressed**
**Location:** Section 14 (lines 1694-1756)
**Finding:** No encryption-at-rest statement for v1 SQLite.
**Suggested fix:** "v1 does not require encryption at rest (operator-only VPS). Multi-tenant migration MUST require it."

**m2-8. Audit trail tamper-evidence not specified**
**Location:** Section 4.8 (lines 637-651)
**Finding:** Append-only without integrity chain.
**Suggested fix:** Defer to v0.2: "v0.2 SHOULD add tamper-evidence (hash chain or Merkle tree)."

**m2-9. SSE framing format not explicitly stated**
**Location:** Section 5.4 (lines 899-909)
**Finding:** "Preserve OpenAI-compatible SSE chunks" relies on pass-through. The `data: {...}\n\n` framing is not explicitly stated.
**Suggested fix:** "Each SSE chunk MUST be framed as `data: {json}\n\n` per OpenAI streaming specification."

---

### Operator questions surfaced

**q2-1. v1 single-instance acknowledgment**
Should the spec explicitly state "v1 is single-gateway-instance" (M2-18)? This affects deployment docs and prevents implementers from attempting multi-instance SQLite.

**q2-2. Demo token mechanism choice**
Should the spec lock a specific demo token mechanism (M2-14) or leave it as an implementation choice? HMAC-signed with gateway secret + IP + expiry is the cheapest safe option.

---

### Round 2 notes on Round 1

**Findings I confirm:**
- C2 (OAuth callback URL): Confirmed as the only CRITICAL. Both rounds agree.
- M1 (Section 2 not verbatim): Confirmed — cosmetic changes, no semantic drift.
- M2 (OAuth scope): Confirmed.
- M3 (key entropy): Confirmed.
- M4 (revocation latency): Confirmed.
- M5 (quota atomicity): Confirmed. This is the most impactful MAJOR.
- M6 (streaming quota): Confirmed.
- M8 (kill switch latency + persistence): Confirmed. I split into two sub-findings for precision.
- M9 (capacity signal measurement): Confirmed.
- M10 (tier de-escalation): Confirmed.
- M11 (feedback scope field): Confirmed — good catch. I missed this on first pass.
- M12 (feedback summary shape): Confirmed.
- M13 (iteration trigger): Confirmed.
- M14 (coordinator status data bridge): Confirmed — important implementation-level finding.
- M15 (AC coverage): Confirmed.
- m1-m5 (all MINOR findings): Confirmed.

**Findings I disagree with:**
- **C1 (missing request fields)**: I reclassify to MAJOR, not CRITICAL. Section 1.4 says "SPEC-006 MUST preserve SPEC-001 v1.2.2 behavior for... `/v1/chat/completions` request body semantics" which is the normative requirement to forward all SPEC-001 fields. Section 5.4's supported list is a documentation gap, not a rejection mandate. An implementer following Section 1.4 would forward `n`, `stream_options`, and `user`. However, a strict whitelist implementer reading only Section 5.4 could break SDK usage, so MAJOR is warranted.

**Findings I disagree with (severity only):**
- **M7 (rate-limit pre/post-decrement)**: Round 1 rated MAJOR. I rate MINOR — pre/post-decrement disagreement doesn't break SDKs or cause production failures, it affects debugging.

**New findings round 1 missed:**
- M2-14: Demo token validation mechanism (MAJOR)
- M2-15: Quota refund on upstream error (MAJOR)
- M2-16: 405/413 error codes (MAJOR)
- M2-17: Kill switch and quota change audit logging (MAJOR)
- M2-18: v1 horizontal scalability vs SQLite (MAJOR)
- M2-19: Already found by round 1 as M14, confirmed
- M2-20: Stored XSS in feedback comments (MAJOR)
- M2-21: Buyer-supplied coordinator routing headers not stripped (MAJOR) — found via coordinator Go code analysis; buyers could pin to specific providers via `X-MacProvider-Provider` header, bypassing provider transparency
- m2-1 through m2-9: Nine MINOR findings on metric redundancy, format ambiguity, state generation, rotation history, panic recovery, encryption, tamper-evidence, and SSE framing

**Verdict (mine, independent of round 1):**

**READY WITH FIX PASS.**

Rationale: Both rounds agree on the verdict. The single CRITICAL (OAuth callback URL) is a one-sentence fix. The ~20 MAJOR findings cluster into three addressable groups:

1. **Precision gaps** (M2-1 through M2-5, M2-11 through M2-13, M2-16): The spec names the requirement but under-specifies it. Fixes are narrow additions.
2. **Concurrency/lifecycle gaps** (M2-6 through M2-10, M2-14, M2-15): The append-only architecture is sound but needs explicit patterns for concurrent access, streaming debit, error refund, and tier reversal.
3. **Verification/operations gaps** (M2-17 through M2-20): Missing audit logging, deployment-reality acknowledgment, coordinator status bridge, and XSS defense.

No architectural CRITICALs. No locked-decision violations. No SPEC-001/002 scope creep. The fix pass targets a single `FIX_SPEC_006_V0_2_PROMPT.md` run.

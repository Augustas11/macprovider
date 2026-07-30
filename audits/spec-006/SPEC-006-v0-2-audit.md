# SPEC-006 v0.2 regression audit

Auditor: Codex GPT-5.5

Spec audited: `specs/SPEC-006-buyer-api.md` v0.2

Reference inputs:
- `specs/SPEC-006-audit.md`
- `specs/FIX_SPEC_006_V0_2_PROMPT.md`
- `specs/BUILD_SPEC_006_PROMPT.md`
- optional coordinator reference under `phase4-coordinator/internal/`

Audit scope: narrow v0.1 to v0.2 regression check only. This report verifies the 1 CRITICAL, 21 MAJOR, 9 MINOR closures, D1-D3 coherence, and AC-26 through AC-37 quality. It does not re-audit unchanged SPEC-006 content.

## Summary

- 0 CRITICAL findings
- 3 MAJOR findings
- 0 MINOR findings
- Overall verdict: READY WITH NARROW FIX

The v0.2 spec text closes the substantive security, quota, feedback, capacity, status, and provider-transparency gaps. D1, D2, and D3 are encoded coherently enough for implementation. The remaining regressions are concentrated in AC-26 through AC-37: every new AC has the required four sections, but the acceptance criteria do not consistently specify status codes and response body shapes, and two ACs fail to prove the exact behavior they are intended to lock.

## Closure verification (Category A)

| Finding | Verdict | Location | Notes |
|---|---|---:|---|
| F-C2 OAuth callback URL allowlist | CLOSED | § 5.8, § 6.1, AC-26 | The allowlist, `auth.oauth.callback_allowlist`, startup validation, and empty-list startup failure are present. AC-26 exists, but see Major M2 for method mismatch in the AC action. |
| F-M1 § 2 verbatim quotation | CLOSED | § 2 | § 2 opens with the required provenance note, states cross-reference and punctuation-only normalization, and forbids alternative proposals. Semantic content matches the BUILD prompt's locked choices. |
| F-M2 missing OpenAI fields | CLOSED | § 5.4 | `n`, `stream_options`, `user`, and `logprobs` are listed with the required v1 behavior. |
| F-M3 OAuth scope minimization | CLOSED | § 6.1, AC-30 | `read:user` is required, `user:email` is optional only under the stated condition, and repository/organization/gist/write scopes are forbidden. |
| F-M4 API key entropy | CLOSED | § 6.4 | Keys require at least 256 bits of CSPRNG entropy before encoding and no truncation. |
| F-M5 token revocation latency | PARTIAL | § 6.6, AC-27 | § 6.6 has the 60-second bound and immediate storage observation. AC-27 does not deterministically prove the bound; see Major M3. |
| F-M6 atomic quota enforcement | CLOSED | § 7.2, § 14.4 | Reservation ledger, atomic storage primitive, and SQLite `BEGIN IMMEDIATE` are specified. |
| F-M7 streaming quota debit timing | CLOSED | § 5.4, § 7.2, § 17.7 | Reserve-before-forward and settle-to-actual streaming behavior match D3. |
| F-M8 kill switch latency + persistence | CLOSED | § 9.3, AC-28 | Runtime toggling, activation within 5 seconds, persistence, startup read, and SIGHUP reload are present. |
| F-M9 capacity signal measurement table | CLOSED | § 10.2-10.4 | The table includes source, cadence, window, threshold, and hysteresis for CPU, memory, bandwidth, provider feedback, cost, provider drops, and operator load. |
| F-M10 tier de-escalation | CLOSED | § 10.5, AC-32 | Automatic cooldown-based and manual de-escalation are specified, with audit events. |
| F-M11 feedback scope field | CLOSED | § 5.7, § 11.3 | `scope` has the four enum values, default behavior, bearer/demo auth split, and dashboard-account capture. |
| F-M12 feedback summary shape | CLOSED | § 11.5, AC-33 | Response shape includes window, count, mean, distribution, `by_scope`, trend, and comment samples. |
| F-M13 iteration trigger threshold | CLOSED | § 11.6 | 40% ratings 1-2, minimum 20 events, and hourly polling are specified. |
| F-M14 demo token HMAC | CLOSED | § 6.8, AC-35 | HMAC-SHA256 payload/signature format, `auth.demo.signing_secret`, issuance endpoint, per-IP rate limit, IP binding, TTL, and static-secret prohibition are present. |
| F-M15 quota refund matrix | CLOSED | § 17.4-17.7, AC-36 | The matrix matches D3: 503 none, 502/504 zero completion prompt only, partial prompt plus actual completion. |
| F-M16 405/413 codes | CLOSED | § 17.1 | 405 and 413 map to `invalid_request_error` with `method_not_allowed` and `request_too_large`. |
| F-M17 audit log coverage | CLOSED | § 14.3 | Kill switches, quota config changes, key revocations/regenerations, account blocks, capacity tier transitions, and budget cap mutations are enumerated. |
| F-M18 v1 single-instance | CLOSED | § 1.8, § 14.2 | v1 single gateway instance with SQLite is acknowledged; multi-instance requires storage migration while handlers stay abstracted. |
| F-M19 coordinator status bridge | CLOSED | § 5.6, § 12.2 | Gateway consumes internal `/poolz`, uses operator auth when configured, redacts provider IDs, hostnames, RAM/CPU, endpoint URLs, and operator identity. Coordinator code confirms `/poolz` on provider port and raw `pool.Provider` exposure, so redaction is necessary and correctly specified. |
| F-M20 stored XSS defense | CLOSED | § 5.7 | Comments are untrusted, raw UTF-8 storage is allowed, output-time HTML escaping is required, and JSON must not include pre-rendered HTML. |
| F-M21 provider-pinning header strip | CLOSED | § 5.4, § 8.3, AC-34 | `X-MacProvider-Provider`, `X-MacProvider-Session`, and undocumented `X-MacProvider-*` request headers are stripped before auth. Coordinator code confirms these headers currently influence routing if received directly. |

## D1/D2/D3 coherence (Category B)

- D1 verdict: CLOSED. § 1.8 states v1 is a single gateway instance with SQLite, and § 14.2 states multi-instance deployment requires moving `AuthStore`, `UsageStore`, and `FeedbackStore` to a multi-writer backend. The older horizontal-scalability wording remains, but § 1.8 now narrows it to multi-instance feasibility rather than v1 exercise.
- D2 verdict: CLOSED. § 6.8 specifies token format, payload fields `v`, `ip`, `iat`, `exp`, `auth.demo.signing_secret`, `/auth/demo-session`, per-IP issuance rate limit, exact IPv4 or IPv6 /64 binding, 24h max TTL, and static shared-secret prohibition.
- D3 verdict: CLOSED. § 7.2 and § 17.7 agree on reserve-before-forward and provider-reached-vs-not settlement: 200 prompt plus completion, 503 none, 502/504 zero completion prompt only, 502/504 partial prompt plus actual completion, client disconnect prompt plus actual completion at disconnect.

## AC quality (Category C)

| AC | Verdict | Notes |
|---|---|---|
| AC-26 OAuth callback allowlist enforcement | PARTIAL | Has precondition/action/outcome/command, but action says `POST` even though § 5.8 defines `GET /auth/github/callback`; outcome lacks exact status codes and error body. See Major M2. |
| AC-27 token revocation latency | PARTIAL | Has the four sections, but "within 65 seconds" does not prove the required 60-second bound and outcome lacks error body shape. See Major M3. |
| AC-28 kill switch persistence | PARTIAL | Has the four sections and names 503 beta-paused, but lacks the expected OpenAI error envelope/body fields. |
| AC-29 OAuth state CSRF defense | PARTIAL | Has the four sections, but lacks explicit status codes and error/success body shape. |
| AC-30 OAuth scope minimization | PARTIAL | Has the four sections, but lacks explicit status codes and response body shape for allowed and rejected callbacks. |
| AC-31 key rotation preserves history | PARTIAL | Has the four sections, but lacks exact old-key/new-key statuses and response body shapes. |
| AC-32 capacity tier de-escalation | PARTIAL | Has the four sections, but lacks exact operator response/status and audit-event shape. |
| AC-33 feedback summary aggregation shape | PARTIAL | Has the four sections and points to § 11.5 schema, but lacks explicit 200 status and operator-auth failure shape. |
| AC-34 provider-pinning header strip | PARTIAL | Has the four sections, but lacks exact gateway status/body expectations and captured forwarded-request shape. |
| AC-35 demo token forgery rejected | PARTIAL | Has the four sections and says forged/cross-IP/expired tokens return 401, but lacks the success status/body for valid token and the 401 error envelope shape. |
| AC-36 quota refund on 504 with zero completion | PARTIAL | Has the four sections, but lacks the 504 error body shape and the exact `/v1/usage` response fields to assert. |
| AC-37 streaming quota reservation + settlement | PARTIAL | Has the four sections, but lacks concrete SSE/status expectations and the exact quota/usage response fields to assert. |

## MINOR cleanups (Category D)

| Check | Verdict | Location | Notes |
|---|---|---:|---|
| D.1 X-Request-ID MUST | CLOSED | § 5.1 | All responses MUST include `X-Request-ID`. |
| D.2 Donations literal | CLOSED | § 1.3 | `Donations` is explicitly out of scope. |
| D.3 SQLite encryption-at-rest decision | CLOSED | § 14.2 | v1 does not require SQLite encryption at rest; future multi-tenant storage must. |
| D.4 Audit log tamper resistance deferral | CLOSED | § 14.3 | v0.3 hash-chain tamper evidence is deferred with rationale. |
| D.5 Capacity expansion budget audit event | CLOSED | § 10.5, § 14.3 | Budget-cap mutation emits audit event with old value, new value, and actor. |
| D.6 median (p50) and p95 | CLOSED | § 2.11 | Metric wording is no longer redundant. |
| D.7 X-RateLimit-Reset Unix timestamp | CLOSED | § 5.1, § 7.3 | Unix timestamp is explicitly required. |
| D.8 Rate-limit post-decision semantics | CLOSED | § 5.1, § 7.3 | Headers reflect post-decision state. |
| D.9 OAuth state entropy | CLOSED | § 5.8 | State uses at least 128 CSPRNG bits and browser-session binding. |
| D.10 Key rotation preserves history | CLOSED | § 6.6 | Regeneration preserves usage, quota, and feedback history. |
| D.11 Panic recovery middleware | CLOSED | § 5.2 | Panics become HTTP 500 OpenAI-shaped envelopes. |
| D.12 SSE framing explicit | CLOSED | § 5.4 | Streaming chunks are `data: {json}\n\n`, followed by `[DONE]`. |

## Scope discipline (Category E)

- E.1 New normative content beyond closed findings: PASS. v0.2 additions map to the fix prompt findings, D1-D3, or AC-26 through AC-37.
- E.2 Upstream spec mutation: PASS. SPEC-001 and SPEC-002 remain read-only references, and the `/poolz` note correctly says to file a SPEC-002 v1.1.4 follow-up if needed.
- E.3 § 2 locked decisions drift: PASS. § 2 gained only the required provenance/header note and cross-reference normalization.
- E.4 Premium positioning, Tier-3 deprecation, buyer personas: PASS. Premium positioning is forbidden in docs, Tier 3 explicitly has no deprecation/shutdown clause, and no buyer-persona expansion appears.
- E.5 Out-of-scope shrinkage: PASS. The list grew to include `Donations`; no shrinkage found in the audited delta surface.

## Critical findings

No CRITICAL findings.

## Major findings

**M1 - AC-26 through AC-37 do not consistently specify status codes and response body shapes.**

Severity: MAJOR

Location: § 18 AC-26 through AC-37

What is wrong: The audit prompt required every new AC to include precondition, action, expected outcome, and verification command, with the expected outcome carrying status code plus response body shape. The ACs have the four headings and deterministic `go test` command names, but most expected outcomes are prose-level assertions such as "proceeds", "rejected", "works", or "settles" without concrete HTTP statuses and JSON/OpenAI envelope fields. This leaves implementers free to pass the named unit test while leaving buyer-visible API semantics ambiguous.

Fix recommendation: For every AC-26 through AC-37, add explicit status codes and response body assertions. For errors, name the OpenAI envelope `type` and `code`; for success paths, name the minimum JSON fields or SSE frames that must be observed. Keep the existing `go test` command names.

**M2 - AC-26 tests the wrong callback method for the allowlist requirement.**

Severity: MAJOR

Location: § 5.8, § 18 AC-26

What is wrong: § 5.8 defines `GET /auth/github/callback`, but AC-26 says to "POST or simulate a GitHub OAuth callback". A literal implementation of the AC can fail with 405 Method Not Allowed before exercising redirect URI allowlist enforcement. That would not prove F-C2 is closed.

Fix recommendation: Rewrite AC-26 to use `GET /auth/github/callback?code=...&state=...&redirect_uri=...` or an internal callback handler simulation that bypasses HTTP method routing. Expected mismatch result should be a deterministic 400 or 403 with an OpenAI-shaped or documented OAuth error body and no account/key issuance.

**M3 - AC-27 does not deterministically prove the revocation latency bound.**

Severity: MAJOR

Location: § 6.6, § 18 AC-27

What is wrong: § 6.6 requires revocation to take effect within 60 seconds across gateway components. AC-27 says to retry "within 65 seconds", which can pass even when revocation is observed only after the required 60-second bound. The AC also names 403 but does not assert the error body shape.

Fix recommendation: Use a fake clock or cache TTL harness and assert that the old key returns 403 before or at the configured 60-second bound, preferably immediately for storage-backed validation and no later than 60 seconds for any cache. Add the expected error envelope, for example `type: "permission_error"` and a machine-readable revoked-key code.

## Minor findings

No MINOR findings.

## Verdict + rationale

READY WITH NARROW FIX. The v0.2 fix pass is substantively clean: the critical OAuth allowlist requirement is now in the spec, the quota and refund matrix matches D3, provider-pinning headers are stripped before auth, feedback XSS handling is explicit, and coordinator status redaction is grounded in the actual `/poolz` and routing-header behavior. D1 and D2 are also encoded with enough precision for Phase 5 implementation. The spec should not be reopened for architecture or upstream changes.

Do one narrow v0.3 text patch limited to AC quality: add status codes and response body shapes to AC-26 through AC-37, fix AC-26's callback method, and make AC-27 prove the 60-second revocation bound. After that patch, SPEC-006 should be ready to lock as v1.0 without another broad audit.

## Self-verification

- [x] Read v0.2 sections touched by the fix pass.
- [x] Walked each of 22 F-* closure checks.
- [x] Verified D1, D2, and D3 coherence across spec sections.
- [x] Verified all 12 new ACs for precondition, action, expected outcome, and verification command.
- [x] Verified all 9 MINOR fixes, including deduplicated encryption and tamper-evidence items.
- [x] Checked scope discipline: no premium positioning, Tier-3 deprecation, upstream spec edits, or d-inference source inspection.
- [x] Wrote verdict and rationale.

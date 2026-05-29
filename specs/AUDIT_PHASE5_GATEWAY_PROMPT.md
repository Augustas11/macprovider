# Audit prompt — phase5-gateway code-level pre-deployment audit

Operator-paste prompt for a code-level audit of the BUILD_PHASE5
gateway implementation at `phase5-gateway/` (commit 4955cce). The
implementation was Claude-built and includes an embedded audit-response
cycle (per Entry 25 commit message); this prompt asks for cross-model
independent verification BEFORE Pearl deployment.

**Cross-model pattern:** Run with **Codex CLI**. The gateway code was
produced by Claude; Codex is the alternate model that has consistently
caught what Claude missed across SPEC-001/002/003/006 audit history
(Entries 19 + 22 + Codex round 1 patterns). Single round chosen
because the embedded audit already absorbed the bigger findings — if
>5 MAJOR findings surface, follow with Claude round 2.

Expected duration: ~60-90 min for a thorough code-level audit.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing the BUILD_PHASE5 gateway implementation at
phase5-gateway/ (commit 4955cce) BEFORE Pearl deployment. The
implementation is 5,580 LoC of Go across 14 source files + 1,565
LoC of tests, with AC_STATUS.md reporting 24 of 37 ACs PASS via
automated tests.

This is a CODE audit, not a spec audit. The spec corpus is locked
(SPEC-001 v1.2.4 + SPEC-002 v1.1.5 + SPEC-003 v0.7 + SPEC-006 v0.6)
and audit-clean against the external security audit
(MACPROVIDER_HIGH_SEVERITY_RISK_AUDIT.md). Your job: verify the
code matches the locked spec + catches security/correctness issues
that automated tests + the embedded audit pass may have missed.

Output:
  /Users/augstar/macprovider-poc/specs/PHASE5_GATEWAY_AUDIT.md

Format: structured audit report. Findings grouped by category, each
tagged with severity (CRITICAL / MAJOR / MINOR / QUESTION) and
location (file:line). Match the rigor of prior audit reports
(specs/SPEC-006-audit.md, SPEC-CROSS-006-audit.md).

## Severity definitions

- **CRITICAL** — production incident class. Security hole (SQL
  injection, authentication bypass, secret leak), data corruption
  (append-only schema bypass, lost usage events), or violation of
  the locked architectural invariants (D1 single-instance, sub-ms
  auth check, append-only schema, no in-process rate-limit state).
- **MAJOR** — first-month-patch class. Undocumented edge case,
  missing error handling for a non-rare condition, spec compliance
  gap that buyers would hit. Hand-wavy assertions in tests claiming
  PASS without actually verifying. Goroutine or resource leaks.
- **MINOR** — quality cleanup. Naming inconsistencies, missing
  godoc on exported symbols, log verbosity, repeated code that
  should be extracted.
- **QUESTION** — genuinely unresolved code-level design choices
  that need operator input (rare; most decisions are spec-locked).

## Critical constraints

**1. Spec is locked.** Do NOT propose architectural changes. If
you find a place where the code DEVIATES from spec, that's a
finding (CRITICAL or MAJOR depending on impact). If you think the
spec itself is wrong, file as QUESTION; do NOT recommend spec
revision in this audit.

**2. SPEC-001 v1.2.4 + SPEC-002 v1.1.5 + SPEC-003 v0.7 + SPEC-006
v0.6 stay untouched.** Verify with `git diff specs/` after audit
— should be empty.

**3. The locked operator pre-commitments are read-only:** D1
(single-instance SQLite), D2 (demo token HMAC), D3 (refund matrix),
D-CROSS-1 (prefer-actuals with byte-estimation fallback), D-CROSS-2
(/v1/pool/check stays on coord), D-CROSS-3 (X-Request-ID UUID v4),
D-CROSS-4 (degraded definition in SPEC-002 § 7.5), D-CROSS-5
(SPEC-006 tier independence from SPEC-002 admission), D-CROSS-6
(logprobs unknown-field tolerance). Verify each is enforced in
code; do NOT recommend changes to the decisions themselves.

**4. d-inference clean-room.** Do not inspect d-inference source.

**5. No live testing.** Pearl deployment + live OAuth + live SDK
smoke are deferred to operator-side post-audit work. This audit is
STATIC code review only. The 7 PARTIAL ACs and 3 MANUAL pending
ACs in AC_STATUS.md MUST stay PARTIAL/MANUAL — your job is to
verify they're truly limited evidence, not hiding deeper code bugs.

**6. The embedded audit response is documented in commit 4955cce's
message.** Read that commit message carefully — it lists specific
findings the executing session absorbed before commit (scoped key
revocation, atomic rotation, secure cookies, nginx hardening,
systemd writable paths, etc.). Your job is to verify those fixes
landed CORRECTLY in code AND to find findings the embedded audit
missed.

## Required reading

In order:

1. `phase5-gateway/docs/AC_STATUS.md` — the implementation's honest
   self-assessment. Every PASS claim cites a specific test
   function; verify the test actually verifies the claim. Every
   PARTIAL/MANUAL pending entry describes its gap; verify the gap
   is honestly described.

2. `phase5-gateway/README.md` — local dev + deployment story.

3. `phase5-gateway/cmd/gateway/main.go` (entrypoint) +
   `phase5-gateway/internal/config/config.go` (config loading) —
   startup-time validation. Does the gateway fail fast on missing
   required fields (OAuth callback allowlist, demo signing
   secret, coordinator operator key)?

4. `phase5-gateway/internal/storage/interfaces.go` +
   `phase5-gateway/internal/storage/types.go` — the abstracted
   storage contract. Verify the interfaces are migration-ready
   (PostgreSQL/D1 swap should require no handler-code changes
   per D1).

5. `phase5-gateway/internal/storage/sqlite/migrate.go` +
   `phase5-gateway/internal/storage/sqlite/store.go` — the
   concrete SQLite implementation. Focus on:
   - Append-only schema enforcement (triggers? UPDATE bypass?)
   - BEGIN IMMEDIATE transaction usage for quota reservation
   - Index design for sub-ms p95 auth lookup
   - Hash storage for bearer tokens (no plaintext anywhere)

6. `phase5-gateway/internal/storage/sqlite/store_test.go` — verify
   each test function does what its name claims. Specifically:
   `TestKeyHashStorage`, `TestKeyRevocationLatency`,
   `TestKeyRotationPreservesHistory`, `TestQuotaSettlement504ZeroCompletion`.

7. `phase5-gateway/internal/auth/oauth.go` — GitHub OAuth flow.
   Focus on:
   - State parameter generation (>=128-bit CSPRNG, session-bound)
   - Callback URL allowlist strict match
   - Scope minimization (read:user + optional user:email; reject
     elevated scopes)
   - Account creation on first successful callback
   - CSRF defense against state forgery

8. `phase5-gateway/internal/auth/keys.go` — bearer token
   issuance/validation/revocation. Focus on:
   - >=256-bit CSPRNG entropy before base64url
   - SHA-256 hash storage (or HMAC-SHA-256 with secret)
   - Full key shown once at issuance, never re-displayable
   - Constant-time comparison on validation
   - Bounded revocation latency <60s
   - Key rotation preserves usage history

9. `phase5-gateway/internal/auth/demo.go` — HMAC demo tokens per
   D2. Focus on:
   - HMAC-SHA256 with operator secret from config
   - Payload includes client IP + issue timestamp + expiry (max 24h)
   - Constant-time HMAC verification
   - Static shared secrets forbidden (startup validation)
   - Rate-limited issuance endpoint (10/IP/hour default)

10. `phase5-gateway/internal/router/server.go` — the HTTP handlers.
    Focus on:
    - Inbound header strip (X-MacProvider-Provider/Route/* per
      F-M21) BEFORE authentication
    - Outbound header strip (per F-606-1)
    - X-Request-ID generation per D-CROSS-3
    - OpenAI envelope on all error responses
    - Streaming SSE pass-through `data: {json}\n\n` framing
    - Refund matrix (200/503/502/504/disconnect) per D3
    - Prefer-actuals fallback to byte-estimation per D-CROSS-1
    - Concurrent request quota arithmetic (no overshoot beyond
      max_tokens_per_request)
    - Coordinator timeout + client reuse
    - Coordinator backend selection (configurable list per
      D-CROSS architecture)

11. `phase5-gateway/internal/router/server_test.go` +
    `phase5-gateway/internal/router/integration_test.go` — verify
    each PASS test name actually verifies its claim. Spot-check:
    `TestStreamingQuotaReservationAndSettlement`,
    `TestQuotaExhaustionReturns429`,
    `TestKillSwitchPersistsAcrossRestart`,
    `TestCapacityTierDeescalation`,
    `TestProviderPinningHeadersStripped`,
    `TestDemoTokenValidation`,
    `TestOAuthCallbackAllowlist`,
    `TestOAuthStateCSRF`.

12. `phase5-gateway/dist/nginx-api.streamvc.live.conf` — the nginx
    config. Verify:
    - /admin/ and /v1/pool/check return 404 from public surface
    - XFF spoofing blocked by overwriting X-Forwarded-For
    - HSTS set
    - limit_req_zone + limit_conn_zone declared and applied to
      /ws/provider per SPEC-002 v1.1.5 PG-2
    - Path routing matches SPEC-002 v1.1.4 § 7

13. `phase5-gateway/dist/macprovider-gateway.service` — systemd
    unit. Verify writable paths are correct + minimal privilege.

14. Locked specs (skim, not deep-read):
    - `specs/SPEC-001-phase3-binary.md` v1.2.4 — § 6.6 cancel-usage
      normative (gateway must consume this when present)
    - `specs/SPEC-002-coordinator.md` v1.1.5 — § 7.5 /poolz shape +
      degraded definition + § 7.X PG-1..PG-5 invariants
    - `specs/SPEC-006-buyer-api.md` v0.6 — full document focusing
      on §§ 1.6, 2 (locked decisions), 5, 7, 8, 9, 10, 17, 18, 22
    - `specs/SPEC-006-audit.md` + `specs/SPEC-CROSS-006-audit.md`
      — prior audit findings already absorbed; sanity-check none
      re-emerged

15. `beta/DECISION_CRITERIA.md` Entries 22, 23, 24, 25 — the
    spec-design + implementation arc context.

## Audit categories — work through each

### Category A: Security pitfalls

A.1 **SQL injection.** Every SQL query in `internal/storage/sqlite/`
    MUST use parameterized statements (`?` placeholders or named
    params). Any string-concatenated SQL = CRITICAL.

A.2 **TOCTOU on quota reservation.** Walk
    `internal/storage/sqlite/store.go` quota functions: read +
    decide + write must be inside a single transaction. Any
    read-then-decide-then-write sequence outside BEGIN IMMEDIATE
    = CRITICAL.

A.3 **OAuth flow edges.** Verify:
    - State parameter validated AND consumed (one-time use)
    - Callback URL exact match (no prefix/suffix vulnerabilities)
    - GitHub access token NEVER stored or logged
    - Authorization code exchanged server-side only
    - Account creation idempotent on retry
    Any deviation = CRITICAL or MAJOR depending on impact.

A.4 **HMAC verification.** Demo token validation MUST use
    constant-time HMAC comparison (e.g., `hmac.Equal` or
    `subtle.ConstantTimeCompare`). Plain byte-equality = CRITICAL
    (timing attack).

A.5 **Bearer token comparison.** Same: validation must use
    constant-time comparison against the hashed token. Plain
    byte-equality = CRITICAL.

A.6 **Secret handling.** Operator key, OAuth client secret, HMAC
    signing secret, GitHub access token MUST NOT appear in:
    - Error responses (look for `err.Error()` or `%v` formatting
      that includes the secret)
    - Log lines at any level
    - Debug output
    - Database except as hash (for keys)
    Any secret leak = CRITICAL.

A.7 **Append-only schema integrity.** Verify SQLite triggers or
    schema constraints prevent UPDATE/DELETE on usage_events,
    feedback_events, audit_events. A schema that allows UPDATE
    via SQL = CRITICAL (the entire append-only discipline can
    be bypassed by a future maintainer).

A.8 **XFF spoofing prevention.** nginx config MUST overwrite
    X-Forwarded-For (not append). Gateway code reading client IP
    MUST use the nginx-set value (not trust upstream). Any code
    path trusting buyer-controlled X-Forwarded-For = MAJOR.

A.9 **Demo token replay.** Demo token MUST be bound to client IP
    (or /64 prefix for IPv6) AND have expiry MAX 24h. Verify
    rejection of tokens with mismatched IP, expired tokens, and
    forged signatures. Replay window > 24h or no IP binding =
    MAJOR.

A.10 **Rate-limit bypass.** Per-IP rate limits on /auth/demo-session
     MUST be enforced at the gateway level (in addition to nginx).
     If only nginx enforces, a misconfigured nginx leaves the
     endpoint open = MAJOR.

A.11 **Panic recovery.** Per spec, gateway MUST install panic
     recovery middleware returning HTTP 500 in OpenAI error
     envelope. Verify any panic in handlers is caught + logged +
     envelope returned. Missing or partial = MAJOR.

### Category B: Spec compliance — operator pre-commitments

B.1 **D1 single-instance.** Verify code declares (or comments)
    "v1 is single-instance SQLite" and contains no in-process
    rate-limit counters, in-process quota state, or in-process
    session caches. Any in-process state for hot-path = CRITICAL.

B.2 **D2 demo token HMAC.** Verify the demo path matches D2 exactly:
    - HMAC-SHA256
    - Payload: {v: 1, ip: "x.x.x.x", iat: unix_ts, exp: unix_ts}
    - Signing secret from gateway.yaml (NOT a constant)
    - Max 24h TTL
    - Issuance endpoint: POST /auth/demo-session
    - Rate-limit: 10/IP/hour default
    Any deviation = MAJOR.

B.3 **D3 refund matrix.** Verify code's terminal accounting logic
    matches the matrix from SPEC-006 v0.5 § 17.5:
    | Status | Completion | Quota debited |
    | 200 | as reported | prompt + completion |
    | 503 | 0 | none (no provider reached) |
    | 502 zero completion | 0 | prompt only |
    | 502 partial | >0 | prompt + actual |
    | 504 zero | 0 | prompt only |
    | 504 partial | >0 | prompt + actual |
    | Client disconnect | actual or estimated | prompt + completion |
    Each row's logic MUST be testable. Mismatch = MAJOR.

B.4 **D-CROSS-1 prefer-actuals + fallback.** Verify code logic:
    - Reads `usage` field from coord response on cancel
    - If present, settles to exact prompt + completion
    - If absent (pre-v1.2.4 provider), falls back to
      `ceil(bytes_emitted_so_far / 4)` for completion estimate
    Either path missing or incorrect = MAJOR.

B.5 **D-CROSS-2 endpoint ownership.** Verify the gateway's
    forwarded path list excludes /v1/pool/check (coord-owned).
    If gateway forwards /v1/pool/check to itself = MAJOR.

B.6 **D-CROSS-3 X-Request-ID propagation.** Verify:
    - Gateway generates UUID v4 per buyer request
    - Includes in usage_events row (as request_id column)
    - Includes in audit_events row
    - Forwards as `X-Request-ID` header to coordinator
    Any missing step = MAJOR.

B.7 **D-CROSS-4 degraded definition.** Verify gateway's degraded
    calculation matches SPEC-002 v1.1.4 § 7.5 normative: ANY of
    (all providers unavailable/draining, <50% ready, all
    slots_free=0). Any divergence = MAJOR.

B.8 **D-CROSS-5 tier independence.** Verify SPEC-006 capacity
    tiers (Tier 1/2/3) do NOT cascade to SPEC-002 admission tiers.
    Specifically: SPEC-006 Tier 3 hard-pause does NOT modify
    coord's auth.require_provider_tokens or pinned_only. Any
    cross-cascade = CRITICAL (violates the explicit independence
    lock from cross-spec audit).

B.9 **D-CROSS-6 logprobs.** Verify gateway forwards `logprobs`
    field syntactically to coord (unknown-field tolerance per
    SPEC-001 v1.2.x). Any rejection or transformation = MAJOR.

### Category C: AC honesty

C.1 For each of the 24 PASS ACs in AC_STATUS.md, verify the
    cited test function actually verifies the AC's claim. If a
    test name claims to verify X but only verifies "X doesn't
    panic," that's a hand-wavy PASS = MAJOR.

C.2 For each of the 7 PARTIAL ACs, verify the gap is honestly
    described. If a PARTIAL is actually MISSING (no code path
    at all), that's MAJOR.

C.3 For each of the 3 MANUAL pending ACs, verify they truly need
    infrastructure (Pearl, GitHub, SDK, front-door) and not just
    "we didn't write the test yet."

### Category D: H-002 production invariants (PG-1..PG-5)

D.1 **PG-1 token validation.** Verify gateway code path with
    `auth.require_provider_tokens=true` actually rejects
    unauthenticated buyer requests cleanly with appropriate error.
    If the code only handles `=false` cleanly = MAJOR.

D.2 **PG-2 nginx rate limits.** Verify nginx config has
    `limit_req_zone` and `limit_conn_zone` declared AND applied
    to `/ws/provider`. Missing either = MAJOR.

D.3 **PG-3 provisional admission rate.** Spec-level; coordinator
    side. Gateway-side: verify gateway doesn't bypass this
    (e.g., by injecting provisional-skipping fields into hello).
    Bypass = MAJOR.

D.4 **PG-4 unknown-provider-id rejection.** Coordinator side. Verify
    gateway's coordinator-error handling produces the right buyer
    response when coord returns 4xx for an unknown provider.

D.5 **PG-5 provisional-spike alerting.** Where is the alert hook?
    If absent or only a TODO = MAJOR.

### Category E: Tier 1 disclosure surface (SPEC-006 v0.6 § 1.6 + § 5)

E.1 Does `/v1/models` response include `tier1_disclosure` top-
    level field with the 4 properties (version, plaintext_to_provider,
    model_identity, hardware_attestation, tier2_milestone)?
    Missing or partial = CRITICAL (the disclosure surface is
    normatively required for public launch).

E.2 Is the block non-overridable by operator? Verify NO config
    flag or env var can suppress it. Override mechanism = MAJOR.

E.3 Are the 4 property values hardcoded to match the spec? Any
    value drift (e.g., `model_identity: "verified"` instead of
    `"provider_reported"`) = CRITICAL (false claim to buyers).

### Category F: Operational concerns

F.1 **Startup validation.** Gateway MUST fail-fast on missing
    required config: OAuth callback allowlist (empty = startup
    failure per F-C2), demo signing secret (missing = startup
    failure per D2), coordinator operator key (missing = startup
    failure per F-M19). Each = MAJOR if absent.

F.2 **Graceful shutdown.** On SIGTERM, gateway MUST drain in-flight
    requests, close DB cleanly, log shutdown. Abrupt termination
    or DB corruption risk = MAJOR.

F.3 **Health check.** /healthz or equivalent for systemd/load-
    balancer probes. Missing = MINOR.

F.4 **Logging.** No secrets, structured (JSON) format preferred,
    log levels appropriate. Verbose logging that includes prompts
    or completions = MAJOR (privacy/data-handling).

F.5 **Database migrations.** Idempotent (running twice doesn't
    break)? Versioned? Reversible (for safety)? Schema changes
    that aren't versioned = MAJOR.

### Category G: Code quality

G.1 **Error handling.** Are errors propagated correctly? Are
    %w wrapping conventions consistent? Lost errors = MAJOR.

G.2 **Goroutine leaks.** Spawning goroutines without context-based
    cancellation = MAJOR.

G.3 **Resource leaks.** File handles, DB connections, HTTP
    clients — verify proper cleanup with defer or RAII pattern.

G.4 **Code organization.** Per-package boundaries respected? Any
    circular imports? Naming inconsistencies = MINOR.

G.5 **Test quality.** Tests must actually assert the claim
    (not just exercise the code path). Hand-wavy tests = MAJOR.

## Output format

Produce `specs/PHASE5_GATEWAY_AUDIT.md` with this structure:

```
# Phase 5 Gateway code audit (Codex, 2026-MM-DDTHH:MM:SSZ)

## Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- L QUESTIONS

## CRITICAL findings
F-C1. [Title]
    Location: phase5-gateway/path/to/file.go:LINE
    Finding: [description]
    Why it matters: [impact]
    Recommended fix: [specific code change OR "operator decision required"]

(repeat for each critical finding)

## MAJOR findings
F-M1. ...

## MINOR findings
F-m1. ...

## Operator questions surfaced
q1. ...

## Category coverage notes
- A through G: one-line note per category ("no findings", or "see Fx, Fy")

## Verdict
- READY TO DEPLOY (zero CRITICAL, zero blocking MAJOR)
- READY WITH NARROW FIX PASS (all findings closable in one FIX cycle)
- DESIGN ROUND NEEDED (architectural CRITICALs requiring spec revisit)
```

## Self-verification before declaring complete

- [ ] Walked every audit category (A through G).
- [ ] For each finding, location is file:line specific.
- [ ] For each CRITICAL/MAJOR, recommended fix is concrete (not
      hand-wavy).
- [ ] AC_STATUS.md PASS claims spot-checked against actual test
      function bodies for at least 5 random ACs.
- [ ] Locked operator pre-commitments (D1, D2, D3, D-CROSS-1..6)
      each have a code-level enforcement check (Category B).
- [ ] Tier 1 disclosure surface (SPEC-006 v0.6 § 5) verified in
      /v1/models handler code.
- [ ] No SPEC-001/002/003/006 edits proposed (Category constraint
      respected).
- [ ] Verdict is honest based on findings count and severity.

When done, print a 200-word handback summary:
- Findings count by severity
- Top 3 most impactful findings
- Verdict + one-sentence rationale
- Whether Pearl deployment dry-run can proceed (zero CRITICAL =
  yes), needs narrow FIX first, or needs design round

Then stop. Do NOT draft a FIX prompt; operator decides next move.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~30 min):

1. Read `specs/PHASE5_GATEWAY_AUDIT.md` start to finish.
2. For each CRITICAL: confirm whether it's a real bug or Codex
   misread the code. Cite line numbers.
3. For each MAJOR: same triage.
4. If verdict is **READY TO DEPLOY** (zero CRITICAL): proceed to
   Pearl deployment dry-run.
5. If verdict is **READY WITH NARROW FIX PASS**: draft
   `FIX_PHASE5_GATEWAY_PROMPT.md` covering only the CRITICAL +
   high-impact MAJOR findings. Run, then proceed to Pearl.
6. If verdict is **DESIGN ROUND NEEDED**: unlikely but possible if
   embedded audit missed something architectural; would require
   revisiting spec or implementation approach.

## Why single Codex round (not Claude round 2)

The embedded audit response in commit 4955cce was a Claude pass
(implementation session). Codex round 1 provides cross-model
independence. Historical pattern from SPEC-001/002/003/006:
- If round 1 surfaces <5 MAJORs and 0 CRITICALs: single round
  suffices, proceed to deployment.
- If round 1 surfaces >5 MAJORs OR any CRITICALs: run Claude
  round 2 for confirmation + additional findings.

Single round chosen as the default because the implementation
already absorbed a previous audit pass; double rounds would
mostly find narrow MINOR cleanups at this stage.

## What this audit does NOT cover

- Live infrastructure: nginx -t against installed nginx,
  systemd-analyze verify against installed systemd. These are
  deferred to Pearl deployment dry-run.
- Live OAuth: deferred to GitHub OAuth app registration +
  integration test.
- Live SDK: deferred to OpenAI Python + JS SDK smoke against
  deployed gateway.
- Front-door: deferred to Vercel demo migration work.

The PARTIAL + MANUAL pending ACs in AC_STATUS.md remain limited-
evidence even after this audit; the audit verifies their
limitations are honest, not that they're production-verified.

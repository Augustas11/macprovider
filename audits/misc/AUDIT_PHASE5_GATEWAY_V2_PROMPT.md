# Regression audit prompt — phase5-gateway FIX cycle verification

Operator-paste prompt for a NARROW regression audit on the 11 patches
landed in commit 7783256 (the FIX cycle that closed Codex round 1
findings from `specs/PHASE5_GATEWAY_AUDIT.md`). This is NOT a full
re-audit. It targets only the FIX delta and verifies:

1. Each F-* finding's claimed fix actually landed in code (not "claimed
   but not landed" — the failure mode that bit F-C1 originally).
2. AC_STATUS.md updates are honest (no hand-wavy PASS retention).
3. No regressions introduced by the 11 patches (new bugs, broken
   tests, dependency drift).

**Cross-model pattern:** Run with **Claude Code**. Codex did round 1
(the audit that surfaced the 11 findings); Claude does round 2 of the
regression check (independent verification that the FIX session
honestly closed what it claimed).

A single round is sufficient for a regression check on a narrow patch.
The full code audit of the gateway is the round 1 file
(`PHASE5_GATEWAY_AUDIT.md`); this audit only verifies the delta.

Expected duration: ~30-45 min.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are running a narrow regression audit on the gateway FIX cycle
that closed 11 findings from the Codex code audit. The FIX commit is
7783256 (572 insertions, 129 deletions across 11 files). The Codex
audit report is at `specs/PHASE5_GATEWAY_AUDIT.md`. The FIX prompt
is at `specs/FIX_PHASE5_GATEWAY_PROMPT.md`.

Your job: verify the 11 patches honestly close their findings + the
AC_STATUS updates are honest + no regressions were introduced. You
are NOT here to re-audit the full gateway code, propose architectural
changes, or relitigate locked decisions.

Output:
  /Users/augstar/macprovider-poc/specs/PHASE5_GATEWAY_AUDIT_V2.md

Format: structured regression report. Findings tagged with severity
(CRITICAL / MAJOR / MINOR) and location (file:line). Match the rigor
of prior regression audits (e.g., `specs/SPEC-CROSS-006-v2-audit.md`).

## Scope discipline (HARD CONSTRAINTS)

**1. Regression scope only.** Verify only the FIX delta. Do NOT
re-audit sections unchanged from commit 4955cce. They were already
audited in Codex round 1 (commit 20f0880).

**2. The 11 findings to verify closure:**
- F-C1 (CRITICAL): Tier 1 disclosure block on /v1/models
- F-M1: OAuth callback redirect_uri requirement removed
- F-M2: Streaming cancel-usage real flow (not synthetic header)
- F-M3: degraded calculation matches SPEC-002 FR-B1
- F-M4: Quota reservation reaper
- F-M5: XFF trust prevention
- F-M6: nginx PG-2 rate-limit + connection-cap on /ws/provider
- F-M7: OpenAI envelope on 404 routes (gateway + nginx)
- F-M8: X-Request-ID UUID v4 validation
- F-m1: Panic recovery logs the panic
- F-m2: /healthz endpoint

**3. AC_STATUS.md updates to verify (no downgrades happened per
operator's commit message):**
AC-3, AC-4, AC-7, AC-11, AC-12, AC-13, AC-21, AC-22, AC-26, AC-37.
For each: does the evidence cited actually verify the AC's claim?
If a PASS retention relies on a test that doesn't honestly verify
the claim, flag as MAJOR.

**4. Locked specs MUST stay untouched.** SPEC-001 v1.2.4 + SPEC-002
v1.1.5 + SPEC-003 v0.7 + SPEC-006 v0.6 verified empty diff. If
your audit reveals any change to these specs, that is a CRITICAL
("FIX session violated the spec-untouched constraint").

**5. Locked operator pre-commitments stay off-limits.** D1, D2,
D3, D-CROSS-1 through D-CROSS-6 cannot be modified by the FIX.
Verify each is preserved.

**6. Three classes of regression to specifically watch for:**
- **Closure regression:** a finding labeled "closed" but the
  patch doesn't actually address the spec requirement (the F-C1
  pattern — claim landed but code path doesn't emit).
- **AC honesty regression:** an AC_STATUS PASS that relies on a
  test name not actually verifying the AC's claim. The F-M2
  pattern (AC-37 PASS via synthetic header) cannot recur.
- **New regression:** the FIX introduces a new bug (broken test,
  new goroutine leak, new error path that drops the OpenAI
  envelope, schema migration breakage, etc.).

**7. No live testing.** Static code review only. Do not run
`go test`, `nginx -t`, etc. The FIX session already ran them
locally with green results; you verify the static code matches
the claims.

**8. d-inference clean-room.** Do not inspect d-inference source.

## Required reading

1. `specs/PHASE5_GATEWAY_AUDIT.md` — the Codex round 1 audit. Each
   F-* finding's location + description + recommended fix.

2. `specs/FIX_PHASE5_GATEWAY_PROMPT.md` — the operator's
   instructions to the FIX session. Each finding's expected fix +
   AC_STATUS update guidance.

3. `phase5-gateway/docs/AC_STATUS.md` — the post-FIX AC table.
   Read the updated entries for AC-3, AC-4, AC-7, AC-11, AC-12,
   AC-13, AC-21, AC-22, AC-26, AC-37. For each PASS: verify the
   cited test name. Spot-check the test function body.

4. Code surfaces (read in order, focused):
   - `phase5-gateway/internal/router/server.go` — focus on:
     - /v1/models handler (F-C1, must emit tier1_disclosure)
     - OAuth callback handler (F-M1)
     - Streaming cancel path (F-M2)
     - Status/degraded computation (F-M3)
     - IP detection middleware (F-M5)
     - 404 handler (F-M7)
     - X-Request-ID middleware (F-M8)
     - Panic recovery (F-m1)
     - /healthz endpoint (F-m2)
   - `phase5-gateway/internal/router/server_test.go` +
     `integration_test.go` — verify each new/updated test
     function actually asserts the AC's claim (NOT just
     "no panic" or shallow shape check)
   - `phase5-gateway/internal/storage/sqlite/store.go` +
     `store_test.go` — reaper logic (F-M4) + storage tests
   - `phase5-gateway/cmd/gateway/main.go` — reaper goroutine
     startup + panic recovery setup
   - `phase5-gateway/dist/nginx-api.malibu.tech.conf` — F-M6
     limit_req_zone + limit_conn_zone + F-M7 envelope on
     denied routes
   - `phase5-gateway/dist/deploy-pearl-vps.md` — F-M6 documented
     correctly
   - `phase5-gateway/README.md` — F-m2 health endpoint + F-M5
     deployment documentation

5. `git log --oneline -3` + `git show 7783256 --stat` — verify
   the FIX commit's file list matches what the prompt requested.

## Audit categories — narrow regression checks

### Category A: Closure verification (HIGHEST PRIORITY)

For each of the 11 findings, verify the code change actually closes
it. Spot-check by reading the cited file:line range.

A.1 **F-C1 (CRITICAL).** Verify `/v1/models` handler emits
    `tier1_disclosure` at top level of response body. The struct
    MUST have hardcoded constants for the 4 properties (version,
    plaintext_to_provider=true, model_identity=
    "provider_reported", hardware_attestation="none",
    tier2_milestone="future"). Non-overridable: verify no config,
    env, or runtime mechanism can suppress or change these values.

    Verdict: CLOSED / PARTIAL / CONTRADICTORY / MISSING.

    If MISSING (the F-C1 failure mode that triggered this audit
    in the first place), that's CRITICAL.

A.2 **F-M1.** OAuth callback handler. Verify the `redirect_uri`
    query param requirement is REMOVED. Verify the state CSRF
    defense is preserved. Verify the gateway-side callback
    allowlist (per F-C2 from v0.2) is still enforced at startup.

A.3 **F-M2.** Streaming cancel path. Verify the real cancel
    request flow exists: gateway sends cancel_request to coord;
    waits bounded time for inference_response_end carrying usage;
    settles to actuals or falls back to byte-estimation per
    D-CROSS-1. The test exercising this MUST use a mock
    coordinator that sends real inference_response_end (NOT a
    synthetic pre-stream header).

    AC-37 evidence MUST cite the real-flow test name. If AC-37
    still cites a synthetic-header test, that's MAJOR (AC honesty
    regression).

A.4 **F-M3.** degraded calculation. Verify it matches FR-B1
    exactly: TRUE if ANY of:
    - All providers unavailable OR draining
    - Less than 50% ready (2 * ready < total)
    - All slots_free = 0
    Test MUST cover all 4 cases + the negative case.

A.5 **F-M4.** Reaper. Verify:
    - Background goroutine in main.go starts the reaper
    - Reaper runs at configurable interval (1h default per spec)
    - Reaper reclaims reservations older than 24h that haven't
      settled
    - Test verifies the 24h boundary

A.6 **F-M5.** IP detection. Verify:
    - X-Real-IP (when set by nginx) is trusted
    - When X-Real-IP absent, falls back to RemoteAddr
    - Raw X-Forwarded-For from buyer is NEVER trusted
    - Test exercises all 3 cases including a forged-XFF scenario

A.7 **F-M6.** nginx config. Verify the new directives:
    - `limit_req_zone $binary_remote_addr zone=ws_provider_rate:10m
      rate=10r/m;`
    - `limit_conn_zone $binary_remote_addr zone=ws_provider_conn:10m;`
    - Both applied to `/ws/provider` location block
    Plus `dist/deploy-pearl-vps.md` documents PG-2.

A.8 **F-M7.** 404 envelope. Verify:
    - Gateway-side NotFound handler returns OpenAI envelope
    - nginx config returns OpenAI envelope JSON (not nginx HTML)
      for /admin/ and /v1/pool/check denied routes
    - Test exercises both surfaces

A.9 **F-M8.** UUID v4. Verify:
    - X-Request-ID validation enforces v4 specifically
    - Malformed/non-v4 IDs replaced with fresh server-generated v4
    - Test covers v1/v3/v5 inputs being normalized to v4

A.10 **F-m1.** Panic recovery. Verify the log line includes both
     the panic value AND a stack trace at ERROR level. Test
     verifies log output.

A.11 **F-m2.** /healthz endpoint. Verify:
     - Returns 200 + `{"status":"ok"}` on normal path
     - Returns 503 when DB SELECT 1 fails
     - Not subject to rate-limit middleware
     - Tests cover both cases

### Category B: AC_STATUS.md honesty

For each updated AC entry (AC-3, AC-4, AC-7, AC-11, AC-12, AC-13,
AC-21, AC-22, AC-26, AC-37):

B.1 The cited test name exists in the codebase (grep
    `git ls-files phase5-gateway | xargs grep -l "TestXyz"`).

B.2 The cited test function body actually asserts the AC's
    claim — not just "no panic" or "field present" without
    verifying value semantics.

B.3 If a PASS retention relies on a test that's shallow, this is
    MAJOR (AC honesty regression). The F-M2 case (synthetic-
    header AC-37 PASS) MUST NOT recur.

B.4 If a new AC entry was added (for new test functions like
    `TestModelsResponseIncludesTier1Disclosure`,
    `TestClientIPDetectionRejectsForgedXFF`,
    `TestNotFoundReturnsOpenAIEnvelope`,
    `TestExpiredReservationsReclaimedAfter24h`,
    `TestXRequestIDValidationRejectsNonV4`,
    `TestPanicRecoveryLogsPanicAndReturnsEnvelope`,
    `TestHealthzReturnsOK`), verify the entry exists with the
    right test name + claim.

### Category C: Regression risk (new bugs introduced by FIX)

C.1 Look at each patched file's git diff (read with `git show
    7783256 -- <file>`). For each new/modified function, check
    for:
    - Goroutine leaks (new goroutines without context-based
      cancellation)
    - Resource leaks (new HTTP clients, DB connections, file
      handles without cleanup)
    - Lost errors (`_` ignored when an error should be checked)
    - Error envelope drops (any new error path returning plain
      text or default 500)
    - Schema migration breakage (new SQL that breaks idempotency
      or reversibility)
    Any new issue = MAJOR.

C.2 Specifically for the reaper (F-M4): verify the goroutine
    has graceful shutdown (context cancellation on SIGTERM) and
    bounded backoff on DB errors. A reaper that crashes the
    gateway on DB errors is MAJOR.

C.3 Specifically for the OAuth callback fix (F-M1): verify the
    removal of redirect_uri doesn't accidentally weaken any
    CSRF or callback URL enforcement.

C.4 Specifically for the streaming cancel path (F-M2): verify
    the bounded wait for inference_response_end doesn't leak
    goroutines on coord timeout.

### Category D: Locked-spec untouched verification

D.1 `git diff specs/SPEC-001-phase3-binary.md` MUST be empty.
D.2 `git diff specs/SPEC-002-coordinator.md` MUST be empty.
D.3 `git diff specs/SPEC-003-open-onboarding.md` MUST be empty.
D.4 `git diff specs/SPEC-006-buyer-api.md` MUST be empty.

If any diff exists, that's CRITICAL (FIX violated spec-locked
constraint).

### Category E: Operator pre-commitment preservation

E.1 D1 (single-instance SQLite, no in-process state): verify the
    reaper goroutine is process-local (acceptable; it's I/O against
    the storage layer, not in-process rate-limit state). Verify
    no other new in-process state was added.

E.2 D2 (demo HMAC): unchanged. Verify the demo path code is
    untouched (or if touched, still matches D2).

E.3 D3 + D-CROSS-1 (refund matrix + prefer-actuals fallback):
    verify F-M2 fix preserves the matrix. Each terminal outcome
    still maps to the right quota debit.

E.4 D-CROSS-2 (/v1/pool/check ownership): unchanged.

E.5 D-CROSS-3 (X-Request-ID UUID v4): F-M8 fix MUST tighten
    validation, not weaken it.

E.6 D-CROSS-4 (degraded definition): F-M3 fix MUST match FR-B1
    exactly.

E.7 D-CROSS-5 (tier independence): unchanged.

E.8 D-CROSS-6 (logprobs tolerance): unchanged.

## Output format

Produce `specs/PHASE5_GATEWAY_AUDIT_V2.md` with this structure:

```
# Phase 5 Gateway FIX regression audit (Claude, 2026-MM-DDTHH:MM:SSZ)

## Summary
- N CRITICAL findings
- M MAJOR findings
- K MINOR findings
- Overall verdict: READY FOR PEARL DEPLOYMENT / NARROW FIX NEEDED / DESIGN ROUND NEEDED

## Closure verification (Category A, 11 items)
For each F-* finding: CLOSED / PARTIAL / CONTRADICTORY / MISSING + evidence reference.

## AC_STATUS.md honesty (Category B)
For each of the 10 updated ACs + 7 potentially new AC entries: verified evidence + notes.

## Regression risk (Category C)
- Any new bugs introduced
- Reaper safety
- OAuth callback security
- Streaming cancel goroutine cleanup

## Locked-spec untouched (Category D)
- SPEC-001/002/003/006 diff status

## Operator pre-commitment preservation (Category E)
- D1 through D-CROSS-6 per item

## CRITICAL findings (if any)
[full description per finding]

## MAJOR findings (if any)
[same]

## MINOR findings (if any)
[same]

## Verdict + rationale
[150 words, with explicit recommendation]
```

## Self-verification before declaring complete

- [ ] Read commit 7783256's diff for all 11 patched files.
- [ ] Spot-checked each of the 11 F-* findings' code change.
- [ ] Verified each of the 10 updated AC_STATUS entries cites a
      test name that exists and verifies the AC claim.
- [ ] Verified locked specs (SPEC-001/002/003/006) diff is empty.
- [ ] Verified operator pre-commitments (D1, D2, D3, D-CROSS-1..6)
      preserved.
- [ ] No live tests run.
- [ ] No suggestion to modify locked specs.
- [ ] Verdict reflects findings count and severity honestly.

When done, print a 200-word handback summary:
- Findings count by severity
- Top 3 most impactful findings (if any)
- Verdict (READY FOR PEARL DEPLOYMENT / NARROW FIX NEEDED /
  DESIGN ROUND NEEDED)
- One-sentence rationale

Then stop. Do NOT draft a fix prompt; operator decides next move.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~15 min):

1. Read `specs/PHASE5_GATEWAY_AUDIT_V2.md` start to finish.
2. For each CRITICAL: confirm whether it's real (the F-C1 pattern
   repeated, code missing despite claim) or a false flag.
3. If verdict is **READY FOR PEARL DEPLOYMENT**: proceed to
   deployment dry-run.
4. If verdict is **NARROW FIX NEEDED**: draft a tight
   `FIX_PHASE5_GATEWAY_V2_PROMPT.md` covering only the regression
   findings, run, then deploy.
5. If verdict is **DESIGN ROUND NEEDED** (unlikely): something
   architectural slipped through; revisit FIX strategy.

## Why this regression check matters

The F-C1 pattern (claimed-but-not-landed) is the failure mode this
audit specifically guards against. The original audit-response
commit message claimed the Tier 1 disclosure block landed; Codex
round 1 verified it had not. The FIX commit (7783256) now claims
the same disclosure block landed alongside 10 other fixes; this
regression audit verifies the new claims are honest.

Historical pattern: small FIX cycles (5 findings) typically have
zero regression findings. Larger FIX cycles (11+ findings, 572 LoC
added) typically surface 1-3 narrow MINORs. The diminishing
returns curve is favorable for ~30-45 min insurance.

## Why Claude (not Codex round 2)

Codex did round 1 of the gateway audit. The FIX session may have
been either model. Claude provides cross-model coverage as the
alternate model. Same pattern as Entry 22's cross-spec audit
(Codex round 1 + Claude round 2) applied here at the implementation
layer.

If this audit produces architectural CRITICALs (unlikely), they'd
indicate the FIX strategy itself was wrong — same signal threshold
as prior regression cycles.

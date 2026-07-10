# AUDIT PR400 CODE R2 PROMPT — Malibu OAuth return_to handoff

Round 2 of the code lane. Round 1 findings are in
`specs/PR400_HANDOFF_r1_code_audit.md`. The following fixes have been
applied on branch `feat/malibu-oauth-handoff`; verify they close the
findings and did not introduce regressions.

Scope stays as in round 1: correctness, control-flow, signature
consistency, test adequacy. Read `specs/AUDIT_PR400_HANDOFF_CODE_PROMPT.md`
for the full checklist and diff surface.

## Fixes applied since round 1

### r1 CODE M1 — `return_to` allowlist overmatch
Fixed in `phase5-gateway/internal/router/oauth.go`. `returnToAllowed`
now:
- Requires exact path equality when the allowlist path does NOT end
  in `/`.
- Treats trailing-`/` allowlist paths as explicit directory prefixes.
- Rejects any target path containing `.` or `..` segments (literal or
  URL-encoded via `%2E`), by way of a new `hasDotSegment` helper.

Confirm:
- Exact allowlist entry `/console/auth/callback.html` accepts target
  `/console/auth/callback.html`.
- Same allowlist entry REJECTS `/console/auth/callback.htmlx`,
  `/console/auth/callback.html/extra`, and
  `/console/auth/callback.html/../admin`.
- Path `/` and empty path still accept any target path on the host.

### r1 CODE M2 — Missing regression coverage
Added:
- `TestOAuthStateReturnToRoundTrip` in
  `phase5-gateway/internal/storage/sqlite/store_test.go`.
- `TestOAuthHandoffStoreConsumeReplay` in same file.
- `TestOAuthHandoffExpiredReturnsNotFound` in same file.
- `TestPruneExpiredOAuthHandoffs` in same file.
- `TestReturnToAllowedRejectsPrefixAndTraversal` in
  `phase5-gateway/internal/router/oauth_handoff_test.go` (new file).
- `TestOAuthHandoffFlowRoundTrip` in same new file — start → callback
  → exchange → replay.
- `TestHandoffExchangeErrorSurface` in same new file — 405, empty
  body, unknown token.
- `TestReturnToConfigRequiresMatchingCORSOrigin` in same new file
  (this one is for the architect-lane config cross-check but also
  serves as router-config regression).

Confirm the new tests actually assert what they claim; flag any test
that passes trivially (e.g. asserting an empty struct's zero value).

## Cross-cutting changes to also re-check

- `handleGitHubCallback` now sets the `mp_new_api_key` cookie for
  every `fullKey != ""` case (not only the legacy `/account` path).
  See the fallback-cookie comment above the `SetCookie` call. Confirm:
  - The cookie is set BEFORE the returnTo branch runs (so a
    handoff-storage failure still leaves the cookie for `/account`
    recovery).
  - The cookie's Path=/account keeps it scoped to the gateway origin
    and NOT readable by Malibu.
  - No behavior change for the pre-existing legacy flow
    (`returnTo == "" && fullKey != ""` still writes cookie then
    redirects to `s.cfg.Public.AccountPath`).

- `redirectOAuthHandoff` now sets `Referrer-Policy: no-referrer` and
  `Cache-Control: no-store` before the redirect. Confirm this does
  not break integration tests that inspect response headers.

## Output format

Write findings to `specs/PR400_HANDOFF_r2_code_audit.md` in the same
CRITICAL/HIGH/MEDIUM/LOW format the round-1 audit used. End with
`VERDICT: code lane READY TO MERGE` iff 0 C/H/M.

If the r1 findings are closed and no new C/H/M surfaced, PASS.

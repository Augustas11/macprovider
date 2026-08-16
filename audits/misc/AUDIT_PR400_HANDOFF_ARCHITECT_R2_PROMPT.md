# AUDIT PR400 ARCHITECT R2 PROMPT — Malibu OAuth return_to handoff

Round 2 of the architect lane. Round 1 findings are in
`specs/PR400_HANDOFF_r1_architect_audit.md`. Read
`specs/AUDIT_PR400_HANDOFF_ARCHITECT_PROMPT.md` for the full checklist
and diff surface.

## Fixes applied since round 1

### r1 ARCHITECT H1 — `PruneExpiredOAuthHandoffs` unwired
Fixed in `phase5-gateway/cmd/gateway/main.go`.
- The `oauthStatePruner` interface now requires both
  `PruneExpiredOAuthState` and `PruneExpiredOAuthHandoffs`.
- `runOAuthStatePruner` calls both on every tick (immediately + on
  each ticker fire).
- `cmd/gateway/main_test.go::TestRunOAuthStatePrunerRunsAndStops`
  and its fake pruner now assert BOTH methods are invoked
  immediately.

Confirm:
- No `store` object that implements `AuthStore` or
  `OAuthStateStore` is now missing a `PruneExpiredOAuthHandoffs`
  method (compile check — but re-verify by name search).
- The pruner interface change does not silently drop callers or
  break `cmd/gateway/main.go`'s call site `go runOAuthStatePruner(...)`.

### r1 ARCHITECT M1 — return_to / CORS allowlist drift
Fixed in `phase5-gateway/internal/config/config.go::Validate`.
- Validate now builds a set of CORS origins (`scheme://host`,
  lowercased) and requires every `auth.oauth.return_to_allowlist`
  entry to have a matching CORS origin, else returns an error
  naming the offending index and origin.
- `TestReturnToConfigRequiresMatchingCORSOrigin` in
  `phase5-gateway/internal/router/oauth_handoff_test.go` locks it in.

Confirm:
- The cross-check is order-independent (CORS entries validated first,
  then return_to entries, both scoped to lowercase scheme+host).
- The check does not spuriously fire when
  `return_to_allowlist` is empty (default).
- The error message names the offending origin so operators can
  fix it without reading source.

### r1 ARCHITECT M2 — Handoff-storage failure leaves orphan key
Partially mitigated in
`phase5-gateway/internal/router/oauth.go::handleGitHubCallback`.
The `mp_new_api_key` cookie is now set on every `fullKey != ""`
path, BEFORE the `returnTo` branch decides between handoff and
legacy paths. If `StoreOAuthHandoff` fails, the user is redirected
to Malibu with `?error=handoff_failed` AND the cookie survives on
`api.malibu.tech`, so the user can retrieve the key by visiting
`api.malibu.tech/account`.

Rate this fix:
- SUFFICIENT if the recovery path is a normal user-facing behavior
  (visiting `/account` after the redirect) with a stable UX.
- INSUFFICIENT if you see a case where the user cannot recover:
  - Cookie MaxAge of 300s is too short if Malibu shows the error but
    doesn't redirect back to gateway `/account`.
  - Signup flow: does the audit trail record the newly-minted key on
    the signup path? (Previously only the mint path emitted an
    `api_key_minted_via_oauth` audit event; signup relied on the
    `RecordSignupEvent`. Flag as MEDIUM if you can show the operator
    cannot correlate the orphan key with the account.)

Do NOT re-raise as HIGH/CRITICAL unless you can show a strict-loss
scenario the fallback cookie doesn't cover.

### r1 ARCHITECT L1 — CORS-only handoff route lacks explanation
NOT fixed (LOW). Skip per project convention (LOWs ship in PR body).

## Output format

Write findings to `specs/PR400_HANDOFF_r2_architect_audit.md`. End
with `VERDICT: architect lane READY TO MERGE` iff 0 C/H/M.

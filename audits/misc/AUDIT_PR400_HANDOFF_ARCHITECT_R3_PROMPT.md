# AUDIT PR400 ARCHITECT R3 PROMPT — Malibu OAuth return_to handoff

Round 3 of the architect lane. Round 2 findings are in
`specs/PR400_HANDOFF_r2_architect_audit.md`. Read the round-2 prompt
for the fixed-lane context; only ONE finding remained.

## Fix applied since round 2

### r2 ARCHITECT M1 — Handoff-store failure fallback was not a stable recovery contract
Fixed in `phase5-gateway/internal/router/oauth.go::handleGitHubCallback`.
- On `StoreOAuthHandoff` failure, the handler no longer redirects back to
  Malibu with `?error=handoff_failed`. It redirects directly to
  `s.cfg.Public.AccountPath` (the gateway `/account` page), which reads
  the already-set `mp_new_api_key` cookie and shows the user their key.
- The recovery UX is now anchored inside the gateway contract — no
  dependency on Malibu client behavior for the failure path.
- The cookie set BEFORE the returnTo branch (unchanged from round 2) is
  the fallback: `Path=/account`, `HttpOnly`, `Secure`, `SameSite=Lax`,
  `MaxAge=300`.

Test pin added: `TestOAuthHandoffPersistenceFailureRedirectsToAccount`
in `phase5-gateway/internal/router/oauth_handoff_test.go`. Uses a
`failingHandoffStore` wrapper that induces `StoreOAuthHandoff` failure
and asserts the redirect Location matches `cfg.Public.AccountPath` and
the fallback cookie is set.

## Confirm

- The failure branch does NOT double-redirect: `redirectOAuthHandoff`
  errors before it can call `http.Redirect`, so the subsequent
  `http.Redirect(w, r, s.cfg.Public.AccountPath, ...)` is the only
  Location write on that response.
- The Malibu `?error=handoff_failed` code path (previously used for
  persistence failure) is now dead. `redirectOAuthReturn` is still used
  for the `no_key` case (existing account, no mint action) — that
  remains a Malibu-side UX because there is no key to deliver.
- No other C/H/M architecture defects surfaced (parity/lifecycle/migration
  concerns from r1 remain closed).

## Output format

Write findings to `specs/PR400_HANDOFF_r3_architect_audit.md`. End with
`VERDICT: architect lane READY TO MERGE` iff 0 C/H/M.

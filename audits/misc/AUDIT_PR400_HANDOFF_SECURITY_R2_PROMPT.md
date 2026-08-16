# AUDIT PR400 SECURITY R2 PROMPT — Malibu OAuth return_to handoff

Round 2 of the security lane. Round 1 findings are in
`specs/PR400_HANDOFF_r1_security_audit.md`. Read
`specs/AUDIT_PR400_HANDOFF_SECURITY_PROMPT.md` for the full checklist
and diff surface.

## Fixes applied since round 1

### r1 SECURITY M1 — `return_to` path allowlist bypasses
Fixed in `phase5-gateway/internal/router/oauth.go::returnToAllowed`.
- Exact-path allowlist entries now match ONLY the exact target path.
- Trailing-`/` allowlist paths are explicit directory prefixes.
- Targets containing `.` or `..` segments (raw or percent-encoded
  `%2E` / `%2E%2E`) are rejected outright via `hasDotSegment`.

Confirm the following attacker inputs are rejected with 400
`oauth_return_to_not_allowed`:
- `https://malibu.tech/console/auth/callback.htmlx`
- `https://malibu.tech/console/auth/callback.html/extra`
- `https://malibu.tech/console/auth/callback.html/../admin`
- `https://malibu.tech/console/auth/callback.html/%2E%2E/admin`
- `https://malibu.tech.attacker.example/console/auth/callback.html`
- `http://malibu.tech/console/auth/callback.html` (scheme mismatch)

Verify by inspecting the code AND by reading the assertions in
`phase5-gateway/internal/router/oauth_handoff_test.go`
(`TestReturnToAllowedRejectsPrefixAndTraversal`).

Flag any additional path-shape bypass you can construct (e.g.
Unicode normalization tricks, path with backslashes on Windows-style
parsing, whitespace in path). Only rate as HIGH/CRITICAL if you can
demonstrate an actual attacker path to leak the handoff token.

### r1 SECURITY M2 — Missing `Referrer-Policy`/`Cache-Control` on redirect
Fixed in `phase5-gateway/internal/router/oauth.go::redirectOAuthHandoff`.
`Referrer-Policy: no-referrer` and `Cache-Control: no-store` /
`Pragma: no-cache` / `Expires: 0` are now set on the redirect
response (via `setNoStoreHeaders`).

Confirm:
- The headers land on the 302 redirect that includes `?handoff=<token>`.
- Assertions exist in `TestOAuthHandoffFlowRoundTrip` (the new test
  in `oauth_handoff_test.go`).
- The error redirect (`redirectOAuthReturn` on
  `?error=handoff_failed`) does NOT include the token — that redirect
  goes to a URL without the raw token, so it does not need the same
  hardening, but flag if you see a case where a partial URL still
  carries token material.

## Cross-cutting: fallback cookie on failure
`handleGitHubCallback` now sets the `mp_new_api_key` cookie for
every `fullKey != ""` case, regardless of `returnTo`. The cookie is
`Path=/account`, `HttpOnly`, `Secure` in prod, `SameSite=Lax`,
`MaxAge=300`.

Security concerns to check:
- Cookie is scoped to the gateway origin (`api.malibu.tech`) and
  path `/account`, so no Malibu page can read it — even a compromised
  Malibu return_to page could not exfiltrate the fallback via
  document.cookie.
- Any XSS on `/account` could exfiltrate the cookie — is `/account`
  already CSP-hardened? Look at `pages.go`. Flag only if the fallback
  materially changes the risk (it doesn't change the pre-existing
  cookie behavior — the same cookie was already set in the legacy
  path — this fix just extends the case).

## Output format

Write findings to `specs/PR400_HANDOFF_r2_security_audit.md` in the
same format the round-1 audit used. End with
`VERDICT: security lane READY TO MERGE` iff 0 C/H/M.

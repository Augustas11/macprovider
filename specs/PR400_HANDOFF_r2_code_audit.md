AUDIT_PR400_CODE: PASS

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

## Findings
No code-lane defects found.

## Verification
- r1 CODE M1 is closed: `returnToAllowed` now requires exact path equality for non-directory allowlist paths, preserves explicit trailing-slash directory-prefix semantics, and rejects literal or `%2E`-encoded dot segments before matching. The exact `/console/auth/callback.html` case accepts, while `.htmlx`, `/extra`, and `/../admin` targets reject; empty and `/` allowlist paths still match any path on the same scheme/host.
- r1 CODE M2 is closed: the added sqlite tests assert non-empty `ReturnTo` round-trip, handoff happy path, replay rejection, expiry rejection, and pruning counts. The added router tests assert return_to rejection cases, callback-to-handoff-to-exchange round-trip, replay failure, 405/empty/unknown-token error surfaces, fallback cookie presence, and response no-store/referrer headers.
- Cross-cutting cookie check passed: `handleGitHubCallback` sets `mp_new_api_key` before the `returnTo` branch whenever `fullKey != ""`; the cookie remains `Path=/account`, `HttpOnly`, and same gateway-origin scoped, and the legacy `returnTo == "" && fullKey != ""` flow still writes the cookie before redirecting to `s.cfg.Public.AccountPath`.
- Cross-cutting redirect-header check passed: `redirectOAuthHandoff` sets `Referrer-Policy: no-referrer` and `Cache-Control: no-store` before `http.Redirect`; router tests covering these headers pass.

## Tests
- `go test ./internal/storage/sqlite` from `phase5-gateway`
- `go test ./internal/router` from `phase5-gateway`
- `go test ./...` from `phase5-gateway`

VERDICT: code lane READY TO MERGE

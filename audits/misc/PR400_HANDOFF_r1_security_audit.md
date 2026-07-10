AUDIT_PR400_SECURITY: FAIL

CRITICAL: 0
HIGH: 0
MEDIUM: 2
LOW: 0

## Findings
### M1 `return_to` path allowlist accepts prefix and dot-segment bypasses
- file: phase5-gateway/internal/router/oauth.go:381
- attacker path: An attacker starts OAuth with an allowlisted Malibu origin but a non-callback path that still has the allowlisted callback path as a raw prefix, such as `https://malibu.tech/console/auth/callback.htmlx` or `https://malibu.tech/console/auth/callback.html/../../../admin`. `returnToAllowed` compares `target.Path` with `strings.HasPrefix` and does not clean or boundary-check the path before accepting it.
- impact: The gateway can redirect a fresh one-time handoff bearer token to a non-callback path on an allowlisted origin. If any accepted sibling/traversed path is attacker-controllable, open-redirecting, or emits the full URL via referrer/telemetry, the attacker can exchange the leaked handoff token for the live `mp_*` API key within the five-minute window.
- fix: Parse and validate against canonical paths before storing `return_to`: reject any `.` or `..` path segment, reject encoded slash/dot traversal after unescaping, and require exact path equality for file allowlist entries such as `/console/auth/callback.html` unless the allowlist explicitly marks an entry as a directory prefix with a `/` boundary.

### M2 Handoff token redirect lacks no-referrer/no-store protection
- file: phase5-gateway/internal/router/oauth.go:360
- attacker path: A victim completes OAuth through Malibu handoff. `redirectOAuthHandoff` adds `handoff=<raw token>` to the destination query string and immediately calls `http.Redirect` without setting `Referrer-Policy: no-referrer` or no-store headers on the redirect response.
- impact: The one-time handoff token is a bearer credential for `/auth/handoff/exchange`. It is short-lived and single-use, but while valid it can leak through browser history, intermediary/access logs, and referrer chains from the callback URL before Malibu exchanges and clears it. Any party that obtains it first can trade it for the returned API key.
- fix: Before the redirect, set `Referrer-Policy: no-referrer` and `Cache-Control: no-store`/`Pragma: no-cache` on the response. Prefer delivering the handoff in the URL fragment plus immediate `history.replaceState` on the Malibu callback page so it is not sent in HTTP request lines or server access logs.

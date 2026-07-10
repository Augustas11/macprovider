# AUDIT PR400 SECURITY PROMPT — Malibu OAuth return_to handoff

You are the **security** lane of a three-lane audit (code / security /
architect) of PR #400 (branch `feat/malibu-oauth-handoff`, commit
`ca8f491`). Stay narrowly in your lane.

## Why this diff is security-load-bearing

The diff introduces two new attacker-reachable surfaces on the
production gateway (`api.streamvc.live`):

1. `GET /auth/github/start?return_to=<url>` — accepts an attacker-
   controlled URL and, on successful OAuth callback, HTTP-redirects the
   authenticated user's browser to that URL with a one-time handoff
   token in the query string.
2. `POST /auth/handoff/exchange` — anonymous endpoint that trades a
   one-time token for a live `mp_*` API key.

Anything short of full mediation between the token and the key is a
credential-leak vector.

## Diff surface

- `phase5-gateway/internal/router/oauth.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/cors.go` (for context, unchanged)
- `phase5-gateway/internal/storage/sqlite/store.go` (handoff table)
- `phase5-gateway/internal/storage/sqlite/migrate.go`
- `phase5-gateway/gateway.yaml.example`

## Security-lane checks (apply each; stay in lane)

### SEC-1. Open-redirect / phishing via `return_to`
`returnToAllowed` (oauth.go ~L381) matches `Scheme` + `Host` (case-
insensitive) and a path-prefix check. Verify the following attacker
inputs are **rejected**:

- Different scheme: `http://malibu.tech/console/auth/callback.html`
  when allowlist has `https://…`.
- Different host: `https://malibu.tech.attacker.example/console/auth/callback.html`
  (subdomain of attacker containing allowed host as a substring).
- Case-tricks: `https://MALIBU.TECH/console/auth/callback.html` —
  intended to succeed; confirm it does succeed (or is documented as
  intentional).
- Userinfo injection: `https://malibu.tech@attacker.example/…`
  (Go's `url.Parse` puts `attacker.example` in Host — confirm).
- URL with credentials or unusual ports:
  `https://malibu.tech:8443/console/auth/callback.html`.
- Query / fragment injection where the fragment is
  `#https://attacker.example` — not exploitable per se but confirm no
  path uses the raw fragment.
- Path prefix pun: allowlist path `/console/auth/callback.html`,
  target path `/console/auth/callback.htmlx`. `strings.HasPrefix`
  accepts this because there is no separator boundary check — is
  this exploitable given the specific allowlisted paths? Any Malibu
  route beginning with the prefix could receive the handoff token.
  Rate as CRITICAL/HIGH only if there is a real path to attacker
  landing; MEDIUM otherwise.
- Path traversal: `/console/auth/callback.html/../../../admin` after
  URL parse — does Go's `url.Parse` normalize `..` here, or does the
  raw path survive to `HasPrefix`?

### SEC-2. Handoff token — one-time, single-audience, short-lived
- Confirm `oauth_handoffs.token_hash BLOB PRIMARY KEY` + the
  `UPDATE ... SET consumed_at = ?` guarantees at-most-once claim
  under concurrent exchange (uses `beginImmediate` — SQLite writer
  serialization is fine, but confirm the SELECT reads current row).
- TTL is 5 minutes (`now.Add(5 * time.Minute)` in
  `redirectOAuthHandoff`). Reasonable for browser-to-server hop;
  flag only if the code has an off-by-one where an expired row is
  still consumable.
- The token itself is `auth.StateToken()`. Is that the same 32-byte
  cryptographic randomness used for OAuth state? Confirm no lower-
  entropy generator was introduced.
- Is the RAW token ever logged (server logs, access log, error
  return)? Only the HASH is stored — but redirect emits the raw
  token as a query param, so it will land in nginx access logs and
  browser referrer chains. Is that acceptable given the 5-minute TTL
  and one-shot consume? Call out only if the token appears in
  additional log locations beyond the redirect URL itself.
- Referrer leak: on Malibu's callback page, the browser's next
  outbound request could include the referrer with the token in the
  query string. Should the redirect set `Referrer-Policy: no-referrer`
  header? Rate as MEDIUM if unmitigated.

### SEC-3. Exchange endpoint attack surface
- No authentication or rate limit on `POST /auth/handoff/exchange`.
  An attacker who exfiltrates a token from any leak path (log line,
  referrer, browser history sync) can trade it for a key from any
  IP. Given at-most-once + 5-minute TTL + hash-only-in-DB, is the
  residual risk acceptable? If any code path allows repeated attempts
  to enumerate tokens (e.g. distinguishing "wrong hash" vs "expired"
  vs "already consumed" via error code or timing), flag it. Confirm
  `handleHandoffExchange` returns the SAME error for all failure
  modes.
- Body size cap is `1<<20` (1 MiB). Fine; not a DoS lever at this
  volume.
- Is there any CSRF exposure? The endpoint is POST-only, requires a
  JSON body with the handoff token — CSRF only bites if the token
  is available to the attacker. If token was already leaked, CSRF is
  moot.

### SEC-4. CORS envelope on the exchange endpoint
- Route is wrapped with `s.withCORS(http.MethodPost, …)`.
  `corsOriginAllowed` walks `cfg.CORS.AllowedOrigins`. The new YAML
  adds `https://malibu.tech`, `https://www.malibu.tech`,
  `http://127.0.0.1:5173`, `http://localhost:5173`. Confirm:
  - `Access-Control-Allow-Credentials` is set to `false` in
    `setCORSHeaders` (cors.go L46). Confirm the exchange handler does
    NOT rely on cookies (it accepts the token via JSON body).
  - The API key returned in the response body is NOT wrapped by
    `Access-Control-Allow-Credentials: true` — if it were, a
    cross-origin script from ANY allowed origin could read it. Since
    Credentials is false, the response body is still readable by any
    allowed origin's script (that's the whole point). Confirm this is
    intentional and matches Malibu's fetch call shape.
  - Any origin outside the allowlist gets no CORS headers and their
    XHR/fetch is blocked. Confirm the request still succeeds
    server-side (no auth) but the browser drops the response — which
    means an attacker page from a bad origin still SEES the API key
    if they can bypass CORS via a preflight bug. Look for
    preflight-caching abuse (`Access-Control-Max-Age: 3600`
    combined with wildcard origins).

### SEC-5. Return-to redirect after failure
On handoff DB failure, `redirectOAuthReturn(returnTo, "handoff_failed")`
is called. This redirects the user's browser to the attacker-friendly
`returnTo` URL with `?error=handoff_failed`. Two concerns:
- Any secret in an error path? Confirm the error code is a stable
  literal (`no_key`, `handoff_failed`) with no user-controlled data
  interpolated.
- If `s.redirectOAuthReturn` is called AFTER `redirectOAuthHandoff`
  already wrote the redirect header, do we double-write? In the code
  path `if err := s.redirectOAuthHandoff(...); err != nil { ... }` —
  `redirectOAuthHandoff` calls `http.Redirect` unconditionally after
  success. The error path returns before `http.Redirect` runs
  (it errors before `target.String()`), so redirectOAuthReturn is
  safe. Confirm this reasoning is right.

### SEC-6. State row `return_to` — cannot be swapped mid-flow
The `return_to` value is stored in the same `oauth_states` row as the
state hash. `ConsumeOAuthState` atomically reads it out with the
redirect_uri and action. Attacker cannot mutate it after start:
- Confirm no code path allows updating an `oauth_states` row after
  insert (search for `UPDATE oauth_states`; only the `SET consumed_at`
  path exists).
- Confirm `returnTo` is validated at `/auth/github/start` time and NOT
  re-validated at callback — this is fine because it is bound to the
  state row, but flag if the callback path could accept a query-param
  `return_to` override.

### SEC-7. Handoff cookie / cache surfaces
- `handleHandoffExchange` calls `setNoStoreHeaders(w.Header())`.
  Confirm this sets `Cache-Control: no-store` and `Pragma: no-cache`
  (or the project's equivalent) so intermediary proxies do not cache
  the response containing the API key.
- The redirect to `returnTo?handoff=<token>` does NOT itself carry
  the API key — only the token. Confirm.

### SEC-8. Existing account, `action != "mint"` return-to path
The callback code sets `fullKey == ""` for existing-account non-mint
flows and takes the `no_key` early-return with `?error=no_key`. Is
there a way for an attacker to trigger a signup with an attacker-
controlled `return_to`, then use the resulting session/key for a
different account? The callback binds identity via GitHub OAuth
`ProviderUserID`, so no. Confirm the flow.

## Output format

Write a Markdown file at `specs/PR400_HANDOFF_r1_security_audit.md`:

```
AUDIT_PR400_SECURITY: PASS   # 0 C / 0 H / 0 M
# or
AUDIT_PR400_SECURITY: FAIL

CRITICAL: n
HIGH: n
MEDIUM: n
LOW: n

## Findings
### C1 <title>
- file: path:line
- attacker path: <who does what to trigger it>
- impact: <what they get / what leaks>
- fix: <concrete change>
```

Report ONLY defects. LOWs are optional. Do not propose scope
expansion. End with `VERDICT: security lane READY TO MERGE` iff
0 C/H/M.

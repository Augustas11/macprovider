AUDIT_PR400_CODE: FAIL

CRITICAL: 0
HIGH: 0
MEDIUM: 2
LOW: 0

## Findings
### M1 `return_to` path allowlist overmatches specific callback files
- file: phase5-gateway/internal/router/oauth.go:392
- evidence: `returnToAllowed` accepts any target path with `strings.HasPrefix(target.Path, u.Path)`, while `gateway.yaml.example` allowlists specific callback documents such as `https://malibu.tech/console/auth/callback.html`.
- impact: A configured allowlist entry for `/console/auth/callback.html` also allows `/console/auth/callback.html/extra` and `/console/auth/callback.htmlish` on the same scheme/host. That does not match the example config shape, which names exact `.html` callback files, and can redirect the OAuth handoff to an unintended Malibu route instead of the callback page expected to exchange the token.
- fix: Make non-empty allowlist paths exact by default, or use explicit directory-prefix semantics only for allowlist paths ending in `/`. For example, accept when `target.Path == u.Path`, or when `strings.HasSuffix(u.Path, "/") && strings.HasPrefix(target.Path, u.Path)`. Add a router-level `TestReturnToAllowedExactCallbackPath` covering exact match, `/extra`, and `.htmlish`.

### M2 New `return_to` and handoff behavior lacks regression coverage
- file: phase5-gateway/internal/storage/sqlite/store_test.go:247
- evidence: `TestOAuthStateAndRateLimitStores` only asserts the new `returnTo` return value is empty; repository test search shows no `OAuthHandoff`, `StoreOAuthHandoff`, `ConsumeOAuthHandoff`, `PruneExpiredOAuthHandoffs`, `returnToAllowed`, or `/auth/handoff/exchange` test coverage.
- impact: The new key-delivery path can regress while the current test suite still passes: a non-empty `ReturnTo` may fail to round-trip through `StoreOAuthStateWithCap` and `ConsumeOAuthState`, one-time handoff replay/expiry/prune behavior may break, or the HTTP exchange contract may drift from `{ "api_key": "mp_..." }` without a failing test.
- fix: Add focused tests named `TestOAuthStateReturnToRoundTrip`, `TestOAuthHandoffStoreConsumeReplay`, `TestOAuthHandoffExpiredReturnsNotFound`, `TestPruneExpiredOAuthHandoffs`, `TestReturnToAllowed`, and `TestHandoffExchange`. Cover 405, empty body, unknown token, valid token, and replay for `/auth/handoff/exchange`.

VERDICT: code lane NOT READY TO MERGE

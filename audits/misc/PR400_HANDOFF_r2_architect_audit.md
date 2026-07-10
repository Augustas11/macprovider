AUDIT_PR400_ARCHITECT_R2: FAIL

CRITICAL: 0
HIGH: 0
MEDIUM: 1
LOW: 0

## Findings

### M1 Handoff-store failure fallback is not a stable recovery contract
- file: phase5-gateway/internal/router/oauth.go:163
- observation: `handleGitHubCallback` now sets the `mp_new_api_key` cookie before entering the `returnTo` handoff branch, so the key is not strictly lost if `StoreOAuthHandoff` fails. However, the actual failure redirect is still only `return_to?error=handoff_failed` (`phase5-gateway/internal/router/oauth.go:180`), while the recovery page is a different gateway-origin route (`/account`) that reads and clears the cookie (`phase5-gateway/internal/router/pages.go:79`). The cookie is scoped to `/account` and expires after 300 seconds (`phase5-gateway/internal/router/oauth.go:171`).
- risk: this is an improvement over round 1, but it is not yet a normal, stable user-facing recovery path. If Malibu displays the error locally, waits for user action, or does not know to navigate to `https://api.streamvc.live/account` inside the 5-minute cookie window, the user still cannot retrieve the newly minted key. The gateway contract does not put the recovery URL in the redirect, extend the recovery window, or otherwise guarantee that the paired client will land the user on `/account` before the fallback cookie expires. This is not a HIGH/CRITICAL strict-loss scenario because the cookie fallback can recover the key, but the recovery depends on cross-client behavior outside the gateway contract.
- fix: make the failure fallback explicit and durable at the gateway/client contract boundary. For example, redirect with a documented recovery URL parameter, redirect directly to the gateway `/account` page on `StoreOAuthHandoff` failure, or increase/replace the 300-second cookie fallback with a one-shot recovery token whose UX is explicitly exercised by a gateway test. Keep the existing pre-handoff cookie as defense in depth.

## Confirmed Closed / Non-Blocking Checks

- r1 H1 is closed: `oauthStatePruner` requires both `PruneExpiredOAuthState` and `PruneExpiredOAuthHandoffs` (`phase5-gateway/cmd/gateway/main.go:197`), `runOAuthStatePruner` invokes both immediately and on each tick (`phase5-gateway/cmd/gateway/main.go:213`, `phase5-gateway/cmd/gateway/main.go:218`), and `main` still launches that loop with the concrete store (`phase5-gateway/cmd/gateway/main.go:81`). Name search found no alternate `AuthStore` / `OAuthStateStore` implementation missing the handoff pruner; the SQLite store remains the concrete implementation.
- r1 M1 is closed: config validation first validates return-to URLs, then builds a lowercase `scheme://host` set from exact CORS origins, then checks each return-to origin against that set (`phase5-gateway/internal/config/config.go:364`, `phase5-gateway/internal/config/config.go:454`). The check is order-independent, empty `return_to_allowlist` is a no-op loop, and the error includes both the offending index and normalized origin (`phase5-gateway/internal/config/config.go:477`).
- Migration compatibility remains clean: v9 fresh schema embeds `oauth_states.return_to` and `oauth_handoffs`; upgrade helpers preserve existing DBs; schema version 9 is stamped with the existing `INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(9, ?)` pattern; rollback remains gated by `maxKnownSchemaVersion`.
- Gateway/Malibu contract names match the prompt: redirect query parameter `handoff`, exchange endpoint `/auth/handoff/exchange`, request body field `handoff`, response field `api_key`, and error redirects `no_key` / `handoff_failed`.
- `AuthStore` / `OAuthStateStore` method parity is compile-enforced by the concrete SQLite store and current call sites; no separate interchangeable test double was found that would create a divergence hazard.
- Legacy no-`return_to` behavior is preserved: when `returnTo == ""`, the callback still redirects to `Public.AccountPath` after setting the `mp_new_api_key` cookie.
- r1 L1 remains a LOW route-comment issue and is skipped per the round-2 prompt/project convention.

## Verification

- `rg -n "AuthStore|OAuthStateStore|oauthStatePruner|runOAuthStatePruner\\(" phase5-gateway --glob '*.go'`
- `rg -n "PruneExpiredOAuthHandoffs|PruneExpiredOAuthState|StoreOAuthHandoff|ConsumeOAuthHandoff|return_to_allowlist|ReturnToAllowlist" phase5-gateway`
- `go test -count=1 ./cmd/gateway ./internal/config ./internal/router ./internal/storage/sqlite`
- `go test ./...` from `phase5-gateway`

VERDICT: architect lane NOT READY TO MERGE

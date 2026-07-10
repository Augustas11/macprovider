AUDIT_PR400_ARCHITECT: FAIL

CRITICAL: 0
HIGH: 1
MEDIUM: 2
LOW: 1

## Findings

### H1 OAuth handoffs have a prune method but no lifecycle wiring
- file: phase5-gateway/cmd/gateway/main.go:197
- observation: `oauthStatePruner` exposes only `PruneExpiredOAuthState`, `runOAuthStatePruner` only calls that method, and `main` only launches that pruner. The SQLite store implements `PruneExpiredOAuthHandoffs`, but no background loop invokes it.
- risk: `oauth_handoffs` persists every handoff row indefinitely. Consumed rows and expired unconsumed rows both remain after their 5-minute validity window, so a production instance accumulates stale API-key handoff material and grows the table/B-tree over months. There is no restart truncation, TTL, VACUUM cleanup, or alternate delete path.
- fix: extend the existing OAuth pruner interface/loop to call both `PruneExpiredOAuthState` and `PruneExpiredOAuthHandoffs`, or add a sibling `runOAuthHandoffPruner` launched from `main` on the same cadence. Add a `cmd/gateway` test fake that fails unless both methods are invoked.

### M1 Return-to and CORS allowlists can drift into a broken Malibu flow
- file: phase5-gateway/internal/config/config.go:364
- observation: `Validate` checks `auth.oauth.return_to_allowlist` entries only as absolute URLs and checks `cors.allowed_origins` entries only as exact origins, but it never verifies that every return-to scheme+host has a corresponding CORS origin. The example YAML updates both lists, but production config can update one without the other.
- risk: OAuth can accept a Malibu `return_to`, redirect back with a valid `handoff`, and then the browser-side `POST /auth/handoff/exchange` fails CORS because `withCORS` only reflects origins present in `cors.allowed_origins`. That leaves the user back on Malibu without an API key even though the OAuth flow and handoff creation succeeded.
- fix: in config validation, normalize each `return_to_allowlist` URL to `scheme://host` and require it in `cors.allowed_origins`, or derive the CORS origins for `/auth/handoff/exchange` from the return-to allowlist at boot. Cover the drift case in `config_test.go`.

### M2 Handoff persistence failure consumes state after minting an inaccessible key
- file: phase5-gateway/internal/router/oauth.go:100
- observation: `handleGitHubCallback` consumes the OAuth state before exchanging the GitHub code, then may create an account and issue an API key, and only afterward calls `redirectOAuthHandoff`. If `StoreOAuthHandoff` fails, the handler redirects to `return_to?error=handoff_failed`; the state row is already consumed and the newly issued key is not delivered.
- risk: on a transient DB error or disk-full condition after key issuance, the user receives no API key and cannot retry the same OAuth callback. In the signup branch this can leave an account plus active `mp_*` key that the user never saw; a later retry is now an existing-account flow and may return `no_key` unless the client also opts into minting.
- fix: make the callback storage transition atomic at the abstraction boundary: consume state, persist the issued key, and persist the handoff in one store transaction, or add a compensating path that revokes/deletes the just-issued key and leaves a retryable state when handoff persistence fails. At minimum, document and test the retry contract for the Malibu start URL if the intended recovery is `action=mint`.

### L1 CORS-only handoff route lacks a local route-level explanation
- file: phase5-gateway/internal/router/server.go:191
- observation: `/auth/handoff/exchange` is correctly registered with `withCORS(POST, ...)`, while `/auth/github/start` and `/auth/github/callback` remain plain navigation routes. The route table itself does not explain why this OAuth sibling needs CORS and the others do not.
- risk: future route cleanup can treat the asymmetry as accidental and remove CORS from the only XHR leg of the Malibu handoff flow.
- fix: add a short registration comment noting that the start/callback routes are browser navigations, but Malibu exchanges the handoff token from its origin via XHR/fetch.

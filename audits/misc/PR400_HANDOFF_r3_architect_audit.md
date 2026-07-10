AUDIT_PR400_ARCHITECT_R3: PASS

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

## Findings

(none)

## Confirmed Closed / Non-Blocking Checks

- r2 ARCHITECT M1 is closed: `handleGitHubCallback` sets the
  `mp_new_api_key` fallback cookie before entering the `returnTo` branch
  (`phase5-gateway/internal/router/oauth.go:163`), and on
  `StoreOAuthHandoff` failure it now redirects directly to
  `s.cfg.Public.AccountPath` (`phase5-gateway/internal/router/oauth.go:180`).
  That path is the gateway `/account` page, which reads and clears the cookie
  (`phase5-gateway/internal/router/pages.go:79`).
- The failure path does not double-redirect: `redirectOAuthHandoff` returns
  before writing a redirect when token generation, storage, or URL parsing
  fails (`phase5-gateway/internal/router/oauth.go:355`), and writes the Malibu
  handoff redirect only after those steps succeed
  (`phase5-gateway/internal/router/oauth.go:383`). Therefore the callback's
  `/account` redirect is the only `Location` write on an induced
  `StoreOAuthHandoff` failure.
- The former Malibu `?error=handoff_failed` persistence-failure route is dead
  in the gateway callback. Name search found no `handoff_failed` emission in
  `phase5-gateway/internal/router`, while `redirectOAuthReturn` remains in use
  for the existing-account/no-new-key `no_key` branch
  (`phase5-gateway/internal/router/oauth.go:176`).
- The recovery contract is pinned by
  `TestOAuthHandoffPersistenceFailureRedirectsToAccount`, which forces
  `StoreOAuthHandoff` to fail and asserts both the `/account` redirect and
  the fallback `mp_new_api_key` cookie
  (`phase5-gateway/internal/router/oauth_handoff_test.go:174`).
- No new C/H/M architecture defect surfaced in the reviewed handoff failure
  path. The parity, lifecycle, migration, and return-to/CORS concerns closed
  in prior rounds remain closed for this lane.
- r1 L1 remains a LOW route-comment issue and is skipped per the prompt /
  project convention.

## Verification

- `rg -n "handoff_failed|StoreOAuthHandoff|redirectOAuthHandoff|redirectOAuthReturn|mp_new_api_key|AccountPath" phase5-gateway/internal/router phase5-gateway/internal/config phase5-gateway/cmd/gateway`
- `rg -n "error=handoff_failed|handoff_failed" . --glob '!audits/**' --glob '!specs/PR400_HANDOFF_r2_architect_audit.md'`
- `go test -count=1 ./internal/router` from `phase5-gateway`
- `go test -count=1 ./...` from `phase5-gateway`

VERDICT: architect lane READY TO MERGE

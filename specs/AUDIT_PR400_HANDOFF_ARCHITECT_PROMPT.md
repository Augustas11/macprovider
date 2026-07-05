# AUDIT PR400 ARCHITECT PROMPT — Malibu OAuth return_to handoff

You are the **architect** lane of a three-lane audit (code / security /
architect) of PR #400 (branch `feat/malibu-oauth-handoff`, commit
`ca8f491`). Stay narrowly in your lane.

Architect lane covers: lifecycle wiring, background pruners, migration
compatibility across deploy directions, contract/schema drift, and
whether the new abstractions cleanly compose with existing ones. Do
not re-do the code lane's line-checking or the security lane's threat-
modeling.

## Diff surface

- `phase5-gateway/internal/router/oauth.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/gateway.yaml.example`
- `phase5-gateway/internal/storage/interfaces.go`
- `phase5-gateway/internal/storage/types.go`
- `phase5-gateway/internal/storage/sqlite/migrate.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/store_test.go`
- `phase5-gateway/cmd/gateway/main.go` (for background-pruner wiring
  cross-reference — NOT modified by the PR)

## Architect-lane checks (apply each; stay in lane)

### ARCH-1. Background pruner wiring for `oauth_handoffs`
The PR adds `PruneExpiredOAuthHandoffs` to both `AuthStore` and
`OAuthStateStore` interfaces and implements it in the SQLite store.
Look at `cmd/gateway/main.go` for background pruners:

- `runOAuthStatePruner` (line ~201) currently calls only
  `PruneExpiredOAuthState`. Is `PruneExpiredOAuthHandoffs` wired into
  any background loop?
- If NOT: the `oauth_handoffs` table grows unbounded over time
  (consumed rows never deleted, expired-but-not-consumed rows never
  deleted). On a production instance issuing N handoffs per day for
  months, this leaks disk and slows the PK BLOB lookup on
  `ConsumeOAuthHandoff`. Given the volume is small (bounded by
  active-user signup rate), rate the finding by acuity:
  - HIGH if the interface adds a method the caller never invokes AND
    there is no other cleanup path (VACUUM, TTL, etc.).
  - MEDIUM if there is another indirect cleanup (e.g. app-restart
    truncation, which there isn't — SQLite persists).
- Fix suggestion: extend the existing pruner to call both, or add a
  parallel `runOAuthHandoffPruner`. The interface method already
  exists — flag the missing invocation.

### ARCH-2. Migration compatibility direction — deploy-then-rollback
Schema v9 adds a column to `oauth_states` and creates
`oauth_handoffs`. The migration file uses
`CREATE TABLE IF NOT EXISTS oauth_states (... return_to TEXT NOT NULL DEFAULT '' ...)`
AND runs `ensureOAuthStateReturnToColumn` (ALTER TABLE for existing
v8 databases).

Confirm the deploy directions:

- **Fresh v9 install**: CREATE TABLE embeds the column; ensureColumn's
  PRAGMA read finds it, no ALTER. Migration writes
  `schema_migrations(9, ...)`. Clean.
- **v8 → v9 upgrade**: pre-existing `oauth_states` lacks `return_to`;
  ensureColumn ALTERs it in. Clean. `oauth_handoffs` created via
  ensureOAuthHandoffsTable. Clean.
- **v9 → v8 rollback (older binary on v9 db)**:
  `maxKnownSchemaVersion = 8`, so `checkSchemaVersionGate` refuses
  to start when the applied version (9) is greater. Deployment must
  restore the v8 snapshot per `deploy-pearl-vps.sh 5b`. Confirm the
  gate actually fires — is there a way the v8 binary can silently
  start on a v9 db (e.g. the `INSERT OR IGNORE INTO schema_migrations`
  never ran on some edge path)?
- Is the pattern of BOTH embedding `return_to` in the CREATE TABLE
  AND running `ensureOAuthStateReturnToColumn` intentional? Yes —
  matches the existing `ensureOAuthStateActionColumn` pattern on v7
  → v8. Confirm consistency; flag any drift from prior migration
  style (`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(N, ?)`
  pattern is followed).

### ARCH-3. Two allowlists must stay in sync
The PR adds Malibu URLs to two configuration surfaces:

- `auth.oauth.return_to_allowlist` in `phase5-gateway/gateway.yaml.example`
- `cors.allowed_origins` in the same file

For Malibu to complete the flow, BOTH must be updated in production.
The PR body reminds the operator, but there is no configuration-time
check that they stay consistent. Consider:

- Is a Validate-time cross-check appropriate? (Every entry in
  `return_to_allowlist` should have a `cors.allowed_origins` entry
  matching scheme+host.) Missing check → MEDIUM if the failure mode
  is silent (`return_to` works but the exchange call fails CORS,
  leaving the user in a broken state on Malibu with no key). LOW if
  the failure is obvious to the operator.
- Alternative: derive one list from the other at boot. Not required
  but worth calling out.

### ARCH-4. Contract with the paired Malibu client
The PR body cites Malibu commit `5a677d1` on branch
`site-review-2026-07`. Contract points that must match:

- Query param name: `handoff` (not `handoff_token`, not `code`).
- Exchange endpoint path: `/auth/handoff/exchange`.
- Exchange request body: `{ "handoff": "<token>" }`.
- Exchange response body: `{ "api_key": "mp_..." }`.
- Error surface on redirect: `?error=no_key` or `?error=handoff_failed`.

Do NOT read the Malibu repo — that is out of scope. But flag any
place where the gateway code uses a name inconsistent with the PR body
(e.g. the redirect path or response body key drifts from what the PR
body claims Malibu expects).

### ARCH-5. `AuthStore` vs `OAuthStateStore` interface parity
Both interfaces gained the same three new methods. Is one a superset
of the other, or is the duplication intentional? Sweep the code for
which interface is used at which call site and confirm this parity
does not create two paths of divergence over time (one implementer
staying behind on a signature change).

Rate MEDIUM if the duplication is a real maintenance hazard (e.g.
test doubles implement one but not the other and are used
interchangeably); LOW/INFO if the split is a well-established
project convention.

### ARCH-6. `withCORS` vs plain mux consistency
`/auth/handoff/exchange` is wrapped in `withCORS(POST, …)`.
`/auth/github/start` and `/auth/github/callback` are NOT wrapped
(they are user-navigation endpoints, not XHR). This asymmetry is
correct but worth confirming the reasoning is preserved via a
comment or route registration comment. Flag as LOW/INFO if the
`/auth/handoff/exchange` line lacks any explanation of why it needs
CORS while its siblings don't.

### ARCH-7. Concurrency: two callbacks racing for one state
`ConsumeOAuthState` uses `beginImmediate` and consumes the row
atomically. `redirectOAuthHandoff` runs AFTER `ConsumeOAuthState` has
already committed the "consumed" flag. Two race concerns:

- If two identical callback requests race, only one wins
  `ConsumeOAuthState`; the loser gets `ErrNotFound` → 400. Good.
- If `StoreOAuthHandoff` fails (disk full, transient DB error), the
  state row is ALREADY consumed. The user is redirected back with
  `?error=handoff_failed` and has NO way to retry — they cannot
  reuse the state, and the API key has been minted (in the mint or
  signup branch). Is this an acceptable failure mode? On a mint
  branch this leaves an orphan `mp_*` key that the user cannot
  access. Rate as MEDIUM if this leaks credentials or leaves the
  user with a broken account; LOW if the standard recovery is
  "start OAuth again and re-mint".

### ARCH-8. Cookie surface unchanged for legacy path
The legacy `mp_new_api_key` cookie + `/account` redirect still fires
when `returnTo == "" && fullKey != ""`. Confirm the console.streamvc.live
provider portal flow (which does NOT pass `return_to`) is unchanged.
Flag if any assumption in the console portal about the cookie's
presence or path is broken by the refactor (e.g. Path=`/account`
still matches; the SetCookie call site is unchanged in structure).

## Output format

Write a Markdown file at `specs/PR400_HANDOFF_r1_architect_audit.md`:

```
AUDIT_PR400_ARCHITECT: PASS   # 0 C / 0 H / 0 M
# or
AUDIT_PR400_ARCHITECT: FAIL

CRITICAL: n
HIGH: n
MEDIUM: n
LOW: n

## Findings
### H1 <title>
- file: path:line (or "cross-cutting")
- observation: <what the architecture does today>
- risk: <what breaks over time or at scale>
- fix: <concrete refactor / wiring change>
```

Report only architecture defects. Do not double-count with code or
security lanes. LOWs are optional. End with
`VERDICT: architect lane READY TO MERGE` iff 0 C/H/M.

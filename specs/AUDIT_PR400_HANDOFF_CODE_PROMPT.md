# AUDIT PR400 CODE PROMPT — Malibu OAuth return_to handoff

You are the **code** lane of a three-lane audit (code / security / architect)
of PR #400 (branch `feat/malibu-oauth-handoff`, commit `ca8f491`).

Scope: correctness, control-flow, signature consistency, test adequacy.
Security and architecture concerns are covered by the sibling lanes — stay
in your lane.

## Diff surface

Files in scope (`git diff origin/main...HEAD` on the branch, or view the PR
at https://github.com/Augustas11/macprovider/pull/400):

- `phase5-gateway/internal/router/oauth.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/gateway.yaml.example`
- `phase5-gateway/internal/storage/interfaces.go`
- `phase5-gateway/internal/storage/types.go`
- `phase5-gateway/internal/storage/sqlite/migrate.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/store_test.go`

## What the diff does

1. Adds `return_to` query param on `GET /auth/github/start`, gated by a new
   `auth.oauth.return_to_allowlist` config allowlist.
2. Threads the value through `OAuthState` (new `ReturnTo` column, schema v9
   migration + additive column on existing v8 tables).
3. On `GET /auth/github/callback`, if `returnTo != ""`, mint a one-time
   handoff token (`oauth_handoffs` table), redirect to
   `<returnTo>?handoff=<token>`, and skip the usual `mp_new_api_key`
   cookie + `/account` redirect.
4. Adds `POST /auth/handoff/exchange` — Malibu exchanges the handoff for
   the full `mp_*` key exactly once.
5. Extends the CORS `allowed_origins` list to include Malibu.

## Code-lane checks (apply each; stay in lane)

### CODE-1. Signature change fanout — every caller updated?
- `AuthStore.ConsumeOAuthState` grew a fourth return value (`returnTo`).
  Every implementer and every caller must match. Sweep for stale 3-value
  call sites (`_, _, err := ... .ConsumeOAuthState(`) and stale 3-value
  method implementations. In-tree caller today is
  `handleGitHubCallback`; test doubles in `store_test.go` and any router
  test mocks must also be updated.
- `OAuthStateStore` mirror interface has the same signature. Confirm.
- `storage.OAuthState` gained `ReturnTo string`. Confirm nothing constructs
  the struct positionally (would silently swap fields).

### CODE-2. `fullKey` scoping across signup vs mint branches
`handleGitHubCallback` now declares `var fullKey string` outside the
signup / mint branches and uses `=` (not `:=`) inside each branch.

- Confirm there is NO `:=` inside either branch that would shadow the
  outer `fullKey` (which would silently leave `fullKey == ""` after
  the branch and force the `no_key` return path for every user).
- Confirm the third code path — existing account, `action != "mint"` —
  correctly leaves `fullKey == ""` so that the `return_to` branch takes
  the `no_key` early-return (that is the intended UX: existing users
  who came without `action=mint` get redirected back with `?error=no_key`
  rather than an empty key).
- Confirm `err` reuse inside the branches does not mask an earlier
  non-nil `err` that should have already returned.

### CODE-3. `return_to` allowlist matching semantics
`returnToAllowed` matches on `Scheme` + `Host` (case-insensitive) and a
path-prefix check that accepts:
- Empty or `/` allowlisted path → any target path on that host.
- Non-empty allowlisted path → `strings.HasPrefix(target.Path, u.Path)`.

- Is this the right shape given the configured allowlist entries in
  `gateway.yaml.example` (each entry names a specific `.html` path)?
- Does `HasPrefix` on the exact configured path
  `/console/auth/callback.html` accept the target
  `/console/auth/callback.html` (same string)? Yes — but does it also
  accept `/console/auth/callback.html/extra` and
  `/console/auth/callback.htmlish`? Flag if you find a semantic
  mismatch between the config comment and the code.
- Fragment / query on `returnTo` — is it preserved through
  `redirectOAuthHandoff`'s `values := target.Query(); values.Set("handoff", …)`
  round-trip? What if Malibu passes `?state=xyz` — is `xyz` kept?

### CODE-4. `handleHandoffExchange` request body handling
- `http.MaxBytesReader(w, r.Body, 1<<20)` caps body at 1 MiB. Reasonable
  for a `{ "handoff": "..." }` payload.
- On decode error, on empty handoff, and on store failure the handler
  returns the SAME `oauth_handoff` / `invalid_handoff` error code. Is
  the collapsed error surface intentional? (Not leaking whether the
  token was valid-shape but wrong-value is deliberate; confirm the
  handler never returns a distinguishable success on failure.)
- Response: `writeJSON(w, http.StatusOK, map[string]any{"api_key": apiKey})`.
  Contract must match what Malibu expects — PR body says
  `{ "api_key": "mp_…" }`. Confirm exact key name.

### CODE-5. Store: `StoreOAuthHandoff` / `ConsumeOAuthHandoff` correctness
- `StoreOAuthHandoff` runs OUTSIDE a transaction (single `INSERT`).
  Compare to `StoreOAuthStateWithCap` which uses `beginImmediate`
  because it does a per-IP cap count first. There is no per-IP cap
  here — is a bare `ExecContext` right, or should we mirror the
  transactional pattern for consistency?
- `ConsumeOAuthHandoff` uses `beginImmediate` + `SELECT` +
  `UPDATE consumed_at`. Verify the consumed / expired guard mirrors
  `ConsumeOAuthState` exactly — the two now diverge only in schema
  (no session cookie binding here); flag any accidental divergence
  in the freshness check.
- `token_hash BLOB PRIMARY KEY` gives us idempotent replay protection
  and O(1) lookup. Confirm the token generator (`auth.StateToken`) has
  the same entropy as it does for `state`, and that
  `auth.StateHash(token)` is used consistently (start vs consume).

### CODE-6. Schema v9 migration
- `ensureOAuthStateReturnToColumn` reads `PRAGMA table_info` and issues
  an `ALTER TABLE ... ADD COLUMN return_to TEXT NOT NULL DEFAULT ''`
  if missing. Confirm idempotence: running on a fresh v9 schema (from
  `CREATE TABLE IF NOT EXISTS oauth_states (...)` already including
  `return_to`) is a no-op, and running on an old v8 schema is
  additive.
- `ensureOAuthHandoffsTable` uses `CREATE TABLE IF NOT EXISTS` +
  `CREATE INDEX IF NOT EXISTS`. Idempotent. Confirm.
- Version bump: `maxKnownSchemaVersion` goes 8 → 9, and a new
  `INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(9, ?)`
  row is written. Confirm nothing else in the migration ladder was
  missed (e.g. an intermediate v-string in comments that also needs
  bumping).
- What happens if an operator downgrades the binary back to a v8 build
  after v9 has been applied? The binary compares
  `current > maxKnownSchemaVersion` and refuses to start — confirm
  this fail-loud path still fires. (The CLAUDE.md note references
  `deploy-pearl-vps.sh step 5b` snapshot as the roll-back path.)

### CODE-7. Test coverage adequacy (code lane view only — no security)
- `TestOAuthStateAndRateLimitStores` was updated for the new 4-value
  return and the `returnTo == ""` assertion. Good.
- Is there ANY test for:
  - a non-empty `ReturnTo` round-tripping through `StoreOAuthStateWithCap`
    → `ConsumeOAuthState`?
  - `StoreOAuthHandoff` + `ConsumeOAuthHandoff` happy path (returns
    key, then replay returns `ErrNotFound`)?
  - `ConsumeOAuthHandoff` on an expired row returns `ErrNotFound`?
  - `PruneExpiredOAuthHandoffs` deletes only rows whose
    `expires_at <= now`?
  - `returnToAllowed` at the router level (mismatch host, mismatch
    scheme, empty allowlist)?
  - `handleHandoffExchange` HTTP behavior (405, empty body, unknown
    token, valid token, replay)?
- If any of these are absent, that is a CODE finding — call the
  missing coverage out with an exact test name suggestion.

### CODE-8. Config default + validation
- `OAuthConfig.ReturnToAllowlist` has no default. If YAML omits it,
  the slice is nil, `returnToAllowed` returns false for all inputs,
  and the flow degrades to "no `return_to` allowed" — the existing
  cookie+`/account` path. Confirm this default-off posture.
- `Validate()` runs `requireURL` on each entry. Confirm empty entries
  and duplicates behave the way you'd expect (either both accepted
  or both rejected).

### CODE-9. Route registration
- `server.go` wires `/auth/handoff/exchange` via `s.withCORS(http.MethodPost, …)`
  even though the `/auth/github/*` routes above it are wired plainly
  with `mux.HandleFunc`. This is intentional (Malibu is a same-origin-
  from-its-own-DNS cross-origin caller). Confirm the wrapper does not
  double-set Access-Control-* headers via `setCORSHeaders` +
  `setNoStoreHeaders` and does not conflict with `writeJSON`.

## Output format

Write a Markdown file at `specs/PR400_HANDOFF_r1_code_audit.md` with:

```
AUDIT_PR400_CODE: PASS   # if 0 CRITICAL / 0 HIGH / 0 MEDIUM
# or
AUDIT_PR400_CODE: FAIL

CRITICAL: n
HIGH: n
MEDIUM: n
LOW: n

## Findings
### C1 <title>
- file: path:line
- evidence: <exact snippet or claim>
- impact: <what breaks in prod>
- fix: <concrete one-paragraph change>
### H1 …
### M1 …
### L1 …
```

Report ONLY defects. Do not propose scope expansion, feature refactors,
or opinion-level stylistic changes. LOWs are optional and never block.

End with a VERDICT line: `VERDICT: code lane READY TO MERGE` iff 0 C/H/M.

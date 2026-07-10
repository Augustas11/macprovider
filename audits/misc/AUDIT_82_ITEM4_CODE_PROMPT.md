# Issue #82 item 4 — explorer auth_state exposure — CODE-lane audit

You are the **code** lane of a three-lane audit of #82 item 4 — a
small admin-surface addition exposing `auth_state` in the explorer's
provider list + detail views. Stay narrowly in your lane.

## Branch / commit

- Branch: `fix/explorer-auth-state-exposure`
- Worktree: `../macprovider-82-item4-explorer` (origin/main base: 5a233bc)
- Files in scope (`git diff origin/main`):
  - `phase4-coordinator/internal/explorer/store.go` — added
    `"auth_state": p.AuthState` to `providerMap` (line ~520).
  - `phase4-coordinator/internal/explorer/handlers_test.go` — new
    `Test82Item4_ProviderMapExposesAuthState` (5 sub-cases:
    bearer_validated, self_minted, bearerless_duplicate, mint_failed,
    empty_legacy).

## What this change does (operator summary — NOT the audit answer)

Closes issue #82 item 4 (MEDIUM). The explorer admin surface listed
providers but omitted `auth_state` from the JSON — operators could
see a provider in `/poolz` but couldn't see WHY a session was
non-routable from the explorer. The fix adds `auth_state` to the
shared `providerMap` so both list (`/admin/explorer/providers`) and
detail (`/admin/explorer/providers/{id}`) responses include it.

## Code-lane scope

### CODE-1. Single-source-of-truth boundary
- The change is one line in `providerMap`. `providerMap` is the
  shared rendering function for both list and detail views, so a
  single edit covers both surfaces. Confirm.
- The serialized value is `p.AuthState` directly (a `pool.AuthState`
  typed string). It JSON-marshals as its underlying string value
  (bearer_validated / self_minted / bearerless_duplicate /
  mint_failed / empty).

### CODE-2. Empty-state semantics
- For pre-FR-C9 sessions the AuthState field is the zero value
  (empty string). `providerMap` emits `"auth_state": ""` rather
  than omitting the field. Is that the right choice (always-emit
  for explorer admin views), or should the rendering use
  `omitempty`-style suppression to match `pool.Provider`'s JSON
  tag?
- The other fields in `providerMap` (e.g. `binary_version`,
  `hash_status`) are emitted unconditionally even when empty.
  Confirm consistency.

### CODE-3. Test coverage
- The new test exercises all 5 distinct AuthState values, asserting
  both list and detail views surface the field correctly. Is
  there any scenario the test does not cover?
- The test seeds a registered provider via `pool.Registry.Register`
  and a corresponding `provider_tokens` row via raw SQL. The
  registry call uses `&pool.Provider{... AuthState: tc.authState}`.
  Confirm this is the right way to set AuthState on a registered
  Provider (vs. needing to go through the full admission flow).

### CODE-4. JSON ordering / shape stability
- The added field is at the end of the map. Map key ordering in Go
  JSON marshal is deterministic (alphabetical), so the on-wire
  position is unaffected. Confirm.

### CODE-5. No SPEC change
- The explorer is internal admin surface (operator-only,
  authenticated by operator token). The issue body explicitly
  treats item 4 as MEDIUM observability. No SPEC change is
  required. Confirm.

## Output format

```
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM4_CODE_audit.md`. If 0 C/H/M, end with:
`VERDICT: code lane READY TO MERGE`

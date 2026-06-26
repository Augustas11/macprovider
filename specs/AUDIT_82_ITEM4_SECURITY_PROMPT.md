# Issue #82 item 4 — explorer auth_state exposure — SECURITY-lane audit

You are the **security** lane of a three-lane audit of #82 item 4.
Stay narrowly in your lane.

## Files in scope (`git diff origin/main`)

- `phase4-coordinator/internal/explorer/store.go` — adds
  `"auth_state": p.AuthState` to `providerMap`.
- `phase4-coordinator/internal/explorer/handlers_test.go` — adds
  test asserting the field appears for every AuthState value.

## Why security cares

The explorer admin surface is operator-only (bearer auth checked at
the handler layer). Exposing `auth_state` lets operators distinguish
bearer-validated / self-minted / bearerless-duplicate / mint-failed
sessions — which is exactly the WHY-non-routable signal SPEC-003
FR-C9.4 introduced. Without it, an operator might admit a session
to a deploy pipeline that should have been quarantined.

## Security-lane scope

### SEC-1. Disclosure surface
- `auth_state` is an enum value (strings: bearer_validated /
  self_minted / bearerless_duplicate / mint_failed / empty). It
  carries NO credential material (no token, no hash, no IP). Is
  this disclosure boundary safe?
- The explorer surface already discloses `provider_id`,
  `assigned_id`, `hostname`, `model_id`, `token_prefix`, etc.
  Adding `auth_state` is strictly less sensitive than the existing
  surface.

### SEC-2. Authorization boundary
- The handlers gating this view (`/admin/explorer/providers`) already
  require operator-level bearer. Confirm no change in
  authorization is required by the addition.

### SEC-3. Cross-surface consistency
- The same `auth_state` field is exposed by `/poolz` (operator-only,
  same auth tier). Item 4 brings the explorer surface in line with
  `/poolz`. Confirm this is the right cross-surface alignment.

### SEC-4. No write path
- The explorer surface is read-only. The added field is read from
  in-memory `pool.Provider.AuthState`; no new write path is
  introduced. Confirm.

## Output format

```
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM4_SECURITY_audit.md`. If 0 C/H/M, end with:
`VERDICT: security lane READY TO MERGE`

# Issue #82 item 4 — explorer auth_state exposure — ARCHITECT-lane audit

You are the **architect** lane of a three-lane audit of #82 item 4.
Stay narrowly in your lane.

## Files in scope (`git diff origin/main`)

- `phase4-coordinator/internal/explorer/store.go` — adds
  `"auth_state": p.AuthState` to `providerMap`.
- `phase4-coordinator/internal/explorer/handlers_test.go` — table-
  driven test.

## Architect-lane scope

### ARCH-1. Boundary cleanliness
- `providerMap` is the shared rendering function for both list and
  detail views. The fix is a single-field addition to that map. Is
  this the right architectural boundary, vs. duplicating in two
  handlers?

### ARCH-2. No SPEC change
- The issue body marks item 4 as MEDIUM observability. The
  explorer surface is not on the SPEC-002/SPEC-003 normative wire;
  it's an internal admin convenience. The PR ships no SPEC change.
  Is that the right call?
- Counter: should SPEC-002 or SPEC-003 normatively document the
  explorer's `auth_state` field for forward-compatibility? My
  read: no — the explorer is treated as a debug/admin surface and
  has no SPEC tier of its own. Confirm.

### ARCH-3. Closing criterion for #82
- Items 1 (PR #174), 2 (shipped pre-#82-close), 3 (this PR's
  sibling, item 3), and 4 (this PR) all shipped → #82 closes. The
  closing criterion in the issue body is "all 4 items shipped +
  verified. SPEC-002 + SPEC-003 cross-spec consistency restated."
  Item 1 brought SPEC-002 to v1.4.1; item 3 brings SPEC-003 to
  v0.10.1. Cross-spec consistency: confirm.

### ARCH-4. Test depth vs item severity
- Item 4 is MEDIUM. The new test is table-driven across 5
  AuthState values + 2 surfaces (list + detail) = 10 assertions.
  Is that adequate, or overkill for a MEDIUM-rated single-line
  fix? (Probably adequate — the AuthState enum is exhaustive and
  the test pins the contract.)

## Output format

```
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM4_ARCHITECT_audit.md`. If 0 C/H/M, end with:
`VERDICT: architect lane READY TO MERGE`

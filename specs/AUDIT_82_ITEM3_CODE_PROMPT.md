# Issue #82 item 3 — coordinator-cli pre-flip-audit — CODE-lane audit

You are the **code** lane of a three-lane audit (code / security /
architect) of issue #82 item 3 — a new `coordinator-cli
pre-flip-audit` subcommand that automates the SPEC-003 FR-C9.4
runbook freshness gate before flipping `RequireProviderTokens=true`.

## Branch / commit

- Branch: `fix/coordinator-cli-pre-flip-audit`
- Worktree: `../macprovider-82-item3-preflip` (origin/main base: 5a233bc)
- Files in scope (`git diff origin/main`):
  - `phase4-coordinator/cmd/coordinator-cli/main.go` — added `io`
    import; new `case "pre-flip-audit":` in dispatch switch; new
    `preFlipAudit` + `preFlipAuditRun` functions; usage() updated.
  - `phase4-coordinator/cmd/coordinator-cli/pre_flip_audit_test.go`
    — 8 new tests (table-of-scenarios style): empty DB, all-fresh,
    NULL last_used, old last_used, revoked-row-ignored, near-
    boundary fresh, JSON mode, zero-duration rejected.
  - `specs/SPEC-003-open-onboarding.md` — version bump 0.10 →
    0.10.1; FR-C9.4 runbook prose updated to point at the shipped
    command instead of the tracking issue.

## What this change does (operator summary — NOT the audit answer)

Closes issue #82 item 3 (MAJOR per the issue). Before this change,
SPEC-003 FR-C9.4 specified the runbook prose ("operator MUST check
`last_used_at` freshness") but no code enforced it. A confused
operator could flip `RequireProviderTokens=true` while an active
row still had `last_used_at IS NULL` (a provider that never
authenticated with Bearer), bricking that provider.

The new command queries the active `provider_tokens` rows and
exits non-zero if any row has stale `last_used_at` (NULL or older
than `--max-last-used-age`, default 24h). Operators wire it into
their deploy pipeline as a gate.

## Code-lane scope (apply each; stay in lane)

### CODE-1. Time/timestamp handling
- The comparison uses lex `<` on the existing
  `"2006-01-02T15:04:05Z"` string format (matching
  `auth/tokens.go`'s `nowString()`). Confirm this is correct:
  every UTC ISO-8601 with second-precision and 'Z' suffix is
  lex-comparable iff both sides have identical format. If a
  legacy row had a different format (e.g. microseconds), the
  lex compare would silently break.
- `time.Now().UTC()` is captured once at the start; the cutoff
  is `now.Add(-*maxAge)`. Test
  `TestPreFlipAudit_NearBoundary_Fresh` uses a 500ms backdated
  row with `--max-last-used-age=1s` — assumes the test runs in
  ≪500ms; the cushion is small. Acceptable?
- The default `--max-last-used-age=24h` matches the SPEC-003
  runbook recommendation.

### CODE-2. Active-row predicate
- The walker skips rows where `r.RevokedAt.Valid` is true. Is
  there any other "inactive" state the predicate misses? For
  instance, a row with `RevokedAt.Valid==false` AND
  `provider_id == ""` (legacy untagged row) — is that active?
- Trace: `auth.ListTokens` returns all rows regardless of
  status; filtering is the subcommand's responsibility.
- The active count (printed as `active_tokens=N`) excludes
  revoked rows. Sanity-check.

### CODE-3. Output schemas
- Text mode and JSON mode emit different shapes. The JSON shape
  is unmarshalable into `parsed` in `TestPreFlipAudit_JSONMode`.
  Confirm `safe_to_flip`, `stale_count`, and `offenders[]` field
  names + types are stable enough for pipeline integration.
- The `last_used_at` field on each offender is `*string` (nil
  for NULL DB column). JSON consumers must handle `null`.
  Acceptable for a CLI tool? Confirm the test asserts both
  branches (NULL case + non-NULL case).

### CODE-4. Exit-code surface
- `preFlipAuditRun` returns `(stale bool, err error)`.
  `preFlipAudit` (the dispatch entry) calls `os.Exit(1)` on
  `stale==true`, returns `err` otherwise. Is this the right
  separation?
- The `flag.ExitOnError` mode means `--help` and bad flags exit
  2; non-empty `err` from main.go's switch becomes exit 1; an
  audit-failed result also exits 1. The exit-code surface is:
  0 = safe; 1 = stale OR I/O error; 2 = bad flag. Is the
  conflation of "stale" with "I/O error" at exit 1 OK?
- Suggestion to consider: exit 1 = stale rows found (the
  documented gate semantic); exit 2 = bad usage; exit 3 =
  I/O error. But matching existing CLI conventions
  (issueToken etc. return errors → exit 1 indiscriminately)
  may be preferred for consistency.

### CODE-5. Test fixture correctness
- `backdateLastUsed` opens `sql.Open("sqlite", dbPath)` and
  runs a raw UPDATE. The driver string "sqlite" (not
  "sqlite3") matches `auth/tokens.go`'s
  `sql.Open("sqlite", ...)`. The test imports
  `_ "modernc.org/sqlite"`. Confirm the import is needed +
  doesn't conflict with anything else.
- `TestPreFlipAudit_RevokedRow_Ignored` revokes one token
  and stamps a second as fresh. Confirm the revoked row's
  pre-revoke state is also (NULL last_used_at) — meaning
  if we DIDN'T filter revoked, that test would fail. Good
  drift coverage.

### CODE-6. SPEC v0.10.1 wording
- The runbook now says "Operators MUST integrate this command
  into the deploy pipeline as a precondition before flipping
  `RequireProviderTokens=true`". Confirm the SHOULD/MUST level
  is appropriate. Compare to the existing runbook text from
  v0.8.4.
- Version bumped 0.10 → 0.10.1 (additive patch, no wire-
  shape change). Change-log entry references issue #82 item 3.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM3_CODE_audit.md`. If 0 CRITICAL/HIGH/MEDIUM,
end with: `VERDICT: code lane READY TO MERGE`

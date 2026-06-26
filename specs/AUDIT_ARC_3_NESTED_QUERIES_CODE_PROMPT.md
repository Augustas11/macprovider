# ARC-3 nested-query unwind — CODE-lane audit

You are the **code** lane of a three-lane audit (code / security /
architect) of the phase4-coordinator nested-cursor refactor for issue
#21 / ARCH-3. Stay narrowly in your lane — security and architect
findings have their own lanes; flag overlap as `QUESTIONS` rather
than mixing scopes.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries` (origin/main base: eaae922)
- Files in scope (`git diff origin/main -- phase4-coordinator/`):
  - `phase4-coordinator/internal/billing/store.go` (rebuildLegacyConfigSnapshots two-pass)
  - `phase4-coordinator/internal/billing/endpoints.go` (providers handler + buyerEquivalentCredits two-pass)
  - `phase4-coordinator/internal/billing/snapshot.go` (snapshotAtTx + snapshotQueryer)
  - `phase4-coordinator/internal/billing/recovery.go` (RecoverLedger switched to snapshotAtTx)
  - `phase4-coordinator/internal/billing/nested_query_regression_test.go` (new)
  - `phase4-coordinator/internal/requestlog/store.go` (SetMaxOpenConns(1) + SetMaxIdleConns(1))

## What the change does (operator summary — NOT the audit answer)

Issue #21 / ARCH-3. Three nested-cursor sites in billing money-path code
deadlocked at the `MaxOpenConns(1)` cap PR #14 tried to set on the
shared requestlog/billing `*sql.DB`. The refactor:

1. `rebuildLegacyConfigSnapshots` — collect unique-index names into
   a slice, close the outer cursor, then run inner PRAGMA per name
   (early `break` on first match).
2. `providers` handler — drain aggregate cursor into a typed
   `[]providerSummary` slice, close cursor, then run `h.sum(...)` per
   item.
3. `buyerEquivalentCredits` — drain request_log cursor into a typed
   `[]requestLogScan` slice (carries raw `tsText`), close cursor,
   then in second pass apply 503 filter BEFORE `time.Parse` (preserves
   origin/main's silent-503 behavior).
4. `RecoverLedger` 4th site — was calling `s.snapshotAt` (which uses
   `s.db`) from inside a tx → deadlock at cap=1. New `snapshotAtTx`
   helper using a narrow `snapshotQueryer` interface (both `*sql.DB`
   and `*sql.Tx` satisfy it).
5. `requestlog.OpenStore` now caps to 1 conn (matches auth + audit).
6. `nested_query_regression_test.go` pins each site at cap=1.

`go test ./...` in phase4-coordinator: green, 15.5s.

## Code-lane scope (apply each; stay in lane)

### CODE-1. Semantics preservation
For each of the four refactored sites, trace one or more execution paths
against the origin/main behavior. A semantic no-op claim is the load-
bearing one — verify, don't assume.
- `rebuildLegacyConfigSnapshots`: original scanned every unique index;
  new code breaks on first match. Is there any schema state where
  multiple `(config_hash)` unique indexes could exist and the early
  break would mis-fire? (Theoretical: SQLite allows it. Practical:
  this rebuild only triggers when EXACTLY ONE legacy unique exists.)
- `providers` handler pagination: confirm the `len(scratch) >= limit+1`
  drain-cap + the second-pass `len(items) == limit` cursor gate
  produce IDENTICAL `next_cursor` and `items` output to origin/main for:
  empty result, single result, exactly-limit results, limit+1 results,
  cursor handoff between pages.
- `buyerEquivalentCredits`: the r2 fix (carry `tsText`, parse in
  second pass after 503 filter) — confirm parse errors on non-503
  rows still surface as hard errors, and 503-row tsText is never
  consumed.
- `snapshotAtTx`: confirm the new wrapper preserves the
  `errors.Is(err, sql.ErrNoRows) → ErrNoSnapshot` mapping byte-for-
  byte against the original `snapshotAt`.

### CODE-2. Error handling correctness
- Old `providers` loop: cursor closed via `defer rows.Close()`;
  errors returned inline. New loop: explicit `rows.Close()` before
  every error return AND before the second pass. Are any new code
  paths leaving cursors open? Specifically: the second pass calls
  `h.sum(ctx, ...)` which internally opens its own row; if the
  context is cancelled mid-second-pass, does anything leak?
- New `buyerEquivalentCredits` second pass: `time.Parse` failure on
  a non-503 row returns `total=0` and the parse error. Origin/main
  did the same. Confirm.

### CODE-3. Refactor completeness
The 4th site (`RecoverLedger`) was caught by the test sweep, not the
issue. Independently grep for OTHER places where:
- Code inside `for rows.Next()` calls any method that internally uses
  `s.db.*` or `h.store.db.*` (not the open cursor / tx).
- Code inside a `tx, _ := s.db.Begin(...)` block calls any method
  that uses `s.db.*` instead of `tx.*`.

Look in: `phase4-coordinator/internal/billing/*.go`. Optionally check
`phase4-coordinator/internal/{requestlog,admission,explorer,buyer,
session,pool}/` for cap=1 deadlock risk now that requestlog is capped
(billing shares its DB; admission and explorer may too).

### CODE-4. Test adequacy
- Does `nested_query_regression_test.go` actually exercise the
  multi-row outer-cursor case for each of the three refactored sites?
  Inserting only 1 outer row would still let cap=1 succeed even with
  a nested-cursor bug. Confirm row counts.
- Does any test prove the cap value lives at `requestlog.OpenStore`
  specifically (not on a test-only handle)?
- Missing-coverage check: empty input, single input, multi-input,
  cap=1 + concurrent caller (e.g. one goroutine running the providers
  handler while another tries `WriteHotPath`).

### CODE-5. Comment quality
- Each refactor carries a 5-line ARCH-3-flagged justification.
  Comments justifying NON-OBVIOUS code (the cap=1 deadlock cause,
  the second-pass shape, the snapshotAtTx existence) — load-bearing
  or noise? Restating-what-the-code-does is noise.
- The `snapshotQueryer` interface — does its doc comment clearly
  explain WHY (the tx vs db distinction) rather than WHAT?

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

Use CRITICAL/HIGH/MEDIUM/LOW. Write the report to
`specs/ARC_3_NESTED_QUERIES_CODE_audit.md` (round suffix on follow-
ups: `_CODE_r2_audit.md`).

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`

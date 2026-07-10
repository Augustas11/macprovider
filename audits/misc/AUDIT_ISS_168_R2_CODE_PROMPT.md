You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), CODE lane, ROUND 2.

R1 returned 1 CRITICAL + 1 MEDIUM + 1 LOW. R2 fixes:

1. **CRITICAL: `Store.Insert` race fix.** `Store.Insert` now acquires a
   single `*sql.Conn` via `s.db.Conn(ctx)` and runs both COUNT and
   INSERT through it. Under SetMaxOpenConns(1), holding the conn blocks
   other writers. Hotpath callers (`InsertExec(ctx, conn, ...)` inside
   BEGIN IMMEDIATE) were already safe.
   New test `TestInsertConcurrentSameGroupProducesMonotonicAttemptN`:
   16 goroutines insert into the same `(account_id, request_id)` group;
   assert each receives a distinct `attempt_n ∈ [0, 15]`.

2. **MEDIUM: mixed-rollout-state regression test.** New
   `TestBackfillAttemptNHandlesMixedRolloutState`: 3 rows inserted (all
   populated), rows 1+2 nulled out, backfill run, asserts final sequence
   is `[0, 1, 2]` — proving the ROW_NUMBER computes over ALL rows
   (preserving row 0's persisted=0 and assigning rows 1,2 to backfilled
   slots), and the UPDATE WHERE attempt_n IS NULL leaves the populated
   row untouched.

3. **LOW: external API break** — noted, acceptable for internal package.

Also (cross-lane CRITICAL ARCHITECT + HIGH SECURITY): hotpath.go +
recovery.go quarantine rule narrowed from "row 3+ always quarantines"
to "only attempt_n==1 with retried==0 quarantines"; the
`if attemptN > 1 { unconditional quarantine }` branch in recovery.go
removed; corresponding billing tests rewritten to assert row 3+ is
CREDITED, not quarantined.

## Verify

- The `Store.Insert` race fix correctly serializes COUNT+INSERT. Is
  the held-conn pattern actually defended against goroutine
  interleaving? Verify by tracing the database/sql Conn lifecycle:
  Conn() acquires from the pool, exclusive until Close().
- The concurrent-insert test runs 16 goroutines under the
  Go runtime's GOMAXPROCS. Is this a meaningful race test?
- The mixed-state test covers `[populated=0, NULL, NULL]`. Does it
  also need to cover `[NULL, populated=1, NULL]` or
  `[NULL, NULL, populated=2]` to prove the ROW_NUMBER respects
  pre-existing values in any position? Edge case worth thinking
  about — though ROW_NUMBER respects the OVER ORDER BY id ASC
  ordering, so it always assigns deterministically.
- The hotpath/recovery quarantine narrowing: does the new contract
  correctly handle the `attempt_n=1 retried=0` case across both
  hotpath and recovery? Look for divergence between the two paths.
- The test rename `TestWriteHotPath_ThirdDerivedAttemptIsAlways
  Quarantined` → `TestWriteHotPath_ThirdDerivedAttemptIsCredited
  UnderMonotonicAttemptN` — was the old test's setup correct? Did
  it actually exercise the row-3+ class, or some other class that
  now needs separate coverage?
- `recovery.go::sameRequestCount` is now unused (`_ = sameRequestCount`).
  Should we remove the variable + the SQL subquery that computes it,
  or keep it for future use?
- Full coordinator test suite `go test ./...` — green?
- Any new race detector findings under `go test -race ./...`?

## Severity rubric

- **CRITICAL**: race still reachable; OR a money-path regression.
- **HIGH**: an R1 finding not actually closed; OR a new contract
  violation between SPEC and IMPL.
- **MEDIUM**: missed test coverage on a MUST.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

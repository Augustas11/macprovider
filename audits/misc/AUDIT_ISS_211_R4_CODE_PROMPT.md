# AUDIT — ISS-211 R4 — CODE lens

## Task

R4 re-audit. R3 surfaced 1 MEDIUM on the code lens (hotpath.go
NULL-account fallback diverged from recovery/endpoints IS-clustering).
R4 aligned hotpath.go to use `account_id IS ?` matching the other
two sites.

Branch: `spec/iss-211-coordinator-account-scope`.

## R4 deltas (relative to R3)

- `phase4-coordinator/internal/billing/hotpath.go`: single
  branchless query using `account_id IS ?` with a nil binding
  for empty AccountID — matches recovery.go and endpoints.go.
- `specs/SPEC-002-coordinator.md` v1.5.0 money-path-scope
  change-log bullet + §11 Money-path narrative both updated to
  describe IS-clustering across all three sites (no longer
  saying "legacy rows continue to use the prior unscoped count").
- `specs/SPEC-005-billing.md` §4.2, §8.2, §15.2, §AC-D10, OQ-1
  all reworded to NULL-with-NULL clustering language.

## What to audit

1. Does the new hotpath.go query (`account_id IS ?` with nil bind
   for empty AccountID) produce identical results to recovery.go
   and endpoints.go in three scenarios:
   - All rows non-NULL same account_id: scoped count = number of
     siblings.
   - All rows NULL account_id (legacy): scoped count = number
     of NULL-account siblings (intra-NULL cluster).
   - Mixed rows (some NULL, some non-NULL): each subgroup is
     isolated; NULL rows do not count non-NULL siblings.
2. Does the existing legacy regression test
   `TestWriteHotPath_DuplicateRequestIDWithoutRetryQuarantinesAttempt`
   still cover the intra-NULL case after the R4 query rewrite?
   (If both inserted rows have empty AccountID, they should still
   cluster and quarantine — the test passing confirms this, but
   verify the contract.)
3. Is there a parameter-binding issue with passing `nil` (`any`)
   to a `database/sql` driver via QueryRowContext for the
   `account_id IS ?` predicate? The modernc.org/sqlite driver
   should handle this correctly, but verify.
4. SPEC drift: does any SPEC-002 or SPEC-005 line still mention
   "unscoped count for NULL account_id" (the pre-R4 wording)?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

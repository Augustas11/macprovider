You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), CODE lane, ROUND 1.

## Scope

SPEC-002 v1.5.2 + SPEC-005 v0.3.3 add a monotonic `attempt_n INTEGER NULL`
column to `request_log` populated at INSERT time, with a backfill subcommand
for legacy NULL rows.

## What landed

**SPEC** (`specs/SPEC-002-coordinator.md` v1.5.2, `specs/SPEC-005-billing.md`
v0.3.3): new column; INSERT-time monotonic write-path; backfill subcommand;
per-column migration state machine `legacy | populating | populated`;
read-side discipline (prefer persisted attempt_n, fall back to v0.3.1 id-ASC
derivation for NULL rows).

**IMPL** (`phase4-coordinator/`):
- `internal/requestlog/store.go`:
  - `Row.AttemptN *int` field added.
  - Schema: `attempt_n INTEGER NULL` in CREATE TABLE + ensureColumns ALTER.
  - `insert()` reworked: computes `COUNT(*) FROM request_log WHERE
    account_id IS ? AND request_id = ?` in the same `execer` (sql.DB /
    Conn / Tx — `execer` interface now includes both ExecContext and
    QueryRowContext), then INSERTs with `attempt_n=count`. If caller
    supplies non-nil `row.AttemptN`, derivation is skipped and supplied
    value is used verbatim (for backfill).
  - `AttemptNStatus` + `AttemptNState(ctx)` reports `legacy |
    populating | populated` + `NullCount` + `TotalCount`.
  - `BackfillAttemptN(ctx)` — one-shot UPDATE using
    `ROW_NUMBER() OVER (PARTITION BY account_id, request_id ORDER BY id
    ASC) - 1` filtered to `attempt_n IS NULL`. Idempotent.
- `cmd/coordinator/backfill_attempt_n.go`: new subcommand
  `coordinator backfill-attempt-n [--check] [--format text|json]`
  routing through OpenStoreReadOnly when `--check`, OpenStore when
  actually backfilling.
- `cmd/coordinator/main.go`: dispatcher + usage text updated.
- `internal/billing/recovery.go` (orphan-detection subquery + main
  SELECT): `COALESCE(rl.attempt_n, id_asc_count_derivation)` so persisted
  attempt_n wins when non-NULL, fallback derivation handles NULL legacy
  rows.
- `internal/billing/endpoints.go` (admin reconcile SELECT): same
  COALESCE pattern.
- `internal/billing/hotpath.go`: **unchanged** — the existing post-INSERT
  `COUNT(*)-1` derivation produces the same value as the just-written
  attempt_n column (since the INSERT populated it inside the same tx).
  No code change needed.

## Tests added

- `TestInsertPopulatesMonotonicAttemptN`: 3 rows in
  `(acct-A, req-A)` → `attempt_n=0,1,2`; new account → new group starting
  at 0; same request_id with NULL account → separate group starting at 0
  (preserves v1.5.0 IS clustering).
- `TestBackfillAttemptNPopulatesLegacyNullRows`: insert 3 rows, null out
  attempt_n to simulate legacy state, run backfill, assert values
  `0,1,2` + state transition `populating → populated` + idempotence on
  second run.

## Verify

- **Race-freeness of INSERT-time COUNT-then-INSERT** under the
  `SetMaxOpenConns(1)` discipline. Is it actually race-free? The COUNT
  and INSERT happen on the SAME connection (`execer` param). Could a
  parallel INSERT through a different goroutine using the same `s.db`
  interleave? (Single-writer pool says no, but verify the ordering
  guarantee against `database/sql` semantics.)
- **Backfill query correctness**: the ROW_NUMBER() OVER PARTITION
  computes ordinals over ALL rows in each group (including any v1.5.2-
  written rows that already have attempt_n). Then the UPDATE filters
  to `attempt_n IS NULL`. Does this produce the SAME values that the
  v0.3.1 fallback derivation would have computed? Specifically: if a
  group has rows in state [populated=0, NULL, NULL] (e.g. row 1 was
  written under v1.5.2, then a v1.5.1 rollback wrote rows 2 and 3 as
  NULL), the backfill must assign `1, 2` not `0, 1` to preserve
  monotonic order.
- **Read-side COALESCE** in recovery.go and endpoints.go — does it
  actually produce the right ordinals during the mixed-state window?
- **Hotpath unchanged claim**: verify hotpath.go's post-INSERT COUNT-1
  derivation actually equals the persisted attempt_n in the v1.5.2
  steady state. (It should: the INSERT wrote `count-before-insert` as
  attempt_n; the post-INSERT COUNT returns `count-before-insert + 1`;
  `count-after-insert - 1 = count-before-insert = attempt_n`.)
- **`execer` interface change** — adding `QueryRowContext` to the
  required set is backwards-incompatible for any third-party callers
  that pass a bare execer. Are there any?
- **Test corpus alignment** — any existing test that previously
  expected `attempt_n` to be derived at read time, that might now see
  a persisted value that differs from the expected derivation?
- **Full suite**: `go test ./...` from `phase4-coordinator` — green?

## Severity rubric

- **CRITICAL**: money-path regression; race in INSERT-time derivation;
  backfill produces wrong ordinals.
- **HIGH**: SPEC↔IMPL divergence; read-side prefers wrong column.
- **MEDIUM**: ambiguity in cross-spec contract; missed test coverage on
  a documented MUST.
- **LOW / NIT**: wording, defensive checks, idempotence on edge cases.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

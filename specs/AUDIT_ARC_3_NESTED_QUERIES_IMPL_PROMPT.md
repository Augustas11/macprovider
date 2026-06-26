# ARC-3 nested-query unwind IMPL Audit Prompt

You are an IMPL auditor. Scope is **only** the phase4-coordinator
nested-cursor refactor + the new `requestlog.OpenStore` cap=1 for issue #21
/ ARCH-3. NOT a fresh audit of unrelated billing code, NOT the
arc-3 production-side reasoning that issue #21 already captures.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries` (origin/main base: eaae922)
- Files in scope (`git diff origin/main -- phase4-coordinator/`):
  - `phase4-coordinator/internal/billing/store.go` (rebuildLegacyConfigSnapshots)
  - `phase4-coordinator/internal/billing/endpoints.go` (providers handler + buyerEquivalentCredits)
  - `phase4-coordinator/internal/billing/snapshot.go` (snapshotAtTx + snapshotQueryer interface)
  - `phase4-coordinator/internal/billing/recovery.go` (RecoverLedger switched to snapshotAtTx)
  - `phase4-coordinator/internal/billing/nested_query_regression_test.go` (new)
  - `phase4-coordinator/internal/requestlog/store.go` (SetMaxOpenConns(1) + SetMaxIdleConns(1))

## What the change does (operator summary — NOT the audit answer)

Issue #21 / ARCH-3 / 2026-06-10 audit QW-5. PR #14 set `MaxOpenConns(1)` on
the shared coordinator `*sql.DB` (requestlog + billing share via
`billing.NewStore(reqLogStore.DB())`) and CI hung deterministically at
`phase4-coordinator/internal/billing` on the slow ubuntu runner. The root
cause was THREE places where billing held an outer `*sql.Rows` cursor open
while running an inner `Query` against the same shared `*sql.DB` — at cap=1,
the inner Query waits forever for the connection the outer cursor pins.
This branch:

1. **`rebuildLegacyConfigSnapshots`** — drains the outer `PRAGMA
   index_list` cursor into a `[]string` of unique-index names, closes
   the cursor, then runs the inner `PRAGMA index_info(name)` per name.
   Also added early `break` once the legacy unique is found.
2. **`providers` handler** — drains the aggregate scan into a typed
   `[]providerSummary` slice (raw scalar fields), closes the cursor, then
   runs `h.sum(...)` per item for `pending_payout_credits`. Pagination
   semantics preserved (drains up to limit+1 rows; the (limit+1)th
   signals "more pages exist").
3. **`buyerEquivalentCredits`** — drains the outer `request_log` scan
   into a typed `[]requestLogScan` slice (raw scalars + parsed
   `time.Time`), closes the cursor, then runs
   `byteEstimatedLedgerGross` + `snapshotAt` per item.
4. **`RecoverLedger` (4th site, caught by the cap=1 test sweep, not
   originally in #21's three confirmed)** — was calling `s.snapshotAt`
   (which uses `s.db`) from inside a tx. At cap=1 the tx pins the only
   connection, and `s.db.QueryRowContext` asks for a second one and
   deadlocks. Added `snapshotAtTx` + `snapshotQueryer` interface and
   switched the in-tx call to it.
5. **`requestlog.OpenStore` cap** — `SetMaxOpenConns(1)` +
   `SetMaxIdleConns(1)` to match `auth.OpenStore` and `audit.OpenStore`.
6. **Regression test** — opens stores via the existing
   `newRequestAndBillingStores` helper (which uses `requestlog.OpenStore`,
   now capped), exercises each of the 3 confirmed sites, plus asserts
   the cap value directly via `store.DB().Stats()`.

`go test ./... -timeout 120s` in phase4-coordinator: green, 15.5s total
(billing 1.2s; ws — the long pole — still 13.3s as expected).

## Audit lenses (apply each independently — do not collapse)

### Lens 1 — correctness of each refactor against the original semantics
- `rebuildLegacyConfigSnapshots`: was the early `break` after finding the
  legacy unique a safe addition? The original code scanned every unique
  index, so the post-loop `hasLegacyUnique` only ever set to true once
  matching. Confirm the early break does not change behavior in any case
  where multiple unique single-column-on-config_hash indexes could exist
  (a real schema or only theoretical?).
- `providers` handler:
  - The drain-up-to-`limit+1` semantics — is the new condition
    `len(scratch) >= limit+1` exactly equivalent to the old "stop at the
    item that would be the (limit+1)th" given the pre-existing
    `LIMIT ?` query already passes `limit+1` to SQL? Specifically: the
    OLD loop used `if len(items) == limit { nextCursor = …; break }`
    (so the limit+1th row was scanned but NOT appended), and the NEW
    flow drains up to limit+1 rows into scratch, then re-applies the
    same `len(items) == limit` gate in the second loop. Confirm
    cursor-on-page-boundary matches.
  - Could the new typed `providerSummary` struct miss any zero-value
    edge case the prior `sql.NullX` direct decoding handled? (Fields
    are the same `sql.NullX` types in the new struct.)
- `buyerEquivalentCredits`:
  - Original loop parsed `ts` inline AND continued early on
    `status == 503`. The new code does the ts parse BEFORE the 503
    filter (so a malformed `ts_utc` in a 503 row would fail-loud now
    where the old code would have skipped it before parsing). Is that
    behavior change acceptable / preferable, or should the filter move
    above the parse to preserve the original behavior?
  - The original `return total, rows.Err()` is now `return total, nil`
    because rows is closed before the second pass; `rows.Err()` is
    already checked above the close. Confirm equivalence.
- `snapshotAtTx` / `snapshotQueryer`: does the new interface and the
  wrapping function preserve the exact error semantics of the original
  (especially the `errors.Is(err, sql.ErrNoRows) → ErrNoSnapshot`
  path)?
- `recovery.go` switch from `s.snapshotAt` → `snapshotAtTx`: trace
  through one full RecoverLedger loop iteration — are there OTHER
  `s.db` calls reachable from inside the tx loop that would also
  deadlock at cap=1? (E.g. via any helper that defaults to `s.db`
  instead of taking a queryer.) The cap=1 test sweep covers
  `TestWriteRequestLogWithIdentity_AllowsRecoveryAfterHotPathFailure`,
  but is there a corner case (e.g. ambiguous attempt path, missing
  identity path) that doesn't fire today and would still deadlock?

### Lens 2 — completeness: any 5th nested-cursor pattern left?
Grep methodology:
- `grep -n "for rows.Next()" phase4-coordinator/internal/billing/*.go`
  found 5 loops + 1 in tests. Two are scan-only
  (validateRequestLog @ store.go:277, byteEstimatedLedgerGross @
  endpoints.go:324, modelsServed @ endpoints.go:481), three were
  refactored (the issue #21 confirmed three), and one is
  settlement.go:71 (all inner work uses `tx.Exec`/`tx.QueryRow` on the
  pinned connection — safe at cap=1 because the cursor + inner queries
  are all on the SAME tx-bound conn).
- The 4th site I caught (RecoverLedger calling `s.snapshotAt` from
  inside a tx) was the canary that exposed the broader class:
  **any in-tx call to a method that uses `s.db.*` deadlocks at cap=1**.
- Auditor task: independently grep
  `phase4-coordinator/internal/billing/` for any other place where
  code inside a `for rows.Next()` loop OR inside a tx block calls
  `h.store.db.*`, `s.db.*`, or any method that internally does. Be
  exhaustive — the test corpus may not exercise every path.
- Also check `phase4-coordinator/internal/{requestlog,admission,session,
  pool,explorer}/` for cap=1 deadlock risk that landed under the new
  requestlog cap. (Admission and session likely use the same shared
  DB.)

### Lens 3 — money-path semantics preservation
- The 3 refactored loops are money-path code (billing reconcile +
  buyer-equivalent computation + the providers admin row). The
  refactor MUST be a semantic no-op against the original loop. The
  package test sweep is green, but the suite is what it is — auditor
  should reason about what the suite does NOT cover:
  - Pagination corner: exactly-limit results, limit+1 results,
    cursor handoff between pages, empty result, single result.
  - 503-row interleaving in `buyerEquivalentCredits` (the ts-parse-
    before-filter ordering change — see Lens 1).
  - `pending_payout_credits` numeric matching the OLD inline
    computation for each provider (the per-row sum query is unchanged,
    just runs AFTER the outer cursor closes).
- Look for behavior-affecting differences in error handling: the OLD
  loops called `writeError`/`return` inline; the NEW loops call
  `rows.Close()` first. Are any error paths now leaving cursors open
  that the old paths didn't? (The defer-rows.Close that the OLD code
  had is gone in the new structure because rows.Close is explicit
  before the second pass.)

### Lens 4 — cap=1 broader exposure
- The new `requestlog.OpenStore` cap is the second cap=1 store on the
  same project (auth + audit already had it; those are isolated DBs).
  requestlog + billing + admission + recovery + (anything else that
  uses `reqLogStore.DB()`) now serialize on one connection.
- Production-side performance impact: at uncapped, Go's
  `database/sql` would silently grow the pool. Now it's serialized.
  Is there a hot-path write that this throttles unacceptably? Trace
  `cmd/coordinator/main.go` (line ~88 per the issue) and the buyer
  request hot path through `WriteHotPath`. Are concurrent inference
  completions now waiting on each other for the single conn?
- Is the existing `PRAGMA busy_timeout=5000` setup in
  `requestlog.OpenStore` still adequate, or does cap=1 change the
  contention model enough that busy_timeout should be longer / shorter?

### Lens 5 — test adequacy
- The new `nested_query_regression_test.go` has 4 tests: the cap
  assertion, plus one per refactored site. Are they sufficient?
- Specifically:
  - Does any test prove the **old** code DID deadlock at cap=1 (e.g.
    by checking-out main and running the new test there) — i.e. does
    the regression test fail on origin/main? (Auditor doesn't need to
    actually do this — just reason about whether the test SHAPE would
    have caught the original bug.)
  - Is there any way for the refactored code to silently regress to
    nested-cursor without the test failing? (E.g. if a future
    contributor "optimizes" the providers handler back to inline
    sub-queries — the test would still pass because cap=1 just
    serializes; the deadlock only fires when the outer cursor has
    MULTIPLE rows. Confirm the test inserts ≥ 2 providers and
    ≥ 1 request_log row — it does, but state it.)

### Lens 6 — comment quality / API hygiene
- The 4 added prose comments (each ARCH-3-flagged) — are they
  load-bearing or noise? Comments justifying NON-OBVIOUS code (the
  fallback gating, the snapshotAtTx existence, the cap=1 rationale)
  are good; comments restating what the code does are noise.
- The new `snapshotQueryer` interface is exported within the package
  (lower-case `snapshotQueryer` — actually unexported). Is that the
  right scope, or should it be exported as `Queryer` for cross-package
  reuse?

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>

HIGH (N):
  H1. ...

MEDIUM (N):
  M1. ...

LOW (N):
  L1. ...

QUESTIONS (N):
  Q1. ...
```

Use CRITICAL/HIGH/MEDIUM/LOW severity. Write the report to
`specs/ARC_3_NESTED_QUERIES_IMPL_audit.md` (or with a round suffix
on follow-ups, e.g. `specs/ARC_3_NESTED_QUERIES_IMPL_r2_audit.md`).

If 0 CRITICAL and 0 HIGH and 0 MEDIUM, end the report with:
`VERDICT: READY TO MERGE arc-3 nested-query unwind`

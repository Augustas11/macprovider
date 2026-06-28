# [BUG] Weekly settlement job drops settlement errors

**File:** [`phase4-coordinator/internal/billing/settlement.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/settlement.go#L152) (lines 152)
**Project:** macprovider
**Severity:** BUG  •  **Confidence:** medium  •  **Slug:** `other-silent-settlement-failure`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

StartWeeklySettlement invokes RunSettlement and discards the returned error. A DB error, lock timeout, or migration/schema problem would make the weekly payout job fail without an audit row, log, retry signal, or caller-visible failure, delaying payouts until someone notices operationally.

## Recommendation

Record failed settlement attempts in the reconciliation/audit table or structured logs, and expose enough status for operators to alert and retry.

## Revalidation

**Verdict:** true-positive

StartWeeklySettlement invokes RunSettlement in its timer goroutine and assigns the returned error to _. RunSettlement can return errors from BeginTx, every Exec/Query/Scan, rows.Err, or Commit, and it does not write a failed reconciliation/audit row on those paths. StartWeeklySettlement has no logger parameter, no status sink, and no retry signal; main.go simply starts the goroutine and cannot observe per-run failures. If SQLite is locked, the schema is broken, or a commit fails at the weekly boundary, the job silently returns to the loop. Because NextMondayUTC is recomputed after the timer cycle, the next automatic attempt is the following week, not an immediate retry. This is therefore a real operational payout failure mode, not just missing polish.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-01)

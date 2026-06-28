# [HIGH_BUG] Settlement uses lexicographic RFC3339Nano timestamp cutoffs

**File:** [`phase4-coordinator/internal/billing/settlement.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/settlement.go#L23-L120) (lines 23, 37, 61, 120)
**Project:** macprovider
**Severity:** HIGH_BUG  •  **Confidence:** high  •  **Slug:** `other-settlement-window-skew`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

RunSettlement compares ts_utc TEXT directly to windowEnd formatted with time.RFC3339Nano. RFC3339Nano is variable-width, so a row at 2026-06-08T00:00:00.5Z sorts lexicographically before 2026-06-08T00:00:00Z because '.' < 'Z'. That lets work completed just after a settlement boundary be quarantined or settled into the prior window, breaking payout-window integrity and letting a provider time requests around the cutoff for earlier payout inclusion.

## Recommendation

Do not range-filter RFC3339Nano strings lexicographically. Store a fixed-width UTC timestamp or integer unix nanoseconds, or use SQLite time functions consistently for cutoff comparisons; add a regression test for rows in the first fractional second after windowEnd.

## Revalidation

**Verdict:** true-positive

RunSettlement compares ledger_request_credits.ts_utc as TEXT against windowEnd.UTC().Format(time.RFC3339Nano) in the quarantine, grouping, and settled-update queries. The hot path and request-log store also write timestamps with time.RFC3339Nano, which is variable-width. For a weekly boundary like 2026-06-08T00:00:00Z, a row at 2026-06-08T00:00:00.5Z compares lexicographically less than the boundary because '.' sorts before 'Z'. That row is chronologically after the window end but satisfies ts_utc < windowEnd, so settlement can include it in the prior payout window and then mark it settled. The request-log pruning code in another package explicitly documents this same RFC3339Nano lexicographic hazard and uses julianday for that reason, but settlement does not. There is no lower-bound filter that would save this, since old under-threshold rows intentionally roll forward and the settlement query only uses ts_utc < end. A buyer/provider timing work just after the cutoff can therefore be paid in the earlier window.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-01)

# [HIGH_BUG] Reconcile silently skips rows when config snapshot lookup fails

**File:** [`phase4-coordinator/internal/billing/endpoints.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/endpoints.go#L250-L355) (lines 250, 253, 353, 355)
**Project:** macprovider
**Severity:** HIGH_BUG  •  **Confidence:** high  •  **Slug:** `other-reconciliation-integrity`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

For non-503 request_log rows, buyerEquivalentCredits calls snapshotAt and simply continues on any error, including ErrNoSnapshot, malformed snapshot JSON, context cancellation, or database errors. The caller then inserts ledger_reconciliation_runs with status='complete'. This can make a range with unreconciled request_log rows appear clean, especially when both providerGross and buyerEquivalent are reduced to zero for the skipped work.

## Recommendation

Do not silently omit contributing rows. Propagate snapshot lookup errors so /admin/ledger/reconcile returns a failure envelope and does not insert a complete run, or explicitly account for/quarantine missing-snapshot rows consistently with recovery.

## Revalidation

**Verdict:** true-positive

In buyerEquivalentCredits, after the request_log row is parsed and no byte_estimated ledger gross is available, the code calls h.store.snapshotAt(ctx, ts). On any error it executes continue at lines 353-355 instead of returning an error or accounting for the row. snapshotAt can return ErrNoSnapshot, database errors, or JSON unmarshal errors from malformed rate_card_json. The outer reconcile handler treats a nil error from buyerEquivalentCredits as success and inserts a ledger_reconciliation_runs row with status='complete'. This means a reconcile range can report clean completion while omitting non-503 request_log rows from buyer_equivalent_credits. Recovery handles missing snapshots by quarantining or surfacing the condition, but the admin endpoint fallback does not. Some context-cancellation cases may be caught by neighboring queries, but missing/corrupt snapshot cases are enough to make the finding real.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-26)

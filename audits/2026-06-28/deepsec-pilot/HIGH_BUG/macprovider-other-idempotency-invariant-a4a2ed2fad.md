# [HIGH_BUG] Schema does not enforce one active credit per request attempt

**File:** [`phase4-coordinator/internal/billing/store.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/store.go#L73) (lines 73)
**Project:** macprovider
**Severity:** HIGH_BUG  •  **Confidence:** medium  •  **Slug:** `other-idempotency-invariant`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

The ledger_request_credits uniqueness constraint is on (request_id, attempt_n, provider_id), so the database permits multiple non-quarantined rows for the same (request_id, attempt_n) if provider_id differs. The hot path and recovery code try to quarantine ambiguous attempts, but the money-path invariant is not enforced at the storage boundary; any recovery/admin/code-path regression can create duplicate active credits that settlement will later pay independently.

## Recommendation

Add a partial unique index such as UNIQUE(request_id, attempt_n) WHERE quarantined = 0, after migrating or quarantining any existing duplicates. Keep separate quarantined rows allowed if needed for forensic history.

## Revalidation

**Verdict:** true-positive

The ledger_request_credits table still has UNIQUE(request_id, attempt_n, provider_id), not a partial unique constraint on request_id and attempt_n for quarantined = 0. That means SQLite accepts two non-quarantined rows for the same request attempt when provider_id differs. Settlement does not detect that invariant violation: it groups active unsettled rows by provider_id and will include each duplicate row in payout-ready totals independently. I traced the current production write paths and did not find an HTTP endpoint that inserts arbitrary ledger rows; WriteHotPath and RecoverLedger try to derive attempts and quarantine ambiguous cases. That application logic reduces direct remote exploitability, but it is not a storage-boundary enforcement of the stated money-path invariant. Any internal recovery/import/admin regression, or direct DB repair mistake, can create a duplicate active state that the current settlement code will pay rather than reject. The current schema and git history show no partial unique index or equivalent database guard has been added.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-26)

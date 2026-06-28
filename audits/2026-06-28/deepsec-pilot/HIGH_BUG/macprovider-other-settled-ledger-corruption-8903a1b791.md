# [HIGH_BUG] Recovery can quarantine already-settled ledger rows

**File:** [`phase4-coordinator/internal/billing/recovery.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/recovery.go#L117-L446) (lines 117, 159, 213, 446)
**Project:** macprovider
**Severity:** HIGH_BUG  •  **Confidence:** medium  •  **Slug:** `other-settled-ledger-corruption`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

Several recovery branches call quarantineExistingLedgerForRequestAttemptTx before the settled-row mismatch guard in reconcileExistingCreditTx. The helper updates any non-quarantined matching ledger row and does not exclude settled rows or rows with settlement_id set. If a settled/payout-backed row later hits the invalid_usage_tokens, missing_config_snapshot, or ambiguous_attempt_n branch, recovery can retroactively mark it quarantined while the payout row remains intact, corrupting settlement reconciliation and provider earnings history.

## Recommendation

Do not quarantine settled rows in this helper. Add `settled = 0 AND settlement_id IS NULL` to the UPDATE and return an explicit error/page condition if a settled row would otherwise need quarantine, matching the existing settled mismatch behavior.

## Revalidation

**Verdict:** true-positive

The current recovery flow still has quarantine branches before the settled-row guard in reconcileExistingCreditTx. The invalid_usage_tokens branch, missing_config_snapshot branch, and attempt_n > 1 ambiguous branch all call quarantineExistingLedgerForRequestAttemptTx directly. That helper updates ledger_request_credits by request_id, attempt_n, provider_assigned_id or resolved provider_id, and quarantined = 0, but it does not filter on settled = 0 or settlement_id IS NULL. The later guard in reconcileExistingCreditTx only protects rows that reach the recomputation mismatch path; these early branches skip that path entirely. A concrete corruption scenario is a request_log row with invalid usage tokens: request_log has no non-negative CHECK, hot-path billing can zero the ledger row, settlement can still mark it settled as part of a provider window, and later recovery will quarantine the settled row from the request_log token check. The payout_ready row and settlement_id remain intact, so reconciliation and earnings history now disagree about whether a payout-backed source row is active. The finding is not fixed in current HEAD; git blame shows the helper and its callers still have no settled-row exclusion.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-26)

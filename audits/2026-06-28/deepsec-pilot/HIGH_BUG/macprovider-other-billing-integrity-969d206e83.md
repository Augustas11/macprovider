# [HIGH_BUG] Reconcile fallback ignores coordinator-estimated completion tokens

**File:** [`phase4-coordinator/internal/billing/endpoints.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/endpoints.go#L303-L357) (lines 303, 343, 353, 357)
**Project:** macprovider
**Severity:** HIGH_BUG  •  **Confidence:** high  •  **Slug:** `other-billing-integrity`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

buyerEquivalentCredits recomputes buyer-equivalent credits from request_log when there is not exactly one matching byte_estimated ledger row, but the request_log scan does not select estimated_completion_tokens. The fallback builds cp from provider-reported completion_tokens and calls ComputeCredits with a nil estimate and usageFor(..., nil), so billableCompletion cannot clamp provider-reported completion to the coordinator-observed estimate. A provider that over-reports completion_tokens can therefore corrupt admin reconciliation totals whenever the ledger row is missing or duplicate, violating the package invariant that provider-reported completion must be bounded by estimated_completion_tokens.

## Recommendation

Select rl.estimated_completion_tokens into the scratch row, build an ep pointer, and call usageFor(errorCode, ep) and ComputeCredits(pp, cp, ep, ...). Add a reconcile regression where completion_tokens exceeds estimated_completion_tokens and the ledger row is absent or duplicated.

## Revalidation

**Verdict:** true-positive

buyerEquivalentCredits scans request_log into requestLogScan, but the SELECT at lines 303-307 includes prompt_tokens and completion_tokens and omits estimated_completion_tokens. If byteEstimatedLedgerGross finds exactly one non-quarantined byte_estimated ledger row, it safely recomputes using that ledger estimate. When that safe path is unavailable because the ledger row is missing, duplicated, not byte_estimated, or lacks an estimate, the fallback builds pp/cp from request_log and calls ComputeCredits with estimatedCompletionTokens set to nil at line 357. usageFor is also called with nil, so billableCompletion has no coordinator-observed bound and will accept provider-reported completion_tokens up to the global maximum. request_log does store estimated_completion_tokens elsewhere and recovery uses it, so this is a local omission in the admin reconcile fallback. The impact is reconciliation integrity rather than direct payout creation: an over-reporting provider can corrupt buyer-equivalent admin totals whenever reconciliation falls back to request_log instead of a single byte_estimated ledger row.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-26)

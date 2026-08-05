# Code audit prompt: prompt-token reconciliation freeze

Review the full local diff for this fix in `/Users/augstar/macprovider-token-reconcile`.

Scope:

- `phase4-coordinator/internal/billing/recovery.go`
- `phase4-coordinator/internal/billing/hotpath.go`
- `phase4-coordinator/internal/billing/store_test.go`
- `audits/2026-08-05/ROOT_CAUSE_prompt-token-reconciliation-freeze.md`

Task:

Find correctness bugs, behavioral regressions, missing tests, or broken repo
conventions. Focus on whether recovery should reconcile existing non-cache rows
with persisted money-contract fields while preserving existing cache and
mismatch protections.

Report findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include concrete
file:line references. If there are no CRITICAL/HIGH/MEDIUM findings, say so
explicitly.

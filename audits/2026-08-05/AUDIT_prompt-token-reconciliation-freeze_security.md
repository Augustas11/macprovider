# Security audit prompt: prompt-token reconciliation freeze

Review the full local diff for this fix in `/Users/augstar/macprovider-token-reconcile`.

Scope:

- `phase4-coordinator/internal/billing/recovery.go`
- `phase4-coordinator/internal/billing/hotpath.go`
- `phase4-coordinator/internal/billing/store_test.go`
- `audits/2026-08-05/ROOT_CAUSE_prompt-token-reconciliation-freeze.md`

Task:

Evaluate money-path abuse and integrity risks. Focus on whether the recovery
change can allow inflated provider credits, hide tampered ledger rows, bypass
operator split checks, bypass cache-discount validation, or weaken enforce-mode
settlement gating.

Report findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include concrete
file:line references. If there are no CRITICAL/HIGH/MEDIUM findings, say so
explicitly.

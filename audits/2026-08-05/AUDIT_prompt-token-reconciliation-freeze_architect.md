# Architecture audit prompt: prompt-token reconciliation freeze

Review the full local diff for this fix in `/Users/augstar/macprovider-token-reconcile`.

Scope:

- `phase4-coordinator/internal/billing/recovery.go`
- `phase4-coordinator/internal/billing/hotpath.go`
- `phase4-coordinator/internal/billing/store_test.go`
- `audits/2026-08-05/ROOT_CAUSE_prompt-token-reconciliation-freeze.md`

Task:

Evaluate whether the fix respects persisted-ledger immutability, settlement
versioning, SPEC-005/SPEC-022 compatibility, and future maintainability. Focus
on the boundary between historical row reconciliation and current config/rate
lookup.

Report findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include concrete
file:line references. If there are no CRITICAL/HIGH/MEDIUM findings, say so
explicitly.

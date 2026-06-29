# AUDIT — ISS-211 R9 — CODE lens

## Task

R9 code re-audit. R8 surfaced 1 trailing MEDIUM (one stale
"cross-account collision" string in a renamed
defense-in-depth test assertion). R9 reworded it.

R8 security + architect already returned ZERO FINDINGS on this
branch state; this is the final code-lane convergence pass.

Branch: `spec/iss-211-coordinator-account-scope`.

## R9 delta

- `phase4-coordinator/internal/billing/store_test.go:267`:
  "non-quarantined ledger rows for cross-account collision" →
  "non-quarantined ledger rows for synthetic internal request_id
  recurrence".

## What to audit

1. Any remaining stale "cross-account collision" / "buyer-controlled
   collision" framing in `phase4-coordinator/internal/billing/`
   tests or production code?
2. The legacy test `TestWriteHotPath_DuplicateRequestIDWithoutRetryQuarantinesAttempt`
   intentionally keeps the original "buyer-controlled-duplicate"
   fixture id (it predates #211 and pins the NULL-account
   quarantine baseline). Is that distinction now clear?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.

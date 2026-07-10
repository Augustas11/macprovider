# AUDIT — ISS-211 R8 — CODE lens

## Task

R8 code re-audit. R7 surfaced 1 MEDIUM (stale buyer-controlled
fixture IDs + assertion messages in store_test.go defense-in-depth
tests). R8 renamed.

Branch: `spec/iss-211-coordinator-account-scope`.

## R8 deltas

- `phase4-coordinator/internal/billing/store_test.go`:
  - `buyer-controlled-duplicate-recovery` →
    `synthetic-internal-uuid-collision-recovery` (in
    `TestRecoverLedger_AccountScopedInternalRequestIDDefenseInDepth`).
  - `buyer-controlled-duplicate` →
    `synthetic-internal-uuid-collision-hotpath` (in
    `TestWriteHotPath_AccountScopedInternalRequestIDDefenseInDepth`).
  - Failure messages reworded from "cross-account request_id
    collision quarantined rows ... issue #211 regression" to
    "synthetic internal request_id recurrence quarantined rows ...
    issue #211 defense-in-depth regression".

Note: the LEGACY test
`TestWriteHotPath_DuplicateRequestIDWithoutRetryQuarantinesAttempt`
intentionally keeps the `buyer-controlled-duplicate` fixture ID,
because that test pins the pre-#211 (NULL-`account_id`) quarantine
behavior under the original buyer-controlled framing — it predates
#211 and is the legacy baseline. R7 audit explicitly distinguished
this case.

## What to audit

1. Are the renamed fixture IDs and assertion messages internally
   consistent with the renamed function names?
2. Is the legacy test's retained fixture ID (`buyer-controlled-duplicate`)
   still appropriate, given it documents the pre-#211 NULL-account
   behavior?
3. Any other stale "buyer-controlled" or "cross-account request_id
   collision" string in code or comments?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

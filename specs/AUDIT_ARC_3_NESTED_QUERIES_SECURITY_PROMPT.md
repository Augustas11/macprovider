# ARC-3 nested-query unwind — SECURITY-lane audit

You are the **security** lane of a three-lane audit (code / security /
architect) of the phase4-coordinator nested-cursor refactor for issue
#21 / ARCH-3. Stay narrowly in your lane — code correctness and
architectural concerns have their own lanes; flag overlap as
`QUESTIONS` rather than mixing scopes.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries` (origin/main base: eaae922)
- Files in scope (`git diff origin/main -- phase4-coordinator/`):
  - `phase4-coordinator/internal/billing/store.go`
  - `phase4-coordinator/internal/billing/endpoints.go`
  - `phase4-coordinator/internal/billing/snapshot.go`
  - `phase4-coordinator/internal/billing/recovery.go`
  - `phase4-coordinator/internal/billing/nested_query_regression_test.go`
  - `phase4-coordinator/internal/requestlog/store.go`

## Why security cares about this diff

This is money-path code — billing reconcile, buyer-equivalent
computation, payout-ready aggregation, provider-credit attribution.
The diff touches:
- A capacity-limiting resource (the shared `*sql.DB` pool now capped
  at 1 connection across requestlog + billing + admission).
- A reconcile path (`buyerEquivalentCredits`) that determines what
  the operator+platform is paid vs what providers are paid.
- An admin endpoint (`providers`) that exposes per-provider credit
  totals + pending payouts.
- A recovery path (`RecoverLedger`) that quarantines or backfills
  missing ledger rows on coordinator restart.

## Security-lane scope (apply each; stay in lane)

### SEC-1. Resource-exhaustion exposure at cap=1
- `requestlog.OpenStore` now caps the shared pool to 1 connection.
  Trace the buyer hot path through `WriteHotPath` (billing) and any
  concurrent caller. Could an adversary (a buyer or a malicious
  provider) trigger a long-running query on this pool that starves
  legitimate writes?
- The existing `PRAGMA busy_timeout=5000` — is 5s tolerable under
  cap=1 contention? Could a sustained admin `/providers?limit=200`
  request now stall money-path writes for the full 5s window?
- The `providers` handler's second pass runs `h.sum(...)` per item
  — up to 200 inner queries serialized on the single conn. Is the
  worst-case latency of that endpoint bounded? Could an admin
  endpoint be weaponized as a self-DoS against the money-path?

### SEC-2. Deadlock-vs-error-handling
- The four refactors trade nested-cursor deadlock for a longer code
  path with more `close+open` cycles. Any new connection-leak path
  if context cancellation fires between the outer cursor's `Close`
  and the second pass's per-row `Query`?
- If the second pass's per-row query fails (e.g. context cancel,
  SQLite busy), the outer scan is already gone — confirm the error
  path doesn't leak partial state into `ledger_payout_ready` or
  `ledger_reconciliation_runs`.
- `snapshotAtTx` is called from inside `RecoverLedger`'s tx loop.
  If the tx is rolled back, does any uncommitted snapshot lookup
  leak any side effect? (Should be none — it's a SELECT — but
  confirm.)

### SEC-3. Money-path semantics tampering
- `buyerEquivalentCredits` is the reconcile primitive. The r2 fix
  moved `time.Parse` to after the 503 filter. Could a crafted
  `request_log` row (status=503 with a malformed ts_utc) now
  silently exclude itself from the reconcile delta where it was
  surfaced as a hard error on the previous refactor pass?
  (Answer: yes, it skips silently — which matches origin/main, so
  this is preservation not regression. Confirm.)
- The `providers` handler — does the second-pass `h.sum(...)` see
  the same db snapshot as the outer aggregate cursor, or could a
  concurrent write between the two passes produce a sum that
  doesn't match the aggregate it was paired with? (At cap=1 the
  passes are serialized on the same conn but not in the same tx.)
- The `rebuildLegacyConfigSnapshots` early `break` — confirm it
  cannot mis-fire to skip the rebuild when a legacy unique DOES
  exist (false-negative would leave the legacy index in place;
  false-positive would rebuild when not needed). Trace via
  schema state.

### SEC-4. Admin endpoint exposure
- `providers` returns `pending_payout_credits` per provider via
  the new second pass. Confirm the value computation is unchanged
  vs origin/main and the same auth-gating applies (operator key
  check).
- `RecoverLedger` is called on coordinator startup; the
  `snapshotAtTx` switch is internal. Confirm no operator-visible
  surface change.

### SEC-5. Test coverage for security-relevant cases
- Does `nested_query_regression_test.go` cover the case where the
  second pass's inner query fails (timeout, busy, context cancel)?
  Today the suite doesn't fault-inject — should it for the money-
  path sites? Note the gap if so.
- Does any existing test prove the providers handler's per-row
  `pending_payout_credits` value matches the origin/main value for
  multi-provider input?
- Could a future "optimization" silently revert one of the four
  refactors? The cap=1 test would still pass (just serializes; no
  deadlock if inner Query happens on the still-pinned conn via a
  cached statement). State whether the test SHAPE actually
  catches a regression.

### SEC-6. Scope of cap=1 change
- The new cap is the third cap=1 store (auth + audit + requestlog).
  requestlog + billing + admission + recovery + anything else
  using `reqLogStore.DB()` now serializes. Walk the call graph:
  every caller of `billingStore.DB()` (or who uses
  `reqLogStore.DB()` directly) inherits this — any path that
  expects concurrency is now a hidden serialization point.
- Money-path write throughput: the hot `WriteHotPath` is one
  tx per buyer request. At cap=1 concurrent inferences serialize
  their billing-write tx. Is the typical billing tx short enough
  that the cap doesn't cap end-to-end throughput below what the
  inference pool can sustain?

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write the report to
`specs/ARC_3_NESTED_QUERIES_SECURITY_audit.md` (round suffix on
follow-ups: `_SECURITY_r2_audit.md`).

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`

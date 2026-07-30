CRITICAL (0):

HIGH (0):

MEDIUM (1):
  M1. Authenticated admin reads can starve money-path billing writes on the cap=1 shared pool.
      Evidence: phase4-coordinator/internal/requestlog/store.go:70 caps the requestlog DB at one open connection; cmd/coordinator/main.go:83 and cmd/coordinator/main.go:88 reuse that same DB for admission and billing; phase4-coordinator/internal/billing/endpoints.go:114-198 lets an operator request `/admin/ledger/providers?limit=200` run one aggregate query plus up to 200 `h.sum(...)` queries without a handler-level timeout; phase4-coordinator/internal/buyer/server.go:136 and phase4-coordinator/internal/buyer/billing_recorder.go:156-200 give hot-path billing/fallback writes only 6s each to acquire/use that same pool.
      Fix:     Keep admin/explorer read traffic off the hot-path capped pool or bound it with a short read timeout and a single aggregate query for pending payouts, so read-heavy operator calls cannot consume the only connection long enough for post-inference billing writes to fail.

LOW (3):
  L1. Providers second-pass payout sums are not snapshot-consistent with the outer aggregate.
      Evidence: phase4-coordinator/internal/billing/endpoints.go:147-185 closes the aggregate cursor before phase4-coordinator/internal/billing/endpoints.go:189-198 runs per-provider `ledger_payout_ready` sums; no transaction spans both passes.
      Fix:     If operator-visible consistency matters, compute pending payout credits in the same SQL statement or run the providers read inside a read transaction.

  L2. Per-row pending payout query errors are silently reported as zero.
      Evidence: phase4-coordinator/internal/billing/endpoints.go:198 calls `h.sum(...)`, and phase4-coordinator/internal/billing/endpoints.go:492-496 converts any query error, including context cancellation or busy errors, into `0`.
      Fix:     Use `sumErr` in the second pass and return an error response instead of emitting partial provider data with false zero pending payouts.

  L3. Regression tests cover cap=1 deadlock shape but not security-relevant failure semantics.
      Evidence: phase4-coordinator/internal/billing/nested_query_regression_test.go:78-105 verifies `/admin/ledger/providers` completes at cap=1 but does not assert multi-provider `pending_payout_credits`; phase4-coordinator/internal/billing/nested_query_regression_test.go:115-141 verifies reconcile completion but does not fault-inject busy, timeout, or cancellation on second-pass inner queries.
      Fix:     Add focused tests for multi-provider pending payout values and second-pass inner-query failure paths, especially that reconcile does not write `ledger_reconciliation_runs` on failure and providers does not return false zeroes.

QUESTIONS (5):
  Q1. SEC-1 overlap with architecture lane: should operator/admin reads share the same `*sql.DB` pool as requestlog, billing, admission, canary sanctions, and explorer after cmd/coordinator/main.go:72-88 and cmd/coordinator/main.go:128 wire all of those surfaces to `reqLogStore.DB()`?

  Q2. SEC-1 overlap with code/architecture lanes: is `/admin/ledger/providers` expected to be a strongly consistent money report? The refactor preserves the previous pending-payout formula, but phase4-coordinator/internal/billing/endpoints.go:147-198 can pair outer aggregate values with later `ledger_payout_ready` sums after concurrent writes.

  Q3. SEC-2 confirmation: the second-pass `buyerEquivalentCredits` error path returns before phase4-coordinator/internal/billing/endpoints.go:258-268 inserts `ledger_reconciliation_runs`, so no partial reconciliation row is committed when per-row work fails.

  Q4. SEC-3 confirmation: phase4-coordinator/internal/billing/endpoints.go:337-342 skips status 503 rows before parsing `ts_utc`; origin/main had the same order at origin/main:phase4-coordinator/internal/billing/endpoints.go:278-283, so malformed 503 timestamps remain a preserved exclusion, not a regression.

  Q5. SEC-4 confirmation: `/admin/ledger/*` remains operator-only at phase4-coordinator/internal/billing/endpoints.go:75-85, and `RecoverLedger` remains startup/internal code called from cmd/coordinator/main.go:318-321; the `snapshotAtTx` switch at phase4-coordinator/internal/billing/recovery.go:153-157 is a tx-bound SELECT with no operator-visible surface.

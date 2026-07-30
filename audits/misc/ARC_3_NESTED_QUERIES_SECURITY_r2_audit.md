CLOSURE on round-1 findings:
  M1 (MEDIUM): PASS — `providers` now folds `pending_payout_credits` into one grouped `LEFT JOIN` statement (`phase4-coordinator/internal/billing/endpoints.go:145-164`), eliminating the per-provider `h.sum` N+1 and the extra connection acquisitions on the cap=1 pool.
  L1: PASS — the provider aggregate and ready-payout aggregate are read by one SQLite SELECT; under WAL this is one read snapshot, so concurrent writes cannot produce a mixed buyer-visible view across `ledger_request_credits` and `ledger_payout_ready`.
  L2: PASS — the per-row swallowing path is gone; query/setup, scan, and cursor errors now return `internal_error` through `writeError` (`phase4-coordinator/internal/billing/endpoints.go:165-197`) instead of silently reporting `0`.
  L3: PASS — `TestProvidersHandler_PendingPayoutAtCap1` now asserts two providers: one ready payout row returns `900`, and one missing payout row returns `0` through the `LEFT JOIN`/`COALESCE` path (`phase4-coordinator/internal/billing/nested_query_regression_test.go:98-147`).
  Q1-Q5: noted as cross-lane (defer to architect; no architect r2 audit artifact is present in this worktree at audit time).

NEW FINDINGS (round 2):
CRITICAL (0): none
HIGH (0): none
MEDIUM (0): none
LOW (0): none
QUESTIONS (0): none

Security-lane notes:
- The new grouped subquery keeps the same payout-row set as the old per-row sum: `WHERE status = 'ready'` on `ledger_payout_ready`, grouped by `provider_id`.
- `COALESCE(pp.pending_payout, 0)` is semantically equivalent to the old `nullInt(h.sum(...))` NULL behavior for providers with no ready payout rows.
- SPEC-005 section 10.1 uses normative `MUST` / `MUST NOT` language for `MaxOpenConns(1)`, nested cursor prohibition, and in-transaction unpinned DB helper prohibition; the prose is not merely advisory.
- Validation run: `go test ./internal/billing -run 'TestProvidersHandler_PendingPayoutAtCap1|TestBuyerEquivalentCredits_NestedCursorAtCap1|TestRebuildLegacyConfigSnapshots_NestedCursorAtCap1' -count=1 -timeout=20s` passed.
- Validation run: `go test ./internal/requestlog -run TestOpenStoreCapsPoolAtOneConn -count=1 -timeout=20s` passed.

VERDICT: security lane READY TO MERGE

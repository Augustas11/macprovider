# SPEC-016 FULL IMPL code review audit r1

**Verdict:** REQUEST CHANGES on 2 HIGH + 3 MEDIUM. Counts:

| CRITICAL | HIGH | MAJOR | MEDIUM | LOW |
|----------|------|-------|--------|-----|
| 0 | 2 | 0 | 3 | 1 |

Scope: SPEC-016 full implementation on `impl/spec-016`, HEAD at audit time `7b49cd7` (prompt requested `47e4f24`; `47e4f24` is an ancestor of `7b49cd7`). 24 primary implementation/test/spec files plus migrations.

## Summary

The cross-step composition (Tuning provider, lease + self-fence, run-now controller, §7.4 reconcile worker, §7.3 read endpoint, pause flag, bootstrap sentinel, import boundary) is coherent and consistent across Steps 1+2+3+4. The blocking findings are:

1. SPEC §4.3 step 7 requires both RPCs at depth >= `confirmation_blocks`; current code computes depth only against `Primary.BlockNumber()` in both `pollCancelOnce` + `pollAndConfirm`.
2. `Runner.RequestHalt` halts only pre-cycle; once `RunOnce` is past the pre-cycle gate, an in-flight row can still pass through allocate / sign / broadcast / claim. The halt primitive is the cross-step "stop processing" authority, so the gate has to apply at every row-loop boundary + every irreversible chain-write site.
3. Admin halt behavior is partial — `run-now` gates on `IsHalted`, but `abandon`, `pause/resume`, `record-funding`, and `record-orphan` are mounted directly.
4. Migrations 0010 + 0012 use bare `ALTER TABLE ADD COLUMN`; the `payout_schema_applied` marker is inserted after executing the file, so a crash between ALTER and marker leaves a rerun in "duplicate column" failure.
5. No single test exercises the full register → ready → broadcast → confirm → claim chain through the HTTP handler.

## Findings

### [full-code:r1-1] HIGH — Confirmation depth checked against only the primary RPC

**File:** `phase4-coordinator/internal/payout/runner.go:813`, `phase4-coordinator/internal/payout/runner.go:1146`

**Confidence:** HIGH

**Issue:** SPEC §4.3 step 7 requires **both** RPCs to return receipts at depth >= `confirmation_blocks`. Both `pollCancelOnce` and `pollAndConfirm` call only `Primary.BlockNumber()` and compute depth from the primary head. A lagging secondary can return the same receipt before it is deep enough, and the runner can mark `confirmed` / claim using single-RPC depth.

**Fix:** Fetch `BlockNumber` from both primary and secondary, require both depths to satisfy the snapshot confirmation threshold; add a regression where primary depth passes but secondary depth fails.

### [full-code:r1-2] HIGH — `RequestHalt` does not stop an in-flight payout cycle

**File:** `phase4-coordinator/internal/payout/runner.go:391`, `phase4-coordinator/internal/payout/runner.go:504`, `phase4-coordinator/internal/payout/runner.go:893`

**Confidence:** HIGH

**Issue:** `RunOnce` checks `halted` only before acquiring the in-flight lock. If the chain-balance worker calls `RequestHalt` during row processing, the current cycle can continue into fresh allocation / sign / broadcast / claim paths. That weakens the halt primitive as the cross-step "stop processing" authority after negative drift or other incident-class halt reasons.

**Fix:** Check `IsHalted()` at row-loop boundaries and before irreversible money-path operations (allocation, signing, broadcast, confirmation, claim); return `ErrRunnerHalted` or a halt outcome without emitting a second halt event.

### [full-code:r1-3] MEDIUM — Admin halt behavior is incomplete/undocumented outside run-now

**File:** `phase4-coordinator/internal/payout/mux.go:313`, `phase4-coordinator/internal/payout/mux.go:322`, `phase4-coordinator/internal/payout/mux.go:328`

**Confidence:** HIGH

**Issue:** `run-now` gates on `IsHalted`, but `abandon`, `pause/resume`, `record-funding`, and `record-orphan` are mounted directly with no halt gate and no explicit documented bypass reason. The audit prompt specifically requires every admin entry point to gate on halt or state its bypass.

**Fix:** Add a small halt-gate wrapper/dependency for admin routes. For endpoints intentionally allowed during halt, encode that as explicit bypass policy, log it, and test halted behavior per route.

### [full-code:r1-4] MEDIUM — Non-idempotent `ALTER TABLE` migrations are not crash-safe

**File:** `phase4-coordinator/internal/payout/migrations.go:73`, `phase4-coordinator/internal/payout/migrations.go:77`, `phase4-coordinator/internal/payout/migrations/0010_cancel_gas_reservation.sql:17`, `phase4-coordinator/internal/payout/migrations/0012_stale_outbox_run_id.sql:12`

**Confidence:** HIGH

**Issue:** Migrations 0010 and 0012 use bare `ALTER TABLE ADD COLUMN`; the applied marker is inserted after executing the file. A crash after ALTER but before recording `payout_schema_applied` leaves rerun in "duplicate column" failure.

**Fix:** Make ADD COLUMN guarded via Go-side `PRAGMA table_info` checks, or execute schema change and applied marker in one safe migration transaction where SQLite permits it.

### [full-code:r1-5] MEDIUM — Missing single end-to-end smoke test

**File:** `phase4-coordinator/internal/payout/runner_test.go:223`, `phase4-coordinator/internal/payout/runner_test.go:234`

**Confidence:** HIGH

**Issue:** `TestRunner_HappyPath_SinglePayout` covers broadcast/confirm/claim, but it seeds `provider_payout_addresses` directly instead of using `ServePayoutAddress`. The combined corpus does not appear to exercise the full cross-step money path (register → ready → broadcast → confirm → claim) in one test.

**Fix:** Add one integration-style test that registers via the HTTP handler, inserts/creates a ready ledger row, runs the runner through broadcast/receipt confirmation, and asserts `ClaimPayoutReady` writes `payout_external_id` and `USDC-BASE`.

### [full-code:r1-6] LOW — `gofmt -l phase4-coordinator/` not clean for one SPEC-016-touched file

**File:** `phase4-coordinator/internal/config/config.go:568`

**Confidence:** HIGH

**Issue:** `gofmt -l` reports `internal/config/config.go`; the diff is comment alignment around payout default caps.

**Fix:** Run `gofmt -w phase4-coordinator/internal/config/config.go`.

## Positive Observations
- `SelectReadyPayouts` correctly joins on `registered_against_hot_wallet = ?`, preventing stale-hot-wallet payout selection.
- `claimAndLog` passes the tx hash as `payout_external_id` and the canonical `"USDC-BASE"` currency.
- Import graph protection is backed by `TestImportGraph_BillingDoesNotImportPayout`.
- `go test -race -count=1 ./...` passed from `phase4-coordinator/`.
- `govulncheck ./...` reported no called vulnerabilities.

## Recommendation

REQUEST CHANGES.

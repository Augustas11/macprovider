# SPEC-016 Step 4 IMPL Code Audit - r6

## Code Review Summary

**Lane:** code-only r6 audit  
**Branch:** `impl/spec-016`  
**Prompt commit under audit:** `e0f7da1`  
**Observed workspace HEAD:** `5a2f42f` (adds the r6 audit prompt only; implementation diff under review remains `e0f7da1^..e0f7da1`)  
**Files Reviewed:** 21 changed Go files, plus SPEC §7.1 lines 3712-3732  
**Total Issues:** 1

### By Severity

- CRITICAL: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 0

### Issues

[HIGH] The insufficient-funds guard runs before deciding whether the row actually needs a new payout transfer

File: `phase4-coordinator/internal/payout/runner.go:451`

Confidence: HIGH

Issue: `RunOnce` checks `runningBalance < row.ProviderCredits` before calling `processRow`. That means the new guard can emit `payout_insufficient_funds`, increment `skipped_funds`, and break `rowLoop` for rows that would not consume hot-wallet USDC in this cycle:

- a row over `PerPayoutCapBaseUnits`, which `processRow` would otherwise emit as `payout_capped` and continue (`runner.go:563`);
- a row that would trip the daily cap before a fresh attempt is inserted (`runner.go:850`);
- a row with an existing confirmed or already-broadcast attempt, where the cycle should poll/claim rather than preflight a new transfer (`runner.go:575` onward).

This is a money-path regression because an over-cap or already-attempted row can halt the entire cycle and prevent later eligible rows from being processed. It also regresses the r5 requirement that `payout_capped` remains reserved for per-payout cap, because an over-cap row with insufficient hot-wallet balance is now reported as `payout_insufficient_funds` instead of `payout_capped`.

Fix: move the balance guard to the point where the runner is about to perform a transfer-consuming operation, after per-payout and per-day cap decisions and after the existing-attempt state machine has determined that a fresh broadcast or rebroadcast is needed. Propagate a distinct insufficient-funds outcome back to `RunOnce` so it can emit the §7.1 event, increment `skipped_funds`, and break the outer loop. Add regression tests for at least: over-per-payout-cap with low balance continues; daily-cap trip with low balance emits `payout_daily_cap_tripped`; existing confirmed attempt with low balance still claims.

### Open Questions (low-confidence findings - surfaced, not blocking)

None.

### r5 Closure Verification

- [code:r5-1] `payout_insufficient_funds`: required §7.1 fields are present; the check happens before sign/broadcast for fresh happy-path rows; successful `rowOutcomePaid` deducts in-memory and `payout_run_finished.skipped_funds` is wired. Not fully closed because the guard is too early and can preempt capped or already-attempted rows.
- [code:r5-2] `payout_daily_cap_tripped`: required fields are present, `rowOutcomeDailyCapTripped` breaks `rowLoop`, and per-payout cap still emits `payout_capped`.
- [code:r5-3] nonce cold-start `ts_utc`: present and shared with nonce cursor write.
- [code:r5-4] cancel reorg fields: `last_seen_block=0` sentinel and `rpc_source="both"` are present.
- [code:r5-5] `CloseIdleConnections`: test uses `ConnState` and asserts request 2 opens a new connection after idle drain.
- [code:r5-6] `Reload` wrapping: `%w: %w` wraps both sentinel and `*BoundViolationError`; test asserts `errors.As`.
- [code:r5-7] sanitized attempted value: test asserts exact `"config_load_failed"`.
- [code:r5-8] gofmt: changed Go files in `e0f7da1` are gofmt-clean. The broader requested `gofmt -l phase4-coordinator/` reports three pre-existing files outside the audited implementation diff.

### §7.1 Sweep

The requested §7.1 rows 3712-3732 were rechecked. Required fields are present for the Step 4 events touched by this fix pass, including `payout_run_started`, `payout_run_finished`, `payout_run_now_invoked`, `payout_paid`, `payout_failed`, `payout_capped`, balance alerts, insufficient funds, daily cap, reorg events, RPC disagreement, chain-balance drift, nonce cold-start, config reload/reject, and registration pause/resume. Additive fields such as `severity`, `run_id`, `outcome`, and `tolerance` were treated as non-breaking telemetry.

### Validation Evidence

- `go test -count=1 ./...` from `phase4-coordinator/`: PASS
- `go test -race -count=1 ./internal/payout/...` from `phase4-coordinator/`: PASS
- `git diff --check e0f7da1^..e0f7da1`: PASS
- `gofmt -l` on changed Go files in `e0f7da1`: PASS
- `gofmt -l phase4-coordinator/`: reports unrelated existing files:
  - `phase4-coordinator/internal/buyer/transport_result_test.go`
  - `phase4-coordinator/internal/config/config.go`
  - `phase4-coordinator/internal/tier2/catalog_di_test.go`
- `lsp_diagnostics`: not available in this Codex tool environment; Go tests were used as the type/build validation substitute.
- `ast_grep_search`: not available in this Codex tool environment; an `rg` static-pattern scan on changed files found no hardcoded-secret, `console.log`, or empty-catch matches.

### Positive Observations

- The r5 tests exercise the intended happy-path insufficient-funds boundary and the daily-cap loop halt.
- RPC failure in `currentHotWalletUSDCBalance` is non-fatal, matching the prompt's observability-only expectation.
- The new daily-cap outcome cleanly separates `payout_daily_cap_tripped` from per-payout `payout_capped`.
- Reorg and config-reload event field repairs are concrete and covered by focused tests.

### Recommendation

REQUEST CHANGES

r6 is **not CONVERGENT**: 0/1/0/0.

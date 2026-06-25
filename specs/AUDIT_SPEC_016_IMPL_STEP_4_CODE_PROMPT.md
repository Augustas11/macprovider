# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 4
IMPL — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT.md`.

HEAD: `dbf7e78`. Branch `impl/spec-016`.

## Files in scope (~1,200 LOC + ~600 LOC tests + docs)

- `phase4-coordinator/internal/payout/config_tuning.go`
- `phase4-coordinator/internal/payout/config_tuning_test.go`
- `phase4-coordinator/internal/payout/reconcile.sql`
- `phase4-coordinator/internal/payout/reconcile.go`
- `phase4-coordinator/internal/payout/payouts.go`
- `phase4-coordinator/internal/payout/runner.go` (Step 4 delta:
  emitBalanceAlerts + RunnerOptions LowBalanceThreshold +
  LowNativeThreshold)
- `phase4-coordinator/internal/payout/rpc.go` (Step 4 delta:
  CallContract + NativeBalance)
- `phase4-coordinator/internal/payout/mux.go` (Step 4 delta:
  step4PathTable + NewMuxStep4)
- `phase4-coordinator/internal/payout/step4_test.go`
- `phase4-coordinator/cmd/coordinator/main.go` (Step 4 delta:
  TuningProvider + ChainBalanceWorker construction +
  startPayoutSIGHUPListener)
- `phase4-coordinator/dist/coordinator.yaml.example` (Step 4
  payout block append)
- `phase4-coordinator/dist/check-deploy-config.sh` (Step 4
  payout deploy gate)
- `phase4-coordinator/dist/payout-runbook.md` (new)

## Code-review checklist

### A. §6.5 TuningProvider

1. `NewTuningProvider` validates the initial snapshot via
   `validateBounds`. The bound matrix is centralised.
2. `Snapshot()` returns the atomic.Value by VALUE (copy).
   Modifications to the returned struct cannot reach the live
   value.
3. `Reload` calls `validateBounds(candidate, perDayCap)`.
   On failure: emit `payout_config_reload_rejected` PAGE +
   return `ErrTuningBoundViolation` + LIVE VALUE RETAINED.
4. On success: atomic.Store + emit one
   `payout_config_reloaded` PAGE PER CHANGED key.
5. The bound matrix constants are easy to find for a future
   SPEC bump.
6. The cross-field `low_balance_threshold <= 2 × per_day_cap`
   is enforced; perDayCap == 0 skips that check (test path).
7. The AST static-check unit test
   `TestTuningStaticCheck_NoSecurityNamespaceReference` actually
   walks the file's identifiers.

### B. §7.4 reconcile.sql + ParseLabeledQueries

1. All 6 labeled queries (A..F) present with the
   `-- @label: X` directive.
2. 3 unlabeled regression queries present.
3. Query (D) filters `is_cancel_self_transfer = 1`.
4. Query (F) excludes `is_cancel_self_transfer` from outflow.
5. Chain-balance recon (unlabeled #3) excludes
   `is_cancel_self_transfer` from outflow.
6. `splitStatements` correctly handles `;` characters in
   comments (no fracturing).
7. `extractLabel` strips ONLY the directive line, not the
   query body.

### C. §7.4 ChainBalanceWorker

1. Both RPCs called via `CallContract`. Both errors → skip
   tick + emit `payout_chain_balance_rpc_error`.
2. Both balances decoded. Either decode failure → skip tick.
3. Tolerance check: `|primary - secondary| > tol` →
   `payout_rpc_disagreement` + skip drift comparison.
4. Drift comparison: `onChain - expected`. Positive over
   tolerance → WARN. Negative over tolerance → PAGE +
   haltRunner callback.
5. `computeExpectedBalance` uses `payout_hot_wallet_funding`
   (sum to_address = hot) MINUS `payout_attempts` (sum from
   hot, confirmed, non-abandoned, non-cancel).
6. Start/Stop bool mirror Runner/Reaper/ReorgPoller pattern.
7. Eager first pass on Start.

### D. §6.2 emitBalanceAlerts

1. Skips both probes when both thresholds are 0.
2. USDC probe uses primary RPC `CallContract`.
3. Native probe uses primary RPC `NativeBalance`.
4. Threshold comparison is correct direction (balance < threshold).
5. Failure on either probe is observability-only (no money-
   path stall).

### E. §7.3 PayoutsHandler

1. Path provider_id MUST match token's provider — 403 on
   mismatch, NOT 401.
2. 401 on missing/empty bearer.
3. 429 on per-provider rate-limit overflow.
4. `is_cancel_self_transfer = 0` filter in queryPayouts.
5. Sliding window correctly prunes expired entries before
   the count check.

### F. mux.go Step 4

1. step4PathTable extends step3PathTable.
2. New route `/providers/{provider_id}/payouts` is in
   RealmProviderToken (NOT RealmOperatorKey).
3. NewMuxStep4 nil-checks every required field.
4. Path-table verifier asserts parity.

### G. main.go Step 4 wiring

1. setupPayout constructs TuningProvider AFTER perDayCap is
   known from security namespace.
2. ChainBalanceWorker haltRunner callback emits PAGE; no
   programmatic auto-halt (operator runbook drives).
3. `startPayoutSIGHUPListener` uses `signal.Notify` with
   ONLY `syscall.SIGHUP`. No SIGUSR1/SIGUSR2 leakage.
4. Shutdown closure stops chainWorker FIRST so a final
   reconcile can fire; runner Stop next; poller Stop after;
   reaper Stop last; lease release only on
   `runnerClean && pollerClean`.

### H. Tests

1. step4_test.go covers reconcile parsing, chain-balance
   drift +/-, RPC disagreement, Stop idempotency, handler
   403 + cancel-filter.
2. config_tuning_test.go covers Reload happy + bound
   violation + every bound at the edge + AST static check.

### I. Ops bundle

1. `dist/coordinator.yaml.example` payout block has
   placeholder strings that the deploy gate would reject.
2. `dist/check-deploy-config.sh` payout gate validates all
   required keys + recognises env:NAME.
3. `dist/payout-runbook.md` covers hot-wallet provisioning,
   cap worksheet, BetterStack synthetics, cutover, key-rotation,
   weekly reconciliation.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-code-r1-audit.md`. Standard
structure (Code Review Summary, By Severity, Findings,
Recommendation).

## Discipline

- Verify each item above against the actual code.
- Don't re-flag patterns Step 1/2/3 already audited; only
  audit the Step 4 delta.
- Wall-clock target: 30-40 min.

=== END PROMPT ===
```

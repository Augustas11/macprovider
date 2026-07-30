# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 4**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r4.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 4
IMPL — round 4.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r4.md`. HEAD: `6eb49c0`.

The r3 audit returned 0 / 1 HIGH / 3 MEDIUM / 1 LOW. The r3 fix-pass
landed at `6eb49c0`. Verify closure + look for new defects.

## Files priority focus

r3 fix-pass touched:
- `phase4-coordinator/internal/payout/rpc.go` (HTTPRPCClient transport field + CloseIdleConnections)
- `phase4-coordinator/internal/payout/rpc_test.go` (EOF blank removed; close-idle test)
- `phase4-coordinator/cmd/coordinator/main.go` (SIGHUP handler accepts TwoRPCs + close-idle on SPKI change)
- `phase4-coordinator/internal/payout/config_tuning.go` (Reload returns changedKeys; BoundViolationError; emit field renames)
- `phase4-coordinator/internal/payout/config_tuning_test.go` (updated tests)
- `phase4-coordinator/internal/payout/runner.go` (RunOnce returns runID; stale producer uses snap.RunInterval)
- `phase4-coordinator/internal/payout/runnow.go` (runnerExecutor interface + injection + ServeRunNow uses returned runID)
- `phase4-coordinator/internal/payout/runnow_test.go` (fakeRunner + halt-race test)
- `phase4-coordinator/internal/payout/reconcile.go` (chain-balance event rename)
- `phase4-coordinator/internal/payout/step4_test.go` (RunOnce callers updated)
- `phase4-coordinator/dist/payout-runbook.md` (new §6 SPKI rotation section + BetterStack alert list)

## Code-review checklist (r4)

### A. r3 closure verification

For each r3 finding:
- [sec:r3-1]/[arch:r3-4.2] HIGH/MEDIUM — SPKI pool close
- [arch:r3-4.1] MAJOR — runner stale-producer
- [code:r3-1] HIGH — run_id correlation
- [code:r3-2]/[sec:r3-2] MEDIUM — §7.1 reload event field names
- [code:r3-3] MEDIUM — chain-balance event rename
- [code:r3-4] MEDIUM — halt-race test
- [code:r3-5] LOW — EOF blank

### B. Reload signature change blast radius

1. `TuningProvider.Reload` return type: `(changedKeys []string, err error)`.
   Verify every caller in the codebase is updated. Grep for the old
   single-error pattern.
2. `changedKeys` correctness: only contains actually-changed keys
   (compare against the old snapshot field-by-field), not all
   present keys.
3. On error (bound violation), `changedKeys` should be `nil` (or
   empty) — the live value was retained. Verify.

### C. RunOnce signature change blast radius

1. `Runner.RunOnce` return type: `(runID string, err error)`.
2. Cadence loop's RunOnce call ignores or uses the runID
   appropriately.
3. Tests that called `RunOnce` are all updated.
4. `RunNowController` uses the returned runID in both the response
   AND the `payout_run_now_invoked` event.

### D. Close-idle composition

1. The SIGHUP handler calls `CloseIdleConnections` ONLY when an SPKI
   key actually changed.
2. The call is on BOTH primary and secondary clients.
3. CloseIdleConnections only closes idle (not active) connections —
   verify by reading the implementation. Active in-flight requests
   complete naturally on the old pin.
4. If the SPKI key changed to empty (operator disabling pinning), the
   verifier-on-next-handshake will skip pinning. Does the close also
   happen? (Should it?)

### E. BoundViolationError

1. `*BoundViolationError` type exposes Field, Attempted, Bound, Actor
   public fields.
2. `validateBounds` returns this concrete type, not a wrapped error.
3. `errors.As` is callable from the SIGHUP handler to extract the
   rejection-event fields.

### F. §7.1 event-field sweep

Re-verify every Step 4 event:
- `payout_run_now_invoked` — run_id, actor, ts_utc + outcome
- `payout_run_started` — run_id, ts_utc
- `payout_run_finished` — run_id, ts_utc, paid/capped/failed/skipped/...
- `payout_runner_halted` — reason, ts_utc + severity=PAGE
- `payout_runner_halted_skipping_cycle` — reason, ts_utc
- `payout_config_reloaded` — key, old_value, new_value, actor, ts_utc, severity
- `payout_config_reload_rejected` — key, attempted_value, bound, actor, ts_utc, severity
- `payout_low_balance` — from_address, usdc_base_units, threshold_usdc_base_units, ts_utc
- `payout_low_native_balance` — from_address, native_wei, threshold_wei, ts_utc
- `payout_chain_balance_drift_positive` — from_address + in_db_expected + on_chain + drift + ts_utc
- `payout_chain_balance_drift_negative` — same as positive + severity=PAGE
- `payout_chain_balance_rpc_disagreement` — primary_balance, secondary_balance, tolerance, hot_wallet, ts_utc (new event; chain-balance only)
- `payout_chain_balance_rpc_error` — see SPEC

### G. Tests

1. New tests for the SPKI close-idle path.
2. New test for the stale-producer snap.RunInterval.
3. New test for the post-RunOnce halt-race branch.
4. Existing tests don't regress.
5. `go test -race -count=1 ./internal/payout/...` clean.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_4-code-r4-audit.md`.
Standard structure.

If 0/0/0/0 — declare CONVERGENT in the output.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```

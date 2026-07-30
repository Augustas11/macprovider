# IMPL audit prompt — SPEC-016 Step 4, **r4 shared context**

Master shared-context block for the round-4 fan-out:
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT_r4.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_SECURITY_PROMPT_r4.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_ARCH_PROMPT_r4.md`

All three lanes are **read-only**.

## Round history

| Round | Code | Security | Arch | Verdict |
|-------|------|----------|------|---------|
| r1 | 0/2/3/1 | 0/1/3/0 | 1/2/1/2 | BLOCK |
| r2 | 0/1/3/0 | 0/1/1/0 | 0/2/0/0 | BLOCK |
| r3 | 0/1/3/1 | 0/1/1/0 | 0/1/1/0 | BLOCK |

## What changed between r3 and r4 (fix-pass commit `6eb49c0`)

### Closed HIGH/MAJOR convergent

1. **[sec:r3-1]/[arch:r3-4.2] HIGH/MEDIUM convergent — SPKI pool retention.**
   `HTTPRPCClient` gained a `transport *http.Transport` field and a
   `CloseIdleConnections()` method. `TuningProvider.Reload` now returns
   `(changedKeys []string, err error)`; the SIGHUP handler in
   `main.go::startPayoutSIGHUPListener` checks whether the changed
   keys include either SPKI field and calls
   `rpcs.Primary.CloseIdleConnections()` + `Secondary.CloseIdleConnections()`
   on a hit. New §6 SPKI-pin-rotation section in
   `dist/payout-runbook.md`.

2. **[arch:r3-4.1] MAJOR — runner stale-producer uses snap.RunInterval.**
   `Runner.RunOnce` now passes `snap.RunInterval` to
   `ProduceStaleOutboxRows`. Closes the last `TuningSnapshot`
   authority gap (per r3 arch enumeration, every other field was OK).

3. **[code:r3-1] HIGH — run_id correlation.** `Runner.RunOnce` now
   returns `(runID string, err error)`. `RunNowController.ServeRunNow`
   uses the returned id for `payout_run_now_invoked` AND the response
   body. Cadence loop's RunOnce call ignores the returned id.

### Closed MEDIUMs

4. **[code:r3-2]/[sec:r3-2] MEDIUM — §7.1 reload event field names.**
   `payout_config_reloaded` now emits `key, old_value, new_value,
   actor, ts_utc, severity`. `validateBounds` returns a structured
   `*BoundViolationError` carrying `Field, Attempted, Bound, Actor`.
   `payout_config_reload_rejected` now emits `key, attempted_value,
   bound, actor, ts_utc, severity`. YAML-load failure path emits
   `key=yaml_parse` with the parse error in `bound`.

5. **[code:r3-3] MEDIUM — chain-balance disagreement schema.** The
   chain-balance worker's event renamed from `payout_rpc_disagreement`
   to `payout_chain_balance_rpc_disagreement` so the SPEC §7.1
   `payout_rpc_disagreement` schema (payout-row receipts) doesn't
   collide. BetterStack alert list updated.

6. **[code:r3-4] MEDIUM — halt-race test coverage.** New
   `runnerExecutor` interface in `runnow.go` with `runnerExec`
   injection field on the controller. New `fakeRunner` in
   `runnow_test.go` lets tests force `ErrRunnerHalted` POST-RunOnce
   while `IsHalted=false` at admission. New
   `TestRunNowController_PostRunOnceHaltRaceReturnsHaltedBody`
   exercises that path.

7. **[code:r3-5] LOW — EOF blank line.** Removed.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `6eb49c0 impl(016): Step 4 r3 fix-pass — close all r3 findings`
- Step 4 is the LAST step. PR opens after the audit loop converges
  to 0/0/0 across all three lanes.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What the r4 lane MUST check

1. **r3 closure verification.** For each of the 7 r3 findings, verify
   the fix matches SPEC and doesn't introduce a new defect class.
2. **Whether the abstraction is exhaustive.** Per r3 arch
   enumeration, every `TuningSnapshot` field now has a documented
   live consumer or restart-only semantics. Verify the same is true
   AFTER the r3 fix-pass — no new field/site added that breaks
   exhaustiveness.
3. **`TuningProvider.Reload` signature change blast radius.** The
   return type changed from `error` to `(changedKeys []string, error)`.
   Verify every caller is updated AND the changedKeys slice is
   correct (only actually-changed keys, not all keys that exist).
4. **`Runner.RunOnce` signature change blast radius.** The return
   type changed from `error` to `(string, error)`. Verify every
   caller is updated (cadence loop, tests, run-now controller).
5. **Pool-close hook composition.** When SPKI pin changes,
   `CloseIdleConnections` fires. Does it race with an in-flight RPC
   request? Does an idle reaper RPC get interrupted? (Probably not —
   `CloseIdleConnections` only closes IDLE connections; active ones
   complete.)
6. **§7.1 PASS.** No more event-field-drift findings. Run a sweep
   on every Step 4 event in the SPEC §7.1 table (lines ~3712-3732).
7. **Test halt-race coverage actually fires the right branch.**
   The new test `TestRunNowController_PostRunOnceHaltRaceReturnsHaltedBody`
   must (a) call `IsHalted()` returning false, (b) call `RunOnce`
   returning `ErrRunnerHalted`, (c) assert 409 + halt body.

## Severity guidance + BLOCK rule (unchanged)

- CRITICAL — money-path defect or data-loss class.
- MAJOR — confirmed bug observable in production.
- MEDIUM — confirmed bug not directly observable but breaks audit
  invariant.
- LOW — cosmetic / docs / minor consistency.

BLOCK only on: new CRITICAL, regression of an r1/r2/r3 finding, or a
SPEC normative violation a future step cannot unwind.

## Output format

Each lane writes findings to its own file:
- `specs/SPEC-016-IMPL-STEP_4-code-r4-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-security-r4-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-arch-r4-audit.md`

Standard structure: Verdict, counts, one section per finding with
`[code:r4-X.Y]` / `[sec:r4-X.Y]` / `[arch:r4-X.Y]` label + severity
+ evidence (file:line) + recommended fix.

**If the lane returns 0/0/0/0, declare CONVERGENT** in the output
file.

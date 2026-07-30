# IMPL audit prompt — SPEC-016 Step 4, **ARCHITECTURE REVIEW lane, round 4**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r4.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 4
IMPL — round 4.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r4.md`. HEAD: `6eb49c0`.

The r3 audit returned 0 / 1 MAJOR / 1 MEDIUM / 0 LOW. The r3 fix-pass
landed at `6eb49c0`. Verify closure + check whether the abstraction
is now exhaustive.

## Architecture focus (r4)

The r1+r2+r3 fix arc has been about establishing `TuningProvider`
and the halt primitive as authorities. r3 enumerated every
`TuningSnapshot` field and found a single remaining gap (runner
stale-producer). r4 closes that AND adds the close-idle hook for
SPKI pool retention.

The r4 question: is the abstraction now **fully** exhaustive, or is
there a new gap revealed by the r3 fix-pass?

### A. TuningSnapshot post-fix re-enumeration

Walk each field again:

| Field | Live consumer site (or restart-only doc) |
|-------|------------------------------------------|
| AddressCoolingOffPeriod | `currentCoolingOff()` at write-time |
| RunInterval | (a) ticker cadence captured at Start (restart-only — documented) (b) stale-age threshold via `snap.RunInterval` in runner.RunOnce (live, post-r3-fix) (c) `3 × Snapshot().RunInterval` in reaper.ReapOnce (live) |
| RunNowMinInterval | `RunNowController.currentInterval()` |
| ConfirmationBlocks | `r.snap().ConfirmationBlocks` per cycle |
| MaxRowsPerRun | per-cycle snapshot |
| ReorgPollWindow | `currentPollWindow()` per poll |
| LowBalanceThreshold | per-cycle snapshot in emitBalanceAlerts |
| LowNativeThreshold | per-cycle snapshot in emitBalanceAlerts |
| RPCURLPrimaryPinSPKI | live read via pinFn() in TLS verifier + CloseIdleConnections on change |
| RPCURLSecondaryPinSPKI | live read via pinFn() in TLS verifier + CloseIdleConnections on change |

Verify each field actually has the named consumer at the right
boundary AND that no new field has been added without a consumer.

### B. TuningProvider.Reload signature change

`Reload` now returns `(changedKeys []string, error)`. Architectural
considerations:

1. The `changedKeys` slice must be computed by comparing snapshots
   field-by-field, NOT by listing all keys present in the candidate.
2. On error, `changedKeys` should be nil (or empty) — the live value
   was retained.
3. The slice order is deterministic (probably alphabetical or
   declaration order) so the SIGHUP handler can rely on it.
4. The SIGHUP handler's "did any SPKI key change" detection should
   be a set-membership check, not a positional one.

### C. RunOnce signature change

`Runner.RunOnce` now returns `(runID string, err error)`. Verify:

1. Every caller is updated (cadence loop, tests, run-now controller).
2. Cadence loop's RunOnce call still works correctly.
3. Test path constructions are clean.

### D. RunNowController + runnerExecutor interface

1. The interface decouples the controller from the concrete Runner.
2. Production wiring still passes `*Runner` (concrete) — the
   interface is for tests, not for prod indirection.
3. The interface contract is minimal: RunOnce, IsHalted, HaltReason.
   Verify no other Runner methods are needed for the controller's
   semantics.
4. fakeRunner in tests satisfies the interface; production Runner
   does too.

### E. SPKI close-idle composition

1. CloseIdleConnections is on the concrete `*HTTPRPCClient`, not
   on the `RPCClient` interface. Verify the SIGHUP handler reaches
   the concrete type through `TwoRPCs`.
2. The close is idempotent — safe to call when no idle conns exist.
3. Active in-flight requests complete; only idle pool members close.
4. Does the close need to happen ATOMICALLY with the
   `TuningProvider.Reload` accept? (Probably no — the verifier
   already uses live read, so the close is just operational
   acceleration.)

### F. Cross-step composition unchanged

1. Shutdown ordering: chainWorker → runner → reorgPoller → reaper,
   lease released only when runnerClean && pollerClean. Verify the
   new close-idle doesn't introduce a deadlock.
2. The runner.go RunOnce signature change ripples through
   cadence-loop test paths — verify they still pass.

### G. Final TuningSnapshot exhaustiveness verdict

Score each field CLOSED / OPEN. If ALL fields are CLOSED — the
abstraction is now exhaustive. State that explicitly.

## Step 4 PR Readiness Matrix (r4)

| Row | Verdict |
|-----|---------|
| §6.5 dual-namespace loader split | ? |
| §7.4 reconciliation queries verbatim | ? |
| §7.4 chain-balance worker drift detection | ? |
| §7.4 negative-drift halt | ? |
| §6.2 balance monitoring emits | ? |
| §7.3 provider-scoped read endpoint | ? |
| §4.2 admin run-now contract | ? |
| §7.1 event field-name compliance | ? |
| TuningProvider authoritative across consumers | ? |
| Halt primitive authoritative across entry points | ? |
| Ops bundle | ? |
| Construction ordering correctness | ? |
| Step 3 advisories addressed or deferred | ? |

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_4-arch-r4-audit.md`.
Standard structure.

If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```

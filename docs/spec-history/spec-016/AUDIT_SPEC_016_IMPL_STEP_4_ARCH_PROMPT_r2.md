# IMPL audit prompt — SPEC-016 Step 4, **ARCHITECTURE REVIEW lane, round 2**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r2.md`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the architect lane (3 of 3) auditing SPEC-016 Step 4
IMPL — round 2.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r2.md`. HEAD: `dd72e0e`.

The r1 audit returned 1 CRITICAL / 2 MAJOR / 1 MEDIUM / 2 LOW. The
r1 findings file is at
`specs/SPEC-016-IMPL-STEP_4-arch-r1-audit.md`. Verify each finding
is closed AND look for new architectural defects.

## Architecture-review focus (r2)

The r1 fix-pass introduced two cross-cutting structural changes:

1. `*payout.TuningProvider` is now an authority — every reloadable
   consumer reads from it at the right boundary.
2. `Runner.RequestHalt` / `IsHalted` is a new primitive — used by
   the chain-balance worker and gating run-now.

The architect lens at r2 must verify the abstractions are
**authoritative across the system** (cf [[audit-cycles-are-design-discovery]]
+ PR #69 fix-pass-4 pattern). The bug class introduced by an
abstraction is "is this primitive used everywhere it should be?"

### A. TuningProvider as authority

1. **Every cycle-boundary read uses the live snapshot.** Find every
   `r.opts.ConfirmationBlocks` / `r.opts.MaxRowsPerRun` /
   `r.opts.LowBalanceThreshold` / `r.opts.LowNativeThreshold` in
   `runner.go` and verify it's now via `r.snap()`. Same for
   `s.CoolingOffPeriod` in addresses.go (must be currentCoolingOff),
   `p.PollWindow` in reorg.go (currentPollWindow), and
   `r.staleAge` in reaper.go (currentStaleAge).
2. **No NEW site captures Tuning fields at construction.** Any
   future helper that takes `time.Duration` for cooling-off or
   `int` for max-rows needs to accept `*TuningProvider` or
   `TuningSnapshot` instead. Verify the r1 fix-pass didn't leave
   any leaked-at-construction value in the four consumers.
3. **The `activeSnap` field on Runner is single-cycle-scoped.** The
   `mu+inFlight` mechanism guarantees no concurrent reader.
   Verify this is robust to re-entry (e.g. RunOnce called from
   within RunOnce — which can't happen, but the assertion should
   be defensible).
4. **Ticker cadence is the documented limitation.** Verify Runner
   `loop`, ReorgPoller `Start`, Reaper `Start` capture
   `RunInterval` at Start. The docstring/code comment must call
   this out so a future maintainer doesn't add a SIGHUP-triggered
   ticker reset attempt without thinking it through.

### B. Halt primitive as authority

1. **Every entry into the payout cycle gates on IsHalted.** Find
   every path that calls `RunOnce` or otherwise advances a payout
   row:
   - Cadence loop's RunOnce call (top of cycle check should suffice)
   - Admin run-now
   - Any test path that calls RunOnce directly
   - ProduceStaleOutboxRows (does this run before or after the halt
     check? what does SPEC §7.4 say should happen on halted runner
     w.r.t. stale outbox?)
   Verify the halt is observable + correctly gates each path.
2. **Halt-state initialization.** A newly-constructed Runner has
   `halted == false`. After RequestHalt, all queries return
   consistent state. No torn read.
3. **No path clears halted.** Search for any code that calls
   `r.halted.Store(false)` — there should be NONE; halt is
   process-restart-required. If there is one, flag as defect.
4. **Composition with shutdown ordering.** chainWorker.Stop runs
   BEFORE runner.Stop in the shutdown closure. After a halt,
   shutdown should proceed normally (no deadlock between
   RequestHalt and Stop's wait-for-done).

### C. SIGHUP path architecture

1. **LoadPayoutTuningOnly is the right surface.** Compare with
   the existing tier2 `reloadTier2Config` pattern — does the
   payout SIGHUP path mirror it (atomic swap on success; live
   value retained on failure; PAGE emit per changed key)?
2. **YAML parsing isolation.** The tuning-only loader must not
   accidentally bring in payout.security via inherited struct tags.
   Verify the new struct type.
3. **TuningProvider.Reload composition.** The SIGHUP handler →
   TuningProvider.Reload → atomic.Store path is the only path that
   mutates the live snapshot. Verify no other write site exists.

### D. Cross-step composition

1. **Step 1+2+3+4 shutdown ordering.** The shutdown closure stops:
   chainWorker → runner → reorgPoller → reaper, then Release if
   `runnerClean && pollerClean`. Verify chainWorker.Stop doesn't
   block on something else (e.g. RequestHalt has been called and
   the worker now expects a callback).
2. **Mux composition.** Step4Mux extends Step3Mux extends Step2Mux.
   The new run-now-halted 409 is in ALL three mux levels (Step2/
   Step3/Step4 each have their own run-now handler since the path
   table extends). Verify.
3. **Test path composition.** The Tuning field is optional (nil
   means use static fields). Verify the existing test corpus
   (Step 1/2/3 tests) doesn't break because they construct
   AddressesService/Runner/etc. WITHOUT a TuningProvider.

### E. PR-opening readiness

1. Run the full coordinator test suite — verify no regression.
2. Verify all r1 advisories have either been closed or explicitly
   deferred with a named follow-up.
3. Step 4 audit-prompt files exist for r2.
4. Check the Step 3 advisories. Were any closed by Step 4 r1 fix
   pass? Document.

### F. New defects introduced

1. **`activeSnap` zero-value sentinel.** `r.snap()` falls back to
   `currentTuning()` when `r.activeSnap.ConfirmationBlocks == 0`.
   This is a sentinel. Is `ConfirmationBlocks == 0` truly
   impossible during an active cycle? The bound matrix says
   `confirmation_blocks` must be in [5, 200], so 0 is rejected at
   parse + reload time. Verify there's no startup race where the
   field is zero-initialized but a cycle is in flight (unlikely
   given construction order, but worth checking).
2. **Halt race during construction.** Runner is constructed
   stopped; RequestHalt before Start is allowed but never
   observed. Verify.
3. **Resource leaks in the halt path.** RequestHalt does not call
   Stop on the chainWorker; the worker continues to run, which is
   intentional (so it keeps the operator informed). Verify the
   worker handles repeated negative-drift detections after halt
   gracefully (does it keep emitting PAGE? once per cycle? or
   once-only?).

## Step 4 → PR readiness matrix (r2)

| Row | Verdict |
|-----|---------|
| §6.5 dual-namespace loader split | ? |
| §7.4 reconciliation queries verbatim | ? |
| §7.4 chain-balance worker drift detection | ? |
| §7.4 negative-drift halt | ? |
| §6.2 balance monitoring emits | ? |
| §7.3 provider-scoped read endpoint | ? |
| Ops bundle (yaml.example + deploy gate + runbook) | ? |
| 4-background shutdown composition | ? |
| TuningProvider authoritative across consumers | ? |
| Halt primitive authoritative across entry points | ? |
| Step 3 advisories addressed or deferred | ? |

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-arch-r2-audit.md`. Standard structure.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```

# AUDIT_PROVIDER_IDLE_PREWARM_R2 — three lanes, ROUND 2

Round 1 audit findings (all fixed):

- **CODE H1** — `IdlePrewarmer.stop()` shutdown race (didn't await
  loop task, no cancellation check between `runTick()` awaits and
  `fireWarmup()`).
- **CODE H2** — HTTP handler ordering race (called
  `cancelInflightPrewarm()` before `providerStatus.beginRequest()`;
  tick could fire prewarm concurrent with real inference).
- **CODE M** — test coverage gaps (13 vs required 14 cases, missing
  SIGINT case, missing amplification cooldown case).
- **SECURITY M** — prewarm amplification: `runTick()` only checked
  `lastActivityAt`, so once idle threshold crossed, every tick fired
  a new prewarm indefinitely.
- **ARCHITECT M** — `--idle-prewarm-on-battery` was a bare positive
  flag with no inverse, breaking CLI > yaml precedence.

Fixes applied in the R1 → R2 delta:

- Actor stopped-flag + `stop()` awaits `loopTask.value`; tick checks
  the flag between awaits and immediately before fire.
- HTTP handler now bumps `providerStatus.beginRequest()` BEFORE
  calling `cancelInflightPrewarm()`, then dispatches.
- Tick has a second actor-owned "double-check" of
  `requestsInFlight` and idle time right before `fireWarmup()`.
- `ProviderStatus.secondsSinceLastActivityOrPrewarm()` new method
  returns `min(now - lastActivityAt, now - lastPrewarmAt)`;
  `runTick()` uses it. `noteInternalPrewarm(at:)` called on prewarm
  START.
- `--idle-prewarm-on-battery` now uses `inversion: .prefixedNo` (or
  equivalent), so `--no-idle-prewarm-on-battery` overrides yaml
  back to false.
- New tests: `testPrewarmSkipsOnSerious`,
  `testPrewarmSkipsOnCritical` (previously combined),
  `testPrewarmDoesNotFireAgainWithinIdleThreshold`,
  `testShutdownDuringInflightPrewarmCompletesWithinBoundedTime`,
  and `--no-idle-prewarm-on-battery` yaml-override case.

R1 LOW / INFO findings ship as-is with PR-body documentation and
are NOT expected to be fixed in this round.

## Your task

You are running the CODE, SECURITY, and ARCHITECT audit lanes
against the R1 → R2 delta. Audit ONLY the fixes for the five
findings above and their supporting test additions. Do not
re-litigate R1 findings; do not re-audit code that R1 already
accepted at 0 C/H/M.

### CODE lane focus for R2

- Correctness of the stopped-flag semantics: no lost-update on
  concurrent stop/tick.
- The `await loopTask.value` path in `stop()` handles the case where
  `loopTask` was never started (start not called).
- The "double-check" in `runTick()` uses actor-isolated reads (i.e.
  the second read of `requestsInFlight` happens INSIDE the actor's
  isolated context after all preceding awaits).
- HTTPServer ordering swap does not break existing streaming /
  non-streaming test cases.
- `secondsSinceLastActivityOrPrewarm()` semantics: verify
  `min(now-a, now-b)` = "the more recent one", i.e. `max(a, b)` in
  time — correct direction.
- `noteInternalPrewarm(at:)` called on START, not COMPLETION, so
  cancelled prewarms still count toward cooldown.
- New tests use bounded waits (< 5 s per BUILD prompt AC6).

### SECURITY lane focus for R2

- The amplification fix actually closes the loop: with defaults
  (tick=5, threshold=30, prewarm-cooldown=30), a hostile config
  cannot cause more than one prewarm per idle_threshold_seconds.
- The `noteInternalPrewarm` START timing preserves the cooldown
  even under cancellation (a HTTP-handler-triggered cancel between
  ticks does NOT reset the cooldown clock, so an attacker who spams
  1-token requests cannot rapidly resume amplification).
- CLI `--no-idle-prewarm-on-battery` closes the yaml-override
  security gap for battery-drain amplification.

### ARCHITECT lane focus for R2

- The CLI flag change follows ArgumentParser's `inversion:
  .prefixedNo` idiom, consistent with any other invertible flags
  present in the phase3-binary codebase.
- Actor stopped-flag pattern is consistent with any other
  actor-lifecycle patterns present.
- No scope creep — the fix touched only files listed in R1
  MUST-change scope.

### Do NOT flag

- Anything already accepted in R1 (config surface, IOKit release
  discipline, receipt-path bypass, etc.).
- R1 LOW / INFO findings (deferred by design):
  - ARCHITECT L1 (prewarmer start before HTTP listener bound)
  - ARCHITECT L2 (`currentState()` vs `currentThermalState()` naming)
  - ARCHITECT L3 (`powerSource` default, unused `clock`)
  - ARCHITECT I1 (activity-tracking comment grouping)
  - SECURITY L1 (operator prompt printed raw at startup)
  - CODE R1 LOW (real Task.sleep in tests — kept per convention)
- Anything outside the R1 → R2 delta.

## Output format

Three separate status lines, one per lane:

```
STATUS: CODE lane R2 — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
STATUS: SECURITY lane R2 — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
STATUS: ARCHITECT lane R2 — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

For each finding, one paragraph: file:line, defect, concrete
failure scenario, proposed fix.

## Diff to audit

`git diff` in the worktree shows the full accumulated R1+R2 change.
The R2 delta is:

- `IdlePrewarmer.swift`: stopped-flag, `stop()` await, double-check
  in `runTick()`, `secondsSinceLastActivityOrPrewarm()` gate,
  `noteInternalPrewarm` on start.
- `HTTPServer.swift`: order swap of `beginRequest()` before
  `cancelInflightPrewarm()`.
- `ProviderStatus.swift`: new `secondsSinceLastActivityOrPrewarm()`
  method + `lastPrewarmAt` update on start.
- `MacProviderCLI.swift`: `--idle-prewarm-on-battery` flag
  `inversion: .prefixedNo`; resolution site updated.
- `IdlePrewarmerTests.swift`: 5 new / restructured cases.

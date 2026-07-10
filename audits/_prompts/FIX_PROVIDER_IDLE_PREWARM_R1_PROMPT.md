# FIX_PROVIDER_IDLE_PREWARM_R1 — apply all R1 audit findings

Round 1 three-lane audit returned the following findings that must be
fixed before ship:

## CODE HIGH #1 — stop() shutdown race

**File:** `phase3-binary/Sources/macprovider-cli/IdlePrewarmer.swift`
around line 176.

**Defect:** `stop()` cancels `loopTask` but does not `await` its
completion. `runTick()` has multiple suspension points (calls to
`providerStatus.snapshot()`, `modelRuntime.isLoaded`, etc.) with no
cancellation check before `fireWarmup()`. If shutdown lands while a
tick is between the snapshot/isLoaded awaits, `stop()` can return
with `inflight == nil`, then the cancelled loop resumes past the
suspension point and starts a NEW warmup after shutdown supposedly
completed.

**Fix:**

1. Add a `stopped: Bool` (or `state: enum { .idle, .running, .stopping,
   .stopped }`) flag on the actor.
2. `stop()` sets `stopped = true`, cancels `loopTask`, cancels any
   inflight prewarm, then `await`s `loopTask.value` (or `?.value`)
   before returning.
3. `runTick()` checks `stopped` (or `Task.isCancelled` on the ambient
   task) after EACH `await` and immediately before `fireWarmup()`.
4. When `stopped` is observed, exit the tick cleanly without firing.
5. Ensure `runOneTickForTest()` respects the same `stopped` gate so
   tests behave deterministically.

## CODE HIGH #2 — cancel-vs-begin ordering race

**File:** `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
around line 276 (real-request handling in `handleChatCompletions`).

**Defect:** the HTTP handler calls `idlePrewarmer.cancelInflightPrewarm()`
BEFORE `providerStatus.beginRequest()` (or equivalent
`noteRealRequestStart()`). A tick that has already observed
`requestsInFlight == 0` and `idle_since >= threshold` can be
suspended at an await, get past the "should I fire?" checks, and
then fire `fireWarmup()` AFTER the HTTP handler's `cancelInflightPrewarm()`
returned (because there was no inflight yet), while a real inference
starts on the same MLX runtime.

**Fix:**

1. In `handleChatCompletions` (and the streaming variant if separate),
   call `providerStatus.beginRequest()` / `noteRealRequestStart()`
   BEFORE `cancelInflightPrewarm()`. Order:
   a. `beginRequest()` (bumps `requestsInFlight`, updates
      `lastActivityAt`).
   b. `cancelInflightPrewarm()` (cancels anything already running).
   c. Actual `modelRuntime.complete()` / `.stream()` dispatch.
2. In `IdlePrewarmer.runTick()`, add a FINAL actor-owned busy /
   activity recheck immediately before `fireWarmup()`:
   ```swift
   // Re-check inside the actor after all preceding awaits so a
   // real request that raced in between the initial snapshot and
   // the fire decision can't be preempted by the prewarm.
   let snap = await providerStatus.snapshot()
   guard snap.requestsInFlight == 0 else { emitSkipped(.busy); return }
   let idle = await providerStatus.secondsSinceLastRealActivity()
   guard idle >= config.idleThresholdSeconds else {
       emitSkipped(.notIdleYet); return
   }
   ```
3. This "double check" pattern is standard for actors with async
   observation windows and is not redundant — the first check
   short-circuits cheap ineligible ticks, the second closes the race.

## SECURITY MEDIUM — prewarm amplification (every-tick vs every-interval)

**File:** `phase3-binary/Sources/macprovider-cli/IdlePrewarmer.swift`
around line 207 (the tick-eligibility check).

**Defect:** `runTick()` checks
`providerStatus.secondsSinceLastRealActivity()` but prewarms do NOT
advance `lastActivityAt` (that's a REAL-request tracker). Once idle
threshold is crossed, every subsequent tick fires another prewarm
until real traffic arrives. With `tick_seconds: 1`,
`idle_threshold_seconds: 5`, `max_tokens: 8`, `run_on_battery: true`
(all valid per current validation), you get 8 tokens of GPU work
every second indefinitely.

**Fix:**

1. Extend `ProviderStatus.secondsSinceLastRealActivity()` to be
   `secondsSinceLastActivityOrPrewarm()` that returns
   `min(now - lastActivityAt, now - lastPrewarmAt)`. Rename call sites
   if the semantic differs from what other callers want; otherwise
   keep the original method and add a NEW
   `secondsSinceLastActivityOrPrewarm()` for the prewarmer only.
2. In `runTick()`, gate on `secondsSinceLastActivityOrPrewarm() >=
   config.idleThresholdSeconds` instead of the activity-only version.
3. `noteInternalPrewarm(at:, elapsedMS:)` already updates
   `lastPrewarmAt`; make sure it's called on prewarm START (not
   completion) so cancellations still count against the cooldown.
4. Add a new test case: `testPrewarmDoesNotFireAgainWithinIdleThreshold`
   that fires one prewarm, advances clock < idleThreshold, ticks, and
   asserts zero additional fires. Add another case that advances
   clock ≥ idleThreshold and asserts one additional fire.

## ARCHITECT MEDIUM — `--idle-prewarm-on-battery` non-invertible

**File:** `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
around line 98 (`@Flag(name: .customLong("idle-prewarm-on-battery"))`).

**Defect:** the flag is a bare positive `@Flag` that only turns
`run_on_battery` ON. If yaml has `idle_prewarm.run_on_battery: true`
and the operator wants to disable for a single serve invocation via
CLI, they cannot — the flag has no inverse. This breaks the stated
CLI > yaml > default precedence for this specific knob.

**Fix:**

1. Change the flag definition to use ArgumentParser's inversion:
   ```swift
   @Flag(
       name: .customLong("idle-prewarm-on-battery"),
       inversion: .prefixedNo,
       help: "Allow idle prewarm while running on battery. Default off."
   )
   var idlePrewarmRunOnBattery: Bool?
   ```
   (Or the equivalent `@Option(name: ...)` with `Bool?` if `@Flag`
   inversion doesn't yield an optional; the key requirement is that
   both `--idle-prewarm-on-battery` and `--no-idle-prewarm-on-battery`
   are valid CLI flags, and the ABSENCE of both preserves the yaml
   value.)
2. Update the resolution site (around line 322 in the same file) to
   pass the optional through instead of mapping `true ? true : nil`.
3. Add a test case exercising `--no-idle-prewarm-on-battery` overriding
   a yaml `run_on_battery: true` back to false.

## CODE MEDIUM — test coverage gaps

**File:** `phase3-binary/Tests/macprovider-cliTests/IdlePrewarmerTests.swift`

**Defect:** AC3 in the BUILD prompt lists 14 distinct test cases;
current file has 13, combining `.serious` and `.critical` thermal
into one test. Also uses real `Task.sleep` (lines 9, 183, 371) for
tick timing, and AC4 uses `ProviderStatus.snapshot()` instead of a
coordinator-heartbeat spy. AC6 (SIGINT during in-flight prewarm) is
absent.

**Fix (minimum viable — do NOT over-engineer):**

1. Split `.serious` and `.critical` thermal skip into two separate
   `testPrewarmSkipsOnSerious` and `testPrewarmSkipsOnCritical` cases.
2. Add `testPrewarmDoesNotFireAgainWithinIdleThreshold` (from
   SECURITY MEDIUM fix above).
3. Add `testShutdownDuringInflightPrewarmCompletesWithinBoundedTime`
   that simulates SIGINT during an inflight prewarm and asserts the
   full `IdlePrewarmer.stop()` returns within 5 seconds (per AC6).
4. **Do NOT** rewrite the whole test file to use an injected Clock
   protocol — that's a much larger change and the LOW-tier concern
   (real sleeps around 40 ms per test) is acceptable per repo
   convention for LOW-severity test hygiene. Focus on new coverage,
   not migrating existing.

## What NOT to fix in this round

- All LOW / INFO findings from R1 ship as-is with PR-body
  documentation:
  - ARCHITECT L1 (prewarmer start before HTTP listener bound)
  - ARCHITECT L2 (`currentState()` vs `currentThermalState()` naming)
  - ARCHITECT L3 (`powerSource` param not defaulted, `clock` unused)
  - ARCHITECT I1 (comment grouping on activity-tracking region)
  - SECURITY L1 (operator prompt printed raw at startup)

## Deliverables

- Updated `IdlePrewarmer.swift`, `HTTPServer.swift`,
  `ProviderStatus.swift`, `MacProviderCLI.swift`, and
  `IdlePrewarmerTests.swift`.
- No changes to files outside the R1 diff scope.
- All existing tests must still pass.
- New tests must pass.
- No new SwiftPM dependencies.

## After you finish

1. Run `cd phase3-binary && swift build --product macprovider-cli`.
2. Run `cd phase3-binary && swift test --filter IdlePrewarmerTests`.
3. Run `cd phase3-binary && swift test` (full suite must remain
   green).
4. Print a short summary of the applied changes ordered by finding
   (H1, H2, S-M, A-M, C-M).

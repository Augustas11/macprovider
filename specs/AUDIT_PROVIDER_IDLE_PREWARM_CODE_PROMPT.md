# AUDIT_PROVIDER_IDLE_PREWARM_CODE — CODE lane

You are auditing the diff that implements the provider idle-prewarm
described in `specs/BUILD_PROVIDER_IDLE_PREWARM_IMPL_PROMPT.md`. Read
that file for the behavioural contract, then read the diff.

## Your lane: CODE correctness

Focus exclusively on code-correctness bugs. Not security, not
architecture. Assume the design in the BUILD prompt is fixed.

### Look for

1. **Actor + Task lifecycle**
   - Background tick loop is a `Task.detached` or `Task { }` owned by
     the actor and stored so `stop()` can `.cancel()` it.
   - `Task.sleep(nanoseconds:)` (or injected `Clock.sleep`) is
     `try await` and honours `Task.isCancelled`.
   - No `Task { }` leaks — every spawned task's handle is retained.
   - First tick fires after ONE full interval (not immediately).
   - Stopping the actor cancels the tick loop AND any in-flight
     prewarm task within one boundary check.

2. **Cancellation propagation**
   - `cancelInflightPrewarm()` sets a cancel flag AND cancels the
     inflight prewarm `Task` if any.
   - `shouldCancel` closure passed into `runInternalWarmup` reads a
     `Sendable` state that gets flipped on real-request arrival.
   - No path where `shouldCancel` returns false but the surrounding
     task was cancelled (deadlock risk).
   - Cancellation during MLX token generation aborts on next token
     boundary — no infinite loop.

3. **Concurrency / race conditions**
   - `isPrewarmInflight` state read + set is inside the actor (safe by
     actor isolation).
   - The tick loop checks `isPrewarmInflight` BEFORE deciding to fire.
   - HTTP handler's `cancelInflightPrewarm` call is `await`ed before
     the real inference begins so ordering is guaranteed.
   - No data race on `providerStatus.lastActivityAt` — reads and
     writes both go through the actor's async surface.
   - `ProviderStatus.noteRealRequestStart()` is called from the HTTP
     handler with proper `await`.

4. **Config validation**
   - New validation branches trigger correctly for each of the 6
     knobs' out-of-range values.
   - Validation error messages name the offending field.
   - Defaults applied when field absent from yaml.

5. **Battery detection**
   - `PowerSourceReporting` protocol is used in production and in tests.
   - IOKit CFTypeRef objects (`IOPSCopyPowerSourcesInfo` return value,
     `IOPSCopyPowerSourcesList` return value) are released via
     `CFRelease` — no leaks.
   - Absence of power source objects returns `.unknown`, treated as
     "not on battery" per R9.

6. **Thermal detection**
   - Prewarmer polls `thermalGate.currentThermalState()` at the actor
     level, not caching a value across ticks.
   - `.serious` and `.critical` both cause skip; `.nominal` and
     `.fair` both allow fire.

7. **Idle threshold logic**
   - `providerStatus.secondsSinceLastRealActivity()` uses monotonic
     clock (or `Date().timeIntervalSince(lastActivity)`) — not
     wall-clock-jump-sensitive on system clock changes.
   - `lastActivityAt` bumps on request START (not just end) so a
     long-running request keeps the "recent activity" window active.
   - Values compare correctly at boundary (idle == threshold).

8. **runInternalWarmup contract**
   - Does NOT call `providerStatus.noteRealRequestStart()` or
     `.noteRealRequestEnd()`.
   - Does NOT increment `requestsTotal` or `requestsInFlight`.
   - Does NOT emit `ReceiptAudit` lines.
   - Does NOT contribute to throughput / latency metrics.
   - DOES call `providerStatus.noteInternalPrewarm(...)` for
     observability only.
   - Uses the SAME MLX inference path as `complete()` for Metal-warmup
     effect.
   - Bounded `maxTokens` [1, 8] and `prompt` length [1, 64] enforced
     at load time (not runtime).

9. **Observability**
   - Each event name (`idle_prewarm_fired`, `idle_prewarm_completed`,
     `idle_prewarm_skipped`, `idle_prewarm_cancelled_by_real_request`,
     `idle_prewarm_failed`) is emitted exactly once per lifecycle.
   - Fields match R6's list; no field name typos.
   - `idle_prewarm_skipped` fires at most once per tick with the
     tightest reason (per R6 last sentence).

10. **Test coverage matches AC3**
    - All 14 AC3 test cases present as distinct tests.
    - Tests use injected fake clock + fake `ThermalStateProviding` +
      fake `PowerSourceReporting` + spy `ModelRuntime` (no real MLX
      inference).
    - No `Thread.sleep` or real wall-clock waits > 100 ms in tests.
    - AC4 (slots_free invariance) is asserted via a coordinator
      heartbeat spy.
    - AC6 (SIGINT during in-flight prewarm) has a bounded-wait
      assertion.

### Do NOT flag

- Placement / architecture (that's the ARCHITECT lane).
- Auth / credential concerns (that's the SECURITY lane).
- Naming taste, comment style, log-message wording (unless it
  violates R6 event names verbatim).
- Anything outside the diff.

### Output format

Report findings ranked C (CRITICAL) / H (HIGH) / M (MEDIUM) / L (LOW) /
I (INFO). One paragraph per finding: file:line, defect description,
concrete failure scenario, proposed fix in plain English. No code
patches.

Include a bottom-line status line:

```
STATUS: CODE lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>
```

## Diff to audit

`git diff` in the worktree. New file
`phase3-binary/Sources/macprovider-cli/IdlePrewarmer.swift`.

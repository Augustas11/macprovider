# Audit — Provider thermal auto-throttle IMPL

You are a code auditor. Audit the diff against `origin/main` on branch `feat/thermal-autothrottle`. Source-of-truth BUILD prompt: `specs/BUILD_THERMAL_AUTOTHROTTLE_PROMPT.md`.

## Scope

This is a ~99-line production diff + ~111 lines of unit tests. Provider thermal auto-throttle: `ProcessInfo.thermalState` → `ProviderSnapshot.slotsFree=0` when `.serious` or `.critical`. Not money-path, no wire-format change.

## Files changed

- NEW `phase3-binary/Sources/macprovider-cli/ThermalGate.swift`
- MOD `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`
- MOD `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- NEW `phase3-binary/Tests/macprovider-cliTests/ProviderStatusTests.swift`
- MOD `beta/DECISION_CRITERIA.md` (Entry 91)

Full diff at the repo root in `feat/thermal-autothrottle`. Run `git diff origin/main` from a fresh checkout of that branch.

## Audit lenses — return findings classified CRITICAL / HIGH / MEDIUM only

### Correctness
1. Does `ProviderSnapshot.slotsFree` actually drop to 0 for every code path that previously read `max(0, capacity.maxConcurrency - requestsInFlight)`? Are there other call sites that bypass the snapshot and read `capacity.maxConcurrency` directly for an admission-control decision (NOT capacity advertising)?
2. Is the `effectiveStatus` override (`.busy` when throttled AND status was `.ready`/`.busy`) correct? Does it preserve `.draining`, `.unavailable`, `.degraded` as the BUILD prompt implies it should?
3. Is the notification observer correctly registered on a queue (`queue: nil` posts on the calling thread — is that safe given the `[weak self]` capture into `Task { await self.refresh() }`)?
4. Are in-flight requests truly NOT cancelled by the throttle? Find any cancellation/drain path that could be triggered by a `.busy` status flip.
5. Does the `ThermalGate` actor's `inject(state:)` test-seam expose any production mutation surface that shouldn't exist outside tests?

### Concurrency
1. Is `ThermalGate` correctly Sendable / actor-isolated? Any data-race risk in `transitionLogger` closure execution given `@Sendable`?
2. `applyTransition` calls `transitionLogger?(old, newState)` synchronously inside the actor — the logger is `@Sendable (Old, New) -> Void`. Is this correct, or should it be async-dispatched off-actor to avoid blocking the actor on a slow log writer?
3. Could the notification observer fire after `ThermalGate` is deallocated and produce a use-after-free? (Observer not explicitly removed in `deinit` — actor `deinit` semantics under Swift concurrency.)

### Hidden assumptions / spec-divergence
1. The BUILD prompt example log line includes `slots_free=N`. The shipped log line drops `slots_free` because the gate doesn't hold capacity. Is this an acceptable simplification or a spec violation?
2. The BUILD prompt says "do not pre-emptively add hysteresis logic". The shipped code uses edge-only notification (no debounce). Correct?
3. The BUILD prompt says "No new heartbeat field" — confirm `thermallyThrottled` does NOT leak onto the coordinator wire shape. It's an internal `ProviderSnapshot` field; verify nothing in `CoordinatorClient.swift` serializes it.
4. `ProviderCapacity.maxConcurrency` is reported verbatim in registration payloads (e.g. CoordinatorClient.swift:2027, 2130, 2178) AND in `/v1/models`/`/healthz` (HTTPServer.swift:852, 929). The BUILD prompt explicitly says capacity is a hardware fact and should NOT be degraded under throttle. Confirm those sites remain unchanged.

### Test adequacy
1. Do the 6 new tests cover: (a) `.serious` and `.critical` both throttle, (b) `.nominal` and `.fair` do not, (c) transitions in both directions, (d) in-flight survival, (e) edge-only logger fires, (f) `shouldThrottle` boundary?
2. Are there missing transition cases (e.g. `.fair → .serious`, `.critical → .nominal` directly)?
3. Is `TransitionRecorder`'s `@unchecked Sendable` + `NSLock` correct for the test's concurrent access pattern?

## Output format

Per finding:

```
[CRITICAL|HIGH|MEDIUM] <one-line title>
file: <path:line>
problem: <2-3 sentences>
fix: <concrete suggestion>
```

If zero findings at all three severities, return exactly: `AUDIT CLEAN — 0 CRITICAL / 0 HIGH / 0 MEDIUM`.

Do NOT include LOW / NIT / style findings unless they would block correctness or convoluted reading.

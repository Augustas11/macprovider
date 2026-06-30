# Audit — Provider thermal auto-throttle (CODE lens)

You are a code auditor. Audit the diff against `origin/main` on branch `feat/thermal-autothrottle`. Source-of-truth BUILD prompt: `specs/BUILD_THERMAL_AUTOTHROTTLE_PROMPT.md`.

This lane is ONE OF THREE: code lens (this) + security lens + architect lens are running independently. Do NOT cover security concerns or architectural / abstraction-placement findings — those are in the other lanes. Focus exclusively on code-level correctness, Swift-concurrency soundness, and test adequacy.

## Scope

~99 production lines + 127 test lines. Not money-path. No wire-format change.

## Files changed

- NEW `phase3-binary/Sources/macprovider-cli/ThermalGate.swift`
- MOD `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`
- MOD `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- NEW `phase3-binary/Tests/macprovider-cliTests/ProviderStatusTests.swift`

`git diff origin/main` from a fresh checkout of `feat/thermal-autothrottle`.

## Code lenses

### Correctness
1. Is the throttle behaviour exactly what the BUILD prompt §"What v1 MUST do" specifies on every code path? Specifically `slotsFree==0` when state is `.serious` OR `.critical`; restored when `.fair` OR `.nominal`. Are there any subtle bugs in the boolean / switch?
2. `effectiveStatus`: `(throttled && (status == .ready || status == .busy)) ? .busy : status`. Verify this preserves `.draining` / `.unavailable` / `.degraded` correctly and never demotes a higher-priority terminal state.
3. `refreshAvailabilityState()` in `ProviderStatus` is called from `beginRequest` / `finishRequest`. It doesn't know about thermal throttle. Could it overwrite a throttle-induced `.busy` back to `.ready` between snapshots? (Note: snapshot recomputes `effectiveStatus` so the final wire value is correct, but does the actor-internal `status` flapping cause observable issues?)
4. `ThermalGate.applyTransition`: `guard old != newState else { return }` — confirm `ProcessInfo.ThermalState` Equatable behaviour is well-defined.
5. The notification handler does `Task { await self.refresh() }`. If multiple notifications fire rapidly, are the resulting `refresh()` invocations serialized by the actor in the order the notifications arrived, or could they race and apply transitions out of order? Does that matter given `refresh()` always reads the current state?

### Swift concurrency
1. `ThermalGate` is an actor. `setTransitionLogger`, `currentState`, `isThrottled`, `inject`, `refresh`, `applyTransition` — actor-isolated. `shouldThrottle(_:)` is `static`. Any cross-actor data flow issues with the `@Sendable (Old, New) -> Void` logger closure being called synchronously inside the actor on transition?
2. The closure captures `configuredSlots` (an `Int`) — trivially Sendable. But it also captures the implicit closure-context. Any captured state risks?
3. `Task { [weak self] in await self?.refresh() }` from the notification handler — actors can be weakly referenced (they're reference types). Confirm `[weak self]` works as expected on an `actor` type and there's no leak path if the gate is held by a long-lived `ProviderStatus`.
4. The new `func snapshot(...) async` was a non-async method before. Confirm every caller already used `await` (cross-actor calls were already async-bridged) and no caller is silently broken. Check Tests as well.
5. Round-1 fix moved `await thermalGate?.isThrottled()` to the top of `snapshot()` before reading window state. Confirm the single `await` happens cleanly before ANY mutable-state read, and reset (if `resetWindow == true`) happens after the snapshot is constructed without any further suspension.

### Build / compile / warnings
1. Does the diff introduce ANY new Swift 6 strict-concurrency warning, `@unknown default` warning, deprecation warning, or `-Wall`-style compile noise on top of the pre-existing warning baseline?
2. `extension ProcessInfo.ThermalState { var label: String }` — does this collide with any future Foundation-provided extension? `@unknown default` is handled.
3. The notification handler stores `observer = NotificationCenter.default.addObserver(...)`. The return is `NSObjectProtocol` — confirm we don't need to retain the handler block separately to prevent it being collected.

### Test adequacy
1. Tests cover: thresholds (`.serious`/`.critical`/`.nominal`/`.fair`), bi-directional transitions, in-flight survival, edge-only logger, `shouldThrottle` boundary, and the snapshot-reset reentrancy regression. Anything missing for a one-round IMPL audit?
2. The `inject(state:)` test seam — is there a test that locks "no real notification ever fires during a unit test" so injected state isn't overridden by host-machine thermal state mid-test?
3. `TransitionRecorder` uses `@unchecked Sendable` + `NSLock`. Any subtle bug in that pattern (e.g. lock ordering, re-entrant access)?
4. Is the regression test `testSnapshotResetWindowReadsAllFieldsInOneActorTurn` actually a regression test for the race, or does it just exercise the happy path without exposing the race? Suggest improvements if it doesn't deterministically catch the prior bug.

## Output format

Per finding:

```
[CRITICAL|HIGH|MEDIUM] <one-line title>
file: <path:line>
problem: <2-3 sentences>
fix: <concrete suggestion>
```

If zero findings at C/H/M severity, return exactly: `AUDIT CLEAN — 0 CRITICAL / 0 HIGH / 0 MEDIUM`. Do NOT include LOW / NIT / style findings.

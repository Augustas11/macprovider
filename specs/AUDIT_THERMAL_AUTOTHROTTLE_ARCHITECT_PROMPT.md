# Audit — Provider thermal auto-throttle (ARCHITECT lens)

You are an architecture auditor. Audit the diff against `origin/main` on branch `feat/thermal-autothrottle`. Source-of-truth BUILD prompt: `specs/BUILD_THERMAL_AUTOTHROTTLE_PROMPT.md`.

This lane is ONE OF THREE: code lens + security lens + architect lens (this) are running independently. Do NOT cover code-correctness bugs or security findings — those are in the other lanes. Focus exclusively on design / architecture / spec-fit / abstraction-level findings.

## Scope

~99 production lines + 127 test lines. Not money-path. No wire-format change.

## Files changed

- NEW `phase3-binary/Sources/macprovider-cli/ThermalGate.swift`
- MOD `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`
- MOD `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- NEW `phase3-binary/Tests/macprovider-cliTests/ProviderStatusTests.swift`
- NEW `specs/AUDIT_THERMAL_AUTOTHROTTLE_IMPL_PROMPT.md`
- MOD `beta/DECISION_CRITERIA.md` (Entry 91)

`git diff origin/main` from a fresh checkout of `feat/thermal-autothrottle`.

## Architect lenses

### Abstraction placement
1. The throttle plugs into `ProviderSnapshot.slotsFree` as a computed property. Is this the right altitude? Alternatives: (a) the actor-level `refreshAvailabilityState()`, (b) at every admission site in `CoordinatorClient`/`HTTPServer`, (c) at the `ModelRuntime` admission boundary. Which is most resilient to future additions?
2. `ThermalGate` is a NEW actor composed by `ProviderStatus`. Should it instead be a property of `ProviderStatus` directly (avoid extra actor hop)? Or a free-standing global / dependency-injected service shared across multiple actors? What does the actor-hop cost (now an extra `await` on every `snapshot()` call) buy us?
3. `ThermalStateProviding` is a 1-method protocol with one production impl and one test impl. Is the protocol justified, or should the test use a different injection (e.g. an internal `init` overload that takes a starting state)?

### Spec/contract fit
1. The BUILD prompt §"Files you'll likely touch" lists `ProviderStatus.swift`, the CLI bootstrap, and tests. The diff matches. Anything ELSE this change should touch but didn't? Specifically: `Tier2Attestation.swift:151` reads `snapshot.capacity.ramGB` — the spec explicitly excludes it, but does anything in attestation paths read slot-availability that should now reflect throttle?
2. `ProviderHealthState` already has `.degraded`. Should thermal-throttle map to `.degraded` instead of `.busy`? The BUILD prompt explicitly says `.busy` — verify this is the right call long-term, not just expedient. (Concern: `.degraded` is reserved for "still serving but reduced capacity" while `.busy` is "queue-full" — thermal throttle is closer to `.degraded` semantically.)
3. The `effectiveStatus` override only fires when `status == .ready || .busy`. What if a future state is added (e.g. `.maintenance`)? The current switch will silently NOT apply throttle. Is that intentional or a foot-gun?

### Future-proofing
1. The transition log records `slots_free=0` (throttled) or `slots_free=<configured maxConcurrency>` (unthrottled). When SPEC-013 CLI autotune dynamically resizes `maxConcurrency`, the log line's "configured" value at startup will diverge from runtime. Will operators be misled?
2. The `inject(state:)` test seam is `internal` (default Swift access). Is this acceptable for a test-only mutation surface on a production type, or should it be guarded with `#if DEBUG` / a separate test-target-only file?
3. SPEC-016 payout pipeline + SPEC-017 stats API both depend on accurate slot/availability telemetry. Does the throttle-driven `.busy` status affect any rollup, reputation, or payout-eligibility calculations downstream in a way the prompt didn't anticipate?

### Operational shape
1. The throttle logs once per transition. Is there an aggregate "we've been throttled for the last N minutes" observability surface needed, or is the heartbeat slot count + the transition log sufficient for ops to spot "this Mac is chronically thermal-bound"?
2. No metric / counter / time-in-state stat is recorded anywhere. SPEC-017 stats API could surface "fraction of last 24h spent throttled". Is the absence of any state-time accumulator a deliberate v0 choice or a gap?
3. The notification observer relies on macOS's notification queue. On a headless / unattended provider (the target deployment), does the run loop processing depend on a particular thread being alive? Confirm the bootstrap doesn't need an explicit RunLoop pump.

### DECISION_CRITERIA Entry 91
1. Entry 91 claims `event=thermal_state_changed` matches "the existing `event=` grep convention". The only other `event=` line I can find in the provider binary is internal coordinator audit logs (server-side, not in this binary). Does this claim hold for the PROVIDER binary's logs, or is this the first `event=` line in provider stdout?
2. Does the Entry capture every load-bearing decision? Missing: (a) the placement-at-snapshot-property choice, (b) the no-hysteresis choice, (c) the rationale for NO new heartbeat field.

## Output format

Per finding:

```
[CRITICAL|HIGH|MEDIUM] <one-line title>
file: <path:line>
problem: <2-3 sentences — architecture impact must be concrete>
fix: <concrete suggestion or "deferred to follow-up issue #NNN">
```

If zero findings at C/H/M severity, return exactly: `AUDIT CLEAN — 0 CRITICAL / 0 HIGH / 0 MEDIUM`. Do NOT include LOW / NIT findings.

# Audit — Provider thermal auto-throttle (SECURITY lens)

You are a security auditor. Audit the diff against `origin/main` on branch `feat/thermal-autothrottle`. Source-of-truth BUILD prompt: `specs/BUILD_THERMAL_AUTOTHROTTLE_PROMPT.md`.

This lane is ONE OF THREE: code lens + security lens (this) + architect lens are running independently. Do NOT cover general code quality / design / correctness — those are in the other lanes. Focus exclusively on security-relevant findings.

## Scope

~99 production lines + 127 test lines. New `ThermalGate` actor + `ProviderSnapshot.slotsFree` gating. Not money-path. No wire-format change.

## Files changed

- NEW `phase3-binary/Sources/macprovider-cli/ThermalGate.swift`
- MOD `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`
- MOD `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- NEW `phase3-binary/Tests/macprovider-cliTests/ProviderStatusTests.swift`
- NEW `specs/AUDIT_THERMAL_AUTOTHROTTLE_IMPL_PROMPT.md`
- MOD `beta/DECISION_CRITERIA.md` (Entry 91)

`git diff origin/main` from a fresh checkout of `feat/thermal-autothrottle`.

## Security lenses

### Trust boundary integrity
1. Does the throttle introduce any new way for an UNTRUSTED party to influence provider behaviour? `ProcessInfo.thermalState` is read from the OS; can a buyer / coordinator / co-tenant influence what it reports (e.g. via fork-bombs, CPU pressure, IORegistry pokes)?
2. Could a malicious provider operator EXPLOIT the throttle to falsely report `slots_free=0` while still admitting requests through some bypass path (causing the coordinator to deprefer them but still earning revenue)?
3. The new `thermallyThrottled` field is internal-only. Verify it does NOT leak onto: (a) the WebSocket frames to the coordinator, (b) the `/v1/models`/`/healthz`/`/v1/status` HTTP responses, (c) attestation envelopes, (d) signed receipts.

### Information disclosure
1. The log line `event=thermal_state_changed from=X to=Y throttled=B slots_free=N` is emitted via `print()` (stdout). Does this leak any host-identifying or buyer-correlatable information? Thermal state itself is host-machine telemetry — is exposing the transition pattern to anyone reading the provider's stdout (operator, log aggregator, side-channel) a concern?
2. Could thermal transition timing correlate with buyer request patterns in a way that creates a side channel (e.g. "this provider is the one I sent the long request to because it just went `.serious`")?

### DoS / availability
1. Can an attacker INDUCE thermal throttling on a target provider? On Apple Silicon a sustained high-CPU workload from a malicious tenant could push the system to `.serious`. If the provider is shared with other tenants (it isn't — single-tenant macprovider process — but worth confirming), this could be weaponized.
2. Can a malicious buyer cause repeated throttle/unthrottle flapping to (a) flood the log, (b) churn the coordinator's routing state, (c) cause the coordinator to mark the provider unavailable?
3. The notification observer registration happens once at startup. If `ThermalGate` is leaked / retained beyond expected lifetime, could it cause memory pressure?

### Mid-stream cancellation invariant (security-relevant)
1. The BUILD prompt mandates in-flight requests are NOT cancelled by throttle. If this invariant were violated, a malicious actor inducing thermal state could mid-stream-kill an in-progress buyer response — denial of completion AND potential receipt-state divergence (was a billable receipt issued? was completion delivered?). Verify the code does not anywhere drain or cancel based on thermal-driven `.busy` status. Status flips: `.ready→.busy` under throttle — does ANY existing code react to that transition with a cancellation / drain side effect?

### Audit log integrity
1. The log line is the only forensic record of throttle events. Is it tamper-resistant (it isn't — stdout is unsigned). Is that acceptable given non-money-path scope? Could a malicious operator suppress the log to hide thermal-throttle gaming?
2. Could a thermal-state transition coincide with a state mutation that races against the log line, producing a misleading log claim?

### Test seam exposure
1. `ThermalGate.inject(state:)` is an `internal` actor method. Does any production caller use it? Could a non-test caller drive arbitrary thermal state and bypass the genuine `ProcessInfo.thermalState` reading?

## Output format

Per finding:

```
[CRITICAL|HIGH|MEDIUM] <one-line title>
file: <path:line>
problem: <2-3 sentences — security impact must be concrete>
fix: <concrete suggestion>
```

If zero findings at C/H/M severity, return exactly: `AUDIT CLEAN — 0 CRITICAL / 0 HIGH / 0 MEDIUM`. Do NOT include LOW / informational findings.

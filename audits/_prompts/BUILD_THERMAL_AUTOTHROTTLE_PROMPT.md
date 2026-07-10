# BUILD prompt — Provider thermal auto-throttle (Cluster D)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing a single line of code.**

Your job is to make the macprovider provider binary **report zero free slots to the coordinator while its host Mac is under thermal pressure**, then return to normal slot reporting once thermals recover. Half-day of work, single PR, no SPEC.

This addresses the original Cluster D item from `audits/2026-06-22/CLUSTER_HANDOFF.md`: *"Auto-throttle on thermal pressure ~50 Swift lines."* It is independent of the heartbeat-side watchdog work shipped in PR #207 (#191) — that fixes liveness/network signalling, not thermal load.

## Pre-flight: confirm the gap

Verify against the current tree before touching code:

1. `grep -rn 'thermalState\|ThermalState\|pmset\|IOPMCopyCPUPowerStatus' phase3-binary phase4-coordinator --include='*.swift' --include='*.go'` → should return zero matches. If anything appears, surface it and stop.
2. Read [phase3-binary/Sources/macprovider-cli/ProviderStatus.swift](phase3-binary/Sources/macprovider-cli/ProviderStatus.swift) end-to-end (≤240 lines). Confirm: `var slotsFree: Int` at line 92 is `max(0, capacity.maxConcurrency - requestsInFlight)`. `status` at line 228 derives `.busy` vs `.ready` from `requestsInFlight >= capacity.maxConcurrency`. **This is where you plug thermal in.**
3. Read [phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift) around the two heartbeat snapshot sites (currently ~lines 1351 and 1380 — `"slots_free": snapshot.slotsFree`). Confirm: the snapshot is consumed read-only at heartbeat time; no other code paths bypass `slotsFree` to read `capacity.maxConcurrency` directly.
4. `grep -rn 'snapshot.capacity\|snapshot.slots' phase3-binary --include='*.swift'` to confirm every consumer routes through `ProviderStatus`'s computed properties. If anything reads `capacity.maxConcurrency` directly for capacity decisions, surface it — the throttle must affect every such site, not just heartbeat.

If any of 1–4 is wrong, STOP and surface the discrepancy rather than working from this prompt's assumptions.

## What v1 MUST do

### 1. Use the Swift-native thermal API

`ProcessInfo.processInfo.thermalState` returns `.nominal | .fair | .serious | .critical`. It's Foundation, no IOKit, no `pmset` shell-out, no entitlement. **Do not shell out to `pmset`.** It's slow, brittle, and surfaces nothing `thermalState` doesn't.

Subscribe to `NSProcessInfo.thermalStateDidChangeNotification` to get push updates instead of polling. The notification fires on every transition.

### 2. Plug into `ProviderStatus`, not the heartbeat path

Add a property on `ProviderStatus` (or a small `ThermalGate` actor it composes) that exposes `var isThermallyThrottled: Bool`. Wire it into:

- `var slotsFree: Int` → `isThermallyThrottled ? 0 : max(0, capacity.maxConcurrency - requestsInFlight)`
- `status` derivation → return `.busy` when thermally throttled, even with no in-flight requests

This makes throttling visible to **every** consumer of slot/status — heartbeat, `/v1/models`, `/healthz`, attestation snapshots — without touching each one individually.

### 3. Threshold + hysteresis

- **Throttle on** `.serious` OR `.critical`
- **Throttle off** when state drops to `.fair` OR `.nominal`
- Use the notification edge directly — no debounce. macOS already smooths the state transitions.
- Track an `ignoreThrottleUntil` timestamp ONLY if you find empirical flapping during testing. Don't pre-emptively add hysteresis logic that may not earn its complexity.

### 4. Observability

On every transition, emit a single log line at INFO:

```
thermal_state_changed from=nominal to=serious throttled=true slots_free=0
thermal_state_changed from=serious to=fair throttled=false slots_free=4
```

The ops side already greps for `event=` patterns; match that style (`event=thermal_state_changed`). No new metrics surface — slot count change in the existing heartbeat is the observable.

### 5. In-flight requests during throttle

Throttle affects **future** admissions only. **DO NOT** cancel or drain in-flight requests when thermals trip — that would mid-stream a buyer mid-response, which is far worse than briefly running the Mac warm. The coordinator's existing routing already deprefers `slots_free=0` providers, so new buyer traffic naturally migrates off this provider until thermals recover.

Document this explicitly in code comment + PR description so the next reviewer doesn't "fix" it.

## What v1 MUST NOT do

- **No new SPEC.** This is a ~50-line behaviour change inside an existing struct. SPEC-001 already covers the provider snapshot shape; this doesn't change the wire format.
- **No IOKit / `IOPMCopyCPUPowerStatus` / `pmset` shell-out.** `ProcessInfo.processInfo.thermalState` is the API.
- **No coordinator-side changes.** The coordinator already routes around `slots_free=0`. If you find yourself editing `phase4-coordinator/`, you've taken a wrong turn.
- **No new heartbeat field.** Don't add `thermal_state` to the snapshot wire shape — it's debugging noise on the wire. The log line + the `slots_free` swing is enough observability.
- **No mid-stream cancellation.** Per §5 above.
- **No configurable threshold.** `.serious` is the line. Adding a config knob just creates an operator footgun where someone disables throttling and cooks their Mac.

## Files you'll likely touch

- `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift` — primary surface. Expect ~30-50 lines of net diff (new `ThermalGate` or property + computed-property updates + notification observer).
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` OR equivalent bootstrap — start the thermal observer at process launch (notification observer must outlive any single snapshot).
- `phase3-binary/Tests/macprovider-cliTests/ProviderStatusTests.swift` (NEW if missing, OR add to existing) — unit-test the slot-derivation logic with injected thermal state.
- `beta/DECISION_CRITERIA.md` — Entry recording what shipped.

## What you SHOULDN'T touch

- `phase4-coordinator/**` — coordinator doesn't need to know about thermal state directly
- `phase5-gateway/**` — irrelevant
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` — already reads `snapshot.slotsFree`; the throttle should land transparently through that property
- `phase3-binary/Sources/macprovider-cli/Tier2Attestation.swift` line 151 — already reads `snapshot.capacity.ramGB` (capacity, not slots); attestation is orthogonal to throttle and should NOT report a degraded capacity figure (capacity is a hardware fact)

## Test plan

1. **Unit test** — inject a fake thermal-state provider (protocol-back the `ProcessInfo` read so tests can drive it). Assert: `slotsFree==0` and `status==.busy` when injected state is `.serious` or `.critical`; pre-throttle slot count when `.nominal` or `.fair`.
2. **Unit test** — transitions: `nominal → serious` → `slotsFree` drops to 0; `serious → fair` → restores.
3. **Integration test (operator-runnable)** — `yes > /dev/null & yes > /dev/null & yes > /dev/null & yes > /dev/null` for ~5 min on a hot day, observe a real `.serious` transition (won't always reproduce on cool day / cold workstation; document this as "best-effort manual test").
4. **Regression** — existing `swift test` suite stays green. No `slots_free` regression on a thermally-nominal Mac.

## Audit-loop discipline

This is ~50 lines, not money-path, doesn't change wire shape. **ONE codex IMPL audit round on the diff is sufficient.** Per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-build-audit-loop.md` discipline scales to risk. Fix any HIGH/CRIT, ship. Skip the round only if the diff stays under ~80 lines AND the unit tests are comprehensive.

## Deliverables

1. PR opened against `main` with branch `feat/thermal-autothrottle`. Use `GH_TOKEN=$(gh auth token -u Augustas11) gh pr create ...` per `~/.claude/projects/-Users-augstar-macprovider-poc/memory/gh-pr-merge-augustas11-token-prefix.md`.
2. PR description MUST include:
   - Diff line count (target: ≤80 lines)
   - Why no SPEC + no coordinator changes (link to this prompt's §"What v1 MUST NOT do")
   - The mid-stream-cancellation decision (§5) explicitly called out
3. `beta/DECISION_CRITERIA.md` entry recording what shipped + the `.serious` threshold choice.

**You're done when:** PR is merged AND unit tests demonstrate slot-count transitions on injected thermal state. Half-day of work end-to-end including audit round. If you're past one day, scope-creep has happened — surface what's blocking.

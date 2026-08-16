# BUILD_PROVIDER_IDLE_PREWARM_IMPL — Provider Swift idle prewarm (MLX Metal keep-warm)

## Motivation (measured, 2026-07-04)

A 4-way cold-start bisection against `mac` (M5 32GB, v1.8.0) produced
the following breakdown of buyer-observed TTFT after ≥ 90 s of provider
idle:

| Path | Cold TTFT | Warm TTFT | Idle delta |
|---|---:|---:|---:|
| Buyer → api.malibu.tech | 5.6-6.6 s | 1.4 s | ~4-5 s |
| M5 → 127.0.0.1:18080 (direct) | 0.61 s wall | 0.17 s wall | ~440 ms |
| Gateway `wall_ms` on cold request | 5590 ms | ~1200 ms | ~4390 ms |

The bulk (≥ 4 s) of the cold-start penalty occurs between coordinator
`routing_decision` (dispatched immediately, ~1 s after buyer send) and
first content token. Provider WSS keepalive is at 5 s cadence and is
working — NAT idle isn't the cause. macOS `event=thermal_state_changed
from=fair to=nominal` fired during the cold window, indicating GPU
power-managed idle state on the M5. When the same prompt is warm the
buyer sees ~1.4 s TTFT and the provider path is ~168 ms.

Root cause: MLX Metal command queue + kernel scheduler degrade during
provider idle. First inference has to reload kernels and rebuild the
command pipeline. Model weights stay resident so a "true" cold-load
isn't happening — only the Metal runtime + KV state.

Additional 3-run reliability sweep observed one 6.6 s TTFT spike among
30 successful `gap=5s` requests (99th percentile), confirming the same
idle-state degradation reappears whenever the provider is briefly idle
between buyer requests.

## Goal (this PR)

Add a provider-side idle prewarm actor that keeps the MLX Metal state
hot during operator-configurable idle windows. Every N seconds (default
tick: 5 s) the prewarmer asks: "has the provider been idle for at
least K seconds (default 30 s) AND is it in a state where prewarm is
safe?" If yes, it fires a synthetic minimal internal inference
(default: 1 token, prompt "warm") through a new ModelRuntime path that
bypasses request tracking, receipt emission, and coordinator-visible
slot accounting.

The prewarm inference must be transparent to the coordinator and the
buyer. It never counts toward `requestsTotal`, never emits receipts,
never occupies a slot the coordinator sees, and never appears in
throughput / latency metrics.

## Non-goals

- No change to coordinator (`phase4-coordinator/**`) or gateway
  (`phase5-gateway/**`) code.
- No new buyer-visible endpoints.
- No change to the WSS keepalive cadence or protocol.
- No change to SPEC-023 autotune, SPEC-024 conversation-cache, or
  SPEC-016 payout code paths.
- No change to model weights, quantization, or MLX runtime version.
- No visible signal to the coordinator that prewarm happened (no new
  heartbeat field, no new WSS message type).

## Scope of change

Files that MUST change:
- `phase3-binary/Sources/macprovider-cli/IdlePrewarmer.swift` (new).
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — add
  the internal prewarm entry point.
- `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift` — add
  the `lastActivityAt` field / update path.
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` — bump
  `lastActivityAt` on each real request start, and (optionally) hand
  the prewarmer a cancel signal.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` —
  instantiate + start / stop the prewarmer.
- `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift` +
  `MacProviderCLI.swift` — CLI flag(s) / config-yaml key(s) for the
  new knobs.
- `phase3-binary/Tests/macprovider-cliTests/IdlePrewarmerTests.swift`
  (new).

Files that MAY change (only if the implementer determines it's the
cleanest home):
- `phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift`
  if activity-tracking naturally lives there instead of
  `ProviderStatus.swift`.
- `phase3-binary/Sources/macprovider-cli/ThermalGate.swift` if a
  thermal-state accessor is added there instead of duplicating.

Files that MUST NOT change:
- Anything under `phase4-coordinator/**` or `phase5-gateway/**`.
- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`,
  `ReceiptAudit.swift`, `CachedReceiptKeyStore.swift`,
  `InMemoryReceiptKeyStore.swift` — the prewarm path must not emit
  receipts, so it never touches these files.
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  request-dispatch code — no coordinator interaction from the
  prewarm path.
- `phase3-binary/Sources/macprovider-cli/AutotuneDB.swift`,
  `AutotuneRecommend.swift` — prewarm results MUST NOT contribute
  to autotune measurements.

## Behavioural requirements

**R1 — Idle-detection contract.** The prewarmer fires iff *all* of
the following hold at the check tick:

1. Configuration `idle_prewarm.enabled == true`.
2. `providerStatus.requestsInFlight == 0` (no active real request).
3. `now - providerStatus.lastActivityAt >= idle_prewarm.idle_threshold_seconds`.
4. `thermalGate.currentThermalState()` is not `.serious` and not
   `.critical` — i.e. `.nominal` or `.fair` only.
5. Power source is not battery-only OR
   `idle_prewarm.run_on_battery == true`. Battery / plugged-in is
   detected via `IOPSCopyPowerSourcesInfo` + `IOPSGetPowerSourceState`
   (macOS `IOKit.pwr_mgt`). Absence of any power source (rare on Mac
   Studio / Mac mini) is treated as "not on battery" for the check.
6. Model is loaded (`await modelRuntime.isLoaded == true`) and a
   `loadedModelHash` is present.

If any check fails at the tick, log the reason at `event=idle_prewarm_skipped`
with the tightest matching reason (`disabled`, `busy`, `not_idle_yet`,
`thermal_pressure`, `on_battery`, `model_not_loaded`) and skip to next
tick.

**R2 — Prewarm inference contract.** The prewarm inference:

- Uses a NEW `ModelRuntime` entry point named `runInternalWarmup(
  maxTokens: Int, prompt: String, shouldCancel: @escaping @Sendable ()
  -> Bool) async throws -> InternalWarmupResult`.
- MUST NOT increment `providerStatus.requestsTotal`.
- MUST NOT increment `providerStatus.requestsInFlight` (so
  `slots_free` reported to the coordinator stays at
  `slots_total - real_in_flight`, not `slots_total - real_in_flight - 1`).
- MUST NOT emit any receipt event, receipt-omitted event, or
  ReceiptAudit line.
- MUST NOT contribute to `providerStatus.avgLatencyMSSinceLast`,
  `throughputTPSSinceLast`, or `requestsServedSinceLast`.
- MUST NOT be visible in the coordinator's WSS heartbeat / provider
  activity payloads.
- SHALL update a new `providerStatus.lastPrewarmAt` timestamp used
  only for observability / test assertions.
- SHOULD reuse the same MLX inference path as `complete()` for
  Metal-warmup effect (going through a totally different code path
  would defeat the purpose).
- SHALL run with `maxTokens` bounded to `[1, 8]`. Values outside are
  clamped or produce a load-time config validation error.
- SHALL run with a prompt bounded to `[1, 64]` characters after
  UTF-8 encoding.

**R3 — Cancellation on real-request arrival.** If a real chat request
arrives (HTTP `/v1/chat/completions`) while a prewarm is in flight,
the prewarm MUST be cancelled promptly (measured: within one MLX
token boundary or 200 ms, whichever is shorter). Cancellation MUST
NOT partially charge the real request, corrupt the KV cache, or
leave the runtime in a bad state.

Preferred mechanism: the prewarmer holds the currently-running
prewarm `Task` and exposes a `cancelInflightPrewarm()` method the
HTTP handler calls before it invokes `modelRuntime.complete()` /
`.stream()`.

**R4 — Tick discipline.** The prewarmer runs a background `Task` on
its own actor with a `Task.sleep(nanoseconds:)` loop cadenced at
`idle_prewarm.tick_seconds` (default 5, range [1, 60]). At startup
the first tick fires after one full tick interval (not immediately)
so warmup benefits from natural startup + first-real-request patterns.

If a prewarm is already in flight when a tick fires, the tick is
skipped (no queuing).

**R5 — Startup / shutdown ordering.**

- Prewarmer is instantiated AFTER `modelRuntime`, `providerStatus`,
  and `thermalGate` are all constructed and after
  `modelRuntime.setProviderStatus(providerStatus)` has run.
- Prewarmer is started (its background loop begins) AFTER the HTTP
  server is listening and BEFORE the coordinator client dials in.
  If that ordering can't be honoured cleanly, start prewarmer after
  the coordinator dial completes so a start-time prewarm doesn't
  race with the first real request.
- Prewarmer must be stoppable via `stop()` that cancels the
  background loop AND any in-flight prewarm.
- On SIGINT / SIGTERM (graceful serve shutdown), the prewarmer's
  in-flight prewarm inference is cancelled BEFORE the runtime begins
  drain; the prewarmer's background loop is stopped BEFORE the
  server closes its listener.

**R6 — Observability.** Emit exactly one structured JSON line per
event, printed to stdout in the existing `log_format: json` style
used by the rest of the serve loop. Event names (values of `"event":`):

- `idle_prewarm_fired` — at successful start of a prewarm inference.
  Fields: `idle_seconds`, `max_tokens`, `thermal_state`, `on_battery`.
- `idle_prewarm_completed` — at successful completion. Fields:
  `elapsed_ms`, `tokens_generated`, `first_token_ms`.
- `idle_prewarm_skipped` — at tick when preconditions fail. Field:
  `reason` from R1's enumerated set.
- `idle_prewarm_cancelled_by_real_request` — when R3 cancellation
  fires. Field: `elapsed_ms` (time from prewarm start to cancel).
- `idle_prewarm_failed` — on error from `runInternalWarmup`. Fields:
  `error_class`, `elapsed_ms`.

Do NOT emit `idle_prewarm_skipped` more than once per tick (i.e.
find the tightest reason and log only that one).

**R7 — Config surface.**

New CLI flag block (long-form only, no short flags):
- `--idle-prewarm / --no-idle-prewarm` (default: enabled)
- `--idle-prewarm-idle-threshold-s` (default 30, range [5, 3600])
- `--idle-prewarm-tick-s` (default 5, range [1, 60])
- `--idle-prewarm-max-tokens` (default 1, range [1, 8])
- `--idle-prewarm-prompt` (default "warm", length [1, 64] UTF-8 bytes)
- `--idle-prewarm-on-battery` (default false — do NOT run on battery)

Config-yaml keys under a new top-level `idle_prewarm:` block:
- `enabled`, `idle_threshold_seconds`, `tick_seconds`, `max_tokens`,
  `prompt`, `run_on_battery`.

Precedence follows the existing pattern used for other flags: CLI
flag > yaml > default.

Config validation errors (out-of-range) MUST fail load-time (not at
first tick).

**R8 — Do-not-degrade guarantees.**

- The prewarm's presence MUST NOT change the SPEC-024 conversation-
  cache state that a subsequent buyer request would see. If the
  prewarm inference is a cache-miss it MUST NOT populate cache in a
  way that persists to buyer traffic — i.e. either bypass cache-
  write for internal warmup, OR use a prompt that is guaranteed to
  produce the same key any prior buyer traffic would produce (unsafe;
  bypass is preferred).
- The prewarm MUST NOT affect `providerStatus.slotsFree` reported to
  the coordinator at any point (before, during, after).
- The prewarm MUST NOT trigger `event=thermal_state_changed` more
  frequently than pre-diff behaviour (it must respect thermal
  throttling and step out during `.serious`+).

**R9 — Battery awareness.** Battery detection uses IOKit
`IOPSCopyPowerSourcesInfo` + `IOPSGetPowerSourceState` + a check for
`kIOPSBatteryPowerValue`. Wrap in a minimal helper `PowerSourceInfo`
struct or extension for testability (inject a
`PowerSourceReporting` protocol). Absence of any power source object
returns `.unknown`; treat `.unknown` as "not on battery".

## Concrete API additions

```swift
// ModelRuntime.swift
struct InternalWarmupResult: Sendable {
    let tokensGenerated: Int
    let firstTokenElapsedMS: Double
    let totalElapsedMS: Double
}

extension ModelRuntime {
    /// Runs a synthetic warmup inference on the currently-loaded model.
    /// Does not increment ProviderStatus.requestsTotal or
    /// requestsInFlight; does not emit receipts; does not update
    /// throughput metrics. Cancellable via shouldCancel.
    func runInternalWarmup(
        maxTokens: Int,
        prompt: String,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> InternalWarmupResult
}
```

```swift
// ProviderStatus.swift additions
extension ProviderStatus {
    /// Marks the start of a real (non-prewarm) request. HTTP handler
    /// calls this before invoking modelRuntime.complete/.stream.
    func noteRealRequestStart()

    /// Marks the completion of a real request.
    func noteRealRequestEnd()

    /// Reports the number of seconds since the last real request
    /// started OR ended (whichever is later). Used by IdlePrewarmer.
    func secondsSinceLastRealActivity() -> Double

    /// Marks a completed prewarm run for observability.
    func noteInternalPrewarm(at: Date, elapsedMS: Double)
}
```

```swift
// IdlePrewarmer.swift (new)
actor IdlePrewarmer {
    init(
        modelRuntime: ModelRuntime,
        providerStatus: ProviderStatus,
        thermalGate: ThermalGate,
        powerSource: PowerSourceReporting,
        config: IdlePrewarmConfig,
        clock: any Clock = ContinuousClock()
    )
    func start()
    func stop() async
    func cancelInflightPrewarm() async
}

struct IdlePrewarmConfig: Sendable, Equatable {
    let enabled: Bool
    let idleThresholdSeconds: Double
    let tickSeconds: Double
    let maxTokens: Int
    let prompt: String
    let runOnBattery: Bool
}
```

## Acceptance criteria

**AC1** — `swift build --product macprovider-cli` clean.

**AC2** — `swift test` full suite passes: existing tests unchanged
(including the 822+ tests baseline), plus all new
`IdlePrewarmerTests.swift` cases.

**AC3** — New tests in
`phase3-binary/Tests/macprovider-cliTests/IdlePrewarmerTests.swift`
cover, using a fake clock + injected `ThermalStateProviding` +
`PowerSourceReporting` + a spy `ModelRuntime`:

1. Prewarm fires after `idleThresholdSeconds` of no activity.
2. Prewarm does NOT fire while `requestsInFlight > 0`.
3. Prewarm does NOT fire when `now - lastActivity < idleThreshold`.
4. Prewarm does NOT fire on `.serious` thermal state.
5. Prewarm does NOT fire on `.critical` thermal state.
6. Prewarm does NOT fire on battery when `runOnBattery == false`.
7. Prewarm DOES fire on battery when `runOnBattery == true`.
8. `enabled: false` produces zero prewarm calls across 10 ticks.
9. In-flight prewarm is cancelled within one tick when a real
   request arrives.
10. `runInternalWarmup` does not touch `requestsTotal`,
    `requestsInFlight`, or emit ReceiptAudit lines.
11. Structured JSON events with correct event names are emitted for
    each of R6's five event categories (use stdout capture).
12. Config validation: out-of-range values for each of the 6 knobs
    each fail at load time with a message that names the offending
    field.
13. Tick skipping when a prewarm is already in flight (no queuing).
14. Stop cancels the background loop AND any in-flight prewarm.

**AC4** — `providerStatus.slotsFree` observed via a spy coordinator
heartbeat is unchanged before, during, and after a prewarm cycle.
Slot accounting is invariant to prewarm activity.

**AC5** — Battery detection is unit-tested with `PowerSourceReporting`
protocol injection (no real IOKit dependency in tests).

**AC6** — On SIGINT during an in-flight prewarm, the shutdown path
completes within 5 seconds of signal receipt (test with a mocked
signal handler or a bounded-wait assertion).

## Observability contract

Emit only structured JSON lines to stdout, matching the existing
`log_format: json` schema. Do NOT add metrics counters, Prometheus,
or new HTTP endpoints in this PR.

## Backwards compatibility

- Buyer-observable behaviour is unchanged. No new headers, no new
  status codes, no changed timing on real requests.
- Coordinator-observable behaviour is unchanged. `slots_free`
  heartbeats are identical whether the prewarm ran or not.
- Config: an operator that does not touch the new `idle_prewarm:`
  yaml block gets the enabled defaults automatically. To fully
  disable, they set `idle_prewarm.enabled: false` OR pass
  `--no-idle-prewarm`.
- Battery-only Macs: default OFF (`run_on_battery: false`) preserves
  battery life; operator opt-in required to change.

## Prohibited implementation choices

- Do NOT run prewarm through the HTTP surface (loopback to
  `127.0.0.1:18080` /v1/chat/completions). It MUST bypass the HTTP
  server, coordinator dispatch, receipt path, and slot accounting.
- Do NOT create a second MLX ModelRuntime instance; the prewarm
  MUST share the loaded model with real inference.
- Do NOT change the WSS heartbeat cadence or fields.
- Do NOT introduce a new persistent state file, SQLite table, or
  IPC channel.
- Do NOT add prewarm-derived rows to `AutotuneDB.swift`'s samples.
- Do NOT change the return type or signature of `ModelRuntime.
  complete()` / `.stream()` (add a NEW method for internal warmup).
- Do NOT use `Task.sleep(seconds:)` — use `Task.sleep(nanoseconds:)`
  or the injected `Clock` for testable tick cadence.
- Do NOT block the actor's mailbox while an inference is running —
  the prewarm must run in a child `Task` so `cancelInflightPrewarm`
  can preempt it.

## Commit style

```
feat(provider): idle-prewarm timer keeps MLX Metal warm during idle

Motivation: cold-start bisection 2026-07-04 measured 4-5s buyer TTFT
after 90s provider idle vs 1.4s warm; provider-side (bypassing WAN
and coord) still showed 442ms cold-vs-warm delta. Root cause is MLX
Metal command queue + GPU power-managed idle. Model weights stay
resident; only the runtime state degrades.

Change: new IdlePrewarmer actor fires a synthetic 1-token internal
inference every 30s of provider idle, gated on thermal (must be
<= .fair) and power (skips battery by default). Runs through a new
ModelRuntime.runInternalWarmup that bypasses request tracking,
receipt emission, and slot accounting.

Config: new idle_prewarm block; defaults on for AC power, off for
battery, 30s idle threshold, 5s tick, 1 token, prompt="warm".

Tested: 14 IdlePrewarmerTests cases; existing swift test suite
unchanged.
```

## Audit boundaries

Three separate audit lanes will be fired against this diff after
implementation:

- **CODE** — correctness of the actor + Task lifecycle,
  cancellation propagation, thermal / power-source protocol wiring,
  config validation, tick-skipping logic, no accidental
  ProviderStatus mutation during warmup, first-tick timing.
- **SECURITY** — no coordinator-visible signal that prewarm
  happened, no receipt-path leakage, no battery-drain amplification
  vector, no config knob that lets an attacker force expensive work
  (prompt-length cap, max-tokens cap, tick-cadence lower bound), no
  IOKit resource leak (unclosed CFRelease targets).
- **ARCHITECT** — placement in the actor topology, consistency with
  existing `ThermalGate` and `ProviderStatus` patterns, config-key
  naming consistency, event-name greppability for future ops
  dashboards, extensibility (would a future "prewarm with real prompt
  from cache" fit naturally, or is this a dead-end shape?).

## References

- Cold-start bisection data: earlier session, buyer path 5.6-6.6 s
  cold vs 1.4 s warm; local direct 610 ms cold vs 168 ms warm.
- ThermalGate at `phase3-binary/Sources/macprovider-cli/ThermalGate.swift`.
- ProviderStatus at
  `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`.
- Existing HTTP entry to inference at `HTTPServer.swift:200`
  (`handleChatCompletions`).
- Existing runtime instantiation at `MacProviderCLI.swift:319-356`.

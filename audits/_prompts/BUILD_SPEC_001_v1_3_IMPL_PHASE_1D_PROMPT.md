# Implementation BUILD prompt — SPEC-001 v1.3 Phase 1D (heartbeat extension + hello.model_hash source-of-truth)

Operator-paste prompt for Codex GPT-5 to land the **fourth** of five
implementation sub-phases of SPEC-001 v1.3 in `phase3-binary/`.
This phase wires the operator-observable warm-swap signal onto the
coordinator WebSocket: opt-in `model_hash` (raw 64-char lowercase
hex) and `loading: bool` fields on the heartbeat frame, plus the
`hello.model_hash` source-of-truth rule when reconnecting mid-swap.
Consumes the `swapSignals()` AsyncStream from Phase 1B to drive an
immediate heartbeat after the atomic swap completes.

**Scope: SPEC-011 v0.5 §3.3 heartbeat extension + §3.8.3 hello
reconnect rule.** No CLI changes, no new flags, no control socket
work, no cooldown logic (1E), no concurrent-switch-policy
elaboration beyond what 1C already implements.

**One-line summary.** Extend `CoordinatorClient.sendHeartbeat`
(`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:588`)
to emit `model_hash` (raw lowercase hex) and `loading: bool` ONLY
when `--enable-warm-swap` is set, sourced from
`modelRuntime.currentSnapshot()` rather than the stale
`providerStatus.modelHash` boot snapshot. Extend
`helloMessage()` (line 692) to source `model_hash` from
`modelRuntime.currentSnapshot()` when warm-swap is enabled,
preserving byte-identical behavior in disabled mode. Consume the
`RuntimeStateMachine.signalStream()` from 1B and translate
`SwapSignal.Outcome.completed` into an immediate heartbeat per
SPEC-011 R-3.2.4 step 4. L-1 byte-identical default preserved
literally: with `--enable-warm-swap` unset, the heartbeat frame
and hello frame are byte-identical to v1.2.4.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-001 v1.3 §6.10 (lines 1867-1916) — this phase's normative
  section, citing SPEC-011 R-3.3.0 through R-3.3.3, R-3.2.4 step 4,
  R-3.8.3
- SPEC-001 v1.3 §6.11.2 (lines 1930-1940) — WS drop mid-load rule,
  citing SPEC-011 R-3.8.1, R-3.8.3, R-3.8.5
- SPEC-011 v0.5 §3.3 (heartbeat extension), §3.8 (WS drop), R-3.2.5
  (no-starve isolation — preserved from 1B)
- 1A (commit 6744d7c) — `Config.enableWarmSwap` plumbing
- 1B (commit 5c03e88) — `ModelRuntime.currentSnapshot`,
  `swapSignals`, `RuntimeStateMachine`
- 1C (commit 9a4a6c5) — already consumes `swapSignals` in
  `ControlSocketServer.handleSwitchRequest`; 1D adds a *second*
  consumer (heartbeat task) and the two streams MUST NOT interfere

Spec-text-only edits are FORBIDDEN. No edits under `specs/`
(operator-authored BUILD prompts excepted). Verify with
`git diff -- specs/` after edits.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~60-90 min
(one file modified heavily, one test file extended; no new files).

Branch: `fix/spec-001-v1-3-binary` already carries Phases 1A + 1B + 1C.
Codex MUST commit on this branch, MUST NOT create a new one, and
MUST NOT commit or push (operator audits before commit).

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1D of SPEC-001 v1.3 in the Swift binary
at /Users/augstar/macprovider-poc/phase3-binary/. SPEC-001 v1.3 is
LOCKED. SPEC-011 v0.5 is LOCKED. Phases 1A (6744d7c), 1B (5c03e88),
and 1C (9a4a6c5) are already on this branch.

You will edit the following files (and ONLY these):

  phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift           (extend)
  phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift   (extend)

You will NOT edit any other Swift file, any file under `specs/`,
`phase4-coordinator/`, or `phase5-gateway/`. You will NOT touch:
- `Sources/MacProviderCore/SupportedModels.swift` (1A)
- `Sources/MacProviderCore/Config.swift` (1A/1B/1C)
- `Sources/macprovider-cli/RuntimeStateMachine.swift` (1B)
- `Sources/macprovider-cli/ModelRuntime.swift` (1B)
- `Sources/macprovider-cli/HTTPServer.swift` (1B)
- `Sources/macprovider-cli/ControlSocket.swift` (1C)
- `Sources/macprovider-cli/ModelsSubcommand.swift` (1C)
- `Sources/macprovider-cli/MacProviderCLI.swift` (extended in 1A/1B/1C)
- Any 1A/1B/1C test file beyond `CoordinatorClientTests.swift`

Verify with `git diff -- specs/ phase4-coordinator/ phase5-gateway/`
— must be empty (excluding operator-authored
`specs/BUILD_SPEC_001_v1_3_IMPL_*` prompts).

## Critical constraints

**1. L-1 byte-identical default per SPEC-001 v1.3 AC-N.0.**
With `--enable-warm-swap` UNSET, the heartbeat frame emitted by
`sendHeartbeat()` and the hello frame emitted by `helloMessage()`
MUST be byte-identical to the SPEC-001 v1.2.4 baseline. This
means:
  - `model_hash` key MUST NOT appear in the heartbeat frame
    JSON (not present, not null, not empty string)
  - `loading` key MUST NOT appear in the heartbeat frame JSON
  - `helloMessage()` continues to read `modelHash` from
    `providerStatus.snapshot().modelHash` (the boot-time value)
    as it does today — DO NOT switch the disabled-mode hello
    path to `modelRuntime.currentSnapshot()`. The disabled
    code path is byte-frozen.

A new test MUST pin this invariant by JSON-serializing both
frames in disabled mode and asserting on the absence of the
two field names AND on byte-equality against a captured-in-test
canonical baseline string.

**2. SPEC-011 R-3.3.0 opt-in gating.** Both new fields are
emitted ONLY when the operator started `serve` with
`--enable-warm-swap`. The gating signal is
`config.enableWarmSwap` (from 1B's `AppConfig`). Add a private
`let warmSwapEnabled: Bool` field to `CoordinatorClient`,
populated from `config.enableWarmSwap` in the existing init.

**3. SPEC-011 R-3.3.1 + SPEC-001 v1.3 R-6.10.2 — `model_hash`
field format.** When emitted, `model_hash` MUST be:
  - A raw 64-character lowercase hex string
  - NO `sha256:` prefix
  - NO uppercase characters
  - The exact output of `modelWeightArtifactManifestHash()` at
    `ModelRuntime.swift:294-325` (which already returns
    lowercase hex via the `hexString()` helper at line 340)
The source-of-truth for the value is
`await modelRuntime.currentSnapshot().modelHash` (a `String?`).
If nil (model not loaded), the `model_hash` field MUST be
OMITTED entirely (not null, not empty string) from the
heartbeat frame.

**4. SPEC-011 R-3.3.3 + SPEC-001 v1.3 R-6.10.3 — `loading`
field semantics.** When emitted, `loading: Bool` MUST be:
  - `true` when `modelRuntime.currentSnapshot().state == .loading`
    or `.draining`
  - `false` when `.ready`
  - `.failed` is transient (see 1B's `RuntimeStateMachine`);
    if observed treat as `false` (the rollback brings state
    back to `.ready` before any heartbeat tick)
The field MUST always be emitted when warm-swap is enabled —
even when state is `.ready`, the field is present as `false`
(unlike `model_hash` which is omitted when nil). This is the
spec's distinction: `model_hash` is informational and conditional
on having a loaded model; `loading` is a state probe and always
present.

**5. SPEC-011 R-3.2.4 step 4 — immediate heartbeat after swap.**
When the swap completes (atomic-swap step 3 finishes and state
returns to `.ready`), the binary MUST emit a heartbeat as
quickly as possible carrying the NEW `model_hash` and
`loading: false`. The mechanism: a background task (spawned
in `start()` and torn down in `stop()`) consumes
`await modelRuntime.swapSignals()` and, on
`SwapSignal.Outcome.completed`, triggers `sendHeartbeat()`
out-of-cadence WITHOUT cancelling the regular heartbeat
schedule.

Implementation guidance:
  - Add a `swapHeartbeatTask: Task<Void, Never>?` field
  - In `start()` (when warm-swap is enabled), spawn the task
    that iterates `swapSignals()` and calls `try await
    sendHeartbeat()` on `.completed` outcomes
  - On `.failed` outcomes, do NOT emit a special heartbeat
    here (the state has already returned to `.ready` per 1B
    `failSwap`, and the regular heartbeat tick will reflect
    `loading: false` + OLD `model_hash`); however log an
    informational line `coordinator.warmSwap.swapFailed
    reason=<X>` for operator diagnostics
  - In `stop()` and `closeWebSocketAfterKeepaliveFailure()`,
    cancel the task
  - The task MUST be resilient to send failures — if
    `sendHeartbeat()` throws (WS dropped), log and continue
    iterating; the next signal triggers another attempt

The signal-driven heartbeat MUST share the same suspension
discipline as the regular heartbeat — both run as
`Task { ... }` against the actor's serial executor — so that
WS send ordering is preserved.

**6. SPEC-011 R-3.8.3 + SPEC-001 v1.3 R-6.10.5 — hello
reconnect source-of-truth.** The `helloMessage()` function
MUST be extended to:
  - When `warmSwapEnabled == true`: source `model_hash` from
    `await modelRuntime.currentSnapshot().modelHash` (the LIVE
    container hash, which is the OLD hash during in-flight
    loads because `applySwap` writes only AFTER load
    succeeds per 1B R-3.2.4 step 3)
  - When `warmSwapEnabled == false`: keep reading
    `snapshot.modelHash` from `providerStatus.snapshot()` as
    today (the existing line:
    `if let modelHash = snapshot.modelHash { message["model_hash"] = modelHash }`)
    — this preserves L-1 byte-identical default

A new test MUST construct a scenario where:
  1. ModelRuntime has OLD model_id "A" with OLD hash "old-hash"
  2. A swap to "B" is in-flight (state == .loading); the OLD
     container has NOT been replaced yet (1B R-3.2.2 / R-3.2.4)
  3. `helloMessage()` is called (simulating a WS reconnect)
  4. The returned message MUST contain `model_hash: "old-hash"`,
     NOT some new value, NOT empty, NOT missing

This is the "source-of-truth rule" the spec is naming.

**7. authProofMessage UNTOUCHED.** Per Phase 1A's deferral (the
prompt that produced 1A noted the proof-stage re-send of SPEC-010
fields is byte-frozen unless a CRITICAL audit finding forces it),
do NOT modify `authProofMessage` in 1D either. The proof-stage
heartbeat extension is OUT OF SCOPE; SPEC-011 R-3.3 covers
ongoing heartbeats, not the proof handshake.

**8. authInitialMessage UNTOUCHED.** The Phase 1A SPEC-010
emission block at line 670-682 is locked. 1D does NOT add
`model_hash` or `loading` to the v2 `auth_request` initial-stage
frame. The auth path already has its own optional `model_hash`
field (line 686-688) sourced from `providerStatus.snapshot()`;
that path is BOOT-TIME and operates BEFORE warm-swap is even
relevant. Leave it as is.

**9. ProviderStatus untouched.** Do NOT add a swap-aware update
to `ProviderStatus.modelHash` (the boot-time field). The
warm-swap signal flows through `ModelRuntime.currentSnapshot()`
exclusively. `ProviderStatus.modelHash` remains the
boot-snapshot reference used by disabled-mode paths and by the
SPEC-008 attestation hooks. Tests verify this isolation.

**10. d-inference clean-room.** Do NOT read any file under
`phase3-binary/.build/checkouts/`.

**11. Compile + tests pass.** `swift build` and `swift test` MUST
both exit 0. Cumulative test count after this phase SHOULD be
≥ 105 (97 from 1A+1B+1C + ≥ 8 new in 1D). All pre-existing
tests still GREEN.

**12. No drift in 1A/1B/1C surfaces.** Do NOT modify any 1A/1B/1C
file outside the two listed targets above. If a 1D requirement
seems to need a 1B/1C change, STOP and surface the conflict at
the top of your final report.

**13. authInitialMessage line numbers.** The SPEC-010 emission
block in `authInitialMessage` currently lives at lines 670-682
of `CoordinatorClient.swift`. The heartbeat extension lives in
`sendHeartbeat` at lines 588-605. The `helloMessage()` function
is at lines 692-720. These line numbers are reference anchors
for the audit — DO NOT refactor that part of the file in ways
that shift them (you may add lines at the end of `sendHeartbeat`
and inside `helloMessage` — that's normal — but do not introduce
unrelated refactors that move the existing handlers around).

## Required reading (in this order — read fully before writing)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   §6.10 (lines 1867-1916) — heartbeat extension and reconnect
   source-of-truth normative section. R-6.10.1 through R-6.10.5
   are binding.

2. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   §6.11.2 (lines 1930-1940) — WS drop mid-load policy. R-6.11.3
   and R-6.11.4 are binding (1D enforces the reconnect path; 1E
   handles operator-side concurrent-switch policy on the CLI
   side).

3. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   §3.3 (heartbeat extension R-3.3.0 through R-3.3.3) and §3.8
   (WS drop R-3.8.1, R-3.8.3, R-3.8.5) — full text.

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
   - Lines 78-132 (`init`) — add `warmSwapEnabled` and the swap
     signal task field
   - Lines 134-154 (`start` + `stop`) — wire the swap signal task
     lifecycle
   - Lines 465-481 (`startHeartbeat`) — existing heartbeat loop
   - Lines 588-605 (`sendHeartbeat`) — extend the JSON dict
   - Lines 648-690 (`authInitialMessage`) — DO NOT MODIFY
   - Lines 692-720 (`helloMessage`) — extend the model_hash
     source

5. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   lines 130-141 — `currentSnapshot()` and `swapSignals()` actor
   surface from 1B. Consumed unchanged.

6. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift`
   — `SwapSignal`, `SwapSignal.Outcome` types from 1B.

7. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
   handleSwitchRequest at lines 359-401 — the OTHER consumer of
   `swapSignals()`. 1D's consumer MUST be a separate
   `swapSignals()` call (each call returns a NEW AsyncStream;
   they don't share state). Verify by reading 1B's
   `RuntimeStateMachine.signalStream()` at lines 61-65:
   each call appends a new continuation to `signalContinuations`,
   so multiple consumers each get their own stream. Good.

8. `/Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`
   — existing test patterns including 1A's `authInitialMessage`
   and `helloMessage` tests. Mirror their fixture style for the
   new heartbeat / hello tests.

## Required edits — exact shape

### A. `CoordinatorClient.swift` — extend init

Add field:

```swift
private let warmSwapEnabled: Bool
private var swapHeartbeatTask: Task<Void, Never>?
```

In `init` (around line 121, after `self.publishesSupportedModels`),
assign:

```swift
self.warmSwapEnabled = config.enableWarmSwap
self.swapHeartbeatTask = nil
```

### B. `start()` and `stop()` — lifecycle the swap signal task

In `start()` (line 134), after the existing
`runTask = Task { ... }` block, spawn the swap signal consumer
when warm-swap is enabled. Suggested skeleton:

```swift
func start() {
    guard runTask == nil else { return }
    runTask = Task { [weak self] in
        await self?.runReconnectLoop()
    }
    if warmSwapEnabled {
        swapHeartbeatTask = Task { [weak self] in
            await self?.consumeSwapSignals()
        }
    }
}
```

Add a new private method:

```swift
private func consumeSwapSignals() async {
    let stream = await modelRuntime.swapSignals()
    for await signal in stream {
        if Task.isCancelled { return }
        switch signal.outcome {
        case .completed:
            do {
                try await sendHeartbeat()
            } catch {
                Self.keepaliveDebug("warm_swap_heartbeat_send_error error=\(error)")
            }
        case let .failed(reason):
            Self.keepaliveDebug("warm_swap_swap_failed reason=\(reason)")
        }
    }
}
```

In `stop()` (line 141), cancel the task:

```swift
func stop() async {
    runTask?.cancel()
    heartbeatTask?.cancel()
    swapHeartbeatTask?.cancel()
    // ... existing cleanup ...
    swapHeartbeatTask = nil
}
```

Also cancel in `closeWebSocketAfterKeepaliveFailure()` (line
489) IF the existing structure ties it to disconnect cleanup —
read the existing flow and match the discipline. The
`swapHeartbeatTask` MUST survive WS reconnect attempts (per
R-3.8.5 the in-process load is independent of WS connectivity).

### C. `sendHeartbeat()` — extend with conditional fields

Locate `sendHeartbeat()` at line 588. AFTER the existing
`providerStatus.snapshot(resetWindow: true)` and BEFORE the
`try await send(...)` call, add a conditional block that
augments the dict when warm-swap is enabled:

```swift
private func sendHeartbeat() async throws {
    let snapshot = await providerStatus.snapshot(resetWindow: true)
    var payload: [String: Any] = [
        "type": "heartbeat",
        "status": snapshot.status.rawValue,
        "model_id": snapshot.modelID ?? "",
        // ... existing fields ...
    ]
    if warmSwapEnabled {
        let runtimeSnapshot = await modelRuntime.currentSnapshot()
        if let hash = runtimeSnapshot.modelHash {
            payload["model_hash"] = hash
        }
        payload["loading"] = (runtimeSnapshot.state == .loading
                              || runtimeSnapshot.state == .draining)
    }
    try await send(payload)
}
```

Key points:
- `model_hash` only added if `runtimeSnapshot.modelHash != nil`
- `loading` ALWAYS added when warm-swap enabled (true or false)
- Both fields ABSENT when warm-swap disabled (L-1 invariant)

### D. `helloMessage()` — extend source-of-truth

Locate `helloMessage()` at line 692. Find the existing line
(around 715):

```swift
if let modelHash = snapshot.modelHash {
    message["model_hash"] = modelHash
}
```

REPLACE it with conditional source-of-truth:

```swift
let hashForHello: String? = await {
    if warmSwapEnabled {
        return await modelRuntime.currentSnapshot().modelHash
    }
    return snapshot.modelHash
}()
if let hashForHello {
    message["model_hash"] = hashForHello
}
```

(or equivalently, use an explicit `if warmSwapEnabled` /
`else` branch — whichever reads cleaner in context. The
KEY semantic: warm-swap enabled → read from modelRuntime;
warm-swap disabled → read from providerStatus.)

### E. `CoordinatorClientTests.swift` — extend

Reuse the existing test fixture style (the 1A
`testAuthInitialDefaultsToSingleEntryCatalog` and
`testHelloMessageUnchangedByPhase1A` tests are the model). Add
the following XCTests. Each constructs a `CoordinatorClient`
via the test init, calls the relevant frame builder, serializes
the result to JSON, and asserts on the JSON.

Required new tests:

- `testHeartbeatDisabledModeOmitsBothFields` — construct with
  `AppConfig.enableWarmSwap = false`, capture the serialized
  heartbeat JSON via the `sendOverride` mechanism (already in
  CoordinatorClient init), assert the JSON does NOT contain
  the substring `"model_hash"` AND does NOT contain `"loading"`.

- `testHeartbeatEnabledModeReadyEmitsLoadingFalse` — construct
  with `enableWarmSwap = true`, a `ModelRuntime` in `.ready`
  state with a known modelHash "test-hash", assert the JSON
  contains `"model_hash":"test-hash"` AND `"loading":false`.

- `testHeartbeatEnabledModeLoadingEmitsLoadingTrue` — construct
  with warm-swap enabled, drive the state machine to `.loading`
  (via 1B's `beginSwap` with a slow stub loader), capture a
  heartbeat WHILE the state is still `.loading`, assert
  `"loading":true`. Also assert `model_hash` is the OLD hash
  (because the swap hasn't completed yet, `currentSnapshot()`
  still returns the old container's hash).

- `testHeartbeatEnabledModeOmitsModelHashWhenNil` — construct
  with warm-swap enabled and a `ModelRuntime` constructed with
  `modelID: nil` (no model loaded), assert the heartbeat JSON
  contains `"loading":false` but does NOT contain the substring
  `"model_hash"`.

- `testHelloDisabledModeReadsFromProviderStatus` — construct
  with `enableWarmSwap = false`, a `ProviderStatus` carrying
  `modelHash: "boot-hash"`, a `ModelRuntime` with a DIFFERENT
  hash "runtime-hash" (e.g., a stub that has been swapped),
  call `helloMessage()`, assert the JSON contains
  `"model_hash":"boot-hash"` (the providerStatus value, NOT
  the runtime value). This pins the L-1 disabled-mode source
  invariant.

- `testHelloEnabledModeReadsFromModelRuntime` — construct
  with `enableWarmSwap = true`, ProviderStatus has
  `modelHash: "boot-hash"`, ModelRuntime has hash
  "runtime-hash", call `helloMessage()`, assert the JSON
  contains `"model_hash":"runtime-hash"`.

- `testHelloDuringInFlightSwapReturnsOldHash` — this is the
  source-of-truth invariant (R-6.10.5). Construct with
  warm-swap enabled. Drive `beginSwap` to a NEW model with
  a slow stub loader. WHILE state is `.loading`, call
  `helloMessage()`. Assert the JSON's `model_hash` value
  matches the OLD container's hash (because `applySwap`
  hasn't run yet per 1B R-3.2.4 step 3). After awaiting the
  swap task, call `helloMessage()` again — assert the JSON's
  `model_hash` now matches the NEW hash.

- `testSwapCompletionTriggersImmediateHeartbeat` — construct
  with warm-swap enabled, capture heartbeats via
  `sendOverride`, drive a swap to completion, assert that
  WITHIN 500ms of the swap's `Task.value` returning, a
  heartbeat appeared in the capture buffer carrying the NEW
  `model_hash`. This pins R-3.2.4 step 4 "signal heartbeat
  task to emit a new heartbeat".

- (Optional but recommended) `testSwapFailureLogsAndContinues`
  — drive a failing swap with a throwing stub loader; assert
  the regular heartbeat cadence continues; no special heartbeat
  is emitted on `.failed`; if your implementation logs to a
  test-observable channel, assert the log line is present.

If `CoordinatorClient` initialization in these tests requires
the same fixture pattern as 1A (`ModelRuntime` with the test
init overload, a stubbed `Tier2AttestationGenerator`, etc.),
mirror that pattern. The `sendOverride` parameter on
`CoordinatorClient.init` is the standard way to capture frame
emissions in tests — use it.

## Done criteria

You are done when:

- `git diff -- specs/ phase4-coordinator/ phase5-gateway/` shows
  only the operator-authored BUILD prompts under
  `specs/BUILD_SPEC_001_v1_3_IMPL_*` and the pre-existing
  `specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged edit.
- `git diff -- phase3-binary/Sources/MacProviderCore/
  phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift
  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
  phase3-binary/Sources/macprovider-cli/HTTPServer.swift
  phase3-binary/Sources/macprovider-cli/ControlSocket.swift
  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
  is empty (1D does not touch any of these).
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with ≥ 105 tests
  green.
- All Phase 1A + 1B + 1C tests still GREEN (no regressions).
- In disabled mode: heartbeat JSON does NOT contain `model_hash`
  or `loading` keys (verified by
  `testHeartbeatDisabledModeOmitsBothFields`).
- In disabled mode: hello JSON `model_hash` value matches
  `providerStatus.modelHash` (verified by
  `testHelloDisabledModeReadsFromProviderStatus`).
- In enabled mode: heartbeat carries `model_hash` (raw 64-char
  lowercase hex when non-nil; omitted when nil) and `loading:
  Bool` (always present).
- In enabled mode: `helloMessage()` reads `model_hash` from
  `modelRuntime.currentSnapshot()`, NOT from
  `providerStatus.snapshot()`.
- Swap completion triggers an immediate heartbeat carrying the
  new hash (verified by
  `testSwapCompletionTriggersImmediateHeartbeat`).

## Out of scope (do NOT do these in Phase 1D)

- CLI-side cooldown soft guard read/write — Phase 1E
- `--force` cooldown bypass behavior — Phase 1E
- Server-side `switch_ack accepted:false reason:cooldown`
  emission — Phase 1E
- WS drop reconnect path other than the `model_hash` source-of-
  truth rule (the actual reconnect machinery is already in
  CoordinatorClient.runReconnectLoop and is unchanged)
- Concurrent-switch policy beyond what 1C already implements
- `authProofMessage` SPEC-010 re-send — out of scope for 1D
  (would only matter if a CRITICAL audit on SPEC-010 forced it)
- Modifying `phase4-coordinator/` — Phase 2

## Self-check before reporting done

Run this command and confirm all checks pass:

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat -- specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  git diff --stat -- phase3-binary/Sources/MacProviderCore/ phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift phase3-binary/Sources/macprovider-cli/HTTPServer.swift phase3-binary/Sources/macprovider-cli/ControlSocket.swift phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -5) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | grep "Executed.*tests" | tail -3) && \
  echo "----" && \
  grep -n "model_hash\|\"loading\"" phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift | head -10
```

The second diff stat MUST show 0 files changed (no out-of-scope
edits).

Return:
- A brief diff summary (files touched, +/- lines).
- The final `swift test` summary line (Executed N tests, ...).
- Any spec rule you were unable to satisfy exactly, with the
  binding rule number and your interpretation.

Do NOT commit. Do NOT push. The operator audits the working tree
before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 60-90 min. 1D is smaller than 1B/1C —
  one file modified, one test file extended, no new files.
- Audit pass (Claude Opus) reads the diff and tests against the
  13 constraints + done criteria. Key audit foci:
  - **Constraint 1 (L-1)** — verify both heartbeat and hello
    frames are byte-identical to v1.2.4 in disabled mode.
    The disabled-mode hello must source `model_hash` from
    `providerStatus`, NOT `modelRuntime` — a regression here
    breaks L-1.
  - **Constraint 5 (immediate heartbeat after swap)** —
    verify the `swapHeartbeatTask` is correctly spawned in
    `start()` AND torn down in `stop()`. Test the
    swap-completion trigger end-to-end with timing assertions.
  - **Constraint 6 (hello source-of-truth)** — verify the
    enabled-mode hello reads `currentSnapshot().modelHash`
    and that the test pinning the in-flight case actually
    captures the OLD hash (not nil, not the new hash).
- R2 prompt is drafted only if R1 audit surfaces findings.
- After 1D LOCKs and commits to the branch, draft 1E
  (cooldown soft guard + `--force` bypass + concurrent-switch
  policy elaboration + end-to-end ACs) — the final phase of
  SPEC-001 v1.3 binary implementation.

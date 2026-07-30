# Implementation BUILD prompt — SPEC-001 v1.3 Phase 1B (warm-swap gate + state machine + ModelRuntime refactor)

Operator-paste prompt for Codex GPT-5 to land the **second** of five
implementation sub-phases of SPEC-001 v1.3 in `phase3-binary/`. This
phase is the foundational SPEC-011 refactor: it introduces the
warm-swap opt-in gate, the 4-state runtime state machine, the
`ModelRuntime` actor refactor from immutable container to actor-
isolated mutable `current_container`, and inference-rejection wiring
when the runtime is loading or draining. Phases 1C (control socket +
`models` subcommand) and 1D (heartbeat extension) consume the state
machine and `swap(...)` API that 1B establishes.

**Scope: SPEC-011 v0.5 binary runtime surface only (no operator-facing
wire yet).** No control socket, no `models` subcommand, no heartbeat
extension, no WS drop policies. Those are 1C-1E.

**One-line summary.** Add `--enable-warm-swap` and
`--swap-drain-timeout-seconds` CLI flags plumbed through CLI > ENV >
YAML; create `RuntimeStateMachine.swift` (a thread-safe actor holding
`SwapState`); refactor `ModelRuntime` from immutable `let container`
to actor-isolated mutable `currentContainer` exposing
`currentSnapshot()` (snapshot read) and `beginSwap(targetModelID:
loader:)` (atomic four-step replacement per SPEC-011 R-3.2.4) without
blocking the actor's serial executor (the load task runs detached
per no-starve R-3.2.5); wire `HTTPServer` to consult the state
machine and reject NEW inference with HTTP 503 +
`{error: {type: "service_unavailable", code: "provider_loading"}}`
when state is `loading` or `draining`. L-1 byte-identical default
preserved literally: in disabled mode the binary follows the
SPEC-001 v1.2.4 synchronous-load boot path and never opens the new
state-machine surface to operator-observable behavior.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-001 v1.3 §6.8 (this phase's normative section) and SPEC-001
  v1.3 AC-N.0 / AC-N.3 / AC-N.6 / AC-N.7
- SPEC-011 v0.5 §2 L-1 / L-2, §3.2 R-3.2.1 through R-3.2.7, §3.4
  R-3.4.4, §3.7 R-3.7.x, §3.9 config additions
- SPEC-001 v1.2.4 §6 (existing) — must remain byte-identical in
  disabled mode

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` after edits — must be empty (excluding operator-
authored BUILD prompts under `specs/BUILD_SPEC_001_v1_3_IMPL_*`).

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~90-120 min
(3 new Swift files, ~3 files modified, ~2 test files extended /
created).

Branch: `fix/spec-001-v1-3-binary` already carries Phase 1A. Codex
MUST commit on this branch, not create a new one, and MUST NOT
commit or push (operator audits before commit).

---

```
=== BEGIN PROMPT ===

You are implementing Phase 1B of SPEC-001 v1.3 in the Swift binary
at /Users/augstar/macprovider-poc/phase3-binary/. SPEC-001 v1.3 is
LOCKED. SPEC-011 v0.5 is LOCKED. Phase 1A (SPEC-010 catalog surface)
is already on this branch as commit 6744d7c.

You will edit/create the following files (and ONLY these):

  phase3-binary/Sources/MacProviderCore/Config.swift                       (extend)
  phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift          (NEW)
  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift                 (REFACTOR)
  phase3-binary/Sources/macprovider-cli/HTTPServer.swift                   (extend)
  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift               (extend)
  phase3-binary/Tests/macprovider-cliTests/RuntimeStateMachineTests.swift  (NEW)
  phase3-binary/Tests/macprovider-cliTests/ModelRuntimeSwapTests.swift     (NEW)
  phase3-binary/Tests/macprovider-cliTests/HTTPServerSwapTests.swift       (NEW)

You will NOT edit any file under specs/, phase4-coordinator/,
phase5-gateway/, or any other Swift file. Verify with
`git diff -- specs/ phase4-coordinator/ phase5-gateway/` — must be
empty before you finish.

You will NOT touch any 1A-introduced surface:
- `Sources/MacProviderCore/SupportedModels.swift` (DO NOT MODIFY)
- `Sources/macprovider-cli/CoordinatorClient.swift`
  `authInitialMessage(attempt:)` SPEC-010 emission block
  (DO NOT MODIFY; you may add unrelated state-machine plumbing
  elsewhere in the same file IF strictly necessary, but prefer
  routing state through `ProviderStatus` or `ModelRuntime`)
- The `ServeCommand.runSupportedModelsPreflight(_:)` helper
- The 1A tests

## Critical constraints

**1. L-1 byte-identical default per SPEC-001 v1.3 AC-N.0.**
A v1.3 binary started with `serve` and WITHOUT `--enable-warm-swap`
MUST behave byte-identical to a SPEC-001 v1.2.4 binary on the
following axes:
  - `ModelRuntime` boot is synchronous (R-6.8.7) — populate
    `currentContainer` once at init, transition directly to
    `ready` without ever passing through `loading`
  - No state-machine observation hooks fire on operator-facing
    surfaces (no heartbeat field changes, no `/v1/status` changes,
    no log lines)
  - HTTPServer inference behavior is unchanged (existing tests
    still green)
  - No control socket file is created (control socket is 1C, NOT
    1B; do not even add the placeholder)
The four-state machine still EXISTS in the process (the
`RuntimeStateMachine` instance is owned by `ModelRuntime`), but in
disabled mode it stays in `ready` from boot to shutdown and the
`swap(...)` API is either unreachable from production callers or
returns an error.

**2. SPEC-011 R-3.2.1 — mutable actor-isolated current_container.**
Refactor `ModelRuntime` such that:
  - `private var currentContainer: ModelContainer?`
  - `private var currentModelID: String?`
  - `private var currentModelHash: String?`
  - These three fields are written ONLY by `init(...)` (boot path,
    synchronous) and by the atomic-swap completion step inside
    `applySwap(...)`. They are READ by `currentSnapshot()` (a new
    actor method that returns an immutable `RuntimeSnapshot`
    struct) and by the existing `complete / stream / preflight`
    methods.
  - The existing `let modelID: String?`, `let container:
    ModelContainer?`, `let modelHash: String?` declarations are
    REPLACED by their `var` equivalents. The existing
    `loadedModelID`, `loadedModelHash`, `isLoaded` computed
    properties continue to work by reading the `var` fields.
  - All call sites of `modelRuntime.loadedModelID`,
    `.loadedModelHash`, `.isLoaded` continue to compile without
    changes.

**3. SPEC-011 R-3.2.4 — atomic four-step swap.** The
`beginSwap(...)` API on `ModelRuntime` MUST implement the
SPEC-011 R-3.2.4 four-step replacement:
  Step 1: transition state to `loading` and stamp the
    `target_model_id`
  Step 2: kick off the load on a DETACHED `Task` (per R-3.2.5
    no-starve isolation; the load MUST NOT run on the
    ModelRuntime actor's serial executor)
  Step 3: when load completes, ACQUIRE the actor and atomically:
    swap `currentContainer`, `currentModelID`, `currentModelHash`
    to the new values; transition state to `ready`; release any
    references to the OLD container
  Step 4: signal observers (a single `AsyncStream`-style channel
    or a continuation callback) that a new heartbeat MUST be
    emitted (the signal hook exists in 1B but is NOT consumed
    until Phase 1D; tests assert the signal fires)

The four-step contract MUST hold even if the swap is initiated
when in-flight inference requests are still running with the OLD
container. Those in-flight requests continue using their
snapshot reference per R-3.2.2 (constraint 6 below).

**4. SPEC-011 R-3.2.5 — no-starve isolation.** The load task
inside `beginSwap` MUST be a `Task.detached { ... }` (or an
equivalent unstructured task on a non-actor executor). The
`ModelRuntime` actor's serial executor MUST remain unblocked
throughout `loading` and `draining` so that:
  - `currentSnapshot()` reads return promptly
  - `complete / stream` for in-flight requests using their
    OLD-container snapshot proceed without contention with the
    load task
  - Heartbeat emission (in Phase 1D) can read `currentSnapshot()`
    on cadence without waiting for the load to finish
Tests MUST prove this with a deliberately-slow stub loader
(`Task.sleep(nanoseconds: 100_000_000)` = 100ms) AND a concurrent
`currentSnapshot()` call that MUST return in < 10ms.

**5. SPEC-011 R-3.2.6 — rollback semantics.** If the load task
throws an error, `beginSwap` MUST:
  - NOT swap `currentContainer` (it stays as the OLD value)
  - Transition state `loading → failed → ready` (R-3.2.6 the
    `failed` state is observable for ONE state read, then
    immediately becomes `ready`; in 1B the `failed` state is
    transient — 1C will add the `switch_progress` CLI emission
    that reads `failed` exactly once)
  - Signal observers that the swap failed (with the error
    propagated) — same channel as step 4 above; the payload
    differentiates success vs failure
Tests MUST cover both the success path (state ends `ready` with
NEW container) and the failure path (state ends `ready` with OLD
container, observers got a `failed` signal).

**6. SPEC-011 R-3.2.2 — snapshot reads for in-flight inference.**
The existing `complete(_:shouldCancel:)` and
`stream(_:shouldCancel:onChunk:)` methods on `ModelRuntime` MUST
be refactored to grab a `RuntimeSnapshot` value (capturing
`(ModelContainer, String?, String?)` for current container /
model ID / model hash) AT THE START of the request, then perform
all subsequent work against that snapshot. A swap that completes
DURING an in-flight request MUST NOT affect the in-flight
request's container reference; the in-flight request finishes
with the OLD weights. Tests MUST prove this with a stub
`ModelContainer.perform` that signals "still running" while a
concurrent `beginSwap` completes.

**7. SPEC-011 R-3.2.3 / R-3.4.4 — inference rejection during
loading / draining.** The HTTP request entry point in
`HTTPServer.swift` (find the existing chat completions handler
around line 184-232) MUST consult `modelRuntime.currentSnapshot()`
(or an equivalent state probe) BEFORE accepting the request:
  - If state is `loading` or `draining`: respond HTTP 503 with
    body
    `{"error": {"type": "service_unavailable",
                "code": "provider_loading"}}`
    and DO NOT enter `complete` / `stream`. Note the exact
    `code` is `provider_loading` per SPEC-001 v1.3 §6.8.3 — NOT
    `model_loading`, NOT `service_loading`.
  - If state is `failed`: this case is transient and SHOULD NOT
    be observable to HTTP. If it ever happens, treat as
    `loading` (503).
  - If state is `ready`: proceed as today.
This check happens INSIDE the actor (call `currentSnapshot()`
to also retrieve the state). The state field on
`RuntimeSnapshot` is the source of truth.

**8. SPEC-011 R-3.2.7 — boot path UNCHANGED.** The existing
synchronous-load boot path in `ModelRuntime.init(modelID:
maxContextTokensOverride:)` is preserved. The init still calls
`LLMModelFactory.shared.loadContainer(...)` synchronously,
assigns `currentContainer` / `currentModelID` / `currentModelHash`
once, and the state machine is created already in `ready`
(NEVER transitions through `loading` on boot). Tests MUST
verify that for a fresh `ModelRuntime(modelID: nil)`, the
post-init state is `ready` and the snapshot has `nil`
container — matching the current v1.2.4 "no model" boot
behavior.

**9. SPEC-011 R-3.1.0 — `--enable-warm-swap` flag.** Add the
flag on `ServeCommand`. CLI > ENV
(`MACPROVIDER_ENABLE_WARM_SWAP`) > YAML (`enable_warm_swap:
bool`). Default DISABLED.
  - When disabled: `ModelRuntime.beginSwap(...)` MUST throw
    `WarmSwapDisabledError` (a new public Error with description
    `"warm swap is not enabled (start serve with
    --enable-warm-swap)"`). Tests MUST cover this.
  - When enabled: `beginSwap` proceeds per R-3.2.4. Tests MUST
    cover this with a stub loader (do NOT actually load MLX
    weights in tests).
The flag value MUST flow into `ModelRuntime` via the existing
init signature OR a new property setter — Codex chooses, but
the resolution MUST happen in `ServeCommand.run()` BEFORE
constructing the `ModelRuntime` instance.

**10. SPEC-011 §3.9 — `--swap-drain-timeout-seconds` flag.**
Add the flag on `ServeCommand`. CLI > ENV
(`MACPROVIDER_SWAP_DRAIN_TIMEOUT_S`) > YAML
(`swap_drain_timeout_s: int`). Default 30 seconds. The value
is stored on `AppConfig` and on `ModelRuntime`; in 1B the value
is parked (used only by tests to verify it survives the
plumbing). 1E will wire it into actual drain logic.

**11. Test-only loader injection point.** Add an init overload
on `ModelRuntime` (test-only, marked `internal` or
`@testable internal`) that takes a
`loader: @Sendable (String) async throws -> (ModelContainer,
String, String?)` closure. The production init uses the real
`LLMModelFactory.shared.loadContainer`; tests inject a stub
that returns a fake `ModelContainer` (or a `nil`-equivalent
sentinel that the test code handles without actually invoking
`container.perform`). DO NOT use Swift `#if DEBUG` /
`#if TESTING` guards; just expose the overload with
`internal` visibility.

**12. d-inference clean-room.** Do NOT read any file under
`phase3-binary/.build/checkouts/`. Use only the public SPEC +
the in-repo Swift sources for grounding.

**13. Compile + tests pass.** `swift build` and `swift test`
MUST both exit 0. The cumulative test count after this phase
SHOULD be around 70-75 (54 from 1A + 16-21 new in 1B). All
pre-existing tests still GREEN.

**14. NO control socket, NO models subcommand, NO heartbeat
extension.** Those are 1C/1D. If a test convenience would
benefit from a control socket file, DO NOT add one — drive the
test via direct `modelRuntime.beginSwap(...)` calls instead.

## Required reading (in this order — read fully before writing)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   §6.8 (lines 1748-1809) — the warm-swap state machine normative
   section. R-6.8.1 through R-6.8.7 are binding.

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 — focus on:
   - §2 L-1 / L-2 (byte-identical default, opt-in gate)
   - §3.2 R-3.2.1 through R-3.2.7 (state machine, atomic swap,
     in-flight snapshot, no-starve, rollback, boot)
   - §3.4 R-3.4.4 (drain HTTP 503 envelope)
   - §3.9 config additions (drain timeout default)

3. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   — full file (lines 1-437). The refactor MUST preserve:
   - The `ModelRuntimeServing` protocol surface
   - `loadedModelID`, `loadedModelHash`, `isLoaded` computed
     properties
   - `complete / stream / preflight` semantics for in-flight
     requests (R-3.2.2 snapshot reads)
   - The existing `Self.configuration(for:)`,
     `Self.modelWeightArtifactManifestHash(...)`,
     `Self.defaultMaxContextTokens()`, output filters, etc.

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
   — focus on the chat completions handler (around lines 184-232)
   and the streaming handler. Inference rejection wiring goes
   here.

5. `/Users/augstar/macprovider-poc/phase3-binary/Sources/MacProviderCore/Config.swift`
   — mirror the existing `assign(...)` helper pattern for the two
   new YAML / ENV / CLI keys, matching Phase 1A's plumbing style.

6. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
   — `ServeCommand`. Add the two new `@Flag` / `@Option` fields
   after the existing 1A `--supported-models` /
   `--publish-supported-models` flags, mirroring their style.

7. `/Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/ModelRuntimeHashTests.swift`
   — existing test patterns for `ModelRuntime`. Mirror the
   fixture style.

8. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions.

## Required edits — exact shape

### A. `RuntimeStateMachine.swift` — NEW file

```swift
import Foundation

public enum SwapState: String, Sendable, Equatable {
    case ready
    case loading
    case draining
    case failed
}

public struct SwapSignal: Sendable {
    public enum Outcome: Sendable {
        case completed(newModelID: String, newModelHash: String?)
        case failed(reason: String)
    }
    public let targetModelID: String
    public let outcome: Outcome
}

public actor RuntimeStateMachine {
    private var state: SwapState = .ready
    private var targetModelID: String?
    private var signalContinuations: [AsyncStream<SwapSignal>.Continuation] = []

    public init() {}

    public func current() -> SwapState { state }
    public func currentTargetModelID() -> String? { targetModelID }

    public func transitionToLoading(target: String) throws {
        guard state == .ready else {
            throw RuntimeStateMachineError.notReady(current: state)
        }
        state = .loading
        targetModelID = target
    }

    public func transitionToDraining() throws { /* state == .loading guard */ }
    public func completeSwap(newModelID: String, newModelHash: String?) { /* state -> ready, signal completed */ }
    public func failSwap(reason: String) { /* state loading -> failed -> ready, signal failed */ }

    public func signalStream() -> AsyncStream<SwapSignal> {
        AsyncStream { continuation in
            signalContinuations.append(continuation)
        }
    }
}

public enum RuntimeStateMachineError: Error, Equatable {
    case notReady(current: SwapState)
}
```

(The exact body is your responsibility; the public surface must
match the above.)

### B. `WarmSwapDisabledError` — public Error in ModelRuntime.swift

```swift
public struct WarmSwapDisabledError: Error, CustomStringConvertible {
    public var description: String {
        "warm swap is not enabled (start serve with --enable-warm-swap)"
    }
}
```

### C. `ModelRuntime.swift` — refactor

Change the three `let` fields to `var`. Add:

```swift
private let stateMachine: RuntimeStateMachine
private let warmSwapEnabled: Bool
private let loader: @Sendable (String) async throws -> (ModelContainer, String, String?)
```

The default loader (used by production init) wraps
`LLMModelFactory.shared.loadContainer`. The test init overload
injects an arbitrary loader.

Add two new actor methods:

```swift
public struct RuntimeSnapshot: Sendable {
    public let state: SwapState
    public let container: ModelContainer?
    public let modelID: String?
    public let modelHash: String?
}

func currentSnapshot() async -> RuntimeSnapshot {
    RuntimeSnapshot(
        state: await stateMachine.current(),
        container: currentContainer,
        modelID: currentModelID,
        modelHash: currentModelHash
    )
}

func beginSwap(targetModelID: String) async throws -> Task<Void, Error> {
    guard warmSwapEnabled else { throw WarmSwapDisabledError() }
    try await stateMachine.transitionToLoading(target: targetModelID)
    return Task.detached { [stateMachine, loader] in
        do {
            let (container, modelID, modelHash) = try await loader(targetModelID)
            await self.applySwap(container: container, modelID: modelID, modelHash: modelHash)
        } catch {
            await stateMachine.failSwap(reason: String(describing: error))
        }
    }
}

private func applySwap(container: ModelContainer, modelID: String, modelHash: String?) async {
    currentContainer = container
    currentModelID = modelID
    currentModelHash = modelHash
    await stateMachine.completeSwap(newModelID: modelID, newModelHash: modelHash)
}
```

Refactor `complete / stream / preflight` to grab `let snapshot =
await currentSnapshot()` at the start and check
`snapshot.state == .ready`; if not, throw `APIError(status: 503,
message: "Model loading", type: "service_unavailable", code:
"provider_loading")`. The existing `container` reference inside
these methods becomes `snapshot.container`.

### D. `HTTPServer.swift` — inference rejection wiring

In the chat completions handler at around line 184, BEFORE the
existing dispatch to `modelRuntime.complete(...)` / `.stream(...)`,
add a state check:

```swift
let snapshot = await modelRuntime.currentSnapshot()
if snapshot.state != .ready {
    // emit HTTP 503 with body
    // {"error": {"type": "service_unavailable", "code": "provider_loading"}}
    return
}
```

(Exact location and dispatch shape is your responsibility; check
both the non-streaming `Task.detached` branch at line 196 and the
`handleStreamingChatCompletions` branch at line 191.)

### E. `Config.swift` — extend

Add to `AppConfig`:

```swift
public var enableWarmSwap: Bool
public var swapDrainTimeoutSeconds: Int
```

Defaults: `false` and `30`. Plumb YAML keys `enable_warm_swap:
bool` and `swap_drain_timeout_s: int`. ENV vars
`MACPROVIDER_ENABLE_WARM_SWAP` and
`MACPROVIDER_SWAP_DRAIN_TIMEOUT_S`. Add to `CLIOverrides` and
`applyCLI` per existing pattern.

(NOTE: there's an existing `drainTimeoutSeconds: Int` on AppConfig
default 30 — that's the GENERAL drain timeout for shutdown, NOT
the SPEC-011 swap drain timeout. Add `swapDrainTimeoutSeconds` as
a separate field; do NOT reuse `drainTimeoutSeconds`.)

### F. `MacProviderCLI.swift` — extend ServeCommand

Add two new fields after the Phase 1A SPEC-010 flags:

```swift
@Flag(name: .customLong("enable-warm-swap"), inversion: .prefixedNo,
      help: "Opt into the operator-pushed warm model swap workflow (SPEC-011 v0.5). Default off. When off, the binary follows the SPEC-001 v1.2.4 synchronous-load path; no control socket is opened.")
var enableWarmSwap: Bool?

@Option(help: "Drain timeout in seconds for an in-flight warm swap (SPEC-011 v0.5 §3.4 / §3.9). Default 30. Only meaningful when --enable-warm-swap is set.")
var swapDrainTimeoutSeconds: Int?
```

Plumb both through `CLIOverrides` and into `ConfigLoader.load`. The
resolved `AppConfig.enableWarmSwap` and `swapDrainTimeoutSeconds`
flow into `ModelRuntime(modelID:..., warmSwapEnabled:
resolved.enableWarmSwap, ...)`.

### G. `RuntimeStateMachineTests.swift` — NEW

Cover:
- `testInitialStateIsReady` — fresh machine reports `.ready`
- `testTransitionToLoadingFromReady` — succeeds, current returns
  `.loading`, target reflects argument
- `testTransitionToLoadingFromLoadingRejected` — throws
  `.notReady`
- `testCompleteSwapTransitionsToReady` — `.loading → .ready`
- `testFailSwapTransitionsToReadyViaFailed` — `.loading →
  .failed → .ready` (observable via signal stream)
- `testSignalCompleted` — completion emits `Outcome.completed`
  with new model ID + hash on the stream
- `testSignalFailed` — failure emits `Outcome.failed` with the
  reason string

### H. `ModelRuntimeSwapTests.swift` — NEW

Cover (all using `ModelRuntime` with the test-injected loader;
do NOT touch real MLX):
- `testDisabledModeRejectsSwap` —
  `ModelRuntime(modelID: nil, warmSwapEnabled: false)`, call
  `beginSwap(...)` → throws `WarmSwapDisabledError`
- `testEnabledModeAcceptsSwap` — start enabled, beginSwap with
  a 50ms stub loader, await the returned Task, snapshot state
  ends `.ready` with new model ID + hash
- `testInFlightInferenceUsesOldSnapshot` — start enabled with
  an initial fake container, begin a slow `complete(...)`
  call that holds a snapshot, concurrently call `beginSwap` to
  a new container, the `complete` call observes the OLD container
- `testLoadFailureRollsBack` — beginSwap with a loader that
  throws after 50ms, await, snapshot state ends `.ready`,
  container / modelID / modelHash unchanged from pre-swap
- `testNoStarveSnapshotRespondsDuringLoad` — beginSwap with
  100ms loader, concurrently call `currentSnapshot()` 20 times
  in a tight loop, each call MUST return in < 10ms wall-clock
  (assert `Date()` measurements)
- `testBootPathDoesNotPassThroughLoading` — instantiate
  `ModelRuntime(modelID: nil)`, immediately call
  `currentSnapshot()`, state MUST be `.ready` (NEVER observed
  `.loading` during init)

### I. `HTTPServerSwapTests.swift` — NEW

Cover:
- `testInferenceReturns503WhenLoading` — set state machine to
  `.loading`, POST a chat completions request, response is
  HTTP 503 with body containing
  `"code":"provider_loading"` AND
  `"type":"service_unavailable"`
- `testInferenceReturns503WhenDraining` — same with draining
- `testInferenceProceedsWhenReady` — state `.ready`, request
  passes through to `modelRuntime.complete` (mocked to return
  a canned response)

(If wiring an HTTP-level test is too heavyweight for the in-
process server, fall back to driving the dispatcher directly
with a fake request/response pair — but the assertion remains
on the 503 + body shape.)

## Done criteria

You are done when:

- `git diff -- specs/ phase4-coordinator/ phase5-gateway/` shows
  only the operator-authored BUILD prompts under
  `specs/BUILD_SPEC_001_v1_3_IMPL_*` (those are NOT your edits)
  and the pre-existing
  `specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged edit.
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with ≥ 70 tests
  green (54 from 1A + ≥ 16 new in 1B).
- All Phase 1A tests still GREEN (54 from R2).
- `grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/` returns
  zero matches.
- `grep -rn "ctl.sock\|ControlSocket\|ModelsSubcommand\|models switch"
  phase3-binary/Sources/` returns zero matches (those are 1C).
- `grep -rn "model_hash.*loading\|loading.*model_hash"
  phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  returns zero matches (heartbeat extension is 1D).
- A new `ModelRuntime` instantiated without `--enable-warm-swap`
  exhibits `currentSnapshot().state == .ready` immediately and
  `beginSwap(...)` throws `WarmSwapDisabledError`.
- A `ModelRuntime` instantiated with `--enable-warm-swap` and a
  stub loader can complete a swap (state ends `.ready` with new
  model ID).

## Out of scope (do NOT do these in Phase 1B)

- Control socket / NDJSON protocol — Phase 1C
- `models list / switch / status` subcommand — Phase 1C
- `--ctl-socket-path` and `--switch-state-path` flags — Phase 1C
- Heartbeat `model_hash` / `loading` fields on the wire — Phase 1D
- `helloMessage()` source-of-truth rule on WS reconnect — Phase 1D
- Concurrent switch policy (typed switch_ack with `loading_in_progress`)
  — Phase 1E
- WS drop mid-load policies — Phase 1E
- Cooldown soft guard + `--force` flag — Phase 1E
- Modifying `phase4-coordinator/` — Phase 2

## Self-check before reporting done

Run this command and confirm all checks pass:

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat -- specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -5) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | grep "Executed.*tests" | tail -3) && \
  echo "----" && \
  grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/ || echo "no XDG_RUNTIME_DIR (correct)" && \
  echo "----" && \
  grep -rn "ctl.sock\|ControlSocket\|ModelsSubcommand" phase3-binary/Sources/ || echo "no control socket / models subcommand (correct)"
```

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

- Expected wall-clock: 90-120 min. 1B is the heaviest phase: the
  ModelRuntime refactor touches the hot path and the no-starve
  isolation invariant is subtle.
- Audit pass (Claude Opus) reads the diff and tests against the
  14 constraints + done criteria. Key audit foci:
  - **Constraint 4 (no-starve)** — verify the load runs on a
    detached task, not on the actor's executor. Look for
    `Task.detached` and confirm the actor isn't blocked.
  - **Constraint 6 (in-flight snapshot)** — verify `complete` /
    `stream` capture a snapshot at request start and don't re-
    read the actor's mutable state mid-request.
  - **Constraint 8 (boot path)** — verify state machine starts
    in `.ready` and `init` never calls `transitionToLoading`.
  - **L-1** — run the full test suite with all Phase 1A tests
    and confirm they're untouched; spot-check the wire emission
    of `authInitialMessage` and `helloMessage` against R1
    snapshots.
- R2 prompt is drafted only if R1 audit surfaces findings.
- After 1B LOCKs and commits to the branch, draft 1C
  (control socket + `models` subcommand) referencing the actual
  `RuntimeStateMachine` and `ModelRuntime.beginSwap` API
  signatures as they landed.

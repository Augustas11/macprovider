# PR #5 pre-merge fix prompt — 5 blocking findings (1 CRITICAL + 4 MAJOR)

Operator-paste prompt for Codex GPT-5 to land the **pre-merge fixes**
for findings surfaced by the external audit at
`.omc/artifacts/ask/codex-execute-the-audit-prompt-at-users-augstar-macprovider-poc-sp-2026-06-07T00-27-31-529Z.md`.

The audit verdict on PR #5 was **BLOCK-MERGE** (1 CRITICAL / 4 MAJOR /
1 MINOR). The MINOR (arch:1.1 — test fd dup2 race) is deferred to a
later cleanup PR; this prompt addresses the 5 blockers.

**Scope:** real drain semantics + snapshot atomicity refactor +
`--swap-drain-timeout-seconds` range validation + server-side
`supported_models` enforcement on the control socket + bounded
control-socket reads with per-read timeout.

This is the **R1 fix prompt** for the pre-merge audit. After Codex
returns, Claude Opus re-audits the diff; if clean, the same external
Codex audit re-runs as R2 to confirm; if findings remain, R3 prompt is
drafted.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~120-180 min
(the drain implementation + snapshot refactor are non-trivial; the
remaining fixes are smaller).

Branch: `fix/spec-001-v1-3-binary` carries Phases 1A-1E. Codex MUST
commit on this branch, MUST NOT create a new one, MUST NOT commit or
push (operator audits before commit).

---

```
=== BEGIN PROMPT ===

You are landing the pre-merge audit fixes for PR #5 in the Swift
binary at /Users/augstar/macprovider-poc/phase3-binary/. PR #5
carries five commits implementing SPEC-001 v1.3 Phase 1A-1E
(6744d7c, 5c03e88, 9a4a6c5, 3c1da34, 5d013f5). An external Codex
audit on the branch returned BLOCK-MERGE with 5 blocking findings.

Your job is to land all 5 blocking fixes in a single working-tree
session. The operator will commit + push.

You will edit/create the following files (and ONLY these):

  phase3-binary/Sources/MacProviderCore/Config.swift                          (extend)
  phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift             (REFACTOR — significant)
  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift                    (REFACTOR — significant)
  phase3-binary/Sources/macprovider-cli/ControlSocket.swift                   (extend — server-side validation + bounded reads + per-read timeout)
  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift                  (extend — drain timeout range validation, pass supportedModels into ControlSocketServer)
  phase3-binary/Tests/macprovider-cliTests/RuntimeStateMachineTests.swift     (extend OR rewrite to match the demoted-state shape)
  phase3-binary/Tests/macprovider-cliTests/ModelRuntimeSwapTests.swift        (extend with drain + snapshot atomicity tests)
  phase3-binary/Tests/macprovider-cliTests/ControlSocketTests.swift           (extend with bounded-read + per-read-timeout tests)
  phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift        (extend with server-side rejection test)

You will NOT edit any file under `specs/`, `phase4-coordinator/`,
`phase5-gateway/`, or any other Swift file. Verify with
`git diff -- specs/ phase4-coordinator/ phase5-gateway/` after edits
(must be empty excluding operator-authored BUILD/AUDIT prompts).

## Findings to fix

### Finding 1 — CRITICAL [code:1.1] — Real `draining` semantics + `swap_drain_timeout` not implemented

**Spec reference:** SPEC-011 v0.5 §3.4 (drain semantics, R-3.4.1
through R-3.4.5); SPEC-001 v1.3 §6.8 (incorporates draining state
into HTTP 503 contract at R-6.8.4); SPEC-011 §3.9 (drain timeout
default 30s, range 5...600).

**Current bug:** `ModelRuntime.beginSwap` transitions
`.loading → .ready` directly via `applySwap()` after the load
completes. The `draining` state exists in `SwapState` but no
production code path enters it. The `swap_drain_timeout_seconds`
flag is stored in `ModelRuntime` but never read. The control
socket emits a synthetic `draining` progress frame
(`ControlSocket.swift:379`) before `loaded` but the runtime has
already swapped.

**Required behavior (per SPEC-011 §3.4):**

The four-state machine MUST be:
- `.ready` → `.loading` (on `beginSwap` call)
- `.loading` → `.draining` (when async load completes, BEFORE atomic
  swap) — emit a SwapSignal so the control socket can publish a
  real `draining` switch_progress frame
- `.draining` → `.ready` (after drain window closes AND atomic
  swap is applied) — emit the existing completion signal
- `.loading` → `.failed` → `.ready` (on load failure — unchanged from 1B)

**Drain window enforcement:** After entering `.draining`, the
detached load task MUST:

1. Note the drain start time (`drainStartMs`)
2. Poll until either:
   a. `providerStatus.requestsInFlight == 0` — all in-flight
      requests against the OLD container have completed; safe to
      swap immediately
   b. `now - drainStartMs > swapDrainTimeoutSeconds * 1000` —
      drain window expired; proceed with the atomic swap regardless
      (in-flight requests continue to hold their snapshot
      reference to the OLD container per R-3.2.2; they complete
      normally even after the field is swapped)
3. Apply the atomic swap (write new container/modelID/modelHash)
4. Transition `.draining → .ready`
5. Signal completion (`SwapSignal.Outcome.completed`)

The poll interval is 50ms (`Task.sleep(nanoseconds: 50_000_000)`)
— short enough to be responsive, long enough to not burn CPU.

**Inference rejection during draining is ALREADY handled** by the
existing `validateReady(_:)` check in `complete`/`stream`/`preflight`
— it throws on any state != `.ready`. No change needed there.

**Signal stream for control socket:** Currently `SwapSignal` has
two outcomes: `.completed` and `.failed`. To support the real
`draining` frame, ADD a new outcome:

```swift
public enum Outcome: Sendable {
    case loadCompleted(newModelID: String, newModelHash: String?)    // RENAMED from .completed
    case drainStarted(elapsedMs: Int)                                  // NEW
    case completed(newModelID: String, newModelHash: String?)          // KEPT (post-swap completion)
    case failed(reason: String)                                         // KEPT
}
```

Wait — renaming `.completed` is a breaking change for the
CoordinatorClient swap-heartbeat task ([CoordinatorClient.swift:162](phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:162)).
Instead, KEEP `.completed` as the final "post-swap, state is ready"
signal AND add a new outcome for the draining-started moment:

```swift
public enum Outcome: Sendable {
    case loadFinished                              // NEW — load done, draining started
    case completed(newModelID: String, newModelHash: String?)  // KEPT — atomic swap done, state .ready
    case failed(reason: String)                     // KEPT
}
```

The control socket `handleSwitchRequest` consumes the signal
stream and emits `switch_progress` frames mapped to states:
- On `.loadFinished` signal → emit `switch_progress state: draining`
- On `.completed` signal → emit `switch_progress state: loaded`
- On `.failed` signal → emit `switch_progress state: failed reason: X`

The CoordinatorClient's `consumeSwapSignals` continues to react only
to `.completed` (immediate heartbeat) and `.failed` (log); it ignores
`.loadFinished`.

**Drain timeout source:** `ModelRuntime.swapDrainTimeoutSeconds`
already plumbed via init from `AppConfig.swapDrainTimeoutSeconds`.
Read it in the detached drain task. Default 30. Range 5...600
enforced by Finding 3 below.

### Finding 2 — MAJOR [code:1.2] — Mixed state/container observable during swap

**Spec reference:** SPEC-011 R-3.2.4 (atomic four-step swap).

**Current bug:** `applySwap` writes `currentContainer` /
`currentModelID` / `currentModelHash` THEN awaits
`stateMachine.completeSwap()`. The await yields actor isolation.
A concurrent `currentSnapshot()` can call `stateMachine.current()`
(returns `.loading`), then read `currentContainer` (already new).
Result: snapshot reports `state == .loading` with the new
container — inconsistent state.

**Required behavior:** `currentSnapshot()` MUST be an atomic
read returning a consistent view of `(state, container, modelID,
modelHash)`. No interleaving between the state read and the field
reads.

**Required refactor:** Move state ownership INTO `ModelRuntime`.
Demote `RuntimeStateMachine` to a stateless transition-rule
validator (or remove it entirely and inline its logic into
`ModelRuntime`).

Concretely:

1. Add `private var state: SwapState` to `ModelRuntime`. Initialize
   to `.ready` in the production init.

2. Add `private var signalContinuations: [AsyncStream<SwapSignal>.Continuation] = []`
   to `ModelRuntime`. The signal stream moves with the state.

3. Add the transition methods directly to `ModelRuntime`:
   - `private func transitionToLoading(target: String) throws` —
     guards `state == .ready`, sets `state = .loading`
   - `private func transitionToDraining()` — guards `state == .loading`,
     sets `state = .draining`, emits `.loadFinished` signal
   - `private func completeSwapAtomically(container: ModelContainer?, modelID: String, modelHash: String?)` —
     SINGLE non-await actor method that writes ALL FOUR fields
     (state, container, modelID, modelHash) and emits the
     `.completed` signal. This is THE atomic step.
   - `private func failSwap(reason: String)` — guards
     `state == .loading || .draining`, transitions through
     `.failed → .ready`, emits `.failed` signal

4. `RuntimeStateMachine.swift` — choose one:
   - (a) Remove the file entirely (state owned by ModelRuntime now;
     SwapState enum and SwapSignal types stay but move into
     ModelRuntime.swift or stay in their own file as pure types)
   - (b) Keep the file but reduce it to TYPE DECLARATIONS only
     (`SwapState`, `SwapSignal`, `RuntimeStateMachineError`).
     Remove the `RuntimeStateMachine` actor entirely.

   Prefer option (b) — keep `RuntimeStateMachine.swift` as a
   types-only file. Update `RuntimeStateMachineTests.swift` to
   test the transitions via `ModelRuntime`'s actor methods rather
   than the now-removed RuntimeStateMachine actor.

5. `currentSnapshot()` becomes a NON-await actor method:

   ```swift
   func currentSnapshot() -> RuntimeSnapshot {
       RuntimeSnapshot(
           state: state,
           container: currentContainer,
           modelID: currentModelID,
           modelHash: currentModelHash
       )
   }
   ```

   Callers that previously did `await modelRuntime.currentSnapshot()`
   still work — Swift actor methods are implicitly async to non-
   isolated callers. The KEY change: there's only ONE suspension
   point per snapshot call (the actor hop), not two.

6. `beginSwap` becomes (sketch):

   ```swift
   func beginSwap(targetModelID: String) async throws -> Task<Void, Error> {
       guard warmSwapEnabled else { throw WarmSwapDisabledError() }
       try transitionToLoading(target: targetModelID)  // actor-local, atomic
       let drainTimeoutSeconds = swapDrainTimeoutSeconds
       return Task.detached { [weak self] in
           guard let self else { return }
           do {
               let (container, modelID, modelHash): (ModelContainer?, String, String?)
               if let testLoader = await self.testLoader {
                   let (id, hash) = try await testLoader(targetModelID)
                   (container, modelID, modelHash) = (nil, id, hash)
               } else {
                   let (c, id, hash) = try await self.loader(targetModelID)
                   (container, modelID, modelHash) = (c, id, hash)
               }
               // Drain phase per SPEC-011 §3.4
               try await self.enterDrainPhase()
               try await self.waitForDrainOrTimeout(timeoutSeconds: drainTimeoutSeconds)
               // Atomic swap
               await self.completeSwapAtomically(container: container, modelID: modelID, modelHash: modelHash)
           } catch {
               await self.failSwap(reason: String(describing: error))
           }
       }
   }
   ```

   Where:
   - `enterDrainPhase()` is an actor method that does
     `transitionToDraining()` (guarded, emits `.loadFinished` signal)
   - `waitForDrainOrTimeout(timeoutSeconds:)` is the polling
     loop. It MUST NOT run on the actor's executor (use
     `Task.detached` or run inside the existing detached task) so
     it doesn't block other actor calls like `currentSnapshot`.

   The detached task is the safe place for the wait loop — it
   already runs off the actor. The wait body calls
   `await providerStatus.snapshot()` to read `requestsInFlight`
   each poll.

7. Tests in `RuntimeStateMachineTests.swift` need rewriting.
   Since `RuntimeStateMachine` actor is gone, the tests now
   exercise transitions via `ModelRuntime`. Either:
   - Rename the file to `ModelRuntimeStateTests.swift`, OR
   - Keep the filename and have tests use `ModelRuntime` instances
     to drive transitions (e.g., test that `beginSwap` rejects
     when state is `.loading`).

### Finding 3 — MAJOR [code:1.3] — `--swap-drain-timeout-seconds` range validation missing

**Spec reference:** SPEC-011 v0.5 §3.9 (drain timeout range
5...600); SPEC-001 v1.3 AC-25 (validation exit code 2).

**Current bug:** `AppConfig.swapDrainTimeoutSeconds` accepts any
Int from YAML / ENV / CLI without bounds checking.

**Required behavior:** In `ServeCommand.run()`, AFTER
`ConfigLoader.load(...)` returns and BEFORE constructing
`ModelRuntime`, validate:

```swift
if !(5...600).contains(resolved.swapDrainTimeoutSeconds) {
    FileHandle.standardError.write(Data((
        "--swap-drain-timeout-seconds \(resolved.swapDrainTimeoutSeconds) out of range 5...600\n"
    ).utf8))
    throw ExitCode(2)
}
```

The check goes right after the existing SPEC-010 preflight
(`runSupportedModelsPreflight`). Add a test
`testServeCommandExits2OnDrainTimeoutOutOfRange` in
`SupportedModelsTests.swift` (which already houses the static
preflight helper tests) or a new file
`DrainTimeoutValidationTests.swift` — Codex chooses.

Required test cases:
- `swapDrainTimeoutSeconds: 4` → ExitCode(2)
- `swapDrainTimeoutSeconds: 5` → passes (boundary inclusive)
- `swapDrainTimeoutSeconds: 30` (default) → passes
- `swapDrainTimeoutSeconds: 600` → passes (boundary inclusive)
- `swapDrainTimeoutSeconds: 601` → ExitCode(2)
- `swapDrainTimeoutSeconds: -1` → ExitCode(2)

### Finding 4 — MAJOR [sec:1.1] — Server-side switch bypasses CLI policy

**Spec reference:** SPEC-011 v0.5 R-3.1.2 step 2 (supported_models
validation); SPEC-010 v1.5 R-3.6.3 (pre-flight per validate);
threat model in audit prompt (same-UID local processes are
UNTRUSTED for the control socket).

**Current bug:** `ControlSocketServer.handleSwitchRequest`
([ControlSocket.swift:359](phase3-binary/Sources/macprovider-cli/ControlSocket.swift:359))
calls `modelRuntime.beginSwap(targetModelID:)` directly. It does
NOT validate `target_model_id` against the resolved
`supported_models` list. A same-UID local process can connect to
the `0600` socket, send a `switch_request` with any arbitrary
model string, and bypass the CLI's pre-flight.

**Required behavior:** ControlSocketServer MUST enforce the
same `supported_models` validation that the CLI does. On
validation failure, the server emits
`switch_ack accepted: false reason: not_in_supported_models`
(this reason value already exists in the `SwitchAckReason` enum
from Phase 1C).

**Required refactor:**

1. Add a parameter to `ControlSocketServer.init`:
   ```swift
   init(
       socketPath: URL,
       modelRuntime: ModelRuntime,
       supportedModels: [String]?   // NEW — the resolved catalog
   )
   ```
   Store it as `private let supportedModels: [String]?`.

2. In `ServeCommand.run()`, pass `resolved.supportedModels` into
   the `ControlSocketServer(...)` construction
   ([MacProviderCLI.swift:128](phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:128)).

3. In `handleSwitchRequest`, BEFORE calling `beginSwap`, validate:
   ```swift
   do {
       _ = try SupportedModels.validate(
           model: targetModelID,
           supportedModels: supportedModels
       )
   } catch SupportedModelsValidationError.modelNotInCatalog {
       try? await connection.send(.switchAck(
           accepted: false,
           reason: .notInSupportedModels,
           currentTarget: nil,
           secondsRemaining: nil
       ))
       await connection.close()
       return
   } catch {
       // Other validation errors (entry too long, etc.) shouldn't
       // happen here since the catalog was already validated at
       // ServeCommand startup. Treat as `.other` defensively.
       try? await connection.send(.switchAck(
           accepted: false,
           reason: .other,
           currentTarget: nil,
           secondsRemaining: nil
       ))
       await connection.close()
       return
   }
   ```

4. The CLI side (`ModelsSwitchCommand.run()`) ALREADY handles
   `not_in_supported_models` in the switch_ack rejection branch
   (currently only `loading_in_progress` and `cooldown` branches
   are explicit; the `default` falls through to exit 4 with
   "switch rejected"). Extend the switch over `reason` to add a
   case for `.notInSupportedModels` that exits code 2 with stderr
   `"switch target <X> not in --supported-models (rejected by serve)"`
   (the "(rejected by serve)" suffix distinguishes from the
   CLI-side pre-flight rejection at the same exit code).

5. Required test
   `testServerSideRejectsSwitchWhenNotInSupportedModels` in
   `ModelsSubcommandTests.swift`: start a ControlSocketServer
   with `supportedModels: ["A", "B"]` and a runtime with no
   client-side pre-flight (use a raw socket client that bypasses
   `ModelsSwitchCommand`). Send a `switch_request` for `"C"`.
   Assert the response is
   `.switchAck(accepted: false, reason: .notInSupportedModels, ...)`.

   Also: a CLI-side test that exercises the full flow with
   `ModelsSwitchCommand` parsing `--supported-models A,B` and
   targeting `C` should still exit 2 via the existing CLI
   pre-flight, NOT via the new server-side rejection (the CLI
   path catches it first). The audit cited this expectation.

### Finding 5 — MAJOR [sec:1.2] — Unbounded socket reads enable same-UID DoS

**Spec reference:** Audit threat model — local non-CLI same-UID
processes are in-scope adversaries for the control socket.

**Current bug:**
[ControlSocket.swift:464](phase3-binary/Sources/macprovider-cli/ControlSocket.swift:464)
`ControlSocketConnection.receive()` appends bytes into
`receiveBuffer` until it sees `0x0A`, with no max frame size and
no per-read timeout. Server-side calls don't pass a timeout
([ControlSocket.swift:320](phase3-binary/Sources/macprovider-cli/ControlSocket.swift:320)),
and accepted client tasks are detached without tracking, so the
server cannot cancel them on shutdown.

**Required behavior:**

1. Add a max frame size constant:
   ```swift
   public static let maxFrameBytes = 64 * 1024  // 64 KB
   ```
   on `ControlSocketConnection`. Inside the read loop, if
   `receiveBuffer.count > maxFrameBytes`, throw
   `ControlSocketConnectionError.frameTooLarge(size: Int)` (add
   this new case to the enum) and close the connection.

2. Add a per-connection idle timeout. In `handleClient`, wrap
   the receive in a 30s timeout:
   ```swift
   let frame = try await connection.receive(timeout: 30.0)
   ```
   The existing `receive(timeout:)` overload already supports
   this; the server just needs to pass a value instead of nil.

   30 seconds is the IDLE timeout — time between accept and
   first frame, or between sequential frames the server expects
   to read. Note that AFTER the server sends the switch_ack and
   enters the switch_progress streaming phase, it does NOT read
   from the client (only writes). The 30s timeout matters for
   the initial frame read.

3. Track accepted client tasks so the server can cancel them on
   `stop()`. Add a private field:
   ```swift
   private var clientTasks: [Task<Void, Never>] = []
   ```
   In the accept loop, when spawning a client task, append it
   to `clientTasks`. Periodically prune completed tasks (or
   simply rebuild the array as `clientTasks = clientTasks.filter
   { !$0.isCancelled }` on each accept iteration; the array
   stays bounded by the concurrent connection count). In
   `stop()`, before unlinking the socket, cancel all:
   ```swift
   for task in clientTasks {
       task.cancel()
   }
   clientTasks.removeAll()
   ```

4. Required tests in `ControlSocketTests.swift`:
   - `testReceiveRejectsFramesLargerThan64KB` — start a server,
     connect a raw socket, send a single line of 65536 bytes
     (no newline yet — or with newline at byte 65537), assert
     the server closes the connection and the test client gets
     EOF or `.closed`
   - `testReceiveTimesOutAfter30sIdle` — start a server, connect
     but never send anything, await up to 35 seconds, assert
     the server-side connection was closed. (You may use a
     shorter timeout for the test by adding a test-only init
     overload to `ControlSocketServer` that accepts a custom
     idle timeout — say, 200ms — and use that in the test. The
     production code path still uses 30s.)
   - `testServerStopCancelsActiveClientTasks` — start a server,
     connect a client that sits in receive (sends only a partial
     line), call `server.stop()`, assert the client gets EOF
     within 1 second.

## L-1 byte-identical default invariant

The drain phase and snapshot-atomicity refactor MUST NOT change
the L-1 baseline:
- A v1.3 binary started WITHOUT `--enable-warm-swap` still has
  `state == .ready` throughout its lifetime; no drain phase ever
  runs (because `beginSwap` is gated and never called)
- HTTPServer inference behavior in disabled mode unchanged
- Heartbeat / hello frames in disabled mode unchanged (no
  `model_hash` / `loading` fields)
- Control socket file is still NEVER created in disabled mode
- All Phase 1A-1E tests that pin L-1 must remain green

The EndToEndAcceptanceTests AC matrix tests are the canonical
pins. If any of those break, you have introduced a regression.

## Constraints that apply across all 5 fixes

**1. d-inference clean-room.** Do NOT read any file under
`phase3-binary/.build/checkouts/`.

**2. Existing tests stay green.** All 131 tests from Phase 1A-1E
must continue to pass. New tests added by this fix add to the
cumulative count. Final count after fixes should be ≥ 145.

**3. Backwards compatibility of public types.** The
`RuntimeStateMachine` refactor IS a breaking change to that
file's actor surface. Other Swift files that import the type
(test files use `@testable import`) are allowed to break and be
fixed in this PR. External callers do not exist (the binary is
self-contained).

**4. No new CLI flags, no new YAML keys, no new ENV vars.** The
existing surface is sufficient to implement all 5 fixes.

**5. No spec edits.** Do NOT modify any file under `specs/`.

**6. Compile + tests pass.** `swift build` and `swift test` MUST
both exit 0.

**7. Macro discipline.** No `#if DEBUG` / `#if TESTING` guards
introduced. The test-only injection points use `internal`
visibility and `@testable import`.

## Required reading (in this order — read fully before writing)

1. The audit findings document — read this entirely first:
   `/Users/augstar/macprovider-poc/.omc/artifacts/ask/codex-execute-the-audit-prompt-at-users-augstar-macprovider-poc-sp-2026-06-07T00-27-31-529Z.md`
   (search for "## Raw output" — your findings are below that
   marker)

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   - §3.2 (state machine + atomic swap) — re-read R-3.2.4 to
     confirm the four-step contract
   - §3.4 (drain semantics R-3.4.1 through R-3.4.5) — the
     binding source for Finding 1
   - §3.9 (config additions — drain timeout range 5...600)
   - §3.1 R-3.1.2 step 2 (supported_models pre-flight — binding
     source for Finding 4)

3. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   - §6.8 (lines 1748-1809) — incorporates SPEC-011 R-3.2.x and
     R-3.4.x; R-6.8.4 has the HTTP 503 rejection for
     loading/draining
   - §9 AC-25 — the drain timeout range validation AC

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift`
   — full file (77 lines). You are demoting this actor.

5. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   — full file (~437 lines). Read carefully — this is the
   biggest refactor target.

6. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
   - `ControlSocketServer.handleSwitchRequest` at line 359 — add
     the server-side `SupportedModels.validate` check
   - `ControlSocketServer.start` / `stop` — track and cancel
     client tasks
   - `ControlSocketServer.handleClient` at line 314 — pass a
     timeout to `receive()`
   - `ControlSocketConnection.receive` at line 464 — add max
     frame size check

7. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
   - `ServeCommand.run` — add the drain timeout range check
     after the existing SPEC-010 preflight; pass
     `resolved.supportedModels` into `ControlSocketServer`

8. The existing test files. Mirror their fixture style.

## Required edits — exact shape

### Finding 1 (drain semantics)

Per the analysis above. Key files: `ModelRuntime.swift`,
`RuntimeStateMachine.swift` (demoted), `ControlSocket.swift`
(handleSwitchRequest signal mapping).

Code-level constraints:
- The drain wait loop MUST run inside the detached task spawned
  by `beginSwap`, NOT on the actor's serial executor (no-starve
  rule from 1B carried forward)
- The drain wait loop polls every 50ms
- The drain wait loop reads
  `await providerStatus.snapshot().requestsInFlight` per poll;
  exits when 0
- The drain wait loop exits if `(now - drainStartMs) >
  drainTimeoutSeconds * 1000`
- After drain exits (either condition), call
  `await self.completeSwapAtomically(container:modelID:modelHash:)`
- The atomic swap method MUST be a single actor-isolated method
  that writes all four mutable fields (state, container, modelID,
  modelHash) in one synchronous block, then emits the `.completed`
  SwapSignal

### Finding 2 (snapshot atomicity)

Per the analysis above. The refactor:
- Move `state` ownership from `RuntimeStateMachine` into
  `ModelRuntime`
- Move signal continuations into `ModelRuntime`
- Demote `RuntimeStateMachine.swift` to pure type declarations
- `currentSnapshot()` becomes a single non-await actor read

### Finding 3 (drain timeout range validation)

Per the analysis above. In `MacProviderCLI.swift` `ServeCommand.run`,
add:

```swift
if !(5...600).contains(resolved.swapDrainTimeoutSeconds) {
    FileHandle.standardError.write(Data((
        "--swap-drain-timeout-seconds \(resolved.swapDrainTimeoutSeconds) out of range 5...600\n"
    ).utf8))
    throw ExitCode(2)
}
```

Place it AFTER `Self.runSupportedModelsPreflight(&resolved)` and
BEFORE `printResolvedConfiguration(resolved)`.

### Finding 4 (server-side supported_models check)

Per the analysis above. Key files: `ControlSocket.swift` (server
init + handleSwitchRequest), `MacProviderCLI.swift` (pass
catalog), `ModelsSubcommand.swift` (CLI handles `.notInSupportedModels`
ack reason).

The `SwitchAckReason.notInSupportedModels` enum case already
exists from Phase 1C — no enum changes needed.

### Finding 5 (bounded reads + per-read timeout + task tracking)

Per the analysis above. Key file: `ControlSocket.swift`.

Add:
- `ControlSocketConnection.maxFrameBytes = 64 * 1024`
- `ControlSocketConnectionError.frameTooLarge(size: Int)` case
- In `receive()`'s inner loop, after `receiveBuffer.append(byte)`:
  ```swift
  if receiveBuffer.count > Self.maxFrameBytes {
      throw ControlSocketConnectionError.frameTooLarge(size: receiveBuffer.count)
  }
  ```
- A 30s default idle timeout on the server-side
  `connection.receive()` call in `handleClient`
- A test-only init parameter `idleTimeoutSeconds: TimeInterval = 30.0`
  on `ControlSocketServer` so the bounded-read test can use 0.2s
- `clientTasks` array tracking + cancellation on `stop()`

## Done criteria

You are done when:

- `git diff -- specs/ phase4-coordinator/ phase5-gateway/` shows
  only operator-authored BUILD prompts and the pre-existing
  `specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` unstaged edit.
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with ≥ 145 tests
  green.
- All Phase 1A-1E tests still GREEN (131 from the prior commits
  remain unchanged in PASS status).
- A `models switch` against a runtime with `swap_drain_timeout: 5`
  and a long-running in-flight inference triggers a real `draining`
  switch_progress frame (visible via stderr capture in the new
  test).
- A direct control-socket client sending `switch_request` with a
  target NOT in `supported_models` gets a
  `switch_ack accepted:false reason:not_in_supported_models`
  response.
- A direct control-socket client sending a 65537-byte frame gets
  the connection closed by the server with
  `ControlSocketConnectionError.frameTooLarge`.
- A direct control-socket client that connects but never sends a
  frame gets disconnected by the server within the configured idle
  timeout.
- `serve --swap-drain-timeout-seconds 4` exits code 2 with stderr
  matching `"out of range 5...600"`.
- `currentSnapshot()` is a non-await actor method (no
  `await stateMachine.current()` call anywhere); a concurrent
  test driving 1000 snapshots during a 100ms swap shows NO
  observed `(state == .loading, container == NEW)` or
  `(state == .ready, container == OLD)` pairs (atomicity invariant).

## Out of scope for this fix

- The MINOR arch:1.1 finding (test `captureOutput` dup2 race) —
  defer to a separate cleanup PR; do NOT change the test
  harness in this fix
- Any other audit findings — only the 5 listed above
- Modifying `phase4-coordinator/` — separate Phase 2 PR
- Any new CLI flags, ENV vars, or YAML keys
- Refactoring `CoordinatorClient` beyond what's strictly needed
  to consume the new SwapSignal outcome variants (one-line
  switch-case change at most)

## Self-check before reporting done

Run this command and confirm all checks pass:

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat -- specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -10) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | grep "Executed.*tests" | tail -3) && \
  echo "----" && \
  grep -rn "XDG_RUNTIME_DIR" phase3-binary/Sources/ || echo "no XDG_RUNTIME_DIR (correct)" && \
  echo "----" && \
  grep -c "await stateMachine" phase3-binary/Sources/macprovider-cli/ModelRuntime.swift || echo "no await stateMachine refs (correct — stateMachine actor demoted)" && \
  echo "----" && \
  grep -n "transitionToDraining\|enterDrainPhase" phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | head -5
```

Return:
- A brief diff summary (files touched, +/- lines).
- The final `swift test` summary line (Executed N tests, ...).
- Any spec rule you were unable to satisfy exactly, with the
  binding rule number and your interpretation.
- A one-paragraph note on the snapshot-atomicity refactor
  approach you took (option (a) RuntimeStateMachine deleted vs
  option (b) types-only file).

Do NOT commit. Do NOT push. The operator audits the working tree
before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 120-180 min. The drain refactor + snapshot
  atomicity together rewrite a significant portion of
  ModelRuntime; the security fixes are smaller surface but
  require new tests with raw-socket plumbing.
- Audit pass (Claude Opus) re-reads the 5 fixes against:
  - The locked SPEC-011 §3.2 + §3.4 + §3.9 rules
  - The atomicity invariant test (no mixed snapshots)
  - The 131-test baseline regression check
  - The L-1 byte-identical guarantee in disabled mode
- If R1 produces a clean diff and Claude's re-audit yields zero
  new findings, re-dispatch the **external** Codex audit prompt
  at `specs/AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md` to confirm
  the original 5 findings are now resolved AND no new findings
  emerged. That re-audit is the merge gate.
- If R1 surfaces findings, an R2 fix prompt is drafted naming
  the specific R1 findings and citing the new file:line.
- After audits converge to 0/0/0, commit the fixes onto
  `fix/spec-001-v1-3-binary` and force-push PR #5 (or land as
  a separate commit on the same branch — operator decides). PR
  #5 then merges to main; release tag waits for SPEC-002 v1.3.5
  coordinator implementation per Entry 58.

# PR #5 pre-merge fix R2 prompt — 3 remaining findings (2 CRITICAL + 1 MAJOR)

Operator-paste prompt for Codex GPT-5 to land the **R2 fixes** for
findings surfaced by the external audit at
`.omc/artifacts/ask/codex-execute-the-audit-prompt-at-users-augstar-macprovider-poc-sp-2026-06-07T00-57-08-696Z.md`
(re-audit on commit aacf09a).

The R2 verdict on PR #5 is still **BLOCK-MERGE** (2 CRITICAL / 1 MAJOR /
1 MINOR). Three of the original 5 R1 findings are RESOLVED:

- ✅ [code:1.2] Snapshot atomicity (RuntimeStateMachine demoted)
- ✅ [code:1.3] `--swap-drain-timeout-seconds` range validation
- ✅ [sec:1.1] Server-side `supported_models` check on control socket

Two findings remain or are new:

- ❌ [code:1.1] Drain timeout cancellation (PARTIAL — drain phase exists
  but per-request cancellation contract per SPEC-011 R-3.4.2 missing)
- ❌ [code:1.2] Post-swap `model_id` still reads boot `ProviderStatus`
  on heartbeat / hello / HTTPServer / InferenceRelay (NEW finding)
- ❌ [sec:1.1] `clientTasks` array grows unboundedly because the R1 fix
  only filters by `isCancelled` (NEW — introduced by R1)

The MINOR (arch:1.1 captureOutput) remains deferred.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~90-120 min.
Branch: `fix/spec-001-v1-3-binary` carries Phases 1A-1E + the R1 fix
commit aacf09a. Codex MUST commit on this branch, MUST NOT create a
new one, MUST NOT commit or push.

---

```
=== BEGIN PROMPT ===

You are landing the R2 pre-merge audit fixes for PR #5 in the Swift
binary at /Users/augstar/macprovider-poc/phase3-binary/. The R1 fix
commit aacf09a addressed 3 of 5 original findings cleanly. The R2
external audit returned BLOCK-MERGE with 2 CRITICAL + 1 MAJOR
remaining. Your job is to land all 3 R2 fixes in a single working-tree
session.

You will edit the following files (and ONLY these):

  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift                       (extend — drain cancellation)
  phase3-binary/Sources/macprovider-cli/HTTPServer.swift                         (extend — swap_drain_timeout error mapping + live model_id validation)
  phase3-binary/Sources/macprovider-cli/InferenceRelay.swift                     (extend — live model_id validation)
  phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift                  (extend — model_id source switch in heartbeat + hello)
  phase3-binary/Sources/macprovider-cli/ControlSocket.swift                      (extend — clientTasks lifecycle cleanup)
  phase3-binary/Tests/macprovider-cliTests/ModelRuntimeSwapTests.swift           (extend — drain cancellation tests)
  phase3-binary/Tests/macprovider-cliTests/HTTPServerSwapTests.swift             (extend — swap_drain_timeout envelope + live model_id validation)
  phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift          (extend — post-swap model_id heartbeat + hello tests)
  phase3-binary/Tests/macprovider-cliTests/ControlSocketTests.swift              (extend — task lifecycle leak regression)

You will NOT edit any other Swift file, any file under `specs/`,
`phase4-coordinator/`, `phase5-gateway/`, or the prior phase test
files beyond the four listed above.

Verify with `git diff -- specs/ phase4-coordinator/ phase5-gateway/`
— must be empty (excluding operator-authored BUILD/AUDIT prompts and
the pre-existing FOLLOWUP_COORDINATOR_HA_2026_06_03.md edit).

## Findings to fix

### Finding 1 — CRITICAL [code:1.1] — Drain timeout doesn't cancel in-flight requests

**Spec reference:** SPEC-011 v0.5 R-3.4.2; the audit cites SPEC-011
lines 1216-1224 ("Cancellation contract on drain timeout").

**Current bug:** `waitForDrainOrTimeout` polls
`providerStatus.requestsInFlight` and exits when either it reaches 0
OR the configured timeout elapses. On timeout exit, the impl proceeds
to `completeSwapAtomically` and lets the in-flight requests continue
holding their OLD-container snapshot reference. The R1 fix prompt
explicitly told Codex this was OK; the spec disagrees.

Per SPEC-011 R-3.4.2: when drain timeout elapses, still-in-flight
requests against the OLD container MUST be cancelled. The cancelled
requests MUST receive an HTTP 503 response with the OpenAI error
envelope shape:

```json
{
  "error": {
    "type": "service_unavailable",
    "code": "swap_drain_timeout"
  }
}
```

(Note: this is a DIFFERENT `code` than the `provider_loading` code
used for "rejected before entry into ready" requests. The
`swap_drain_timeout` code is specifically for "started in ready,
killed by drain timeout".)

**Required behavior:**

The cleanest mechanism is to give `ModelRuntime` a per-request
cancellation hook list that the drain timeout walks. Concretely:

1. Add a private actor-isolated counter to `ModelRuntime`:
   ```swift
   private var nextInFlightID: Int = 0
   private var inFlightCancellations: [Int: @Sendable () -> Void] = [:]
   ```

2. Add two actor methods:
   ```swift
   func registerInFlight(_ cancel: @escaping @Sendable () -> Void) -> Int {
       nextInFlightID += 1
       let id = nextInFlightID
       inFlightCancellations[id] = cancel
       return id
   }

   func unregisterInFlight(_ id: Int) {
       inFlightCancellations.removeValue(forKey: id)
   }
   ```

3. Add the drain-timeout cancellation method:
   ```swift
   private func cancelAllInFlightForDrainTimeout() {
       let cancels = Array(inFlightCancellations.values)
       inFlightCancellations.removeAll()
       for cancel in cancels {
           cancel()
       }
   }
   ```

4. Modify `waitForDrainOrTimeout` to return a `didTimeout: Bool`
   so the caller knows which exit branch fired. After return, if
   `didTimeout == true`, call `cancelAllInFlightForDrainTimeout()`
   BEFORE `completeSwapAtomically`. The cancelled requests then
   throw their cancellation; the swap proceeds atomically.

5. The actor method `complete(_:shouldCancel:)` and
   `stream(_:shouldCancel:onChunk:)` MUST register themselves at
   entry and unregister at exit via `defer`:

   ```swift
   func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool = { false }) async throws -> CompletionResult {
       let snapshot = currentSnapshot()
       try Self.validateReady(snapshot.state)
       // ... existing validation ...

       // R-3.4.2 drain cancellation hook
       let drainCancelled = DrainCancelToken()
       let registrationID = registerInFlight { drainCancelled.fire() }
       defer { Task { await self.unregisterInFlight(registrationID) } }

       // ... existing inferenceGate.withPermit / container.perform body ...
       // Inside the generate closure, augment the existing
       // `shouldCancel()` check to ALSO check drainCancelled.isFired:
       if Task.isCancelled || shouldCancel() || drainCancelled.isFired {
           if drainCancelled.isFired {
               throw DrainCancelledError()  // new error type
           }
           return GenerateDisposition.stop
       }
   }
   ```

   Where `DrainCancelToken` is a small Sendable class that flips a
   single Bool:
   ```swift
   final class DrainCancelToken: @unchecked Sendable {
       private var _fired = false
       private let lock = NSLock()
       var isFired: Bool {
           lock.lock(); defer { lock.unlock() }
           return _fired
       }
       func fire() {
           lock.lock(); defer { lock.unlock() }
           _fired = true
       }
   }
   ```
   `@unchecked Sendable` is justified because the Bool is guarded by
   the lock.

   `DrainCancelledError` is a new struct:
   ```swift
   public struct DrainCancelledError: Error { }
   ```

6. The caller (HTTPServer) catches `DrainCancelledError` and maps it
   to HTTP 503 with the spec-mandated envelope:

   ```swift
   } catch is DrainCancelledError {
       // SPEC-011 R-3.4.2 / R-6.8.4 swap_drain_timeout envelope
       try await writer.write(status: 503, body: [
           "error": [
               "type": "service_unavailable",
               "code": "swap_drain_timeout"
           ]
       ])
   }
   ```

   Add this catch to BOTH the non-streaming dispatcher at
   `HTTPServer.swift` around line 196-232 AND the streaming dispatcher
   at `:238-260`.

7. Required tests in `ModelRuntimeSwapTests.swift`:
   - `testDrainTimeoutCancelsInFlightRequests` — start a runtime with
     warm-swap enabled, swap-drain-timeout = 5s. Begin a long-running
     `complete` call (use `testCompletion` returning after a
     `Task.sleep(15s)`). Call `beginSwap`, await the swap Task. The
     long-running call MUST throw `DrainCancelledError` within
     ~5.2 seconds (slack: 200ms). Assert post-swap snapshot is
     `.ready` with NEW model.
   - `testInFlightCompletesIfWithinDrainWindow` — same setup but
     completion returns after 2s (well within 5s drain). The
     `complete` call MUST return normally with OLD model content;
     no cancellation thrown.

8. Required tests in `HTTPServerSwapTests.swift`:
   - `testHTTPReturns503SwapDrainTimeoutEnvelope` — drive the
     dispatcher with a `DrainCancelledError` thrown from
     modelRuntime; assert response body matches
     `{"error":{"type":"service_unavailable","code":"swap_drain_timeout"}}`
     (sortedKeys / withoutEscapingSlashes serialization).

### Finding 2 — CRITICAL [code:1.2] — Post-swap `model_id` source-of-truth

**Spec reference:** SPEC-011 v0.5 AC-10 + R-3.3.5; SPEC-002 v1.3.5
R-7.10.6.

**Current bug:** After a swap A→B, several code paths still emit or
validate against the BOOT model ID (immutable
`providerStatus.modelID`):

- `CoordinatorClient.sendHeartbeat()` at line 588 — reads
  `snapshot.modelID` from `providerStatus.snapshot()`. The warm-swap
  block at line ~628 adds `model_hash` and `loading` from
  `modelRuntime.currentSnapshot()` but does NOT override `model_id`.
  Result: heartbeat carries `model_id: A`, `model_hash: hash(B)`,
  `loading: false` — incoherent.
- `CoordinatorClient.helloMessage()` at line 692-720 — same split.
  `model_id` comes from `providerStatus`; only `model_hash` comes
  from `modelRuntime` (added in Phase 1D).
- `HTTPServer.swift` outer validation at line 188 (look for
  `validateModelMatches`) — validates the buyer's request `model`
  field against the BOOT model ID, NOT the live runtime model. After
  a swap, requests for the NEW model are rejected at the outer gate;
  requests for the OLD model pass the outer gate but fail
  `ModelRuntime.complete`'s inner `validateModelMatches(snapshot.modelID)`
  check (Phase 1B).
- `InferenceRelay.swift` line ~189 — same validation issue on the
  WS-tunneled path.

**Required behavior:** When `warmSwapEnabled == true`, ALL FOUR call
sites MUST source the model ID from `modelRuntime.currentSnapshot()`
instead of `providerStatus.snapshot()`. When `warmSwapEnabled ==
false`, the boot `providerStatus` source is preserved (L-1
byte-identical default).

This mirrors the pattern Phase 1D already established for
`model_hash`. Extend it to `model_id`.

**Required edits:**

1. `CoordinatorClient.sendHeartbeat` — augment the existing
   warm-swap block:

   ```swift
   if warmSwapEnabled {
       let runtimeSnapshot = await modelRuntime.currentSnapshot()
       payload["model_id"] = runtimeSnapshot.modelID ?? ""  // override boot value
       if let modelHash = runtimeSnapshot.modelHash {
           payload["model_hash"] = modelHash
       }
       payload["loading"] = runtimeSnapshot.state == .loading
                              || runtimeSnapshot.state == .draining
   }
   ```

   Note: the existing `payload["model_id"] = snapshot.modelID ?? ""`
   is set in the dict literal earlier; the warm-swap block reassigns.

2. `CoordinatorClient.helloMessage` — extend the existing
   source-of-truth conditional to ALSO cover `model_id`:

   ```swift
   let modelIDForHello: String
   let hashForHello: String?
   if warmSwapEnabled {
       let rs = await modelRuntime.currentSnapshot()
       modelIDForHello = rs.modelID ?? ""
       hashForHello = rs.modelHash
   } else {
       modelIDForHello = snapshot.modelID ?? ""
       hashForHello = snapshot.modelHash
   }
   message["model_id"] = modelIDForHello
   if let hashForHello {
       message["model_hash"] = hashForHello
   }
   ```

   The earlier `"model_id": snapshot.modelID ?? ""` in the dict
   literal is overwritten by this assignment.

3. `HTTPServer.swift` line ~188 (the chat-completions handler outer
   validation) — read modelRuntime's current snapshot for the
   validator when warm-swap is enabled. Concretely, find the
   `try request.validateModelMatches(...)` call (or whatever the
   outer validation function is) and replace the immutable model ID
   source with the live one.

   Suggested helper on `RouterHandler`:
   ```swift
   private static func effectiveModelID(
       warmSwapEnabled: Bool,
       providerStatus: ProviderStatus,
       runtimeSnapshot: RuntimeSnapshot
   ) -> String? {
       if warmSwapEnabled {
           return runtimeSnapshot.modelID
       }
       // Disabled-mode L-1 path: boot source unchanged
       return providerStatus.snapshot... // TODO: providerStatus is an actor; in disabled mode, the existing immutable path is already correct
   }
   ```

   The right approach in disabled mode: keep the existing immutable
   field (the HTTPServer holds `modelID: String?` at construction
   from the boot resolved config). In enabled mode, call
   `await modelRuntime.currentSnapshot()` and use its modelID. The
   warm-swap flag is in `AppConfig.enableWarmSwap` — plumb it into
   `RouterHandler` at construction (HTTPServer.swift line 47-58
   already holds `modelRuntime`; add a `warmSwapEnabled: Bool`
   field).

4. `InferenceRelay.swift` line ~189 — same fix as HTTPServer. The
   inference relay validates the request's `model` field against
   the binary's current served model. Same warm-swap source-of-truth
   rule applies.

5. `helloMessage()` test — the existing
   `testHelloEnabledModeReadsFromModelRuntime` from Phase 1D
   asserts on `model_hash`. EXTEND it (or add a sibling test) to
   also assert on `model_id`:

   ```swift
   func testHelloEnabledModeReadsModelIDAndHashFromModelRuntime() async throws {
       // ProviderStatus has modelID = "A", modelHash = "boot-hash"
       // ModelRuntime has been swapped to modelID = "B", modelHash = "runtime-hash"
       let hello = await client.helloMessage()
       XCTAssertEqual(hello["model_id"] as? String, "B")
       XCTAssertEqual(hello["model_hash"] as? String, "runtime-hash")
   }
   ```

6. `sendHeartbeat()` test — same shape. Capture the heartbeat via
   `sendOverride`; assert `model_id == "B"` post-swap.

7. New end-to-end test in `HTTPServerSwapTests.swift`:
   - `testInferenceForNewModelSucceedsAfterSwap` — start
     ModelRuntime with model "A", warm-swap enabled. Begin and
     complete a swap to "B" (via `beginSwap` + await Task). Drive
     the HTTPServer dispatcher with a chat completions request for
     model "B"; assert the request reaches `modelRuntime.complete`
     (use `testCompletion` to confirm) WITHOUT rejection at the
     outer validator.
   - `testInferenceForOldModelRejectedAfterSwap` — same setup;
     drive a request for "A"; assert it's rejected with 4xx
     "model not loaded" or similar (whatever the existing
     mismatch error path emits).

### Finding 3 — MAJOR [sec:1.1] — `clientTasks` array grows unboundedly

**Spec reference:** Audit threat model — same-UID local DoS.

**Current bug:** My R1 fix added
`clientTasks: [Task<Void, Never>] = []` to track accepted client
tasks for cancellation on `stop()`. The append path
(`appendClientTask`) filters by `isCancelled` only. A successfully
COMPLETED task (not cancelled) is NEVER removed. A same-UID process
that repeatedly opens short-lived connections grows the array
indefinitely — eventual OOM.

**Required behavior:** Each tracked task MUST be removed from the
collection when it completes (success OR cancellation OR error).

**Required edit:**

Change the tracking to be UUID-keyed and have each task remove
itself in a `defer`:

```swift
// ControlSocketServer state
private var clientTasks: [UUID: Task<Void, Never>] = [:]

// in the accept loop, when spawning a client task:
let taskID = UUID()
let task = Task.detached(priority: .userInitiated) { [weak self] in
    defer {
        Task { await self?.removeClientTask(taskID) }
    }
    await Self.handleClient(...)
}
clientTasks[taskID] = task

// new actor method
private func removeClientTask(_ id: UUID) {
    clientTasks.removeValue(forKey: id)
}

// stop() iterates values
for task in clientTasks.values {
    task.cancel()
}
clientTasks.removeAll()
```

Also: `ModelRuntime.swapSignals()` creates AsyncStream continuations
appended to `signalContinuations` ([ModelRuntime.swift:145](phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:145))
but never cleans them up when the consumer drops the stream. Add
`onTermination` cleanup:

```swift
func swapSignals() -> AsyncStream<SwapSignal> {
    let pair = AsyncStream<SwapSignal>.makeStream(of: SwapSignal.self)
    let id = UUID()
    signalContinuations[id] = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSignalContinuation(id) }
    }
    return pair.stream
}

private var signalContinuations: [UUID: AsyncStream<SwapSignal>.Continuation] = [:]

private func removeSignalContinuation(_ id: UUID) {
    signalContinuations.removeValue(forKey: id)
}

// signal() iterates values
private func signal(_ signal: SwapSignal) {
    for continuation in signalContinuations.values {
        continuation.yield(signal)
    }
}
```

**Required test:** `testClientTasksDoNotLeakOnCompletion` in
`ControlSocketTests.swift` — start a server, expose
`clientTasksCountForTest()` via a test-only accessor on
`ControlSocketServer`. Open and close 50 connections sequentially.
Assert the count returns to 0 (or small constant) within 500ms of
the last close.

## L-1 byte-identical default invariant

The fixes MUST NOT change L-1 baseline. Specifically:
- In disabled mode (no `--enable-warm-swap`), heartbeat and hello
  frames continue to source `model_id` from `providerStatus` — this
  is the v1.2.4 baseline path
- HTTPServer / InferenceRelay outer validation in disabled mode
  continues to use the boot `modelID` (immutable startup value)
- Drain cancellation is unreachable in disabled mode because
  `beginSwap` is gated on `warmSwapEnabled`
- All 145 tests from R1 must remain green

## Constraints across all 3 fixes

**1. d-inference clean-room.** Do NOT read any file under
`phase3-binary/.build/checkouts/`.

**2. Existing tests stay green.** All 145 tests from the R1 fix
must continue to pass. New tests added by this fix add to the
cumulative count. Final count after fixes should be ≥ 155.

**3. No new CLI flags, no new YAML keys, no new ENV vars.**

**4. No spec edits.** Do NOT modify any file under `specs/`.

**5. Compile + tests pass.** `swift build` and `swift test` MUST
both exit 0.

**6. The MINOR arch:1.1 (captureOutput dup2) is STILL deferred.**
Do not change the test harness.

## Required reading (in this order — read fully before writing)

1. The R2 audit findings document:
   `/Users/augstar/macprovider-poc/.omc/artifacts/ask/codex-execute-the-audit-prompt-at-users-augstar-macprovider-poc-sp-2026-06-07T00-57-08-696Z.md`
   (search for "## Raw output")

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   - §3.4 (drain semantics — focus on R-3.4.2 cancellation contract
     and AC-7)
   - §3.3 (heartbeat extension R-3.3.5 — `model_id` source-of-truth)

3. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   - §6.8.3 (R-6.8.4 — HTTP 503 envelope; verify `swap_drain_timeout`
     code is documented)
   - §6.10 (heartbeat extension — confirm `model_id` source)

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   - `complete` / `stream` methods — add registration/unregistration
   - `waitForDrainOrTimeout` — return didTimeout boolean
   - `beginSwap` — call `cancelAllInFlightForDrainTimeout` on timeout
     exit

5. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
   - `sendHeartbeat` lines 588-635 — model_id override in warm-swap block
   - `helloMessage` lines 692-720 — model_id source switch

6. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
   - The chat-completions outer validator (around line 188)
   - Plumb `warmSwapEnabled` into RouterHandler

7. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
   - The validator at line 189

8. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
   - `clientTasks` array (line 238)
   - `appendClientTask` (line 325)
   - `start` / `stop` lifecycle

## Done criteria

You are done when:

- `git diff -- specs/ phase4-coordinator/ phase5-gateway/` shows
  only operator-authored prompts and the pre-existing FOLLOWUP edit.
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with ≥ 155 tests green.
- A drain-timeout-cancelled in-flight inference request returns
  HTTP 503 with body matching exactly
  `{"error":{"code":"swap_drain_timeout","type":"service_unavailable"}}`
  (sortedKeys serialization).
- A heartbeat captured AFTER a swap A→B carries `"model_id":"B"` AND
  `"model_hash":"hash(B)"` AND `"loading":false`.
- A hello frame captured AFTER a swap A→B carries `"model_id":"B"`.
- An HTTP chat completion request for "B" AFTER a swap A→B reaches
  `modelRuntime.complete` (passes both outer and inner validators);
  a request for "A" is rejected at one of the validators (the spec
  is satisfied either way as long as A is no longer servable).
- Opening and closing 50 control-socket connections sequentially
  leaves `clientTasksCountForTest()` at 0 (or a small constant ≤ 2
  to account for in-flight cleanup) within 500ms of the last close.
- All 145 tests from R1 still GREEN.

## Out of scope for this fix

- The MINOR arch:1.1 finding (test `captureOutput` dup2 race) —
  still deferred to a separate cleanup PR
- Any other audit findings or speculative improvements
- Modifying `phase4-coordinator/` — separate Phase 2 PR
- Any new CLI flags, ENV vars, or YAML keys

## Self-check before reporting done

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat -- specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -10) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | grep "Executed.*tests" | tail -3) && \
  echo "----" && \
  grep -n "swap_drain_timeout" phase3-binary/Sources/macprovider-cli/HTTPServer.swift phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | head -5 && \
  echo "----" && \
  grep -n "modelRuntime.currentSnapshot\|warmSwapEnabled" phase3-binary/Sources/macprovider-cli/HTTPServer.swift phase3-binary/Sources/macprovider-cli/InferenceRelay.swift phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift | head -10
```

Return:
- Diff summary (files touched, +/- lines).
- Final `swift test` summary line.
- Any spec rule you were unable to satisfy exactly with rationale.
- Confirmation that the three R2 findings are addressed and no new
  regressions introduced.

Do NOT commit. Do NOT push. The operator audits before commit.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 90-120 min. Finding 1 (drain cancellation)
  is the heaviest — touches the actor surface, the generate
  closure check, and the HTTP error mapping. Finding 2 is wider
  (4 files) but each edit is small. Finding 3 is small and local.
- Audit pass (Claude Opus) re-audits the diff against the 3
  remaining findings:
  - **Drain cancellation:** verify `DrainCancelledError` propagates
    cleanly from generate closure → complete/stream → HTTPServer →
    HTTP 503 with the exact envelope shape
  - **Model ID source:** verify all 4 sites (heartbeat / hello /
    HTTPServer / InferenceRelay) source from modelRuntime in
    enabled mode and providerStatus in disabled mode
  - **Task lifecycle:** verify `defer { removeClientTask(id) }`
    fires on success, cancellation, and error paths
- If R3 clears Claude's internal audit, re-dispatch the external
  Codex audit (third pass) to confirm 0 CRITICAL / 0 MAJOR. That
  is the final merge gate.
- After audits converge, commit the R2 fix onto
  `fix/spec-001-v1-3-binary`. PR #5 then merges to main; release
  tag still gated on SPEC-002 v1.3.5 coordinator implementation
  per Entry 58.

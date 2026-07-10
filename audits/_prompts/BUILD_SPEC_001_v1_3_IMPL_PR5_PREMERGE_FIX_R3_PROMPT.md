# PR #5 pre-merge fix R3 prompt — 1 remaining MAJOR

Operator-paste prompt for Codex GPT-5 to land the **R3 fix** for the
remaining streaming preflight/stream race surfaced by the external audit
at `.omc/artifacts/ask/codex-execute-the-audit-prompt-at-users-augstar-macprovider-poc-sp-2026-06-07T01-19-56-152Z.md`.

R3 verdict: **MERGE-WITH-FIXES** (0 CRITICAL / 1 MAJOR / 0 MINOR). The
2 CRITICAL + 1 MAJOR fixed in R2 (commit 7826007) are resolved cleanly.
One new MAJOR surfaced: a race between streaming preflight and stream
that can return `provider_loading` for a request originally admitted
in `.ready` state.

Scope: refactor the streaming path to use a **request handle** that
atomically captures snapshot + drain registration in a single actor
call, then carries that handle through preflight and stream so the
window between admit and stream commitment can never see a state
change.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~60-90 min.
Branch: `fix/spec-001-v1-3-binary` carries the 5 phase commits +
R1 fix (aacf09a) + R2 fix (7826007). Codex MUST commit on this
branch, MUST NOT create a new one, MUST NOT commit or push.

---

```
=== BEGIN PROMPT ===

You are landing the R3 pre-merge audit fix for PR #5 in the Swift
binary at /Users/augstar/macprovider-poc/phase3-binary/. The R2 fix
commit 7826007 addressed the two CRITICAL + one MAJOR findings from
the second external audit cleanly. The third external audit returned
MERGE-WITH-FIXES with one new MAJOR finding: a streaming-path race
between preflight and stream.

You will edit the following files (and ONLY these):

  phase3-binary/Sources/macprovider-cli/ModelRuntime.swift                       (extend — RequestHandle + handle-based preflight/stream)
  phase3-binary/Sources/macprovider-cli/HTTPServer.swift                         (extend — streaming dispatcher uses the handle)
  phase3-binary/Tests/macprovider-cliTests/ModelRuntimeSwapTests.swift           (extend — handle race regression test)
  phase3-binary/Tests/macprovider-cliTests/HTTPServerSwapTests.swift             (extend — end-to-end streaming race test)

You will NOT edit any other Swift file, any file under `specs/`,
`phase4-coordinator/`, `phase5-gateway/`, or any prior test files
beyond the two listed above.

Verify with `git diff -- specs/ phase4-coordinator/ phase5-gateway/`
— must be empty (excluding operator-authored prompts and the
pre-existing FOLLOWUP edit).

## Finding to fix

### [code:1.1] MAJOR — Streaming preflight/stream race window

**Spec reference:** SPEC-001 v1.3 R-6.8.4 (HTTP 503 envelope for
inference rejection); SPEC-011 v0.5 R-3.2.2 (in-flight snapshot
isolation), R-3.4.1 (drain state semantics), R-3.4.2 (drain timeout
cancellation contract).

**Current bug:** The streaming dispatcher in
`HTTPServer.handleStreamingChatCompletions` (around
`HTTPServer.swift:277`) calls:
  1. `await modelRuntime.preflight(request)` — tokenizes the prompt
     to validate context length. Internally captures a snapshot,
     calls `validateReady(state)`, registers a drain cancel token.
  2. `await modelRuntime.stream(request, ...)` — captures a FRESH
     snapshot, calls `validateReady` again, registers ANOTHER drain
     cancel token.

Between (1) returning and (2) starting, the actor's serial executor
is free. If a `models switch` arrives and the swap's
`transitionToLoading` runs in that window, the second `validateReady`
inside `stream()` sees `.loading` and throws
`provider_loading` — but the request was originally admitted in
`.ready` state. Per SPEC-011 R-3.2.2 / R-3.4.1 / R-3.4.2, requests
admitted in `.ready` MUST either complete using their captured
snapshot OR receive `swap_drain_timeout` 503 — never
`provider_loading`.

The race window is the preflight tokenization duration (typically
sub-millisecond but grows with prompt length and CPU load). It is
exploitable by an operator timing concurrent `models switch` calls
against an in-flight buyer request.

**Required behavior:** Move the snapshot capture + drain registration
to a SINGLE atomic actor call at request admission. Carry the
resulting handle through both preflight and stream so neither needs
to re-capture state or re-register.

### Required design

Introduce a `RequestHandle` value type and refactor the streaming
path to use it. The non-streaming path is NOT affected — `complete()`
already does its registration in a single actor invocation and has
no preflight separation.

#### A. `ModelRuntime.swift` — new types and refactored methods

Add to `ModelRuntime.swift` (NOT to RuntimeStateMachine.swift —
keep that file types-only):

```swift
public struct RequestHandle: @unchecked Sendable {
    public let snapshot: RuntimeSnapshot
    public let registrationID: Int
    let drainCancelled: DrainCancelToken
}
```

(`@unchecked Sendable` is justified because the constituents are
captured-by-value or thread-safe by construction —
`DrainCancelToken` is already `@unchecked Sendable` with internal
locking from the R2 fix.)

Add an actor method that atomically captures snapshot + validates +
registers:

```swift
func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle {
    let snapshot = currentSnapshot()
    try Self.validateReady(snapshot.state)
    try request.validateModelMatches(snapshot.modelID)
    let drainCancelled = DrainCancelToken()
    let registrationID = registerInFlight { drainCancelled.fire() }
    return RequestHandle(
        snapshot: snapshot,
        registrationID: registrationID,
        drainCancelled: drainCancelled
    )
}
```

Note: this method is NOT async because every operation inside it is
synchronous within the actor. The whole body runs as one
non-interrupting actor invocation. This is the key correctness
property — between `currentSnapshot()` and `registerInFlight()` there
is NO actor yield, so no other actor method (including
`transitionToLoading`) can interleave.

Refactor `preflight(_:)` to a handle-based variant:

```swift
func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws {
    // No snapshot capture; no validateReady; no registration.
    // The handle owns those.
    guard let container = handle.snapshot.container else {
        if testCompletion != nil {
            return
        }
        throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
    }

    let maxContextTokens = maxContextTokens
    try await inferenceGate.withPermit {
        return try await container.perform { context in
            let input = UserInput(chat: request.messages.map { $0.mlxMessage })
            let lmInput = try await context.processor.prepare(input: input)
            try Self.validatePromptTokenCount(
                lmInput.text.tokens.size,
                maxContextTokens: maxContextTokens
            )
        }
    }
}
```

Refactor `stream(_:shouldCancel:onChunk:)` to a handle-based variant:

```swift
func stream(
    _ request: ChatCompletionRequest,
    with handle: RequestHandle,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    onChunk: @escaping @Sendable (String) -> Void
) async throws -> CompletionResult {
    // No snapshot capture; no validateReady; no registration.
    // Use handle.snapshot for container / model ID, handle.drainCancelled
    // for the drain abort check inside the generate closure.

    if let testCompletion {
        let completion = try await testCompletion(handle.snapshot, request)
        if !completion.content.isEmpty {
            onChunk(completion.content)
        }
        return completion
    }
    guard let container = handle.snapshot.container else {
        throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
    }

    let maxContextTokens = maxContextTokens
    let drainToken = handle.drainCancelled
    return try await inferenceGate.withPermit {
        try Self.checkDrainOrCancellation(drainToken, shouldCancel: shouldCancel)
        return try await container.perform { context in
            try Self.checkDrainOrCancellation(drainToken, shouldCancel: shouldCancel)
            // ... existing generate logic using `if Task.isCancelled || shouldCancel() || drainToken.isFired { ... }`
            // is unchanged below ...
        }
    }
}
```

(`Self.checkDrainOrCancellation` already exists from the R2 fix at
ModelRuntime.swift:547 — reuse it.)

The OLD `preflight(_:)` and `stream(_:shouldCancel:onChunk:)`
signatures WITHOUT handle parameters MUST be REMOVED (not kept for
back-compat). Their callers — HTTPServer streaming path — are
updated in step B below. Removing them prevents future drift.

The `ModelRuntimeServing` protocol at `ModelRuntime.swift:7-10`
currently has:

```swift
protocol ModelRuntimeServing: Sendable {
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult
    func stream(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (String) -> Void) async throws -> CompletionResult
}
```

The protocol's `stream(...)` signature MUST be updated to require
the handle:

```swift
protocol ModelRuntimeServing: Sendable {
    func complete(_ request: ChatCompletionRequest, shouldCancel: @escaping @Sendable () -> Bool) async throws -> CompletionResult
    func stream(_ request: ChatCompletionRequest, with handle: RequestHandle, shouldCancel: @escaping @Sendable () -> Bool, onChunk: @escaping @Sendable (String) -> Void) async throws -> CompletionResult
    func preflight(_ request: ChatCompletionRequest, with handle: RequestHandle) async throws
    func acquireRequestHandle(_ request: ChatCompletionRequest) throws -> RequestHandle
}
```

And the extension's convenience overload for stream
(`ModelRuntime.swift:17-22`) MUST be removed (it lacked the handle
parameter).

`complete(_:shouldCancel:)` is UNCHANGED in signature. It does its
snapshot capture + registration internally as today; non-streaming
HTTPServer continues to call it as a single actor invocation, so
there is no race window. Adding a handle parameter to `complete()`
is OUT OF SCOPE for this fix.

#### B. `HTTPServer.swift` — streaming dispatcher refactor

Locate `handleStreamingChatCompletions` (around line 277). The
current flow is approximately:

```swift
// existing
do {
    let snapshot = await modelRuntime.currentSnapshot()
    if let error = Self.warmSwapRejectionError(for: snapshot) {
        throw error
    }
    try await modelRuntime.preflight(request)
    // commit 200 OK with headers
    let result = try await modelRuntime.stream(request, shouldCancel: ..., onChunk: ...)
    // emit final chunk + done
} catch is DrainCancelledError {
    // emit swap_drain_timeout envelope
} catch ... { ... }
```

Refactor to use the handle (after the optional admit-time warm-swap
rejection check):

```swift
do {
    let snapshot = await modelRuntime.currentSnapshot()
    if let error = Self.warmSwapRejectionError(for: snapshot) {
        throw error
    }
    // CRITICAL: acquire handle atomically here — snapshot + register in one actor call.
    let handle = try await modelRuntime.acquireRequestHandle(request)
    defer {
        Task { await modelRuntime.unregisterInFlight(handle.registrationID) }
    }
    try await modelRuntime.preflight(request, with: handle)
    // commit 200 OK with headers
    let result = try await modelRuntime.stream(
        request,
        with: handle,
        shouldCancel: ...,
        onChunk: ...
    )
    // emit final chunk + done
} catch is DrainCancelledError {
    // existing swap_drain_timeout envelope handler stays as is
} catch ... { ... }
```

Key invariants the refactored flow MUST satisfy:

1. The `warmSwapRejectionError` admit-time check stays — it lets the
   dispatcher reject `loading`/`draining` requests BEFORE attempting
   to acquire a handle. Without this, every request would try to
   acquire and fail on `validateReady`, which is wasteful (though
   not incorrect).

2. `acquireRequestHandle` throws `provider_loading` if the state
   has somehow already moved off `.ready` between the admit check
   and the acquire — this catches the small window between the two
   actor calls. The existing dispatcher's catch-all handles this
   correctly.

3. Once `acquireRequestHandle` returns the handle, the registration
   is LIVE. Subsequent state changes (a swap entering `.loading`)
   CANNOT cause this request to be rejected with `provider_loading`
   — it will either complete with the handle's captured snapshot,
   or get `DrainCancelledError` on drain timeout.

4. The `defer { Task { await modelRuntime.unregisterInFlight(...) } }`
   pattern MUST fire on ALL exit paths (success, throw, cancellation).
   Swift `defer` runs on scope exit, so this is automatic.

#### C. Required tests

Add to `ModelRuntimeSwapTests.swift`:

- `testHandleAcquiredInReadyStateSurvivesSwapToLoading` — start a
  runtime in `.ready` with warm-swap enabled and a slow stub loader.
  Call `acquireRequestHandle` (await). Concurrently kick off
  `beginSwap` to a new model. Wait until state transitions to
  `.loading` (poll `currentSnapshot().state`). Now call
  `preflight(request, with: handle)` — assert it DOES NOT throw
  `provider_loading` (it may throw token-too-long if that's the
  test setup, but that's a different error). Then call
  `stream(request, with: handle, onChunk: ...)` — assert it
  completes normally with the OLD-snapshot model content (NOT
  rejected). Cleanup: unregister, await the swap task to
  completion.

- `testHandleAcquiredInLoadingStateFails` — start a runtime, drive
  it into `.loading` via `beginSwap` with a slow stub loader. Call
  `acquireRequestHandle` — assert it throws an APIError with
  `code: "provider_loading"`. This pins the admit-time gate.

- `testHandleDrainCancellationStillFiresEvenIfStateAlreadyChanged`
  — acquire handle in `.ready`. Concurrently drive a swap that
  transitions through `.loading` → `.draining` and hits the drain
  timeout. The in-flight stream call (a long-running test loop)
  MUST be cancelled with `DrainCancelledError`. This pins the
  R2 R-3.4.2 contract still works through the handle.

Add to `HTTPServerSwapTests.swift`:

- `testStreamingRequestAdmittedInReadyDoesNotGetProviderLoading` —
  the end-to-end version. Drive the streaming dispatcher with a
  fake request and a `testCompletion` closure that sleeps for 200ms.
  Concurrently (after the dispatcher has acquired the handle but
  BEFORE the testCompletion sleep returns), trigger a swap. Assert
  the streaming response writer received tokens from the testCompletion
  (proving stream succeeded), NOT a swap_drain_timeout envelope, NOT
  a provider_loading envelope.

  The timing coordination is delicate. Use a probe / barrier pattern
  (see existing `InFlightProbe` in `ModelRuntimeSwapTests.swift`)
  to wait for the dispatcher to be inside `stream()` before
  triggering the swap. If wiring the full HTTPServer is too
  heavyweight, drive the equivalent via direct ModelRuntime calls
  that mimic the dispatcher's flow.

## L-1 byte-identical default invariant

The R3 fix MUST NOT change L-1 baseline:
- In disabled mode (no `--enable-warm-swap`), the handle is still
  acquired and used, but the runtime never transitions out of
  `.ready`, so the handle is effectively trivial. No observable
  wire behavior change.
- The streaming path's existing token-count validation behavior
  is preserved.
- All 155 tests from R2 must remain green.

## Constraints

1. **d-inference clean-room.** No file under
   `phase3-binary/.build/checkouts/`.

2. **All 155 R2 tests stay green.** Final count ≥ 159.

3. **No new CLI flags, no new YAML keys, no new ENV vars.**

4. **No spec edits.**

5. **Compile + tests pass.** `swift build` and `swift test` exit 0.

6. **MINOR arch:1.1 (captureOutput dup2) still deferred.**

## Required reading (in order)

1. The R3 audit findings document:
   `/Users/augstar/macprovider-poc/.omc/artifacts/ask/codex-execute-the-audit-prompt-at-users-augstar-macprovider-poc-sp-2026-06-07T01-19-56-152Z.md`
   (search for "## Raw output"; the single finding is below the
   "### Code review" header)

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   - §3.2 R-3.2.2 (in-flight snapshot isolation)
   - §3.4 R-3.4.1, R-3.4.2 (drain semantics + cancellation)

3. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
   - The `ModelRuntimeServing` protocol at lines 7-10
   - `preflight(_:)` (current shape — to be refactored)
   - `complete(_:shouldCancel:)` (UNCHANGED)
   - `stream(_:shouldCancel:onChunk:)` (current shape — to be
     refactored)
   - `registerInFlight` / `unregisterInFlight` actor methods (from R2)
   - `DrainCancelToken` and `DrainCancelledError` (from R2)
   - `checkDrainOrCancellation` helper (from R2)

4. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
   - `handleStreamingChatCompletions` (around line 277)
   - The non-streaming dispatcher (lines 196-232) — DO NOT MODIFY

5. The existing test fixtures in `ModelRuntimeSwapTests.swift` —
   reuse `makeRuntime`, `InFlightProbe`, `waitUntil`.

## Done criteria

You are done when:

- `git diff -- specs/ phase4-coordinator/ phase5-gateway/` is clean.
- `cd phase3-binary && swift build` exits 0.
- `cd phase3-binary && swift test` exits 0 with ≥ 159 tests green.
- All 155 R2-baseline tests still GREEN.
- `acquireRequestHandle(_:)` exists as a synchronous (non-async)
  actor method on `ModelRuntime` that returns `RequestHandle` and
  performs the atomic capture+validate+register.
- `preflight(_:)` and `stream(_:onChunk:)` WITHOUT handle parameters
  no longer exist on `ModelRuntime` (the old signatures are
  removed; the handle-based variants are the only path).
- `HTTPServer.handleStreamingChatCompletions` calls
  `acquireRequestHandle` BEFORE `preflight(request, with: handle)`
  and uses the same handle for `stream(request, with: handle, ...)`.
- The new regression test
  `testHandleAcquiredInReadyStateSurvivesSwapToLoading` asserts
  that a handle acquired in `.ready` produces neither
  `provider_loading` nor `DrainCancelledError` for a request that
  completes within the drain window AFTER a concurrent swap to
  `.loading`.

## Out of scope

- `complete(_:shouldCancel:)` refactoring (not racy — single
  actor invocation).
- MINOR arch:1.1 (captureOutput dup2 race) — still deferred.
- Any new CLI flags, ENV vars, YAML keys.
- Modifying `phase4-coordinator/`.

## Self-check before reporting done

```bash
cd /Users/augstar/macprovider-poc && \
  git diff --stat -- specs/ phase4-coordinator/ phase5-gateway/ && \
  echo "----" && \
  (cd phase3-binary && swift build 2>&1 | tail -10) && \
  echo "----" && \
  (cd phase3-binary && swift test 2>&1 | grep "Executed.*tests" | tail -3) && \
  echo "----" && \
  grep -n "acquireRequestHandle\|RequestHandle" phase3-binary/Sources/macprovider-cli/ModelRuntime.swift | head -10 && \
  echo "----" && \
  grep -n "acquireRequestHandle\|with: handle" phase3-binary/Sources/macprovider-cli/HTTPServer.swift | head -10
```

Return:
- Diff summary (files touched, +/- lines).
- Final `swift test` summary line.
- Any spec rule you were unable to satisfy with rationale.

Do NOT commit. Do NOT push.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 60-90 min. Scope is small (1 production file
  refactor + 1 test file refactor + 2 new tests) but the design
  must be precise: `acquireRequestHandle` MUST be a non-async
  actor method to close the race; the streaming dispatcher MUST use
  the handle through both preflight and stream.
- Audit pass (Claude Opus) re-verifies:
  - `acquireRequestHandle` is non-async (synchronous actor method)
  - The handle's snapshot is used throughout preflight and stream
    (no re-acquire)
  - `defer { unregister }` fires on all exit paths
  - The regression test successfully demonstrates a swap during the
    handle's lifetime does NOT produce `provider_loading`
- If R3 fix audit returns clean, re-dispatch the external Codex
  audit (fourth pass) for the final merge gate.
- After 0 CRITICAL / 0 MAJOR external audit, commit the R3 fix
  and PR #5 is merge-ready. Release tag still gated on Phase 2
  (SPEC-002 v1.3.5 coordinator) per Entry 58.

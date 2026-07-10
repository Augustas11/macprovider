# IMPL r2 — 5 mechanical fixes (TIGHT scope)

Apply these 5 fixes to the worktree. Each is bounded and specific. No
interpretation or planning needed. NO commit. NO documentation updates.

After all 5: run `cd phase3-binary && swift test 2>&1 | tail -3` and
`cd phase4-coordinator && go test -count=1 ./internal/buyer 2>&1 | tail -3`.
Report pass/fail. Done.

## Fix 1: AC-25a runtime crash

File: `test/integration/cline_session/run_fixture.py`
Line: 224
Bug: `max(...)` called on a list of dicts without `key=` argument →
`TypeError: '>' not supported between instances of 'dict' and 'dict'`.

Fix: read line 224, identify which dict field should be the comparison key,
add `key=lambda d: d['<that_field>']` to the `max()` call.

Verify: `python3 test/integration/cline_session/run_fixture.py --self-test`
should complete without `TypeError`. If `--self-test` flag doesn't exist, just
run `python3 test/integration/cline_session/run_fixture.py` and verify no
`TypeError` at line 224 (other downstream errors are acceptable; the goal is
to close the runtime-crash gate).

## Fix 2: AC-44 timestamp captured at wrong place

File: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
Line: 461
Bug: `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` header is emitted at SSE
start time (before inference). Per SPEC §10d.4, should be captured at first
`.toolCallDelta` arrival from `ModelRuntime.stream`.

Fix:
1. REMOVE the `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` from the
   `writer.startSSE(extraHeaders:...)` call at line 461 (keep
   `X-MacProvider-Provider-Unix-Ms` since that's request-start, valid there).
2. INSIDE the `modelRuntime.stream(...)` closure body (around HTTPServer.swift:475+),
   on the FIRST `case .toolCallDelta(...)` event, emit a separate SSE event
   carrying the timestamp:
   ```swift
   if !toolCallOpenEmitted {
       toolCallOpenEmitted = true
       writer.writeSSEJSON([
           "type": "macprovider_tool_call_open",
           "unix_ms": Int64(Date().timeIntervalSince1970 * 1000)
       ])
   }
   ```
3. Declare `var toolCallOpenEmitted = false` before the stream call.
4. Update `phase4-coordinator/internal/buyer/streaming_timing.go` to parse
   this SSE event (look for lines containing `"type":"macprovider_tool_call_open"`)
   instead of (or in addition to) the response header. Document at the top of
   the file what triggers the sample.

## Fix 3: NTP skew is fake — document as v0.3

File: `phase5-gateway/internal/router/chat_proxy.go`
Lines: 211 + 361 (hardcoded `X-MacProvider-NTP-Skew-Ms: "0"`)

Fix: REMOVE the hardcoded `X-MacProvider-NTP-Skew-Ms: "0"` emission at both
lines (don't emit a fake value).

Then update `docs/operations/spec-018-v0.2-deploy.md`:
- Find the `X-MacProvider-NTP-Skew-Ms` section
- Change "Optional, emitted by phase4-coordinator at request start when known"
  to "DEFERRED TO v0.3 — gateway-side NTP skew measurement requires
  reference-clock infrastructure not present in v0.2. AC-44 v0.2 relies on
  OS-level NTP sync (chrony/timesyncd) without runtime verification of skew.
  v0.3 will add reference-clock handshake at gateway."

Also remove the line about emission from `X-MacProvider-Gateway-FirstByte-Unix-Ms`
section if it claims to emit and doesn't (verify before editing).

## Fix 4: AC-46 phantom closure — log + test mismatch path

File: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
Lines: 795-803 (`validObservedModelHash`)

Fix:
1. In `validObservedModelHash`, when the input string fails the
   `^[a-f0-9]{64}$` regex (i.e., known-but-malformed case), add an emit:
   ```swift
   import os.log  // if not already imported
   // Logger.cli is the existing logger; if different, use whatever the file uses
   if let observed = observed, !observed.isEmpty {
       // Failed regex check on non-empty input is a known-but-malformed case
       Logger.cli.error("AC-46: validObservedModelHash rejected non-hex value: \(observed.prefix(16))…")
   }
   ```
   (Use whatever existing logger pattern is in the file — `os.log`, `Logger`,
   `print`, etc.)

2. Add a test in `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift`
   (or wherever AC-46 tests live; check `MultiTurnTests.swift` first) covering
   the known-but-malformed path:
   ```swift
   func testAC46_KnownButMalformedHashReturnsNilAndLogs() {
       let result = ModelRuntime.validObservedModelHash("not-a-hex-string")
       XCTAssertNil(result, "AC-46: malformed hex input must return nil")
       // Logging happens; test passes if no fatal error
   }
   ```

## Fix 5: Sendable warnings on streamedAnyToolCallDelta

File 1: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
Line: ~489 (where `streamedAnyToolCallDelta = true` mutates captured var)

File 2: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
Line: ~437 (same pattern)

Fix: Replace `var streamedAnyToolCallDelta = false` declaration with an
atomic flag using `OSAllocatedUnfairLock` or `ManagedAtomic<Bool>`. Simplest:

```swift
// Replace:
var streamedAnyToolCallDelta = false

// With:
let streamedAnyToolCallDelta = NSLock()
nonisolated(unsafe) var streamedAnyToolCallDeltaValue = false

// Then inside the closure:
case .toolCallDelta(let toolDelta):
    streamedAnyToolCallDelta.lock()
    streamedAnyToolCallDeltaValue = true
    streamedAnyToolCallDelta.unlock()
    // ... rest of case body
```

OR, if `nonisolated(unsafe)` is not acceptable in Swift 5 mode, use:

```swift
final class StreamedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); defer { lock.unlock() }; value = true }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

let streamedAnyToolCallDelta = StreamedFlag()
// In closure: streamedAnyToolCallDelta.set()
// After stream returns: if !streamedAnyToolCallDelta.get() { ... fallback ... }
```

Use whichever pattern compiles cleanly. The goal is to silence the
Sendable warning, not change behavior.

## Stop condition

After the 5 fixes:

```bash
cd /Users/augstar/macprovider-impl-spec-018-v0-2/phase3-binary && swift test 2>&1 | tail -3
cd ../phase4-coordinator && go test -count=1 ./internal/buyer 2>&1 | tail -3
```

Report pass/fail counts. Done. No commit. No IMPL-NOTES update. No further work.

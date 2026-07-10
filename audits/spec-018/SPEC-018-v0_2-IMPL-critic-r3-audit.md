# SPEC-018 v0.2.4 IMPL — Critic Blind-spot r3 Audit

**Date:** 2026-06-28
**Reviewer:** claude critic blind-spot
**Commit audited:** `125aacc` on `impl/spec-018-v0-2`
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

- CRITICAL: 1
- HIGH: 0
- MEDIUM: 0
- minor: 1
- Open questions: 1

## Closures verified (r2 → r3)

### r2 C-1 — AC-25a runtime crash (`run_fixture.py:224` `max()` TypeError) → **CLOSED**

Mechanically verified at `test/integration/cline_session/run_fixture.py:224-232`:

```python
large_write = max(
    (
        call
        for call in transcript["tool_calls"]
        if call["name"] == "write_to_file"
        and call.get("result", {}).get("bytes_written", 0) >= minimums["write_to_file_bytes"]
    ),
    key=lambda call: call.get("result", {}).get("bytes_written", 0),
)
```

`key=lambda` is in place. Validation now compares ints, not dicts. **Ran end-to-end** (`python3 test/integration/cline_session/run_fixture.py` on `125aacc`): exits 0, writes
`test/integration/cline_session/output/transcript-20260628T142011Z.json`. No TypeError.

### r2 H-1 — AC-44 timestamp placement (`X-MacProvider-Provider-ToolCallOpen-Unix-Ms` at SSE start) → **CLOSED**

Mechanically verified at `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`:

- Line 460-462: `writer.startSSE` extraHeaders contains ONLY `X-MacProvider-Provider-Unix-Ms`. The `ToolCallOpen` header is gone.
- Line 474: `let toolCallOpenEmitted = StreamedFlag()` declared.
- Line 488-494: inside the `case .toolCallDelta` branch (i.e. fires only when a tool-call delta actually arrives from `modelRuntime.stream`'s closure), the SSE event is written:
  ```swift
  case .toolCallDelta(let toolDelta):
      if toolCallOpenEmitted.setIfUnset() {
          writer.writeSSEJSON([
              "type": "macprovider_tool_call_open",
              "unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
          ])
      }
  ```

The `setIfUnset()` gate guarantees fire-once semantics; the placement guarantees firing happens **at the first tool-call delta**, not at SSE-start. Subsequent tool-call deltas in the same stream do not re-emit.

Coordinator parses the event correctly:
- `phase4-coordinator/internal/buyer/streaming_timing.go:110-130` `toolCallOpenFromSSELine` matches `"type":"macprovider_tool_call_open"` and returns the parsed `unix_ms` as a `time.Time`.
- `phase4-coordinator/internal/buyer/server.go:2567-2571` captures the first such timestamp in `providerToolCallOpen` during pre-commit byte scanning.
- `phase4-coordinator/internal/buyer/server.go:2636` passes it explicitly via `observeFromHeadersAndProviderOpen(..., providerToolCallOpen)`.
- `streaming_timing.go:60-66` uses the explicit `providerOpen` argument when non-zero, falling back to the legacy header only if missing — so AC-44's `t_tool_call_open_detected` is now the detection moment, not SSE-start.

### r2 H-2 — Fake NTP skew header (`X-MacProvider-NTP-Skew-Ms: "0"`) → **CLOSED**

Mechanically verified:

- `phase5-gateway/internal/router/chat_proxy.go` lines 209-211: only `X-Request-ID` and `X-MacProvider-Gateway-FirstByte-Unix-Ms` are set. No `NTP-Skew-Ms`.
- `phase5-gateway/internal/router/chat_proxy.go` lines 358-363: response headers set `Gateway-FirstByte-Unix-Ms` + content-type + cache-control. No `NTP-Skew-Ms`.
- `grep -rn "NTP-Skew-Ms" phase5-gateway/` returns zero hits. The fake-zero is fully removed.
- `phase4-coordinator/internal/buyer/streaming_timing.go:20` retains the constant `streamingTimingSkewHeader = "X-MacProvider-NTP-Skew-Ms"` and `:77` reads it via `intMillisHeader` — but when the gateway doesn't emit it, `intMillisHeader` returns `ok=false`, falling through to the `providerNow / gatewayNow` branch at :85. Since the gateway also doesn't emit `X-MacProvider-Gateway-Unix-Ms`, that branch is also a no-op, and `skew` remains 0 with no false "samples discarded" accounting. This is honest behavior under the deferred-to-v0.3 stance.
- `docs/operations/spec-018-v0.2-deploy.md:100-105` rewrites the section to DEFERRED TO v0.3 with rationale matching the IMPL state. Reads honest to ops.

### r2 M-1 — AC-46 silent sanitization in `validObservedModelHash` → **CLOSED**

Mechanically verified at `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:795-809`:

```swift
static func validObservedModelHash(_ hash: String?) -> String? {
    guard let hash, hash.utf8.count == 64 else {
        if let hash, !hash.isEmpty {
            FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected malformed value: \(hash.prefix(16))...\n".utf8))
        }
        return nil
    }
    guard hash.utf8.allSatisfy({ byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }) else {
        FileHandle.standardError.write(Data("AC-46: validObservedModelHash rejected non-hex value: \(hash.prefix(16))...\n".utf8))
        return nil
    }
    return hash
}
```

Both failure modes log to stderr with the offending value prefix (truncated to 16 chars to avoid leaking secrets in logs). Nil and empty-string inputs are intentionally silent (they're the "no hash known" path, not misconfiguration). The wrong-length and non-hex branches now produce operator-visible signal.

Test exists at `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:7-11`:
```swift
func testAC46_KnownButMalformedHashReturnsNilAndLogs() {
    let result = ModelRuntime.validObservedModelHash("not-a-hex-string")
    XCTAssertNil(result, "AC-46: malformed hex input must return nil")
}
```

`"not-a-hex-string"` is 16 bytes UTF-8 → trips the wrong-length branch → logs to stderr → returns nil. Test asserts nil. The logging path is now exercised by the test even though the assertion is only on the nil return value (a strict assertion on stderr capture would be a polish item, not a blocker).

### r2 M-2 — Sendable warnings on `streamedAnyToolCallDelta` → **CLOSED**

Mechanically verified at `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1216-1241`:

```swift
final class StreamedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }

    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }

    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
```

Thread-safety analysis:
- Reference type (`final class`), so closure captures the reference. Mutation through the reference is shared across all closure invocations, which is what we want.
- All three methods take the lock around `value` access. `setIfUnset` is an atomic test-and-set (single lock acquisition spans both read and write).
- `@unchecked Sendable` is safe because every mutation goes through the lock and `value` is `private`.
- No closure-capture-by-value of the flag (which would have been the Swift 6 error in r1).

Used at:
- `HTTPServer.swift:474-475` (`toolCallOpenEmitted`, `streamedAnyToolCallDelta`) inside the `modelRuntime.stream { chunk in ... }` closure. Both captures are class-reference, not `var` capture.
- `HTTPServer.swift:489` `if toolCallOpenEmitted.setIfUnset()` — correct atomic gate.
- `HTTPServer.swift:495` `streamedAnyToolCallDelta.set()` — correct.
- `HTTPServer.swift:512` `if !streamedAnyToolCallDelta.get(), ...` — correct read after stream completes.
- `InferenceRelay.swift:425-437-468` — same pattern, all reference-type access.

Smoke evidence: `swift test` returns 578 tests, 0 failures, 7 skipped. The known r1 warning is gone.

## Fresh findings

### CRITICAL findings

#### C-1 — New `macprovider_tool_call_open` SSE event injects an `AI_TypeValidationError` into Cline's stream via `@ai-sdk/openai-compatible@2.0.38` (Vercel AI SDK)

**Evidence:**

The r2 fix for H-1 (AC-44 timestamp placement) introduces a new SSE event written between `chat.completion.chunk` events:

`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:489-494`:
```swift
if toolCallOpenEmitted.setIfUnset() {
    writer.writeSSEJSON([
        "type": "macprovider_tool_call_open",
        "unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
    ])
}
```

The coordinator forwards this line byte-for-byte to the buyer (`phase4-coordinator/internal/buyer/server.go:2581` pre-commit `preCommit.Write(line)`, `:2627` `w.Write(preCommit.Bytes())`, `:2660` per-line `w.Write(line)`). No stripping happens between provider and buyer. The event reaches every buyer's SSE reader.

The Vercel AI SDK `@ai-sdk/openai-compatible@2.0.38` (Cline's exact pinned dependency per `test/integration/streaming_terminal_error/package.json:9` and SPEC AC-48b citation at `specs/SPEC-018-agentic-tool-calling.md:641,840`) validates each SSE event against a Zod schema. The schema's chunk arm REQUIRES `choices: z.array(...)` (`node_modules/@ai-sdk/openai-compatible/dist/index.mjs:925-960` — `chunkBaseSchema`), and its error arm REQUIRES `{error: {message: string, ...}}` (`:19-29` — `openaiCompatibleErrorDataSchema`). The `macprovider_tool_call_open` event matches NEITHER arm.

Result: the chunk fails Zod validation, `chunk.success === false`, and the SDK's transform stream at `:651-657` enqueues `{type:"error", error: chunk.error}` followed by `{type:"finish", finishReason: {unified:"error"}}`.

Reproduction from this audit (run against the installed pinned versions in `test/integration/streaming_terminal_error/node_modules/`):

```
$ cd test/integration/streaming_terminal_error
$ node -e "<inline doStream test of just data: {macprovider_tool_call_open...} + [DONE]>"
{"type":"stream-start","warnings":[]}
{"type":"error","error":{"name":"AI_TypeValidationError","cause":{"name":"ZodError","message":"[\n  {\n    \"code\": \"invalid_union\",\n    \"errors\": [\n      [\n        {\n          \"expected\": \"array\",\n          \"code\": \"invalid_type\",\n          \"path\": [\n            \"choices\"\n ...
{"type":"finish","finishReason":{"unified":"error"},...}
```

The error part is mid-stream and visible to Cline's `AgentRuntime`.

This violates SPEC-018 §10c (`specs/SPEC-018-agentic-tool-calling.md:687`):

> Future versions MAY add new fields, new SSE delta shapes, or new finish reasons — but additions MUST NOT break existing parsing.

The Vercel AI SDK is the explicit AC-48b release-gate parser. The new SSE event breaks its parsing. Whether Cline's downstream `AgentRuntime` swallows the `error` part or surfaces it to the user, the SDK-level "additions MUST NOT break existing parsing" obligation is violated.

Additional context — the openai-python ecosystem (AC-43 / AC-48a gate, pinned at `openai==2.44.0`) is more permissive: it parses the unknown event into a `ChatCompletionChunk` with `choices=None`, `id=None`, etc., without raising — BUT downstream code that naively iterates `chunk.choices` (the standard usage pattern across the openai-python ecosystem) will hit `TypeError: 'NoneType' object is not iterable`. Verified by direct test of `openai==2.44.0` streaming reader. So even the AC-43 forward-compat invariant is at risk in the integrator-code-quality sense, although it survives at the strict "no SDK parse error" reading of AC-43.

**Confidence:** HIGH (reproduced mechanically against the exact pinned SDK versions from the IMPL test fixtures).

**Why this matters:** The whole point of v0.2.4 (per `specs/SPEC-018-agentic-tool-calling.md:11-15`) is "narrow Cline drop-in works." The Cline drop-in path runs through `@ai-sdk/openai-compatible`. Injecting an `AI_TypeValidationError` into every Cline session that uses tool calls (i.e. every Cline session, since Cline's whole agent loop is tool-call-driven) breaks the release-gate framework. Combined with the §10c forward-compat invariant violation, the new event is functionally an unannounced wire-shape break.

This finding was not surfaced in r2 because: (a) r2's H-1 fix was treated as a "move the timestamp to the right moment" mechanical change, not as introducing a new SSE event type; (b) no test in this IMPL exercises a tool-call stream that includes the new event against the actual Vercel AI SDK (AC-48b fixture exercises only terminal-error frames; no AC-43-style success-stream forward-compat fixture was extended to include `macprovider_tool_call_open`).

**Fix (pick one):**

1. **Encode the tool-call-open timestamp as an additive field on the EXISTING first tool-call `chat.completion.chunk`** instead of a new top-level SSE event. For example: `delta.tool_calls[0].extra_content.macprovider.tool_call_open_unix_ms` (the Vercel SDK schema already accepts `extra_content` per `chunkBaseSchema:945-950`, and the openai-python `looseObject` tolerates unknown nested fields). This preserves the chunk-shape envelope every SDK already validates against and stays within §10c's "additive fields" allowance.

2. **Have the coordinator strip the `macprovider_tool_call_open` event line before forwarding to the buyer.** The coordinator already parses the event for AC-44 instrumentation (`streaming_timing.go:110`), so it can short-circuit the byte-forward at `server.go:2581` and `:2660` when `toolCallOpenFromSSELine` matches. This keeps the provider-side event for instrumentation but removes it from the buyer-visible wire. **Caveat:** this changes the coordinator's pre-commit-buffer logic; needs care so the line is not counted in the cap or commit-worthy detection.

3. **Use an SSE comment line** (e.g. `: macprovider_tool_call_open unix_ms=...\n\n`) instead of a `data:` line. SSE comments start with `:` and are ignored by EventSource-compliant parsers. The Vercel AI SDK's `parseJsonEventStream` skips non-`data:` lines. Same for openai-python. This is the cleanest fix for forward-compat: the comment is informative, instrumentation-only, and zero buyer-side surface. The coordinator's `toolCallOpenFromSSELine` would need to parse the comment shape, but that's a small change.

Of the three, option (3) is structurally cleanest and most §10c-compliant; option (1) is the least change to the coordinator pipeline; option (2) is the most isolated to one component but leaves the byte on the wire from provider→coordinator (still safe).

### minor findings

- **m-1** — AC-46 test at `ToolCallParserTests.swift:7-11` asserts the function returns nil for malformed input, but does not capture stderr to assert that the log line was emitted. Comment at line 10 acknowledges this: "Logging happens; test passes if no fatal error." A strict test would `dup2` stderr to a pipe, parse the output, and assert the marker substring. Not a blocker — the function is small and the log path is straight-line — but a polish item for v0.3.

### Open Questions

- **Q-1** — Does Cline's `AgentRuntime` (downstream of the Vercel AI SDK `streamText` `fullStream`) silently swallow an `{type:"error", error: AI_TypeValidationError}` part mid-stream, surface it as a user-visible error, or abort the agent loop? I confirmed the SDK emits the error part; I did NOT confirm Cline's downstream handling. If Cline does swallow it gracefully, C-1's real-world impact is reduced from "Cline drop-in broken" to "every Cline tool-call session emits a mid-stream error that operators may see in logs." If Cline surfaces it, C-1 is the full release-gate break. Either way, the §10c violation stands; C-1 retains severity at CRITICAL on the SPEC-violation reading. Verifying Cline's actual response would tighten the impact statement but does not change the severity.

## Multi-perspective notes

- **Executor (the buyer integrator):** The new SSE event causes a parse-error part in the Vercel AI SDK stream. Even if Cline swallows it, third-party integrators using the same SDK (the AC-48b-cited path is the canonical openai-compat anchor) will see TypeValidationError noise. They have no way to know this is intentional because the SPEC says additive changes MUST NOT break parsing — there's no contract for "expect a parse-error part on every successful tool-call stream."
- **Stakeholder (v0.2 release gate):** The whole release narrative is "Cline drop-in works." The very fix that closes AC-44 instrumentation breaks the Cline parser. Without C-1's fix the release-gate framework cannot succeed at its primary use case.
- **Skeptic:** The strongest counter is "Vercel AI SDK's error part is informational; Cline may handle it as a no-op and continue accumulating the tool call from subsequent chunks." Rebuttal: my direct test showed `{type:"finish", finishReason:{unified:"error"}}` is the FINAL part of the stream when a single `macprovider_tool_call_open` event is the only delta. In a real stream interleaved with chat.completion.chunk events, the `error` part appears mid-stream and the finish reason may still settle to `"tool_calls"`, but the error part is still emitted and the SDK's `Result` type carries the error. Either Cline must explicitly filter `error` parts by name (not standard), or it surfaces / aborts. Either path violates §10c "MUST NOT break parsing."

## Verdict justification

**FIX REQUIRED** — 1 CRITICAL exceeds the 0/0/0 merge bar.

**Mode:** Started in THOROUGH, escalated to ADVERSARIAL when I found that the new SSE event was not exercised against the AC-48b SDK. r3 was supposed to be defensive close-confirmation; the fact that an undocumented new wire-shape event was introduced as part of the H-1 fix is exactly the kind of structural drift that ADVERSARIAL mode is for.

**Realist Check applied to C-1:**

1. *Realistic worst case:* Cline surfaces "AI_TypeValidationError" mid-stream every time a tool call fires. Every Cline session that uses tool calls (effectively every session) hits this. v0.2.4's release gate fails the moment it's tested with real Cline.
2. *Mitigating factors:* Cline MIGHT defensively skip error parts and continue accumulating. The openai-python ecosystem is more tolerant. AC-44 instrumentation is operator-only (not buyer-visible), so a stripping fix is cheap.
3. *Detection time:* Immediate on first Cline session against any v0.2.4 provider — but only if AC-48b's test is extended to cover SUCCESS streams with the new event, which it currently does not. Without that test, the gap might silently slip to production.
4. *Hunting-mode bias check:* The SPEC §10c text is explicit and unambiguous ("additions MUST NOT break existing parsing"). The mechanical Zod-validation failure is reproducible. This is not an inflated severity — the new event genuinely breaks the canonical parser.

C-1 retained at CRITICAL. Three fix paths offered, ranging from cheap (SSE-comment) to comprehensive (coordinator strip).

**Pre-commitment predictions vs actuals:**

- Predicted: AC-25a fixture passes after the `key=` fix (HIT — runs to completion).
- Predicted: NSLock wrappers correctly capture flag state via reference type (HIT — `StreamedFlag` is `final class`, all accesses lock-guarded).
- Predicted: `validObservedModelHash` logs on both wrong-length AND non-hex paths (HIT — both branches log).
- Predicted: NTP skew header fully removed (HIT — zero references in gateway).
- Predicted: AC-44 timestamp fires at first `.toolCallDelta`, not SSE-start (HIT — placement is correct).

**Bonus uncovered:** The new SSE event introduced by the H-1 fix breaks `@ai-sdk/openai-compatible` chunk validation (C-1). Not in pre-commitment set — I expected r2's H-1 fix to be in-place; I did not predict that the structural mechanism (new top-level SSE event type) would itself violate §10c. Surfaced by mechanically running the new event through the pinned SDK's chunk schema.

**To upgrade to READY TO MERGE:**

1. Apply one of C-1's three fix options (recommend (3) SSE comment for minimum surface; (1) `delta.tool_calls[0].extra_content.*` if a `data:` line is required for some downstream tool).
2. Extend AC-48b OR add a new AC-43-shape success-stream fixture to cover the v0.2.4 wire shape against the Vercel AI SDK — proof that the chosen fix actually keeps `chunk.success === true` end-to-end.
3. (m-1, optional) Tighten the AC-46 test to assert stderr capture.

After C-1 is fixed, re-run the new fixture for AC-48b success-path + AC-43 streaming forward-compat against the pinned SDK; if both pass, the bar is met.

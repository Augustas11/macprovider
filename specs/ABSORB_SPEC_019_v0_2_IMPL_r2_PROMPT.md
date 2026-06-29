# SPEC-019 v0.2 IMPL — r2 absorption prompt

You are absorbing r2 IMPL audit findings (0C + 3H + 6M across 6 lanes,
with A/C/F READY at r2) into the working tree on branch
`impl/spec-019-v0-2`. r2 narrative:
`specs/SPEC-019-v0_2-IMPL-r2-audit.md`.

**Constraints — DO NOT VIOLATE:**

- SPEC-019 v0.2.4 LOCKED text is **immutable**. Do NOT edit
  `specs/SPEC-019-structured-output.md`.
- No SPEC-018 edits, no SPEC-006 edits, no SPEC-015 schema change.
- No new HTTP endpoint.
- No new error codes.
- After edits, the 3-module smoke MUST be green:
  - phase3-binary baseline: 638 tests / 7 skipped / 0 failures
  - phase4-coordinator: green
  - phase5-gateway: green
  - New tests added by absorption MUST pass.
- Reasoning effort: **high** (multipleOf trap fix is a money-path
  regression; buffer-as-of-close TOCTOU touches the AC-V2-9 ordering
  contract).

## Resolved design calls (baked in — DO NOT re-litigate)

**Decision 1A — `Int64(exactly: value)` for multipleOf Int64 trap.**
Replace the unchecked `Int64(value)` cast with `Int64(exactly: value)`.
Remove the redundant boundary guards. `Int64(exactly:)` returns `Int64?`
and never traps.

**Decision 2γ — Defer fixture authenticity to v0.2.x.**
D-r2-H-1 (Cline static fixture) + D-r2-M-1 (Vercel static fixture) +
D-r2-M-2 (partial-content static fixture) + E-N-4 (hand-authored
lockfile assertions) — DO NOT add a JS/TS regen harness in r2
absorption. Instead:
1. Open a GitHub tracking issue: "SPEC-019 v0.2 IMPL fixture
   authenticity — JS/TS harness + real SDK capture".
2. Add `test/integration/spec_019/KNOWN_GAPS.md` documenting the
   static-vs-live gap and pointing at the tracking issue.

**Decision 3ε — Buffer-as-of-close ordering: markTimedOut → cancel → await termination → snapshot → validate.**
Add `operationStopped` flag (or CheckedContinuation) on
`StructuredStreamingIdleState`. Watcher arm reorders to drain the
operation before reading the accumulator snapshot.

## Absorption items

### Convergent — 4 themes

**T-r2-1: multipleOf Int64 trap (1H closure)**

**Site:** `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:278-286`.

Rewrite `exactIntegerValue` to:

```swift
private static func exactIntegerValue(_ value: Double) -> Int64? {
    guard value.isFinite,
          value.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
    return Int64(exactly: value)
}
```

`Int64(exactly:)` returns nil for values outside the `Int64` range
(handling the `Double(Int64.max) = 2^63` rounding boundary correctly).

Add tests in
`phase3-binary/Tests/MacProviderCoreTests/JSONSchemaValidatorTests.swift`:

- `testValidateNumericInstanceAcceptsInt64MaxAgainstMultipleOfOne`:
  schema `{"type":"integer","multipleOf":1}` + value `9223372036854775807`
  → accepts (validation succeeds, no crash).
- `testValidateNumericInstanceAcceptsInt64MinAgainstMultipleOfOne`:
  schema same + value `-9223372036854775808` → accepts (validation
  succeeds, no crash).
- `testValidateNumericInstanceRejectsAboveInt64Max`: schema same +
  value larger than Int64.max (decoded as Double) → FP-fallback path,
  fail-closed via saturation guard.
- `testMultipleOfIntegerPathAcceptsNegativeIntegers`: schema
  `{"type":"integer","multipleOf":2}` + value `-100` → accepts.
- `testMultipleOfIntegerPathRejectsNegativeOffMultiple`: schema same +
  value `-101` → rejects with `json_schema_validation_failed`.

**T-r2-2: buffer-as-of-close TOCTOU (1M closure)**

**Site:** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:668-687`
(`onIdleTimeout` closure passed by T-2 absorption) + `:1138-1180`
(TaskGroup mechanics).

Add to `StructuredStreamingIdleState`:

```swift
private var operationStoppedValue = false

func markOperationStopped() {
    lock.lock()
    operationStoppedValue = true
    lock.unlock()
}

var operationStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return operationStoppedValue
}
```

In the operation closure (the inferenceGate.withPermit { ... } block):
add a `defer { idleState.markOperationStopped() }` at the top OR right
before each return path. Use `defer` so it fires on both success and
throw.

In the watcher arm, when idle fires:
1. `idleState.markTimedOut()`.
2. Cancel the operation via the dedicated `idleCancellation`
   mechanism (already in place from B-M-1 absorption — verify it
   actually fires here).
3. Poll `idleState.operationStopped` with brief sleeps (e.g., 10ms
   intervals, max 100ms wait) until set OR budget elapses.
4. Read `accumulator.content` (now stable).
5. Build synthetic `CompletionResult` and call
   `validateStructuredStreamingCompletion`.
6. Return the validated result OR throw `provider_timeout`.

Add tests:
`phase3-binary/Tests/macprovider-cliTests/StreamingIdleTimeoutValidatesBufferTests.swift`:

- `testIdleBreachReadsBufferAfterOperationStopped`: provider closure
  emits 3 deltas with delays such that the 4th would arrive after
  idle fires; assert the validated buffer is the 3-delta prefix
  (not the 4-delta concatenation that would race the wire).
- Verify existing tests still pass (production code path now uses
  the markOperationStopped barrier).

**T-r2-3: coord-side WS→SSE wire test (1M closure)**

**Site:** `phase4-coordinator/internal/buyer/structured_output_ws_detail_test.go`
(extend the existing file).

Add tests that mount a WS handler and feed synthetic WS end-frames
(or call `forwardWSStreaming` directly with a fake provider stream
ending in the new status):

- `TestForwardWSStreamingMapsResponseByteCapExceededToSSE`: WS
  end-frame `status:"response_byte_cap_exceeded"` → buyer SSE output
  contains `"code":"response_byte_cap_exceeded"`, `settlement_ran:true`,
  literal `request_id` from request.
- `TestForwardWSStreamingMapsProviderTimeoutToSSE`: WS end-frame
  `status:"provider_timeout"` → buyer SSE output contains
  `"code":"provider_timeout"`, `settlement_ran:true`, request_id.

These tests exercise the production branch at `server.go:2347-2350`,
not just the predicate or writer in isolation.

**T-r2-4: idle-breach production catch-translate helper + test (1M closure)**

**Site:** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:680-687`
+ `phase3-binary/Tests/macprovider-cliTests/StreamingIdleTimeoutValidatesBufferTests.swift`.

Extract the catch-translate into a static helper:

```swift
private static func synthesizeIdleTimeoutResultOrThrow(
    accumulator: StructuredStreamingContentAccumulator,
    request: ChatCompletionRequest
) throws -> CompletionResult {
    let synthetic = CompletionResult(
        content: accumulator.content,
        finishReason: "stop",
        promptTokens: 0,
        completionTokens: 0,
        ttftMilliseconds: 0,
        toolCalls: nil,
        modelHashObserved: nil
    )
    do {
        return try validateStructuredStreamingCompletion(
            synthetic,
            request: request,
            buyerVisibleContent: accumulator.content
        )
    } catch {
        throw structuredStreamingProviderTimeoutError()
    }
}
```

The watcher arm calls this helper instead of inlining the
do/catch/translate.

Tests:
- Rewrite `testIdleBreachValidatesBufferAndReturnsSuccessWhenValid`
  and `testIdleBreachValidatesBufferAndThrowsWhenInvalid` to call the
  helper directly. Pass a populated `StructuredStreamingContentAccumulator`
  and a `ChatCompletionRequest` with json_schema. Assert the
  helper's behavior.
- Production code path then has exactly one site that does the
  validate-or-translate, and the test directly exercises it.

### Singular — 1 item

**D-r2-M-3: Composite-render matrix completion**

**Site:** `test/integration/spec_019/composite_render_streaming_invariant/`.

Add 4 JSON files (2 family × 2 streaming-mode for tool-history):
- `non_streaming_qwen3_tool_history_rendered_messages.json`
- `streaming_qwen3_tool_history_rendered_messages.json`
- `non_streaming_llama33_tool_history_rendered_messages.json`
- `streaming_llama33_tool_history_rendered_messages.json`

Extend `assert_fixture.py` to assert byte-equivalence:
- `streaming_qwen3_tool_history` == `non_streaming_qwen3_tool_history`
- `streaming_llama33_tool_history` == `non_streaming_llama33_tool_history`

Use the existing `tool_history_request_body.json` (already present) as
the input. Generate the rendered-messages snapshots from the
ToolPromptRenderer for each family.

### Deferred items (Decision 2γ)

Do NOT add a JS/TS regen harness. Instead:

**Step A:** Create
`test/integration/spec_019/KNOWN_GAPS.md` documenting the
static-vs-live fixture gap:

```markdown
# SPEC-019 v0.2 IMPL — Known fixture gaps (deferred to v0.2.x)

The v0.2 IMPL fixtures assert byte-shape and pinned-version presence,
but the captured request bodies are static (committed JSON) rather
than regenerated from live SDK invocations. The static fixtures
satisfy the AC-V2-5 / AC-V2-12 / AC-V2-13 letter requirements but
the spec-level liveness guarantee is provenance via documentation,
not execution.

**v0.2.x will add:**
- `cline_streaming_structured_output/regenerate.sh` — invokes the
  pinned Cline commit's active streaming primitive against a stub
  endpoint, captures the outbound POST body, overwrites the
  committed JSON.
- `vercel_zod_int_streaming/regenerate.ts` — invokes pinned `ai` +
  `@ai-sdk/openai-compatible` + `zod` against a stub endpoint,
  captures, overwrites.
- `partial_content_negative/{cline,vercel}_partial_then_error/exercise.{sh,ts}`
  — runs the partial-content scenario against a stub upstream that
  emits the SSE sequence, asserts the SDK-side parse failure.

**Tracking:** [GitHub issue link to be added once issue is opened]

**Until v0.2.x:**
- README pins document the intended SDK identity.
- Static `captured_request_body.json` and `sample_stream.sse` are
  hand-crafted to match the shape the pinned SDKs are expected to
  emit.
- `package-lock.json` files in fixture dirs contain the version pins
  as plain text; `assert_fixture.py` checks substring presence.
- Drift detection relies on the human reviewing PRs that change
  these fixtures, not CI.
```

**Step B:** Add a one-line README note to each of the 4 fixture
directories: "Static fixture; see `../KNOWN_GAPS.md`."

**Step C:** Open a GitHub tracking issue titled "SPEC-019 v0.2 IMPL
fixture authenticity — JS/TS harness + real SDK capture" with the
body summarizing D-r2-H-1, D-r2-M-1, D-r2-M-2. Use the per-repo
`gh` helper as documented in CLAUDE.md (the helper routes pushes to
Augustas11 automatically; for `gh` API calls use
`GH_TOKEN=$(gh auth token -u Augustas11) gh issue create ...`).

After opening the issue, edit `KNOWN_GAPS.md` to insert the actual
issue URL where the placeholder is.

### Cleanup — 3 dead-code / rename items

**E-N-1: Remove dead `multipleOf >= .leastNormalMagnitude` guard.**

`JSONSchemaValidator.swift:179`: the guard is already covered by
the `multipleOf > 1e-300` check at line 178. Remove the redundant
line OR annotate as belt-and-suspenders with a comment.

Pick: remove. Single-line cleanup, smaller surface.

**E-N-2: Remove dead `catch is DrainCancelledError where idleState.timedOut` clause.**

`ModelRuntime.swift:1168`: this clause is unreachable after B-M-1
absorption removed `token.fire()` from the idle path. Remove the
clause OR collapse the catch chain.

**E-N-3: Rename `testMultipleOfIntegerPathRejectsFloatingDrift`.**

`JSONSchemaValidatorTests.swift:96-103`: rename to
`testMultipleOfFPFallbackRejectsFloatingDrift` (the test exercises
the FP-fallback path because `numeric: 1.0000000001` is not integer-
representable). Adding the true integer-path coverage is covered by
T-r2-1's new tests.

## Smoke check after edits

```
cd phase3-binary && swift test
cd ../phase4-coordinator && go test ./internal/buyer/...
cd ../phase5-gateway && go test ./internal/router/...
```

All MUST be green. Expected test count:
- phase3-binary: 638 baseline + 5 new from T-r2-1 + 1 new from T-r2-2
  + 2 helper-call tests from T-r2-4 = ~646.
- phase4-coordinator: 391 baseline + 2 from T-r2-3 = ~393.
- phase5-gateway: 206 baseline (no new tests).

## Output requirements

- Commit absorbed changes. Logical per-theme commits preferred OR
  one bundled `impl(019): r2 absorption (0C + 3H + 6M → 0/0/0
  target)`.
- Document test count delta in the commit message.
- DO NOT open the IMPL PR. r3 audit will fire against the absorbed
  tree.
- If you cannot open the GitHub tracking issue (no `gh` access),
  leave the placeholder in `KNOWN_GAPS.md` and surface that as a
  TODO in the commit message for the orchestrator to handle.

# SPEC-019 v0.2 IMPL — r1 absorption prompt

You are absorbing r1 IMPL audit findings (3C + 8H + 9M across 6 lanes)
into the working tree on branch `impl/spec-019-v0-2` at HEAD `e5e9995`.

r1 narrative: `specs/SPEC-019-v0_2-IMPL-r1-audit.md`.

**Constraints — DO NOT VIOLATE:**

- SPEC-019 v0.2.4 LOCKED text is **immutable**. Do NOT edit
  `specs/SPEC-019-structured-output.md`.
- No SPEC-018 edits.
- No SPEC-006 edits.
- No SPEC-015 schema change.
- No new HTTP endpoint.
- No new error codes (the 4 SPEC-019 codes are the active set; reuse
  only).
- After edits, the full 3-module smoke MUST be green:
  - `phase3-binary`: `swift test` (baseline 627 tests / 7 skipped / 0
    failures — must stay ≥ 627 with no failures)
  - `phase4-coordinator`: `go test ./internal/buyer/...`
  - `phase5-gateway`: `go test ./internal/router/...`
- Commit message format: separate commits per absorption theme is
  fine, OR one bundled "impl(019): r1 absorption" commit.
- Reasoning effort: **high** (this absorption touches money-path
  surface; getting any layer wrong opens fresh CRITICAL findings).

## Resolved design calls (baked in — DO NOT re-litigate)

**Decision 1A — Single canonical 4-code set replicated at 3 sites.**
Each site MUST match SPEC-019 v0.2.4 §5 terminal-code table:
`malformed_json_response`, `json_schema_validation_failed`,
`response_byte_cap_exceeded`, `provider_timeout`. Add per-site
unit/integration tests asserting the 4-code parity.

**Decision 2α — Idle breach validates buffer-as-of-close.**
On provider-idle breach, run `validateStructuredStreamingCompletion`
on the accumulated `StructuredStreamingContentAccumulator.content`
buffer BEFORE throwing `provider_timeout`. If buffer validates →
return success `CompletionResult` (buyer sees `[DONE]`). If buffer
fails validation → throw `provider_timeout` APIError.

**Decision 3δ — Scaled-integer multipleOf comparison with denormal pre-inference reject.**
Pre-inference: reject `multipleOf` operands that are sub-normal
(`< Double.leastNormalMagnitude`) or `<= 0` with
`json_schema_unsupported_keyword`. Runtime instance enforcement:
prefer scaled-integer comparison when both operands are integer-
representable; otherwise compute quotient and fail-closed on
non-finite or `|quotient| > 1e15` (precision-loss threshold).

## Absorption items

### Convergent — 5 themes

**T-1: 3-site 4-code allow-list (3C + 5H closure)**

**Site 1.a — Provider WS frame.**
`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529-554`.

Extend the `errorEndFrame` switch:
- Existing: `malformed_json_response`, `json_schema_validation_failed`
- Add: `provider_timeout`, `response_byte_cap_exceeded`

For each of the 4 codes, the WS end-frame `status` MUST match the
APIError `code` literally. `retryable` flag preserved per the
APIError's `retryable` field (with v0.2.4 defaults:
`malformed_json_response`/`json_schema_validation_failed` =
retryable:true; `provider_timeout`/`response_byte_cap_exceeded` =
retryable:false matching `spec018RetryableByCode`).

Add Swift test:
`phase3-binary/Tests/macprovider-cliTests/InferenceRelayStructuredOutputTests.swift`
asserts each of the 4 codes round-trips through `errorEndFrame` with
the literal status string preserved (no `error_internal` downgrade).
Test name pattern: `testInferenceRelayPreserves<CodeName>StatusOverWS`.

**Site 1.b — Coord WS detail-code allow-list.**
`phase4-coordinator/internal/buyer/server.go:5029-5037`.

Extend `isSpec019ProviderDetailCode` from 2 to 4 codes. Same set:
`malformed_json_response`, `json_schema_validation_failed`,
`response_byte_cap_exceeded`, `provider_timeout`.

Verify the surrounding code (`forwardWSStreaming` at `:2347-2350`)
correctly emits the SPEC-019-specific SSE via `writeSSEError` for
all 4 codes (not just generic `"provider_error"`). The
`writeSSEError` site at `:5152` already sets `settlement_ran:true`
for all 4 SPEC-019 codes; verify the call-site chain delivers the
right code to it.

Add Go test:
`phase4-coordinator/internal/buyer/structured_output_ws_detail_test.go`
asserts each of the 4 codes survives the WS end-frame → coord SSE
path with the literal code preserved.

**Site 1.c — Gateway terminal-SSE allow-list.**
`phase5-gateway/internal/router/chat_proxy.go:1076-1083`.

Extend `isSpec019TerminalSSEErrorCode` from 2 to 4 codes. Same set.

Verify `forwardLine` (line 529) correctly recognizes all 4 codes
BEFORE falling through to `streamingCompletionDeltaBytes`. Existing
`terminalStructuredErrorCode` flag mechanism preserves the
post-terminal money-path correctly (e5e9995 pre-audit fix).

Add Go tests in
`phase5-gateway/internal/router/streaming_structured_output_test.go`:
- One test per code asserting the gateway forwards verbatim + refund-
  only + no `stream_malformed` remap + no `outcome:"ok"` settle.
- One test asserting coord-emitted `response_byte_cap_exceeded` SSE
  passes through (was the C-r1-H-2 / E-C-3 specific failure mode).
- One test asserting coord-emitted `provider_timeout` SSE passes
  through.

**Citation comments:** at each of the 3 site allow-list functions, add
a comment block citing AC-V2-3a + AC-V2-9 + AC-V2-9b + SPEC-019 v0.2.4
§5 as the normative source. Document why the 4-code set is the
canonical set (matching the SPEC table) and that asymmetry across the
3 sites is a money-path violation.

**T-2: Idle breach validates buffer-as-of-close (1C closure)**

Modify `withStructuredStreamingIdleTimeout` in
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1105-1145`.

Current behavior (broken): on idle breach, throws
`structuredStreamingProviderTimeoutError()` immediately.

Required behavior:
1. On idle breach, mark `idleState.markTimedOut()`.
2. `token.fire()` to cancel the inference task.
3. Wait briefly for the operation task to terminate.
4. Read `structuredAccumulator.content` (buffer-as-of-close).
5. Build a synthetic `CompletionResult` with `finishReason: "stop"`,
   the buffer-as-of-close content, `promptTokens: 0`, `completionTokens: 0`,
   `ttftMilliseconds: 0`, no tool calls.
6. Call `validateStructuredStreamingCompletion(synthetic, request,
   buyerVisibleContent: structuredAccumulator.content)`.
7. If validation returns successfully → return the validated
   `CompletionResult` (buyer sees success `[DONE]`).
8. If validation throws → throw `structuredStreamingProviderTimeoutError()`
   (current behavior, buyer sees `provider_timeout`).

The TaskGroup arm currently can return T or throw; it now needs to
return the validated result OR re-throw the timeout error. Keep the
no-double-fire semantics: `markFinished()` after either path.

Pass the `structuredAccumulator` into the TaskGroup arm. Pass the
`request` (or just `responseFormat`) into the TaskGroup arm. Pass a
closure that calls `validateStructuredStreamingCompletion` to keep
the validation site co-located.

Add test:
`phase3-binary/Tests/macprovider-cliTests/StreamingIdleTimeoutValidatesBufferTests.swift`
covering both branches:
- Buffer valid → success `[DONE]`
- Buffer invalid → `provider_timeout` APIError

**T-3: multipleOf validator denormal + saturation safety (1H closure)**

**Pre-inference reject in `JSONSchemaValidator.swift:160-180`:**

In `validateNumericBounds`, after the existing `multipleOf > 0`
check, add:

```swift
if let multipleOf = ..., multipleOf < .leastNormalMagnitude {
    throw unsupportedKeyword("multipleOf", pointer: pointer)
}
```

Also reject `multipleOf` that is `.infinity`, `-.infinity`, or `.nan`
(belt-and-suspenders — `numericBoundValue` already filters via JSON
parsing, but explicit is better).

Apply the same check at the coord mirror: `server.go:3893-3955`
`validateJSONSchemaNumericBounds` + `jsonSchemaNumberOperand`. Reject
sub-normal `multipleOf` with `json_schema_unsupported_keyword`.

**Runtime instance enforcement in `JSONSchemaValidator.swift:237-260`
`validateNumericInstance`:**

Replace the existing tolerance-based comparison with:

```swift
private static func validateNumericInstance(_ instance: JSONValue, schemaObject: [String: JSONValue], type: String, pointer: String) throws {
    guard type == "number" || type == "integer", let numeric = numericInstanceValue(instance) else { return }
    if let minimum = ..., numeric < minimum { throw ... }
    if let maximum = ..., numeric > maximum { throw ... }
    if let multipleOf = ... {
        // Try scaled-integer comparison first (exact, no FP error)
        if let numericInt = exactIntegerValue(numeric), let multipleOfInt = exactIntegerValue(multipleOf), multipleOfInt != 0 {
            if numericInt % multipleOfInt != 0 {
                throw validationError("Structured output is not a multipleOf value at \(pointerOrRoot(pointer))", pointer: pointer)
            }
            return
        }
        // FP fallback with saturation guard
        let quotient = numeric / multipleOf
        guard quotient.isFinite, abs(quotient) <= 1e15 else {
            // Fail-closed: unverifiable result is treated as invalid output
            throw validationError("Structured output is not a multipleOf value at \(pointerOrRoot(pointer))", pointer: pointer)
        }
        let nearest = quotient.rounded()
        let tolerance = max(1e-12, abs(quotient) * 1e-12)
        if abs(quotient - nearest) > tolerance {
            throw validationError(...)
        }
    }
}

private static func exactIntegerValue(_ value: Double) -> Int64? {
    guard value.isFinite,
          value.truncatingRemainder(dividingBy: 1) == 0,
          value >= Double(Int64.min),
          value <= Double(Int64.max) else { return nil }
    return Int64(value)
}
```

Add tests:
- `multipleOf: 1e-300` schema with various numeric instances → all
  reject (pre-inference, because denormal pre-reject fires).
- `multipleOf: 0.5` (FP fallback) with `numeric: 1.5` → pass.
- `multipleOf: 0.5` with `numeric: 1.3` → fail validation.
- `multipleOf: 1` with `numeric: 1.0000000001` → fail validation (no
  longer accepted because integer-comparison path rejects).
- `multipleOf: 3` with `numeric: 1e16` → fail-closed because
  saturation.

**T-4: Gateway wall-clock zero-point at entry (1M closure)**

In `phase5-gateway/internal/router/chat_proxy.go`:

Move the `upCtx, cancelUpstream := context.WithTimeout(...)` creation
from `:225` (after body read + reservation + concurrency) to
immediately after the `start` timestamp captured at line 65.

Specifically: at the top of `handleChatCompletions`, after `start :=
s.now()` (line 65), add:
```go
upCtx, cancelUpstream := context.WithTimeout(r.Context(), s.cfg.CoordinatorTimeout())
defer cancelUpstream()
```

Then thread `upCtx` through the downstream calls. Remove the duplicate
`context.WithTimeout` creation later. Verify the `cancelUpstream`
deferred-call is still required at the original site, or move the
defer accordingly.

Add citation comment at the new site:
```go
// AC-V2-9: gateway-side first-byte-of-request is the SPEC-019 v0.2
// wall-clock zero-point. The 300s budget (`coordinator_request_seconds`
// by convention) measures from this point to provider terminal SSE
// frame emission. Pre-upstream gateway time (body read, quota
// reservation, concurrency reservation) counts against the budget.
```

Add test: assert that a request that takes >290s in body-read + setup
still gets a `provider_timeout` SSE within the 300s budget (or
adjust the test to check that the upstream timeout context's parent
deadline is reachable from the request start).

**T-5: No-double-fire invariant test (1H closure)**

Add Go integration test in
`phase5-gateway/internal/router/streaming_structured_output_test.go`:

`TestStreamingStructuredOutputNoDoubleFireProviderIdleTimeout`:
- Simulate provider WS frame with `status: "provider_timeout"` (after
  T-1.a fix, this is now the literal code, not `error_internal`).
- Coord side emits SSE with `code:"provider_timeout"` + the SPEC-018
  §10d.4 envelope (after T-1.b fix).
- Gateway forwards verbatim (after T-1.c fix), sets
  `terminalStructuredErrorCode = "provider_timeout"`.
- Assert that subsequent SSE frames or upstream disconnects do NOT
  produce a second terminal frame (the e5e9995 guard plus any
  follow-on guards).
- Assert no `outcome:"ok"` settle, no `outcome:"stream_truncated"`
  settle, no double-`writeSSEError` call.

### Singular — 7 items

**B-M-1: drainCancelled race with structured-streaming idle**

In `withStructuredStreamingIdleTimeout`, the idle watcher currently
calls `token.fire()` then throws. The outer `withDrainCancellation`
race-converts the fired token into `DrainCancelledError`, which
`HTTPServer.swift:572` maps to swap-drain envelope.

Fix: do NOT call `token.fire()` from the idle-timeout path. Instead
introduce a dedicated `idleCancellation` signal (a fresh
`DrainCancelToken` or a `Task.cancel()` on the inner operation task)
that does not propagate to the outer drain watcher.

Add test exercising the race: trigger idle timeout while
`withDrainCancellation` is also active; assert the buyer sees
`provider_timeout`, NOT swap-drain envelope.

**D-M-1: AC-V2-14 fixture expansion**

`test/integration/spec_019/composite_render_streaming_invariant/`:
- Add Qwen3 family-specific artifact (rendered messages snapshot).
- Add Llama-3.3 family-specific artifact (rendered messages
  snapshot).
- Add non-empty tool-history fixture (request body includes
  `tools` array + at least one prior `assistant` tool-call message).
- `assert_fixture.py` asserts byte-equivalence between
  `streaming_rendered_messages.json` and
  `non_streaming_rendered_messages.json` for each family + tool-
  history case.

**D-M-2 + E-M-1: Fixture version pinning asserted in CI**

`test/integration/spec_019/cline_streaming_structured_output/assert_fixture.py`:
- Read pinned versions from a `pinned_versions.json` (or from the
  README via grep) and assert presence in `package-lock.json` or
  `bun.lockb`.
- Assert captured body contains exact `required`,
  `additionalProperties:false`, and numeric bounds from
  `captured_request_body.json:21-31` (D-M-2 specific).

Same pattern for `vercel_zod_int_streaming/`.

**E-M-2: Inclusive-boundary cap test + end-to-end wire coverage**

In `phase3-binary/Tests/macprovider-cliTests/StreamingByteCapTests.swift`:
- Add test for `cap` exactly (2_097_152 bytes) — must SUCCEED (not
  throw).
- Add test for `cap + 1` (already exists) — must throw.

End-to-end tests after T-1 fix lands:
- Provider emits cap-exceeded WS frame → coord forwards as
  `response_byte_cap_exceeded` SSE → gateway forwards verbatim →
  buyer sees `response_byte_cap_exceeded` SSE + refund-only.
- Provider emits idle-timeout WS frame → coord forwards as
  `provider_timeout` SSE → gateway forwards verbatim → buyer sees
  `provider_timeout` SSE + refund-only.

**F-M-1: AC-V2-* citation comments at enforcement sites**

Add per-site citation comments per the r1 narrative §F-M-1 list. House
style is short single-line comments above the enforcement site:
```swift
// AC-V2-9b (SPEC-019 v0.2.4 §6): 2 MiB streaming content cap on
// post-stop-token-filter buyer-visible content delta concatenation.
```

**F-M-2: Magic constant SPEC citation**

In `ModelRuntime.swift:195-197`:
```swift
// AC-V2-9b (LOCKED): SPEC-019 v0.2.4 §6 normative 2 MiB streaming
// content cap. Byte domain is post-stop-token-filter buyer-visible
// content delta concatenation.
static let structuredStreamingValidationBufferByteCap = 2_097_152

// AC-V2-9 N placeholder: SPEC-019 v0.2.4 §10 defers the concrete
// idle-timeout value to v0.2.x; 60 is the IMPL placeholder.
static let structuredStreamingIdleTimeoutSeconds: TimeInterval = 60
```

**F-M-3: StreamingStructuredOutputTests.swift filename**

Rename `phase3-binary/Tests/MacProviderCoreTests/StreamingStructuredOutputTests.swift`
→ `StrictJSONParserStreamingBufferTests.swift` (reflects its actual
1-test panic-safety content). Update Package.swift if needed.

### Out-of-scope (do NOT absorb)

- Lane E notes on `endErrorMessage` provider-supplied free text being
  buyer-visible — pre-existing, not v0.2-introduced.
- Cline `captured_request_body.json` missing `temperature`/`top_p` —
  lane E observation, but the body shape is what AC-V2-5 actually
  pins. Captured-vs-handcrafted question is for v0.2.x or release-
  prep, not r1 absorption.

## Smoke check after edits

Run all 3 module test suites:
```
cd phase3-binary && swift test
cd ../phase4-coordinator && go test ./internal/buyer/...
cd ../phase5-gateway && go test ./internal/router/...
```

All MUST be green. Document the new test counts.

## Output requirements

- Commit absorbed changes. Logical per-theme commits preferred:
  - `impl(019): r1.T-1 4-code allow-list at 3 sites + parity tests`
  - `impl(019): r1.T-2 idle breach validates buffer-as-of-close`
  - `impl(019): r1.T-3 multipleOf scaled-integer + denormal reject`
  - `impl(019): r1.T-4 gateway wall-clock zero-point at entry`
  - `impl(019): r1.T-5 + S-* test coverage + citations`
- Or one bundled `impl(019): r1 absorption (3C+8H+9M → 0/0/0 target)`.
- Document test count delta in commit message.
- DO NOT open the PR. r2 audit will fire against the absorbed tree.

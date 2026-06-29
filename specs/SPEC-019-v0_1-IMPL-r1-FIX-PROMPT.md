# SPEC-019 IMPL r1 absorption (TIGHT)

Edit the SPEC-019 IMPL diff to absorb r1 findings. Target outcome:
3 IMPL commits → 1 absorption commit, all smoke tests still green.

**Low reasoning effort. No SPEC body edits (SPEC is LOCKED). No
commits during edits — let me commit once at the end. No documentation
files beyond what's specified below.**

Aggregate r1: 2 CRITICAL + 7 HIGH + 8 MEDIUM + 4 minor + 3 Q across
6 lanes. The 2 CRITICALs are one root cause at two layers; the
HIGHs are 4 distinct issues.

## A. CRITICAL — extend error-code allow-list at WS hop (Provider → Coordinator)

The provider's WS `errorEndFrame` allow-list only includes 4 legacy
codes. SPEC-019 codes `malformed_json_response` and
`json_schema_validation_failed` collapse to `error_internal` at the
WS frame, never crossing the boundary.

File: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529-548`

Find the `errorEndFrame` builder (and related serialization) where the
allow-list of buyer-visible codes lives. Extend it to include:

- `malformed_json_response` (preserve `retryable` from envelope)
- `json_schema_validation_failed` (preserve `retryable: true`)

These MUST round-trip through the WS frame unchanged so the
coordinator HTTP path can classify them as `FaultBreakerQualifying`.

## B. CRITICAL — extend coordinator HTTP allow-list (Coordinator → Buyer)

File: `phase4-coordinator/internal/buyer/server.go:4915-4922`
(`spec001EndStatus` allow-list).

Add the 2 SPEC-019 codes:
- `malformed_json_response`
- `json_schema_validation_failed`

ALSO at `server.go:1857-1928`: the provider non-200 path that calls
`nullUsageProviderErrorCode` and then renders a generic `provider_error`
on retry exhaustion. When the recognized code is a SPEC-019 detail
code, the HTTP path MUST:

1. NOT retry/fail over (detail codes are terminal, not transient).
2. Preserve the original provider envelope + body to the buyer
   (analog of `passThroughReceiptEligibleProviderError` posture).
3. Log the request-log row with `fault_flag = FaultBreakerQualifying`
   (not `FaultNone`).
4. Mark `attempt.ErrorCode = "<detail_code>"` so receipt headers
   reflect the actual error.

Cite line: `phase4-coordinator/internal/buyer/billing_recorder.go:181-183`
(where `FaultNone` defaults on empty fault flag — that path MUST be
explicitly set to FaultBreakerQualifying for these codes).

## C. End-to-end test coverage for the money-path money path

**Two new tests required.**

### C.1 — Provider WS path (Swift)

New test in `phase3-binary/Tests/macprovider-cliTests/`:

`InferenceRelayStructuredOutputTests.swift` (NEW file) — proves a
`malformed_json_response` API error from the structured-output
validator round-trips through `InferenceRelay.errorEndFrame`
serialization with the code preserved, NOT collapsed to
`error_internal`. Same test for `json_schema_validation_failed`.

### C.2 — Coordinator HTTP path (Go)

Extend `phase4-coordinator/internal/buyer/structured_output_validation_test.go`
OR add new file `structured_output_provider_error_test.go`:

- Stub an HTTP provider returning a `502` body with
  `{"error":{"code":"malformed_json_response", ...}}`.
- Coordinator MUST:
  - Not retry/fail over.
  - Pass the envelope through to the buyer with status 502.
  - Log the request-log row with `fault_flag = FaultBreakerQualifying`.
  - Preserve the original detail code in `attempt.ErrorCode`.
- Repeat for `json_schema_validation_failed`.

Also assert (via mock or by reading log spy) that the billing-formula
path returns zero provider-positive credits for both codes.

## D. HIGH — depth-bound StrictJSONParser (security H-1 + code H-1 + critic H-1)

**Decision: pass-through `depth: Int` parameter (A).**

File: `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift`

Current signature recurses without bound:
```swift
private mutating func parseValue() throws -> JSONValue { ... }
private mutating func parseObject() throws -> JSONValue { ... }
private mutating func parseArray() throws -> JSONValue { ... }
```

Change to:
```swift
private mutating func parseValue(depth: Int) throws -> JSONValue {
    if depth > JSONSchemaValidator.maxDepth {
        throw APIError(
            status: 502,
            message: "Structured-output JSON exceeds depth cap of \(JSONSchemaValidator.maxDepth) levels",
            code: "json_schema_validation_failed"
        )
    }
    // ... existing logic, recurse with depth + 1
}
```

Apply same `depth: Int` parameter to `parseObject` / `parseArray`.
Each recursion site passes `depth + 1`. Top-level `parse()` entry
calls with `depth = 1` (root).

Add test in `phase3-binary/Tests/macprovider-cliTests/` (extend
existing or new `StrictJSONParserDepthTests.swift`):

- `[[[...]]]` 32-deep arrays → succeeds.
- `[[[...]]]` 33-deep arrays → throws `json_schema_validation_failed`
  BEFORE recursion completes.
- `{"a":{"a":...}}` 32-deep object → succeeds.
- `{"a":{"a":...}}` 33-deep object → throws same.
- Mixed nesting (alternating array/object) at exactly 32 succeeds,
  at 33 rejects.

ALSO add an end-to-end test in
`phase3-binary/Tests/macprovider-cliTests/ModelRuntimeStructuredOutputTests.swift`:
when the model emits a 33-deep JSON string and `json_schema` is
requested, `ModelRuntime.complete(...)` returns the SPEC-019 502
envelope BEFORE recursion overflow.

Add a module-level comment to `StrictJSONParser.swift` (closes
narrative H-1 + critic blind-spot Q):

```swift
// StrictJSONParser
//
// Why this exists:
// SPEC-019 v0.1.5 §5 requires post-inference structured-output
// validation to be panic-safe and to honor a depth cap of 32 BEFORE
// stack overflow can abort the request handler. Foundation's
// `JSONSerialization.jsonObject(with:)` is recursive without an
// observable depth limit, so we cannot wrap it in `do/catch` to
// satisfy SPEC §5's catch-all rule.
//
// This parser is depth-bounded: every recursion threads a `depth`
// counter; exceeding `JSONSchemaValidator.maxDepth` throws a
// structured `json_schema_validation_failed` 502 before the next
// recursion is entered. It also reuses the same byte-level value
// representation (`JSONValue`) that the schema validator and prompt
// canonicalizer expect, avoiding double-parse cost.
//
// What it does NOT do:
// - Duplicate-key rejection (model output may legitimately repeat
//   keys; SPEC-019 §5 routes duplicate-key fail-closed handling to
//   the validator, not the parser).
// - Number canonicalization beyond what JSONValue already provides.
// - Streaming. v0.1.0 is non-streaming only.
```

## E. HIGH — reject empty-after-trim `Content-Encoding` at all 3 layers (critic H-2 + code M-1)

SPEC AC-28a says empty-after-trim is an adversarial reject fixture.
Current IMPL accepts it at all 3 layers.

### E.1 — Provider

File: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:436-448`
(`validateContentEncoding` or equivalent).

Change the predicate: when the header is PRESENT and normalized value
is empty (after trim), REJECT with HTTP 415
`request_content_encoding_unsupported`. Only OMITTED header or
normalized `identity` accepted.

### E.2 — Coordinator

File: `phase4-coordinator/internal/buyer/server.go:5284-5296`
(`contentEncodingSupported`).

Same: change `normalized == ""` to NOT a success state. Only omitted
header or `identity` succeeds. Header-present-with-empty-value rejects.

### E.3 — Gateway

File: `phase5-gateway/internal/router/chat_proxy.go:628-640`
(same predicate).

Same fix.

### E.4 — Fix gateway test that locks the wrong behavior

File: `phase5-gateway/internal/router/structured_output_test.go:5-16`

Currently asserts header-present-empty is accepted. Change test to
assert it REJECTS with 415.

Add a new test case: omitted header still succeeds.

## F. HIGH — `Content-Encoding` whitespace-strip parity (critic H-2 / code M-1)

Swift `String.isWhitespace` strips Unicode whitespace (incl. NBSP
U+00A0). Go `strings.Map` with `unicode.IsSpace` does the same. But
the audit found Go strips only ASCII whitespace.

**Verify before fix**: grep for the actual normalization function in
the 3 layers. If Swift and Go differ on Unicode whitespace handling,
align both to the LESS-PERMISSIVE behavior: **strip only ASCII
whitespace** (`\t\n\r ` 0x20). NBSP and other Unicode whitespace
should NOT be stripped; the header value with NBSP is then treated
as non-identity and rejected with 415.

This is the safer posture: don't normalize Unicode whitespace
silently.

Update:
- Swift HTTPServer normalization helper (cite line after finding it)
- Go coordinator normalization (`server.go` Content-Encoding helper)
- Go gateway normalization (`chat_proxy.go` Content-Encoding helper)

Add tests at all 3 layers:
- `Content-Encoding: identity` (no whitespace) — accepted
- `Content-Encoding: \tidentity ` (ASCII whitespace surrounds) —
  accepted
- `Content-Encoding:  identity` (NBSP) — rejected (not exactly
  `identity` after ASCII-only strip)

## G. HIGH — Gateway preserves AC-20 streaming-reject envelope (PD-H1)

File: `phase5-gateway/internal/router/chat_proxy.go`

Verify what happens when the coordinator returns the AC-20
streaming-reject envelope (`streaming_json_schema_unsupported` or
`streaming_json_object_unsupported`, type `invalid_request_error`,
`param:"stream"`, etc.) to the gateway. Does the gateway preserve the
envelope verbatim, or remap to `api_error/upstream_provider_error`?

If remapping: extend the gateway's pass-through allow-list to include
these 2 streaming-reject codes (analog of the
`malformed_json_response` / `json_schema_validation_failed`
allow-list at `chat_proxy.go:619-625`).

Add a gateway test asserting the streaming-reject envelope is
forwarded byte-identical.

## H. MEDIUMs

### H.1 — `const`/`enum` integer drift (critic M-3)

Swift accepts `1.0` for an integer schema (`{"type":"integer","const":1}`
— does `1.0` match `const:1`?); Go rejects. Pick one and align.

Likely the safer choice is REJECT both: integer schemas require
integer-typed value, not `1.0`. Update Swift `JSONSchemaValidator`
to reject `1.0` for integer.

Add tests at both layers proving parity.

### H.2 — `json_object` breaking-change message (PD-M1)

File: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:955-964`
(non-empty malformed JSON message).

Current message: "Model output was not valid JSON for the requested
response_format".

Replace with:
```
"Model output was not valid JSON for the requested response_format. If you intended free-form prose, send response_format: {\"type\":\"text\"} or omit the field. Per SPEC-019 v0.1.0, json_object now enforces top-level JSON; this is a breaking change from earlier versions where json_object was a silent no-op."
```

Apply same migration hint to the empty-content message
(`ModelRuntime.swift:942-953`).

### H.3 — Enumerated keyword coverage gaps (code L1)

Extend tests at both layers to cover the full 14 rejected keywords
explicitly:
- Swift: `phase3-binary/Tests/macprovider-cliTests/JSONSchemaValidatorTests.swift`
  Replace the 8-keyword sample with the full 14-keyword enumeration.
- Go: `phase4-coordinator/internal/buyer/structured_output_validation_test.go`
  Replace the 1-keyword sample with the full 14-keyword enumeration.

The 14 keywords (per SPEC §3 reject list):
`oneOf`, `anyOf`, `allOf`, `not`, `$ref`, `$defs`, `pattern`,
`format`, `minimum`, `maximum`, `multipleOf`, `minItems`, `maxItems`,
`uniqueItems`. (Plus `$schema` per §3 footnote.)

### H.4 — Go name-regex test parity (code L2)

Add table cases to
`phase4-coordinator/internal/buyer/structured_output_validation_test.go`:
- `person-v1` accepted (currently not asserted at coordinator)
- `person.v1` rejected
- `Café` rejected
- 65-byte name rejected
- `name\nINJECT` rejected

### H.5 — Fixture README polish (narrative M-2 + M-3)

Files:
- `test/integration/spec_019/vercel_ai_sdk_strict_json_schema/README.md`
- `test/integration/spec_019/openai_python_strict_json_schema/README.md`

For Vercel: add explicit "Add `supportsStructuredOutputs: true` to
`createOpenAICompatible(...)` config" instruction and a 3-line `jq`
snippet showing how to strip `$schema` from a captured outbound body.

Add "Expected outcome:" sentence (mirror `nfc_nfd_adversarial/`
README pattern).

### H.6 — Whitespace-only completion classification (critic M-4)

SPEC §5 is silent on whether `"   \n"` (only whitespace) after stop-
token filtering is "empty" or "malformed JSON".

**Decision: treat as `malformed_json_response` with `retryable:false`**
(same as empty-content branch). Add to
`ModelRuntime.swift:942-953` empty-content classifier: trim
ASCII whitespace before checking emptiness. Document in code comment:
"Whitespace-only output is classified as empty per SPEC-019 §5
empty-content override; this prevents `retryable:true` on
deterministic whitespace-emit failures."

Add test for whitespace-only completion fixture.

### H.7 — StructuredOutputRenderer module comment (narrative M-3)

File: `phase3-binary/Sources/macprovider-cli/StructuredOutputRenderer.swift`

Add module-level header:

```swift
// StructuredOutputRenderer
//
// Renders the SPEC-019 v0.1.5 structured-output schema instruction
// into the chat-template system position per family (Qwen3,
// Llama-3.3). Composed BEFORE ToolPromptRenderer.renderMessages
// per SPEC §4 composite-render rule: schema-adjusted ChatMessage →
// ToolPromptRenderer → UserInput.
//
// Stateless: no per-request, per-connection, or per-family cache.
// Concurrent requests render independently. Cache deferred to v0.2
// per SPEC §10.
//
// Family selection mirrors ToolPromptRenderer.detect(modelID:) —
// modelID substring match; Qwen3 / Llama-3.3 only in v0.1.0.
```

### H.8 — Provider commit AC anchors (narrative M-2)

Already-shipped commit (`7b2a272`) cannot be edited without rewriting
history. Skip this; just add AC anchors to the absorption commit
message.

## I. Minors / Qs not requiring fix

- Critic M-1 fixture detail (no action; SDK-side normalization documented in §10)
- Narrative minor 1 (OpenAI/Vercel README "Expected outcome" sentence handled in H.5)
- Critic Q-1 (SPEC-silent edge cases noted)

## Stop conditions

After editing, run all 3 smoke tests:

1. `cd phase3-binary && swift test 2>&1 | tail -5`
   - Expect: 609 + N new tests, 0 failures.
2. `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer 2>&1 | tail -5`
   - Expect: clean + pass.
3. `cd phase5-gateway && go vet ./... && go test -count=1 ./internal/router 2>&1 | tail -5`
   - Expect: clean + pass.

Report:

- New test count (Swift before/after).
- Confirmation each of §A through §H is addressed.
- Files modified (list).
- Any §A-§H fix you could not place — explain why.

Done. No commit. No re-audit. r2 fires next.

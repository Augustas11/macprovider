# SPEC-019 v0.1.5 IMPL r1 code-lane audit

Audited HEAD: `1a6e00f` on `impl/spec-019-v0-1`.

Verdict: REQUEST CHANGES. Code-lane found `0 CRITICAL / 1 HIGH / 1 MEDIUM / 2 LOW`.

## Findings

### HIGH CODE-H1: Parsed-output depth is checked only after an unbounded recursive parser

`StrictJSONParser` recursively parses arrays and objects with no depth parameter or cap:

- `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:29-36`
- `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:53-65`
- `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:74-80`

`ModelRuntime.parseStructuredJSONContent` calls that parser before any `JSONSchemaValidator.validateInstance` / `jsonDepth` cap can run:

- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:922-924`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-958`

SPEC-019 requires decoded output depth over 32 to become HTTP 502 `json_schema_validation_failed`, and the catch-all requires recursion overflow / resource aborts to become a terminal SPEC-019 envelope. A deeply nested but under-2MiB model output can recurse in the parser before the depth check, so stack overflow / fatal abort is not converted into the required envelope. Swift `do/catch` covers thrown parser errors; it does not recover from stack overflow or `fatalError`.

Fix: carry a depth counter through `StrictJSONParser.parseValue` / `parseObject` / `parseArray`, reject `> JSONSchemaValidator.maxDepth` as a thrown parse/postprocess error, and add an HTTP/runtime regression for 33-deep parsed content.

### MEDIUM CODE-M1: Whitespace-only `Content-Encoding` is accepted at all three layers

SPEC-019 AC-28a says empty-after-trim `Content-Encoding` is an adversarial reject fixture. Current implementation accepts it:

- provider: `RouterHandler.validateContentEncoding` removes whitespace and accepts `normalized.isEmpty` at `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:436-448`.
- coordinator: `contentEncodingSupported` returns true for `normalized == ""` at `phase4-coordinator/internal/buyer/server.go:5284-5296`.
- gateway: same predicate returns true for `normalized == ""` at `phase5-gateway/internal/router/chat_proxy.go:628-640`.

The gateway test explicitly locks the wrong behavior by accepting `{"   "}`:

- `phase5-gateway/internal/router/structured_output_test.go:5-16`

Fix: accept only omitted header or normalized `identity`; reject header-present empty/whitespace-only values with 415 `request_content_encoding_unsupported` at provider, coordinator, and gateway. Update tests at all three layers.

### LOW CODE-L1: Rejected-keyword tests sample the set instead of enumerating SPEC v0.1.5's 34-key set

The implementation uses an allow-list, so all unknown keys are rejected. Swift allowed keys are exactly `type`, `properties`, `required`, `items`, `enum`, `const`, `additionalProperties`, `title`, `description`:

- `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:7-17`
- `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:65-67`

Go mirrors the same allow-list:

- `phase4-coordinator/internal/buyer/server.go:3709-3713`

However, tests cover only a subset:

- Swift: `["oneOf", "$ref", "$defs", "$schema", "pattern", "minimum", "maxItems", "default"]` at `phase3-binary/Tests/macprovider-cliTests/JSONSchemaValidatorTests.swift:9-15`.
- Go: only `minimum` at `phase4-coordinator/internal/buyer/structured_output_validation_test.go:49-54`.

This is not an implementation bypass, but it is a coverage gap for the normative 34 rejected keywords in `specs/SPEC-019-structured-output.md:451-458`.

### LOW CODE-L2: Go name-regex tests do not cover the parity fixtures

Swift and Go implementation semantics are byte-identical, but test coverage is asymmetric. Swift tests cover 65-byte, non-ASCII, newline, punctuation, and dashed accepted name:

- `phase3-binary/Tests/macprovider-cliTests/ChatCompletionRequestTests.swift:82-90`

Go tests cover only `valid<script>`:

- `phase4-coordinator/internal/buyer/structured_output_validation_test.go:43-48`

Add Go table cases for `person-v1` accepted and `person.v1`, `Café`, 65-byte, and `name\nINJECT` rejected to lock coordinator-direct parity.

## Verification matrix

### Schema-subset reject list

PASS for implementation. SPEC allows only `type`, `properties`, `required`, `items`, `enum`, `const`, `additionalProperties:false`, `title`, and `description` (`specs/SPEC-019-structured-output.md:437-449`). Swift and Go both implement this as an allow-list, which rejects the prompt's explicit reject list plus the full v0.1.5 unknown-key set:

- Swift allow/reject: `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:7-17`, `:65-67`
- Go allow/reject: `phase4-coordinator/internal/buyer/server.go:3709-3713`

### Depth algorithm

PASS for schema-depth counting. Root starts at `1`; nested object properties and array `items` call the validator with `depth + 1`; siblings do not increment each other:

- Swift root/depth cap: `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:19-20`, `:58-60`
- Swift properties/items recursion: `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:124-134`
- Go root/depth cap: `phase4-coordinator/internal/buyer/server.go:3689`, `:3701-3703`
- Go properties/items recursion: `phase4-coordinator/internal/buyer/server.go:3761-3766`, `:3779-3780`

FAIL for parsed-output pre-cap safety; see CODE-H1.

### Byte-cap algorithm

PASS. Provider counts raw schema value bytes before parsed serialization via `RawJSONPathScanner`, then retains a compact serialization fallback cap:

- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:83-87`
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:460-466`
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:486-489`

Coordinator uses `json.RawMessage` length for the schema value as present in the request body:

- `phase4-coordinator/internal/buyer/server.go:3682-3688`

Tests include raw whitespace cap coverage:

- `phase3-binary/Tests/macprovider-cliTests/ChatCompletionRequestTests.swift:105-110`
- `phase4-coordinator/internal/buyer/structured_output_validation_test.go:92-99`

### Name regex parity

PASS for implementation. Swift uses UTF-8 byte count `1...64` and ASCII byte membership for `A-Z`, `a-z`, `0-9`, `_`, `-`:

- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:474-484`

Go uses `len(name)` bytes and the same ASCII byte membership:

- `phase4-coordinator/internal/buyer/server.go:3792-3804`

Coverage gap in Go tests is CODE-L2.

### Error envelope coverage

PASS for the requested spot check. SPEC-019's table lists status/retryability at `specs/SPEC-019-structured-output.md:640-659`. Provider and coordinator retryability maps include the SPEC-019 codes:

- provider map: `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:271-290`
- coordinator map: `phase4-coordinator/internal/buyer/server.go:54-73`

Spot-checked mappings:

| Code | Expected | Evidence |
|---|---:|---|
| `json_schema_missing_name` | 400 / false | Swift `:441-445`, Go `server.go:3666-3671`, maps false |
| `json_schema_missing_schema` | 400 / false | Swift `:438-439`, `:457-458`; Go `:3662-3664`, `:3682-3684` |
| `json_schema_non_strict_unsupported` | 400 / false | Swift `:447-455`, Go `:3673-3680` |
| `streaming_json_schema_unsupported` | 400 / false | provider `HTTPServer.swift:451-459`, Go `server.go:3655-3658` |
| `streaming_json_object_unsupported` | 400 / false | provider `HTTPServer.swift:461-467`, Go `server.go:3650-3653` |
| `json_schema_unsupported_keyword` | 400 / false | Swift validator `:65-67`, Go `:3709-3713` |
| `json_schema_too_large` | 413 / false | Swift `ChatCompletionRequest.swift:460-466`, Go `server.go:3686-3688` |
| `json_schema_too_deep` | 400 / false | Swift validator `:58-60`, Go `server.go:3701-3703` |
| `request_content_encoding_unsupported` | 415 / false | provider `HTTPServer.swift:442-447`, coordinator `server.go:1333-1337`, gateway `chat_proxy.go:111-118` and `server.go:789-800` |
| `malformed_json_response` | 502 / true except empty override | `ModelRuntime.swift:943-967`; maps true at provider/coordinator |
| `json_schema_validation_failed` | 502 / true | `JSONSchemaValidator.swift:277-286`; maps true at provider/coordinator |

Gateway pass-through avoids double settlement for the two post-inference detail codes:

- `phase5-gateway/internal/router/chat_proxy.go:331-340`
- `phase5-gateway/internal/router/chat_proxy.go:619-625`
- test: `phase5-gateway/internal/router/structured_output_test.go:29-35`

### Empty-content retryable:false

PASS. Empty content is checked before parsing and emits HTTP 502 `malformed_json_response`, `retryable:false`, `inference_ran:true`, `settlement_ran:true`, with a message naming `temperature` / `seed`:

- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-953`

Test coverage asserts the override:

- `phase3-binary/Tests/macprovider-cliTests/ModelRuntimeStructuredOutputTests.swift:24-32`

# SPEC-019 v0.1.5 IMPL r2 code-lane audit

Audited HEAD: `1bad28c` on `impl/spec-019-v0-1`.

**Verdict:** READY TO MERGE
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified

- r1 H-1: CLOSED. `StrictJSONParser.parse(_:)` now enters at depth `1`, `parseValue(depth:)` throws HTTP 502 `json_schema_validation_failed` before dispatching into object/array parsing when `depth > JSONSchemaValidator.maxDepth`, and object/array children recurse with `depth + 1` (`phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:27`, `:52`, `:87`, `:99`, `:108`, `:114`). Valid 32-deep and invalid 33-deep array/object/mixed fixtures are covered in `StrictJSONParserDepthTests` (`phase3-binary/Tests/macprovider-cliTests/StrictJSONParserDepthTests.swift:5`, `:10`, `:15`).
- r1 M-1: CLOSED. Content-Encoding now accepts omitted headers and normalized `identity`, but rejects header-present empty/whitespace-only values and NBSP-padded values at provider, coordinator, and gateway. Evidence: provider ASCII-only normalization (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:436`, `:451`), coordinator ASCII-only normalization (`phase4-coordinator/internal/buyer/server.go:5332`), gateway ASCII-only normalization (`phase5-gateway/internal/router/chat_proxy.go:644`), plus tests for omitted/identity/whitespace-only/NBSP cases (`phase3-binary/Tests/macprovider-cliTests/HTTPServerStructuredOutputTests.swift:14`, `phase4-coordinator/internal/buyer/structured_output_validation_test.go:149`, `phase5-gateway/internal/router/structured_output_test.go:9`).
- r1 L1: CLOSED. Swift and Go tests explicitly enumerate the requested rejected-keyword set: `oneOf`, `anyOf`, `allOf`, `not`, `$ref`, `$defs`, `pattern`, `format`, `minimum`, `maximum`, `multipleOf`, `minItems`, `maxItems`, `uniqueItems`; both also include `$schema` (`phase3-binary/Tests/macprovider-cliTests/JSONSchemaValidatorTests.swift:9`, `phase4-coordinator/internal/buyer/structured_output_validation_test.go:79`). `format` is rejected by the schema allow-list guard, not silently accepted (`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:7`, `:65`; `phase4-coordinator/internal/buyer/server.go:3727`, `:3728`).
- r1 L2: CLOSED. Go name-regex parity now covers `person-v1` accepted and `person.v1`, `Café`, 65-byte, and `name\nINJECT` rejected (`phase4-coordinator/internal/buyer/structured_output_validation_test.go:110`). The implementation uses byte length `1..64` and ASCII byte membership for `[A-Za-z0-9_-]` (`phase4-coordinator/internal/buyer/server.go:3810`).

## Fresh findings

None.

## Verdict justification

Depth-counter threading is complete for the SPEC-019 parser surface: the only `StrictJSONParser` recursive child calls are object and array element descent, both increment depth before entering the next `parseValue`; `parseString` and `parseNumber` are iterative and do not recurse (`phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:99`, `:114`, `:123`, `:175`). The cap references the shared `JSONSchemaValidator.maxDepth` constant rather than a drift-prone local literal (`phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:53`; `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:5`).

The whitespace-only completion path is ASCII-only and matches the Content-Encoding normalization posture: `" "`, tab, LF, and CR classify as empty with `retryable:false`, while Unicode whitespace is not stripped by this pre-check and therefore flows to strict JSON parsing (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942`, `:994`). Tests lock empty and ASCII whitespace-only as non-retryable (`phase3-binary/Tests/macprovider-cliTests/ModelRuntimeStructuredOutputTests.swift:24`, `:35`).

The r1 absorption touched `JSONSchemaValidatorTests` but did not weaken schema validation. The production allow-list remains the narrow SPEC-019 subset (`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:7`) and strict validation still enforces depth, `additionalProperties:false`, all-properties-required, scalar const/enum typing, and instance validation (`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:58`, `:78`, `:116`, `:142`, `:156`). The absorption did not touch `PromptCanonicalizer.swift` (`git diff --name-only HEAD~1..HEAD -- phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift` returned no paths).

WS and coordinator pass-through semantics relevant to the code lane are intact. Provider-side `InferenceRelay` preserves SPEC-019 codes as the frame `status` and copies the envelope `retryable` value (`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529`, `:550`); the Go WS frame type carries `Retryable *bool` (`phase4-coordinator/internal/ws/messages.go:213`). Coordinator HTTP/WS response writing preserves SPEC-019 codes and retryable values for structured-output provider errors (`phase4-coordinator/internal/buyer/server.go:4933`, `:4942`, `:5068`, `:5083`). The new provider-error test proves no fallback retry, byte-identical body pass-through, request-log error code population, and `billing.FaultBreakerQualifying` with zero provider credits (`phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:17`, `:76`, `:82`, `:89`, `:95`).

Verification run:

- `swift test --filter 'StrictJSONParserDepthTests|JSONSchemaValidatorTests|ModelRuntimeStructuredOutputTests|HTTPServerStructuredOutputTests|InferenceRelayStructuredOutputTests'` in `phase3-binary`: 25 tests, 0 failures.
- `go test ./internal/buyer -run 'TestValidateResponseFormatRejectsUnsupportedKeywords|TestValidateResponseFormatNameRegexParity|TestContentEncodingSupportedForSpec019|TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetry'` in `phase4-coordinator`: pass.
- `go test ./internal/router -run 'TestContentEncodingSupportedForSpec019|TestStreamingStructuredOutputRejectEnvelopePassesThrough|TestStructuredOutputProviderErrorsPassThroughWithoutGatewaySettlement'` in `phase5-gateway`: pass.

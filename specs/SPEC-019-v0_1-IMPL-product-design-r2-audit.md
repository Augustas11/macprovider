**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/0/0

## Closure verified

- r1 PD-H1: CLOSED. The gateway now detects coordinator HTTP 400 structured-output streaming rejects and refunds/passes them through instead of normalizing them to opaque 502: `phase5-gateway/internal/router/chat_proxy.go:402-404`. The allow-list is limited to `streaming_json_schema_unsupported` and `streaming_json_object_unsupported`: `phase5-gateway/internal/router/chat_proxy.go:632-638`. The regression test asserts HTTP 400 and byte-identical body preservation for both codes, including `type:"invalid_request_error"`, `param:"stream"`, `retryable:false`, `inference_ran:false`, and `settlement_ran:false`: `phase5-gateway/internal/router/structured_output_test.go:34-51`.
- r1 PD-M1: CLOSED for the r1-fix scope, but see fresh PD-M1 below. Empty-content and malformed-JSON runtime messages both include the prose-buyer migration hint to send `response_format: {"type":"text"}` or omit the field: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:949` and `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:966`. The longer message is far below the gateway's 16 MiB upstream response-body cap at `phase5-gateway/internal/router/chat_proxy.go:991`, and the inspected error writers add no smaller envelope-size constraint.
- Whitespace-only retry posture: VERIFIED. The runtime treats ASCII whitespace-only structured output as the SPEC-019 empty-content override and sets `retryable:false`: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-956`. The focused test covers `"   \n\t"` and expects `malformed_json_response` with `retryable:false`: `phase3-binary/Tests/macprovider-cliTests/ModelRuntimeStructuredOutputTests.swift:35-43`. Product-design impact is acceptable for legitimate buyers: structured-output whitespace-only content is not useful final output, and SPEC-019 retry semantics still permits deliberate buyer-initiated recovery with a changed prompt, seed, temperature, or schema while preventing blind identical auto-retry loops: `specs/SPEC-019-structured-output.md:617-622`.

## Fresh findings

### MEDIUM PD-M1 - `json_object` valid-scalar failures still omit the prose migration path

The r1 fix added migration guidance to empty output and non-JSON parse failures, but not to the valid-JSON scalar root path for `response_format: {"type":"json_object"}`. If the model returns `"hello"` or `123`, the provider parses the output successfully, then `validateJSONObjectOrArray` throws:

`response_format json_object requires a top-level object or array`

at `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:46-54`.

This is the same buyer-facing migration cohort as r1 PD-M1. SPEC-019 calls `json_object` enforcement a breaking change and tells buyers relying on best-effort text fallback to migrate to omitted `response_format` or `{"type":"text"}` before upgrade: `specs/SPEC-019-structured-output.md:110-115`. The error-code table also classifies invalid `json_object` roots under `malformed_json_response`: `specs/SPEC-019-structured-output.md:657`. A prose buyer whose model emits a JSON string rather than raw prose gets no actionable migration path, even though the failure is still caused by the new `json_object` enforcement rather than a schema-authoring mistake.

Fix: apply the same migration hint used in `ModelRuntime.swift:966` to the `json_object` scalar-root error in `JSONSchemaValidator.validateJSONObjectOrArray`, and add an assertion to `testJsonObjectRequiresObjectOrArray` that the message includes `response_format: {"type":"text"}` or `omit the field`.

## Verdict justification

The public gateway AC-20 envelope passthrough is now product-correct for legitimate buyers using Cline/Vercel-style streaming structured-output requests: the buyer sees the original actionable 400 response instead of a gateway 502. The longer `json_object` empty/non-JSON messages fit comfortably within inspected response limits. Whitespace-only structured output should not be auto-retried as-is because it is semantically empty output under a structured contract, and buyers retain deliberate modified retry control.

The remaining issue is narrow but buyer-visible: one `json_object` breaking-change path still returns a terse validator message with no migration instruction. Because this leaves part of the r1 product-design concern open for legitimate prose-migration buyers, the lane is not ready to merge.

## Validation

- `go test ./internal/router -run 'TestStreamingStructuredOutputRejectEnvelopePassesThrough|TestStructuredOutputProviderErrorsPassThroughWithoutGatewaySettlement|TestContentEncodingSupportedForSpec019'` in `phase5-gateway` passed.
- `swift test --filter ModelRuntimeStructuredOutputTests` in `phase3-binary` passed: 9 tests, 0 failures.

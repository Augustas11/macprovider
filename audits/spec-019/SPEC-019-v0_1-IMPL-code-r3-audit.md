# SPEC-019 v0.1.5 IMPL r3 code-lane audit

Audited HEAD: `70b5c44` on `impl/spec-019-v0-1`.

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/1/0/0

## Closure verified

- r2 code lane: CLOSED / not applicable. The r2 code-lane audit had no C/H/M/m/Q findings to close.
- r1 CODE-H1: CLOSED. `StrictJSONParser.parse(_:)` still enters recursive parsing at depth `1`, rejects `depth > JSONSchemaValidator.maxDepth` before descending, and increments depth only through object values and array elements (`phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:27`, `:52`, `:87`, `:99`, `:108`, `:114`). The boundary tests still cover 32-deep accepted and 33-deep rejected array/object/mixed outputs (`phase3-binary/Tests/macprovider-cliTests/StrictJSONParserDepthTests.swift:5`, `:10`, `:15`).
- r1 CODE-M1: CLOSED. Provider, coordinator, and gateway Content-Encoding normalization still accept omitted / ASCII-whitespace-padded `identity` and reject header-present whitespace-only or NBSP-padded values (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:436`, `phase4-coordinator/internal/buyer/server.go:5336`, `phase5-gateway/internal/router/chat_proxy.go:644`; tests at `phase4-coordinator/internal/buyer/structured_output_validation_test.go:149`).
- r1 CODE-L1: CLOSED. Go rejected-keyword coverage still enumerates the SPEC-019 reject probes including `oneOf`, `anyOf`, `allOf`, `not`, `$ref`, `$defs`, `pattern`, `format`, numeric limits, array limits, uniqueness, and `$schema` (`phase4-coordinator/internal/buyer/structured_output_validation_test.go:79`).
- r1 CODE-L2: CLOSED. Go name-regex parity still covers `person-v1` accepted and dot, non-ASCII, 65-byte, and newline names rejected (`phase4-coordinator/internal/buyer/structured_output_validation_test.go:110`).

## Fresh findings

### MEDIUM CODE-M1: WS provider-detail error envelope type drifts from the HTTP fixture and SPEC-019 terminal envelope

The new WS regression test mirrors the HTTP test's provider selection, no-fallback assertion, request-log `error_code`, status, and `FaultBreakerQualifying` billing checks, but it intentionally diverges on the buyer-visible envelope type.

The HTTP fixture supplies and asserts byte-identical pass-through of a provider body with `type:"upstream_provider_error"` (`phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:23`, `:82`). The new WS test reconstructs the envelope from an end frame and asserts `envelope.Error.Type != "upstream_error"` as failure, meaning the expected type is `upstream_error` (`phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:183`, `:184`). Production follows that test: `writeWSEndError` routes the two SPEC-019 statuses to `writeProviderStructuredOutputError`, which writes `type: spec018ErrorType(code, errorType(status))`; because `spec018ErrorType` does not classify `malformed_json_response` or `json_schema_validation_failed`, the 502 fallback type is used (`phase4-coordinator/internal/buyer/server.go:5078`, `:5087`, `:5100`, `:5145`).

SPEC-019 defines both `malformed_json_response` and `json_schema_validation_failed` terminal envelopes as HTTP 502 with `type:"upstream_provider_error"` (`specs/SPEC-019-structured-output.md:624`, `:630`, `:665`). This does not break the r2 money-path fix: the WS path now sets `FaultFlag: billing.FaultBreakerQualifying` for exactly those two detail codes (`phase4-coordinator/internal/buyer/server.go:2131`, `:2132`), and `recordRow` carries the attempt fault flag into billing (`phase4-coordinator/internal/buyer/server.go:1413`, `:1422`; `phase4-coordinator/internal/buyer/billing_recorder.go:184`, `:197`). It is still a buyer-visible envelope-shape regression, and the new WS test currently locks the drift instead of mirroring the HTTP fixture's SPEC-019 type.

Fix: classify `malformed_json_response` and `json_schema_validation_failed` as `upstream_provider_error` in `spec018ErrorType`, then update the WS regression test to expect `upstream_provider_error`.

## Verdict justification

The r2 FaultFlag absorption is correctly scoped and does not broaden legacy WS statuses. `spec001EndStatus` allows the two SPEC-019 detail codes plus legacy statuses, but the `FaultBreakerQualifying` branch calls the exact two-code predicate `isSpec019ProviderDetailCode` (`phase4-coordinator/internal/buyer/server.go:4937`, `:4946`). The returned `requestLogAttempt` then flows through `logAttempt` into `rec.recordRow` with the fault flag intact (`phase4-coordinator/internal/buyer/server.go:2131`, `:2135`, `:1413`, `:1422`).

The new WS test uses the same Go `testing` / `t.Fatalf` style and the same core fixture pattern as the HTTP test: iterate both SPEC-019 codes, force the selected provider, allow one retry, assert no fallback, assert one request-log row with 502 and the detail code, and assert zero provider credits plus `FaultBreakerQualifying` (`phase4-coordinator/internal/buyer/structured_output_provider_error_test.go:20`, `:74`, `:85`, `:88`, `:98`, `:106`, `:162`, `:191`, `:194`, `:204`). The remaining drift is the envelope `type` called out above.

Verification run:

- `go test ./internal/buyer -run 'TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetry|TestValidateResponseFormatRejectsUnsupportedKeywords|TestValidateResponseFormatNameRegexParity|TestContentEncodingSupportedForSpec019'` in `phase4-coordinator`: pass.
- `go test ./internal/router -run 'TestContentEncodingSupportedForSpec019|TestStructuredOutputProviderErrorsPassThroughWithoutGatewaySettlement'` in `phase5-gateway`: pass.
- `swift test --filter 'StrictJSONParserDepthTests|JSONSchemaValidatorTests|ModelRuntimeStructuredOutputTests|HTTPServerStructuredOutputTests|InferenceRelayStructuredOutputTests'` in `phase3-binary`: 26 tests, 0 failures.

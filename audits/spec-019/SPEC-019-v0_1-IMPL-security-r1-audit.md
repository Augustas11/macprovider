# SPEC-019 v0.1.5 IMPL r1 security audit

Lane: SECURITY
Audited HEAD: `1a6e00f` on `impl/spec-019-v0-1`
Verdict: NOT READY

## Findings

### HIGH SEC-1: Post-inference JSON parsing is recursive and not panic/fatal safe

SPEC-019 requires every post-inference validator failure mode, including recursion overflow / fatal assertions, to become a structured terminal 502 with `inference_ran:true`, `settlement_ran:true`, `FaultBreakerQualifying`, no success receipt, and no provider-positive credits (SPEC-019 AC-26 and §5).

The implementation catches ordinary thrown errors, but the parser and depth checks are recursive over model-controlled output before any iterative depth budget protects the process:

- `StrictJSONParser.parse` materializes all scalars and enters recursive descent (`phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:4-11`).
- `parseValue` recurses into `parseObject` / `parseArray` (`StrictJSONParser.swift:29-38`), and `parseArray` recursively calls `parseValue` for each nested element (`StrictJSONParser.swift:74-86`).
- `JSONSchemaValidator.validateInstance` calls recursive `jsonDepth(instance)` before validating (`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:23-27`, `:206-214`).
- `ModelRuntime.validateStructuredCompletion` only converts thrown `Error` values to `json_schema_validation_failed`; it cannot recover from a Swift stack overflow / `fatalError` / process abort (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:921-937`).
- `HTTPServer` has an `APIError` catch and a generic catch for thrown errors (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:308-369`), but process-aborting failures never reach either catch.

A buyer can request `json_schema` / `json_object` and induce repetitive bracket output. Under the 2 MiB response cap, a deeply nested JSON string can still reach far past the 32-level output limit before a structured `json_schema_validation_failed` is emitted. If recursion overflows, the provider process dies or the connection resets instead of returning the required structured 502 and money-path markers.

Required fix: make output parsing depth-bounded before recursion can overflow, or replace it with an iterative parser. The depth excess path must produce the SPEC-019 terminal error and coordinator `FaultBreakerQualifying` settlement. Add a regression that feeds a deeply nested model-output fixture through `ModelRuntime.complete`, not only `JSONSchemaValidator.validateSchemaShape`.

### HIGH SEC-2: Coordinator HTTP path drops the new SPEC-019 provider error codes before money-path classification

The gateway helper correctly treats `malformed_json_response` and `json_schema_validation_failed` as provider-settled pass-through codes when those codes are visible in the upstream body (`phase5-gateway/internal/router/chat_proxy.go:619-626`; test at `phase5-gateway/internal/router/structured_output_test.go:29-35`). The coordinator HTTP path, however, does not preserve those codes from the provider.

Evidence:

- HTTP provider non-200 handling reads the provider body and sets `attempt.ErrorCode = nullUsageProviderErrorCode(respBody)` (`phase4-coordinator/internal/buyer/server.go:1857-1866`).
- The receipt-bearing / pass-through early return depends on `attempt.ErrorCode != ""` (`server.go:1870-1888`).
- `nullUsageProviderErrorCode` parses `error.code`, but then filters it through `spec001EndStatus` (`server.go:5225-5238`).
- `spec001EndStatus` only allows `error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, and `error_internal`; it omits `malformed_json_response` and `json_schema_validation_failed` (`server.go:4915-4922`).
- On retry exhaustion, HTTP renders a generic `provider_error` and logs the row without a fault flag or the original code (`server.go:1916-1928`). `billingRecorder` defaults an empty fault flag to `FaultNone` (`phase4-coordinator/internal/buyer/billing_recorder.go:181-183`).

Impact: a provider-side structured-output validation failure over the HTTP provider path is not terminally attributed as SPEC-019 requires. It can be retried/fail over as a generic upstream 502, loses the detail code the gateway needs for no-settle pass-through, and misses the explicit `FaultBreakerQualifying` marker required by AC-26. That creates a money-path leak/double-attribution risk: coordinator billing/request-log semantics no longer prove zero provider-positive credits for these failures, and the gateway can see only a generic coordinator `provider_error` body and take its generic `settleBeforeResponse(..., "upstream_error")` branch (`phase5-gateway/internal/router/chat_proxy.go:331-340`).

Required fix: extend the coordinator null-usage / provider-settled classifier for the two SPEC-019 codes, preserve the provider body and receipt headers on terminal pass-through, log the original `ErrorCode`, and mark `FaultBreakerQualifying`. Add an end-to-end coordinator test that stubs an HTTP provider returning each code and asserts no retry/failover, original code passthrough, `FaultBreakerQualifying`, and no gateway `settleBeforeResponse`.

## Security checks passed

- Prompt-injection rendering: `StructuredOutputRenderer` renders `name` and `description` through JSON string encoding and renders the schema via deterministic JSON (`phase3-binary/Sources/macprovider-cli/StructuredOutputRenderer.swift:43-61`, `:111-121`). Schema-embedded descriptions, enum values, const values, and property names remain JSON data. The hostile-description test confirms tool-call sentinel text stays quoted/escaped (`phase3-binary/Tests/macprovider-cliTests/StructuredOutputRendererTests.swift:31-43`).
- NFC/NFD property comparison at provider validation: key matching and string equality use UTF-8 byte arrays, not `String ==`, in `rawKey` and `jsonValueEqualsRaw` (`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:237-245`, `:260-267`). The explicit NFC-vs-NFD test rejects the NFD output key against an NFC schema key (`phase3-binary/Tests/macprovider-cliTests/JSONSchemaValidatorTests.swift:68-80`).
- Name validation ReDoS: no regex engine is used. Swift checks byte count and allowed ASCII bytes directly (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:474-484`); Go does the same byte loop (`phase4-coordinator/internal/buyer/server.go:3792-3804`). This is linear and bounded at 64 bytes.
- Coordinator/provider name parity: both implementations enforce letters, digits, underscore, hyphen, and 1-64 bytes. Provider tests cover 65-byte, non-ASCII, newline/control-ish, punctuation, HTML-ish, and `person-v1` accepted cases (`phase3-binary/Tests/macprovider-cliTests/ChatCompletionRequestTests.swift:82-90`). Coordinator tests cover invalid names but should add the full adversarial matrix for parity confidence (`phase4-coordinator/internal/buyer/structured_output_validation_test.go:36-82`).
- Content-Encoding parity: provider, coordinator, and gateway accept omitted / `identity` case-insensitively with whitespace stripped and reject `identity, gzip` (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:436-448`; `phase4-coordinator/internal/buyer/server.go:5284-5296`; `phase5-gateway/internal/router/chat_proxy.go:628-640`). Tests exist at provider and gateway (`HTTPServerStructuredOutputTests.swift:15-21`; `phase5-gateway/internal/router/structured_output_test.go:5-26`).
- Schema-validator DoS from schema shape is bounded by the 16 KiB schema cap and 32-level schema-depth cap. Swift schema validation has some O(properties * required) byte-scan behavior (`JSONSchemaValidator.swift:98-125`), but the cap keeps the absolute pre-inference workload small. This is not the same as SEC-1, which concerns post-inference output recursion under the much larger response cap.

## Verification

Read-only audit plus artifact write. I did not run the full Swift/Go test suites because the requested deliverable was the security audit file and the findings are static path findings grounded in the cited code.

# SPEC-019 v0.1.5 IMPL r1 product-design audit

Result: **NOT READY** from the product-design lane.

Findings: **1 HIGH, 1 MEDIUM**.

Audited HEAD: `1a6e00f` on `impl/spec-019-v0-1`.

## Findings

### HIGH PD-H1 -- Public gateway remaps streaming structured-output rejects instead of preserving the AC-20 envelope

SPEC-019 AC-20 requires `json_schema` or `json_object` with `stream:true` to return HTTP 400 with code `streaming_json_schema_unsupported` / `streaming_json_object_unsupported`, `type:"invalid_request_error"`, `param:"stream"`, `retryable:false`, `inference_ran:false`, `settlement_ran:false`, and a `stream:false` retry message (`specs/SPEC-019-structured-output.md:267-274`). §7 says the gateway stays pass-through and adds no response-format parser (`specs/SPEC-019-structured-output.md:755-760`), so the coordinator/provider can own the validation.

The coordinator does produce the correct preflight error text and envelope fields: `validateResponseFormatSchema` returns HTTP 400 with the two streaming codes and `stream:false` guidance (`phase4-coordinator/internal/buyer/server.go:3647-3658`), and `writeErrorTypedParam` writes `type`, `param`, `retryable`, `inference_ran:false`, and `settlement_ran:false` (`phase4-coordinator/internal/buyer/server.go:5260-5280`).

But through the public gateway path, those coordinator 400s are not pass-through-classified. The gateway only passes through 404s, Tier2 policy errors, idempotency 409s, and selected null-usage provider errors (`phase5-gateway/internal/router/chat_proxy.go:314-340`, `:619-625`, `:655-675`). `streaming_json_schema_unsupported` and `streaming_json_object_unsupported` are absent. Therefore a public buyer who sends a Cline/Vercel-style streaming structured-output request through the gateway falls into the generic non-OK branch, which calls `settleBeforeResponse` and returns HTTP 502 `api_error/upstream_provider_error` instead of the actionable AC-20 400 envelope.

Product impact: the buyer loses the exact fix instruction (`stream:false`), sees a misleading upstream/provider failure, and the public path contradicts `inference_ran:false` / `settlement_ran:false`. This is release-blocking for the buyer-visible contract.

Fix: add a gateway pass-through/refund classifier for SPEC-019 pre-inference request-validation codes, at minimum `streaming_json_schema_unsupported`, `streaming_json_object_unsupported`, and the other coordinator-owned `json_schema_*` request validation codes. Add a gateway test that posts through `/v1/chat/completions` with `stream:true` + each structured response format and asserts the full AC-20 envelope.

### MEDIUM PD-M1 -- `json_object` breaking-change errors do not tell prose buyers to omit `response_format` or use `{"type":"text"}`

SPEC-019 explicitly calls `json_object` enforcement a breaking change and says buyers relying on best-effort text fallback must migrate to omitted `response_format` or `{"type":"text"}` (`specs/SPEC-019-structured-output.md:110-115`). The implementation enforces the new behavior, but the buyer-visible error copy does not include that migration path:

- Empty structured output says to adjust `temperature` / `seed`, prompt, or schema (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-953`).
- Non-empty malformed JSON says only "Model output was not valid JSON for the requested response_format" (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:955-964`).
- `json_object` scalar output says only that `json_object` requires a top-level object or array (`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:42-54`).

Those messages are technically accurate, but they do not help the exact buyer cohort harmed by the breaking change: callers who used `json_object` as a silent no-op for prose. They will not learn from the SDK exception that prose should use omitted `response_format` or `{"type":"text"}`.

Fix: for `json_object` malformed/root failures, add migration guidance such as: "If you expected prose, omit `response_format` or use `{"type":"text"}`; `json_object` now requires valid top-level JSON object or array." Keep the empty-content `temperature` / `seed` guidance for schema/JSON retries.

## Verified Checks

- **AC-30/AC-31 paired fixtures:** PASS. Both fixtures exist under `test/integration/spec_019/`. The OpenAI fixture documents `class Person(BaseModel): name: str; age: float` and pins `openai==2.44.0` (`test/integration/spec_019/openai_python_strict_json_schema/README.md:1-13`, `requirements.txt:1`). The Vercel fixture documents `z.object({ name: z.string(), age: z.number() })`, pins `@ai-sdk/openai-compatible@2.0.38`, and explains the `$schema` strip normalization (`test/integration/spec_019/vercel_ai_sdk_strict_json_schema/README.md:1-11`, `package.json:1-6`). The committed request schemas are identical `Person { name:string, age:number }` bodies (`fixture_request_body.json` in both dirs, lines 14-29).

- **Buyer-facing error-code sample:** MIXED. Five sampled messages are mostly actionable for schema authors: invalid name gives the regex, non-strict says unsupported in SPEC-019 v0.1.0, too-large gives 16384 bytes, unsupported keyword names the keyword/pointer, and strict object errors name `additionalProperties:false` / required-property constraints. The `json_object` migration message gap is PD-M1.

- **Empty-content message:** PASS. The literal message uses `temperature` / `seed` and does not mention `max_tokens`; it sets `retryable:false`, `inference_ran:true`, and `settlement_ran:true` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-953`). The focused Swift test asserts `malformed_json_response` is not retryable for empty output (`phase3-binary/Tests/macprovider-cliTests/ModelRuntimeStructuredOutputTests.swift:24-32`).

- **Cline negative regression:** PASS by static path. Omitted `response_format` parses as `.text` (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:427-435`), and streaming validation returns for `.text` (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:451-470`). Existing streaming relay coverage includes a `stream:true` request without `response_format` (`phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift:27-33`).

- **Streaming reject envelope shape:** PASS at provider/coordinator, FAIL at public gateway. Provider throws `APIError` with code/param and the shared envelope defaults `type:"invalid_request_error"`, `retryable:false`, `inference_ran:false`, `settlement_ran:false` (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:451-470`; `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:270-347`). Coordinator writes the full envelope as noted in PD-H1. Gateway public-path remapping breaks the buyer-visible shape.

## Verification Run

- `diff -u <(jq -cS '.response_format.json_schema.schema' openai fixture) <(jq -cS '.response_format.json_schema.schema' vercel fixture)` -> no diff.
- `cd phase3-binary && swift test --filter 'HTTPServerStructuredOutputTests|ModelRuntimeStructuredOutputTests|JSONSchemaValidatorTests'` -> 17 tests, 0 failures.
- `cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestValidateChatRequestRejectsStreamingStructuredOutput|TestValidateChatRequestAcceptsJSONSchemaResponseFormat'` -> pass.
- `cd phase5-gateway && go test -count=1 ./internal/router -run 'TestContentEncodingSupportedForSpec019|TestStructuredOutputProviderErrorsPassThroughWithoutGatewaySettlement'` -> pass.

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/2/1/0/0

## Closure verified

- r1 H-1: CLOSED. AC-31 now explicitly requires `createOpenAICompatible({ supportsStructuredOutputs: true, ... })`, says the default emits `json_object`, and asserts outbound `response_format.type == "json_schema"` plus `json_schema.strict == true` (§2 AC-31, lines 344-349). AC-32 separately covers the default `json_object` path (§2 AC-32, lines 351-354).
- r1 H-2: CLOSED. §1 now labels the `json_object` enforcement as a breaking change, explains the prior silent no-op, names the 502 behavior, and gives the migration path to omitted or `{"type":"text"}` (§1, lines 110-115). §10 makes the buyer-facing migration note a release acceptance criterion (§10, lines 712-713).
- r1 H-3: CLOSED. `rg "_in_v0_1" specs/SPEC-019-structured-output.md` returns no matches. §1 says version context belongs in the message, not the code (§1, lines 117-123), and §9 documents the pre-lock rename to versionless codes (§9, lines 662-666).
- r1 M-1: CLOSED. §10 explicitly states v0.1.0 is not a Cline drop-in structured-output release and defers Cline structured-output enablement to v0.2 streaming validation (§10, lines 715-720).
- r1 M-2: CLOSED. AC-20 requires the streaming rejection envelope to include `type:"invalid_request_error"`, `param:"stream"`, `retryable:false`, `inference_ran:false`, `settlement_ran:false`, and a `stream:false` retry recommendation (§2 AC-20, lines 252-257).
- r1 Q-1: CLOSED. The spec deliberately rejects explicit `strict:false` before inference (§1, lines 97-101; §2 AC-4, lines 158-160) and keeps non-strict mode deferred (§10, lines 706-709; §11, lines 734-736).

## Fresh findings

### Finding 1: `json_schema.name` rejects OpenAI-compatible dashed names
- Severity: HIGH
- Location: SPEC §3 (lines 414-418), SPEC §5 error table (line 542), SPEC §7 (line 604)
- Issue: The new name rule claims the OpenAI machine-name convention is `[A-Za-z0-9_]+`, but openai-python 2.44.0's generated OpenAPI types say `name` may contain letters, digits, underscores, and dashes, max length 64. Source check: `/tmp/spec019-openai/unpacked/openai/types/shared/response_format_json_schema.py:16-20` and `/tmp/spec019-openai/unpacked/openai/types/responses/response_format_text_json_schema_config_param.py:18-22`. The pinned openai-python Pydantic auto path uses `response_format.__name__`, so it does not appear to emit dotted module namespaces by default (`/tmp/spec019-openai/unpacked/openai/lib/_parsing/_completions.py:272-286`), and Vercel defaults to `name: "response"` (`/tmp/spec019-ai-sdk-pack/package/src/chat/openai-compatible-chat-language-model.ts:205-211`). But a buyer who sends an otherwise valid OpenAI request with `json_schema.name: "person-v1"` would be rejected by macprovider with HTTP 400. That is a drop-in compatibility break in a buyer-visible field.
- Recommendation: Change the allowed name contract to the OpenAI-compatible shape, for example `^[A-Za-z0-9_-]{1,64}$`, and make it normative instead of "Recommended constraint". Add fixtures for `person-v1` accepted, 65-byte rejected, Unicode rejected, and an openai-python manual `response_format` request using a dashed name.

### Finding 2: SDK fixture parity is still under-specified across Pydantic and Zod
- Severity: HIGH
- Location: SPEC §2 AC-15 (lines 222-225), SPEC §2 AC-30/AC-31 (lines 336-349), SPEC §10 (lines 719-720)
- Issue: AC-30 defines an openai-python Pydantic `Person { name: str, age: int }` fixture with a parsed model and golden OpenAI comparison, while AC-31 only proves the Vercel path sets `supportsStructuredOutputs:true` and emits `json_schema.strict == true`. It does not require the Vercel fixture to use the same `Person` Zod shape, commit its outbound `response_format` body, parse the same returned object, or compare the Pydantic-derived schema against the Zod-derived schema. That leaves the product claim "structured output for non-streaming SDK consumers (openai-python, Vercel AI SDK non-stream)" vulnerable to a false green: one SDK can pass while the other serializes a materially different schema shape. The SDK source reinforces the gap: openai-python mutates Pydantic schemas into strict mode, adding `additionalProperties:false` and making every property required (`/tmp/spec019-openai/unpacked/openai/lib/_pydantic.py:49-58`), while `@ai-sdk/openai-compatible` forwards whatever `responseFormat.schema` it receives (`/tmp/spec019-ai-sdk-pack/package/src/chat/openai-compatible-chat-language-model.ts:201-211`).
- Recommendation: Make AC-30/AC-31 a paired parity fixture. Both SDK fixtures should use the same logical `Person` contract, commit the captured outbound request bodies, assert successful parsing into each SDK's native object, and compare canonicalized `response_format.json_schema.schema` with an explicit allow-list for acceptable deltas such as `title` or `description`. If byte-equivalence is required, say so; if semantic equivalence is sufficient, define the canonical normalization.

### Finding 3: Empty-content failures are retryable, causing deterministic buyer loops
- Severity: MEDIUM
- Location: SPEC §2 AC-18 (lines 240-243), SPEC §5 (lines 506-527), SPEC §5 error table (line 545)
- Issue: v0.1.1 correctly stops returning 200 for empty structured output, but it classifies the empty string as `malformed_json_response` with `retryable:true`. §5 also says buyers must key retry logic off `error.code` and that no internal retry exists. For a deterministic local model that emits zero tokens for the same prompt/schema after stop-token filtering, a buyer SDK can burn its whole retry budget on identical 502s with no actionable signal that changing the prompt, schema, or max tokens is required.
- Recommendation: Split empty structured output into a distinct code such as `empty_structured_output` / `empty_completion` with `retryable:false`, or keep the shared code but require `retryable:false` and an actionable message for the empty-content subcase. Add an AC proving deterministic empty output does not invite automatic same-request retries.

## Verdict justification

The product-design r1 findings are closed, including the Vercel structured-output path, `json_object` migration note, versionless codes, Cline boundary, streaming reject envelope, and strict-false posture. The SPEC is not ready to lock because v0.1.1 still rejects an OpenAI-compatible `json_schema.name` shape, does not prove the promised openai-python Pydantic and Vercel Zod fixture parity, and marks deterministic empty completions as retryable.

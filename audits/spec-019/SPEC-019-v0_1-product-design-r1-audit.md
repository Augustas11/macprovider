**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/3/2/0/1

## Findings

### Finding 1: Vercel AI SDK AC can pass without exercising `json_schema`
- Severity: HIGH
- Location: SPEC §2 AC-16 (line 192), SPEC §10 (lines 463-466)
- Issue: AC-16 says `@ai-sdk/openai-compatible@2.0.38` with a Zod schema must return a parsed object, but that does not prove SPEC-019 `json_schema` compatibility. In the pinned package, `supportsStructuredOutputs` defaults to `false`, and the chat model emits `response_format: {type:"json_object"}` for schema output unless `supportsStructuredOutputs === true`; only then does it send `type:"json_schema"` with `strict: strictJsonSchema`. The same package defaults `strictJsonSchema` to `true`, so `strict:false` is not the default-path risk; the risk is that the regression can greenlight the wrong wire mode.
- Recommendation: Split AC-16 into two fixtures: default `createOpenAICompatible(...)` Zod output proves `json_object` compatibility, and an explicit `createOpenAICompatible({ supportsStructuredOutputs: true, ... })` fixture captures the outbound request body and proves `response_format.type == "json_schema"`, `json_schema.strict == true`, and parsed-object behavior.

### Finding 2: `json_object` enforcement is a breaking buyer-visible change but is not labeled as one
- Severity: HIGH
- Location: SPEC §1 (lines 57-59), SPEC §2 AC-7 (lines 139-142), SPEC §2 AC-9 (lines 149-154)
- Issue: Existing buyers who already send `response_format: {"type":"json_object"}` currently receive unconstrained text because the field is parsed but not enforced. AC-7 intentionally changes that behavior, and AC-9 turns malformed model output into HTTP 502 `malformed_json_response`. That is a correct enforcement fix, but it is still a breaking behavior change for any buyer who has been using `json_object` as an ignored hint or who relies on best-effort text fallback.
- Recommendation: Add an explicit "breaking change" note to §1 and a release/doc acceptance criterion requiring buyer-facing migration text: `json_object` now enforces parseable top-level object-or-array JSON; malformed output is a retryable provider-output 502; use omitted/text `response_format` for prose fallback.

### Finding 3: Versioned error codes are frozen into the wire contract
- Severity: HIGH
- Location: SPEC §1 (lines 94-99), SPEC §2 AC-11 (lines 162-165), SPEC §2 AC-22 (lines 226-228), SPEC §9 (lines 440-441)
- Issue: `streaming_json_schema_unsupported_in_v0_1`, `streaming_json_object_unsupported_in_v0_1`, and `json_schema_non_strict_unsupported_in_v0_1` bake a draft version into buyer-facing `error.code`, while §9 says existing codes MUST NOT be renamed or repurposed. If v0.2 later supports streaming, the stable code table will retain obsolete version-specific names forever, and buyers may key compatibility logic on `v0_1` rather than capability semantics.
- Recommendation: Rename before lock to versionless capability codes such as `streaming_json_schema_unsupported`, `streaming_json_object_unsupported`, and `json_schema_non_strict_unsupported`. Put "unsupported in SPEC-019 v0.1.0" in `error.message` or documentation, not in `error.code`.

### Finding 4: Cline compatibility is referenced but not proven by this slice
- Severity: MEDIUM
- Location: SPEC §10 (lines 463-466), SPEC-018 §10d.4 (lines 836-840)
- Issue: SPEC-018's Cline drop-in product story is streaming-first. Current Cline source builds OpenAI-compatible providers with `createOpenAICompatible(...)` and sends the live request path through `streamText(...)`; a source grep found no active `response_format`, `json_schema`, `generateObject`, or `streamObject` usage beyond an OpenRouter metadata type listing `response_format`. Therefore SPEC-019 v0.1.0 does not currently unlock a Cline structured-output use case, and if Cline later did send structured output on its existing streaming path, AC-11 would reject it before inference.
- Recommendation: State explicitly that v0.1.0 is not a Cline drop-in structured-output release. Keep Cline as a v0.2 streaming validation target, and add a negative regression that normal Cline-style `streamText` tool traffic without `response_format` is unaffected by SPEC-019.

### Finding 5: Streaming rejection is defensible scope, but the UX contract is under-specified
- Severity: MEDIUM
- Location: SPEC §1 (lines 94-99), SPEC §2 AC-11 (lines 162-165), SPEC §8 (lines 429-433)
- Issue: Rejecting streaming in v0.1.0 is a reasonable scope boundary, but the buyer experience is only specified as HTTP 400 plus code. AI SDK and agent clients commonly run streaming paths by default; a bare unsupported error will look like provider incompatibility unless the envelope tells the buyer how to recover. The spec also does not state `param`, `retryable`, or an actionable message for these pre-inference failures.
- Recommendation: Add explicit envelope requirements for streaming rejections: `type:"invalid_request_error"`, `param:"stream"` or `param:"response_format"`, `retryable:false`, `inference_ran:false`, `settlement_ran:false`, and a message that says to retry with `stream:false` or omit structured output until streaming structured output is promoted.

### Finding 6: Confirm explicit `strict:false` opt-out posture
- Severity: Q
- Location: SPEC §1 (lines 82-86), SPEC §2 AC-22 (lines 226-228), SPEC §11 (lines 489-491)
- Issue: Primary-source checks did not find a default `strict:false` problem for the pinned SDK paths: openai-python 2.44.0's `type_to_response_format_param(...)` emits `"strict": True`, and `@ai-sdk/openai-compatible@2.0.38` defaults `strictJsonSchema` to `true` when structured outputs are enabled. The remaining product question is explicit buyer opt-out: Vercel documents `strictJsonSchema:false` as an escape hatch for schemas strict mode rejects, and SPEC-019 turns that escape hatch into HTTP 400.
- Recommendation: Decide before lock whether explicit `strict:false` should remain a hard incompatibility, or whether v0.1.0 should accept it as "unsupported capability requested" with a clearer capability error and migration note. Do not block lock on SDK defaults; block only if the product wants opt-out interoperability.

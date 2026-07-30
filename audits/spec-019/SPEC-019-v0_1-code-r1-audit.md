**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/2/0/0

## Findings

### Finding 1: SDK regression ACs do not define executable fixtures
- Severity: HIGH
- Location: SPEC §2 AC-15/AC-16 (lines 186-193)
- Issue: AC-15 and AC-16 require OpenAI SDK and Vercel AI SDK regressions to match a "canonical fixture", but the SPEC never defines the fixture prompt, schema, expected parsed object, model-independent value constraints, or test file/harness that owns those assertions. An implementer can satisfy the words with incompatible fixtures, and an auditor cannot independently decide pass/fail from the SPEC body.
- Recommendation: Define concrete fixture artifacts for both ACs: request body, schema, prompt, expected parsed object shape/values, SDK versions, target test files, and whether the OpenAI `gpt-4o-2024-08-06` run is a checked-in golden fixture or a live comparison.

### Finding 2: Root validation pointer is not RFC 6901
- Severity: MEDIUM
- Location: SPEC §5 (lines 344-349) and SPEC §2 AC-10 (lines 156-160)
- Issue: The SPEC says the envelope MUST include an RFC 6901 JSON pointer, but then states that root failure uses `"/"`. Under RFC 6901, the empty string `""` identifies the whole document; `"/"` identifies an object member whose key is the empty string. This will produce incorrect or non-portable tests for root-level failures such as scalar-vs-object mismatch.
- Recommendation: Use `""` for root failures when claiming RFC 6901 compliance, or explicitly define `"/"` as a macprovider pseudo-path and stop calling that field a pure RFC 6901 pointer.

### Finding 3: Structured-output rendering call sequence is under-specified
- Severity: MEDIUM
- Location: SPEC §4 (lines 288-294), SPEC §5 (lines 323-336), and SPEC §2 AC-13/AC-14 (lines 173-184)
- Issue: The SPEC cites the three current `ToolPromptRenderer.renderMessages` hook sites and says the schema instruction must be in the system position, but it does not prescribe the composition order with the existing tool renderer. The implementation could inject the schema instruction before `ToolPromptRenderer.renderMessages`, after it, or in a wrapper that rewrites `ChatMessage` before MLX `UserInput` creation; those choices can differ when requests contain both multi-turn tool history and `response_format: json_schema`.
- Recommendation: Specify the exact call sequence at each `ModelRuntime.swift` hook, for example "build structured-output-adjusted `ChatMessage` values first, then pass them to `ToolPromptRenderer.renderMessages`, then create `UserInput` with unchanged `tools`", and require mixed `tools + json_schema + prior tool history` fixtures.

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/0/2/1/0

## Closure verified

- r1 H-1: CLOSED. v0.1.1 moved the SDK regression fixture contract into concrete fixture ACs: AC-30 names `test/integration/spec_019/openai_python_strict_json_schema/`, request body, `Person { name: str, age: int }` strict schema, expected `pydantic` model, `openai==2.44.0`, `test_strict_parity.py`, and a committed OpenAI golden fixture; AC-31 names `test/integration/spec_019/vercel_ai_sdk_strict_json_schema/` and requires `supportsStructuredOutputs: true`; AC-32 covers the Vercel default `json_object` path (SPEC §2, lines 336-354).
- r1 M-1: CLOSED. Root-level RFC 6901 failures now use the empty string `""` instead of `"/"` (SPEC §5, lines 519-524). Grep found no `"/"` root-pointer wording in §5, AC-9/AC-10, or the error-code table.
- r1 M-2: PARTIAL. v0.1.1 cites the three live hook sites correctly (`ModelRuntime.swift:400`, `:454`, `:540`), and those lines all construct `UserInput(chat: try ToolPromptRenderer.renderMessages(request.messages, modelID: request.model), tools: ...)`. However §4 now contains two incompatible normative orders: prose says render multi-turn tools first and then prepend the schema instruction, while the numbered sequence says build schema-adjusted `ChatMessage` values first and then pass them to `ToolPromptRenderer.renderMessages` (SPEC §4, lines 452-465).

## Fresh findings

### Finding 1: Composite render order still has two normative sequences
- Severity: MEDIUM
- Location: SPEC §4 (lines 452-465); `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`, `:454`, `:540`
- Issue: The closure text for the hook-site ambiguity contradicts itself. Lines 452-456 require the implementation to first render multi-turn tool history and then prepend the structured-output schema instruction. Lines 461-464 require the implementation to first build schema-adjusted `ChatMessage` values, then call `ToolPromptRenderer.renderMessages`. The current hook sites make the latter implementable directly, but the prose points implementers toward the opposite ordering.
- Recommendation: Pick one order and delete the conflicting wording. If the intended implementation is schema-adjusted `ChatMessage` values followed by `ToolPromptRenderer.renderMessages`, rewrite lines 452-456 to match the numbered sequence and require the composite fixture to assert the exact final system-message order.

### Finding 2: `json_schema_invalid_name` is in the table but has no AC coverage
- Severity: MEDIUM
- Location: SPEC §3 (lines 414-418), SPEC §5 error-codes table (line 542), SPEC §2 AC-1 through AC-34 (lines 144-365)
- Issue: §3 defines invalid `json_schema.name` as HTTP 400 `json_schema_invalid_name`, and §5 lists that code in the table. No AC asserts that an invalid name is rejected with that code. AC-33 covers prompt-injection rendering for hostile `json_schema.name`, but it does not assert the machine-name parser/validator rejection path or the provider/coordinator parity for the code.
- Recommendation: Add an AC for names outside the 64-character `[A-Za-z0-9_]+` constraint returning HTTP 400 `json_schema_invalid_name`, `param:"response_format.json_schema.name"`, `inference_ran:false`, at both provider parser and coordinator boundary.

### Finding 3: Two gateway file:line citations do not match their labels
- Severity: minor
- Location: SPEC §7 (lines 617-634)
- Issue: Grep verification found that `phase5-gateway/internal/router/chat_proxy.go:997-1008` is `parseChatRequest`, not a body-preserving request helper. The body-preserving evidence is already at `chat_proxy.go:102-117` and `chat_proxy.go:217-224`, where the inbound `body` is read and then reused via `bytes.NewReader(body)`. Also, `chat_proxy.go:601-607` is the `isNullUsageProviderError` allow-list predicate, not the receipt-eligible pass-through helper; the helper is at `chat_proxy.go:593-599`.
- Recommendation: Either relabel `:601-607` as the current provider-error allow-list predicate and cite `:593-599` for the helper, or replace the stale labels with the exact function names. Remove or correct the `:997-1008` citation unless `parseChatRequest` is the intended evidence.

## Verdict justification

I grep-verified every `file:line` and `file:line-line` citation in v0.1.1 against the current `ffce39d` worktree. Most citations resolve and match their claim, including the request parser, prompt canonicalizer, model runtime hook sites, SPEC-001/SPEC-006/SPEC-015/SPEC-018 anchors, billing paths, and coordinator allow-list. The exceptions are the two gateway label mismatches above.

§5's error-code table is mostly self-consistent: every AC-used code appears in the table, and the AC HTTP statuses match the table's 400/413/502 classifications. The only table-to-AC gap is `json_schema_invalid_name`, which is normative in §3 and listed in §5 but not asserted by any AC. Because the render-order closure is still contradictory and the error table has an AC coverage gap, the code lane cannot mark v0.1.1 ready to lock.

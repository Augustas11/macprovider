**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/3/1/1

## Findings

### Finding 1: StrictJSONParser.swift has no module-level rationale comment
- Severity: HIGH
- Location: `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift:1-3` (current HEAD `1a6e00f`)
- Issue: A net-new 241-line strict JSON parser lands in `MacProviderCore` with zero documentation. The file opens with `import Foundation` then jumps straight to `public enum StrictJSONParser`. There is no module-level doc comment explaining (a) why this exists rather than `JSONSerialization`, (b) what "strict" means here (duplicate-key rejection is observable from `ParseError.duplicateKey` at line 19 and the `object[key] == nil` check at line 62, but is not stated as the rationale), (c) which SPEC-019 ACs drive the parser's strictness (AC-9 NFC/NFD, AC-14 duplicate keys, JCS canonicalization for AC-25 prompt-hash), and (d) whether the same parser is invoked on both schema-validation input and model output, which matters for semantic consistency. A PR reviewer encountering this file in the diff has to reverse-engineer the contract from call sites in `JSONSchemaValidator.swift`. This is the single largest narrative gap in the IMPL.
- Recommendation: Add a 10–20 line doc comment header to `StrictJSONParser.swift` covering: (1) Why strict (SPEC-019 v0.1.5 §X requires duplicate-key rejection, no trailing data, raw UTF-8 key comparison without NFC normalization); (2) Why not `JSONSerialization` (it silently accepts duplicate keys and may normalize); (3) The error taxonomy (one line per `ParseError` case); (4) Call-site inventory (used by `JSONSchemaValidator`, `ModelRuntime` post-hoc validation, `PromptCanonicalizer`); (5) A pointer back to SPEC-019 v0.1.5 §1, §4, §5.

### Finding 2: `vercel_ai_sdk_strict_json_schema/README.md` omits the `supportsStructuredOutputs:true` requirement
- Severity: MEDIUM
- Location: `test/integration/spec_019/vercel_ai_sdk_strict_json_schema/README.md`
- Issue: The audit prompt's narrative lens flagged this explicitly: "does it explain the `$schema` strip step and why Vercel needs the `supportsStructuredOutputs:true` setting?" The README explains the `$schema` strip (line 5: "v0.1.0 strips that key in the fixture normalization step because SPEC-019 v0.1.5 rejects `$schema`") but says nothing about `supportsStructuredOutputs:true`. A reviewer reproducing this fixture against a fresh Vercel AI SDK install will hit either silent text fallback or a different request shape, and won't know why. Also: "v0.1.0 strips that key" is ambiguous — what is `v0.1.0`? The fixture-normalization tool? SPEC-019 was never v0.1.0. This reads like a copy-paste residue.
- Recommendation: Add a sentence: "The Vercel AI SDK only emits the JSON-schema request shape when the model adapter exposes `supportsStructuredOutputs: true`; the captured `fixture_request_body.json` was produced with that flag set." Replace "v0.1.0 strips that key" with the actual mechanism (e.g., "the fixture loader strips `$schema` before submission") or name the tool/step.

### Finding 3: Provider commit message lacks AC references that coordinator/gateway commits include
- Severity: MEDIUM
- Location: commit `7b2a272 Support SPEC-019 structured output at provider boundary`
- Issue: The 3-commit chain is otherwise coherent (provider → coordinator → gateway, each named for the boundary it covers), but the provider commit is the only one that does not cite specific AC numbers. Coordinator cites AC-26/AC-28a. Gateway cites AC-27/AC-28a. Provider says only "json_schema parsing, schema prompt rendering before tool rendering, post-hoc validation, and no locked spec edits" — readable, but a reviewer cross-walking commits against the AC matrix has to do the mapping themselves for the largest of the three diffs (~1300 LOC of provider-side change including the new `JSONSchemaValidator`, `StrictJSONParser`, `StructuredOutputRenderer`). Given this is the boundary that introduces the most new files, it's also the one that most needs AC anchors in the commit message.
- Recommendation: Either amend the commit message before push (acceptable since the branch is not yet pushed) or note in the PR description which provider-side ACs each new file satisfies: `StrictJSONParser` → AC-9/AC-14, `JSONSchemaValidator` → AC-1..AC-14 subset, `StructuredOutputRenderer` → AC-15/AC-16/AC-19, `ModelRuntime` post-hoc → AC-20..AC-24, `HTTPServer` gate → AC-27.

### Finding 4: `StructuredOutputRenderer.swift` has no module-level comment
- Severity: MEDIUM
- Location: `phase3-binary/Sources/macprovider-cli/StructuredOutputRenderer.swift:1-4`
- Issue: This file is normative for SPEC-019 §4 (schema-instruction rendering, model-family detection, ordering vs `ToolPromptRenderer`). The file opens with `import Foundation / import MacProviderCore / enum StructuredOutputRenderer`. There is no comment explaining (a) that this renderer MUST run before tool prompt rendering per SPEC-019 §4, (b) why model-family detection branches exist (Qwen3 vs Llama-3.3 vs generic — the SPEC pins specific instruction wording per family), (c) the stateless-ness contract that other lanes will be checking. The implementation is reasonably self-explanatory at the function level, but a reviewer reading the diff cold has to consult SPEC-019 to understand why the rendering order matters and why family branching is normative rather than incidental.
- Recommendation: Add a short doc-comment header pointing to SPEC-019 §4 and listing the load-bearing contracts (ordering before tool prompts, family-specific instruction wording, statelessness).

### Finding 5: `openai_python_strict_json_schema/README.md` does not state what the fixture proves
- Severity: minor
- Location: `test/integration/spec_019/openai_python_strict_json_schema/README.md`
- Issue: The README names "AC-30 openai-python strict json_schema fixture", pins the SDK version, and shows the Pydantic model. But it doesn't state in one line what passing this fixture demonstrates (e.g., "Proves the provider accepts a request body produced by `openai==2.44.0` `client.beta.chat.completions.parse(...)` with a `response_format` derived from a Pydantic `BaseModel`, validates the schema subset, and returns a body that re-parses as the same model"). Compare to `nfc_nfd_adversarial/README.md` which clearly states the expected outcome ("must compare raw decoded key strings without Unicode normalization and reject the output as `json_schema_validation_failed` at `/café`"). The Vercel and OpenAI READMEs lack that closing sentence.
- Recommendation: Add a one-sentence "Expected outcome:" line to both SDK-compatibility fixtures stating what the test asserts.

### Finding Q1: Is `StrictJSONParser` invoked on model output, schema-validation input, or both?
- Severity: Q
- Location: `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift` + call sites
- Issue: Not a defect — a question for the implementer that, if answered in code via a module-doc-comment call-site inventory, resolves Finding 1's strongest sub-point. The critic lane raised the same question from a correctness angle ("are the semantics consistent across both?"); from the narrative angle, the answer should appear in the file's own documentation rather than requiring a grep.
- Recommendation: When fixing Finding 1, explicitly enumerate the call sites in the doc comment.

## Summary

The IMPL commit chain is coherent and the test-file naming is consistent and self-describing (all `*StructuredOutput*Tests.swift` and `structured_output_*_test.go` clearly map to the SPEC-019 surface). Two of three fixture READMEs are usable; the Vercel one has a specific gap the audit prompt called out. The dominant narrative gap is the unannotated 241-line `StrictJSONParser.swift` — a reviewer can infer "strict means duplicate-key rejection" from line 62 but cannot infer the SPEC rationale, the call-site coverage, or the canonicalization story without leaving the file. Fix Finding 1 and Finding 2 to clear the HIGH/MEDIUM gates; Findings 3/4/5 are merge-blocking only because the bar is "0 MEDIUM across all 6 lanes" but each is a one-paragraph or one-sentence edit.

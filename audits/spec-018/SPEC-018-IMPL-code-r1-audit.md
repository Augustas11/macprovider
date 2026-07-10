# AUDIT SPEC-018 IMPL — Code Lane

You are auditing the implementation diff for SPEC-018 v0.1.5, not editing code.

Scope:
- Base: `origin/main`
- Head: current branch `impl/spec-018-tool-calling`
- Normative source: `specs/SPEC-018-agentic-tool-calling.md` v0.1.5

Review target:
1. Swift parser changes in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`.
2. Swift parser tests in `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift`.
3. Coordinator commit-signal validator in `phase4-coordinator/internal/buyer/server.go`.
4. Coordinator internal tests in `phase4-coordinator/internal/buyer/server_internal_test.go`.
5. AC-20 docs and AC-23 version-pin files.

Code questions:
- Is every changed line traceable to SPEC-018 §3.2, §3.4, §8.4, AC-19, AC-20, AC-21, AC-23, or AC-24?
- Are edge cases covered: empty modelID, whitespace modelID, mixed-case modelID, Qwen3, sentinel-without-modelID, `[{}]`, non-object arguments, depth > 32, byte length > 256 KiB, depth boundary behavior, and multi-byte/unicode strings?
- Does the Swift JSON pre-scan correctly reject duplicate keys while enforcing depth/byte caps before expensive parsing?
- Does the Go validator reject malformed `delta.tool_calls[]` without regressing content/role/refusal/reasoning/function_call/usage commit signals?
- Does the AC-24 test actually catch array reordering, ID rewriting, field dropping, and value mutation?

Output format:
- Findings first, ordered by severity.
- Severity buckets: CRITICAL, HIGH, MEDIUM, MINOR, QUESTIONS.
- Every finding must cite concrete files and lines.
- End with a verdict: `READY TO MERGE` only if CRITICAL=0, HIGH=0, MEDIUM=0; otherwise `FIX REQUIRED`.

## Final prompt

# AUDIT SPEC-018 IMPL — Code Lane

You are auditing the implementation diff for SPEC-018 v0.1.5, not editing code.

Scope:
- Base: `origin/main`
- Head: current branch `impl/spec-018-tool-calling`
- Normative source: `specs/SPEC-018-agentic-tool-calling.md` v0.1.5

Review target:
1. Swift parser changes in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`.
2. Swift parser tests in `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift`.
3. Coordinator commit-signal validator in `phase4-coordinator/internal/buyer/server.go`.
4. Coordinator internal tests in `phase4-coordinator/internal/buyer/server_internal_test.go`.
5. AC-20 docs and AC-23 version-pin files.

Code questions:
- Is every changed line traceable to SPEC-018 §3.2, §3.4, §8.4, AC-19, AC-20, AC-21, AC-23, or AC-24?
- Are edge cases covered: empty modelID, whitespace modelID, mixed-case modelID, Qwen3, sentinel-without-modelID, `[{}]`, non-object arguments, depth > 32, byte length > 256 KiB, depth boundary behavior, and multi-byte/unicode strings?
- Does the Swift JSON pre-scan correctly reject duplicate keys while enforcing depth/byte caps before expensive parsing?
- Does the Go validator reject malformed `delta.tool_calls[]` without regressing content/role/refusal/reasoning/function_call/usage commit signals?
- Does the AC-24 test actually catch array reordering, ID rewriting, field dropping, and value mutation?

Output format:
- Findings first, ordered by severity.
- Severity buckets: CRITICAL, HIGH, MEDIUM, MINOR, QUESTIONS.
- Every finding must cite concrete files and lines.
- End with a verdict: `READY TO MERGE` only if CRITICAL=0, HIGH=0, MEDIUM=0; otherwise `FIX REQUIRED`.


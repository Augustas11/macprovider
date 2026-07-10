# AUDIT SPEC-018 IMPL — Product-Design Lane

You are auditing the implementation diff for SPEC-018 v0.1.5, not editing code.

Scope:
- Base: `origin/main`
- Head: current branch `impl/spec-018-tool-calling`
- Normative source: `specs/SPEC-018-agentic-tool-calling.md` v0.1.5

Product-design focus:
1. AC-20 buyer-side validation obligation in:
   - `README.md`
   - `examples/tool_calling_demo.py`
   - `test/integration/tool_calling/README.md`
   - `test/integration/tool_calling/openai_tool_call_e2e.py`
2. Buyer mental model for first-turn-only SPEC-018 v0.1.5 tool-call support.
3. Consistency with the SPEC's exclusions and limitations: no provider-side tool execution, no full multi-turn agent-loop certification, no semantic validation of buyer intent.

Product questions:
- Does the required phrase appear verbatim in all four required files?
- Will a buyer using the README, demo, or E2E runner understand that emitted `tool_calls[]` are parsed model output, not provider-verified intent?
- Does any copy overclaim full Ring-1/multi-turn support or imply provider-side validation/execution?
- Does the docs change read naturally where it appears, or should placement/wording improve without weakening the required phrase?

Output format:
- Findings first, ordered by severity.
- Severity buckets: CRITICAL, HIGH, MEDIUM, MINOR, QUESTIONS.
- Every finding must cite concrete files and lines.
- End with a verdict: `READY TO MERGE` only if CRITICAL=0, HIGH=0, MEDIUM=0; otherwise `FIX REQUIRED`.

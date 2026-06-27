# AUDIT SPEC-018 IMPL — Security Lane

You are auditing the implementation diff for SPEC-018 v0.1.5, not editing code.

Scope:
- Base: `origin/main`
- Head: current branch `impl/spec-018-tool-calling`
- Normative source: `specs/SPEC-018-agentic-tool-calling.md` v0.1.5

Security focus:
1. §3.2 parser trigger hardening: modelID match required; sentinels alone are plain content.
2. §3.4 parser-side duplicate-key and DoS-bound validation.
3. §8.4 coordinator commit-worthy validator: minimal OpenAI tool-call shape, object-string arguments, depth <= 32, bytes <= 256 KiB.
4. Billing boundary: commit-worthy gates settlement; malformed deltas must not settle provider-positive usage.
5. AC-24 request-side pass-through test must catch silent field drops before provider dispatch.

Security questions:
- Does the §8.4 validator close malformed-precommit settlement abuse for `[{}]`, `arguments:"[]"`, deep nesting, and oversized arguments?
- Are unknown fields still allowed where SPEC-018 §10c forward compatibility requires them?
- Are there bypasses through negative/non-integer `index`, missing/empty `id`, non-`function` type, empty `function.name`, missing `function.arguments`, trailing JSON, or multiple top-level JSON values?
- Does the parser change reduce sentinel-trigger injection without creating a new modelID spoofing claim beyond SPEC-018 v0.1 limitations?
- Does any doc/example imply MacProvider validates tool intent or executes buyer tools?

Output format:
- Findings first, ordered by severity.
- Severity buckets: CRITICAL, HIGH, MEDIUM, MINOR, QUESTIONS.
- Every finding must cite concrete files and lines.
- End with a verdict: `READY TO MERGE` only if CRITICAL=0, HIGH=0, MEDIUM=0; otherwise `FIX REQUIRED`.

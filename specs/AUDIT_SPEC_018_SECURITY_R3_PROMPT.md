# SPEC-018 v0.1.2 — SECURITY-lane round-3 audit (lock confirmation)

You are the **security** lane of a round-3 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.2. This is a lock confirmation round — your r2 verdict was READY TO LOCK; r3 verifies the v0.1.2 polish does not regress anything.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round-2 security findings: `specs/SPEC-018-security-r2-audit.md` (m-1, m-2, Q-1 all marked absorbed in v0.1.2)

## Round-3 lane scope

1. **Verify r2 absorption.**
   - **m-1** (`function.arguments` JSON-object): §8.4 + AC-21 now require `function.arguments` to be "a JSON string whose decoded value is a JSON object." Verify the wording closes the `"arguments": "[]"` residual.
   - **m-2** (§5 stale text): §5 disambiguated — `function.arguments` cap is §10a #7 v0.2-gating; `max_tool_calls` is §10b future. Adequate?
   - **Q-1** (v0.2 unknown-hash fail-closed): §10a #2 now explicitly says "v0.2 MUST require unknown-or-unregistered `model_hash` to fail closed for tool-call synthesis (NOT fall back to modelID substring matching), unless an explicit operator override is logged and buyer-visible." Adequate normative constraint for v0.2 design?
2. **Verify the §3.1 row collapse does not introduce a new security surface.** The Qwen2.5-Coder, Qwen3, and Qwen3-Coder variants now share one family row + one detection predicate. Does this:
   - Lower the bar for a malicious provider advertising a generic `qwen3` modelID while serving a different model? (Answer: not relative to v0.1.1 — same modelID-trust model, mitigated by v0.2 §10a #2.)
   - Allow a body-grammar bypass? The row's "JSON body parsing tried first; on failure, falls back to Python-style" means a Qwen model emitting a Python-style call still parses. Is the same duplicate-key validator applied in both branches?
3. **Net residual threat model for v0.1.2.** Re-state in 2-4 sentences. Same as r2 unless v0.1.2 changes it.

## Output format

Tight.

```
## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r2-absorption verification

## Findings (if any)

## Net residual threat model for v0.1.2

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

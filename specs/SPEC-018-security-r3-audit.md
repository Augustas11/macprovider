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

## Final prompt

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

## Raw output

```text
## Counts
CRITICAL: 0
HIGH: 0
MEDIUM: 0
MINOR: 0
QUESTIONS: 0

## r2-absorption verification
m-1: Absorbed. §8.4 and AC-21 now require `function.arguments` to be a JSON string whose decoded value is a JSON object, and explicitly reject `{"function":{"arguments":"[]"}}`. The prior `"arguments": "[]"` residual is closed.

m-2: Absorbed. §5 now clearly separates `function.arguments` byte caps as §10a #7 v0.2-gating with fail-closed semantics, while `max_tool_calls` remains §10b future work.

Q-1: Absorbed. §10a #2 now requires unknown-or-unregistered `model_hash` to fail closed for tool-call synthesis, with no modelID-substring fallback unless an explicit logged, buyer-visible operator override exists. Adequate v0.2 normative constraint.

§3.1 row collapse: No new security finding. The generic `qwen3` modelID trust issue is not worse than v0.1.1’s modelID-trust model and is explicitly carried as a v0.1 limitation, with §10a #2 closing it in v0.2. The JSON and Python-style body paths both reject ambiguity: JSON duplicate keys via the duplicate-key validator, Python-style duplicate keywords via keyword rejection; fallback does not create a duplicate-key bypass.

## Findings (if any)
None.

## Net residual threat model for v0.1.2
v0.1.2 remains a first-turn wire-shape certificate, not a full Ring-1 agent security boundary. The main residual buyer-facing risk is a legitimate modelID-matched or malicious provider producing a hostile but syntactically valid tool call; macprovider transports it, and buyer-side policy/schema validation remains the execution boundary. Full closure still depends on v0.2 model-hash grammar binding, prompt-echo guard, structured malformed-tool-call signaling, and argument size caps.

## Verdict
READY TO LOCK


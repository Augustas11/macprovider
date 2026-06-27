# SPEC-018 v0.1.1 — SECURITY-lane round-2 audit

You are the **security** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 security findings: `specs/SPEC-018-security-r1-audit.md`
- Round-1 absorbed: C-1, H-1, M-1, M-2, M-3, m-1, m-2, Q-1, Q-2 all marked absorbed in the round narrative.

## Round-2 lane scope

1. **Verify r1 absorption fidelity (security-lane lens).**
   - **r1 C-1** (Q6 prompt-injection): v0.1 path chosen is (a)+(b) — §3.2 makes modelID-match-required normative; §1 buyer-side validation obligation; §10a #2 model-hash → family registry; §10a #3 prompt-echo guard. Is this actually a sufficient v0.1 mitigation, or does (a)+(b) leave a usable attack window (e.g. a tool-call-capable-modelID-matched legitimate provider's model can still echo hostile content)? If the residual window is non-trivial, flag it explicitly — even though v0.2 (c)+prompt-echo-guard closes it, v0.1 may need a §1 callout that strongly warns users.
   - **r1 H-1** (commit-on-malformed-delta): §8.4 + AC-21 add the minimal-shape validator. Verify the validator's shape requirements (integer `index`, non-empty `id`, `type=="function"`, non-empty `function.name`, parseable `function.arguments`) are sufficient to reject the `{"choices":[{"delta":{"tool_calls":[{}]}}]}` exploit. Are there shape variations that still pass the validator and commit-billing settle?
   - **r1 M-1** (arguments size cap): rolled into §10a #7. Verify §10a #7 is genuinely a v0.2 gating item, not a "we'll get to it" — does the SPEC commit to fail-closed semantics?
   - **r1 M-2** (ID namespace + entropy): partially addressed (§2.1 now says ≥122 bits entropy; full `(provider_id, request_id, choice_index)` scope moved to §10b future). Is "partial absorption" the right v0.1 stance, or is the residual a v0.1 risk?
   - **r1 M-3** (silent fallback observability): rolled into §10a #5 (structured `malformed_tool_call` signal). v0.1 stays silent. Acceptable for a "wire-shape certificate" framing?
   - **r1 m-1** (mixed-sentinel suppression): §3.6 + AC-22. Verify the rule actually prevents both bypass directions (Qwen sentinel suppresses Llama, Llama suppresses Qwen).
   - **r1 m-2** (string arguments validation-only): §2.3 now says "Validation-only — not re-canonicalized; SDKs MUST JSON-parse and schema-validate before execution." Is the wording strong enough?
   - **r1 Q-1** (model-hash binding): committed to §10a #2. Verify the v0.2 commitment is concrete enough that an implementer in 2026-Q3 can act on it.

2. **New content security lens.**
   - §3.2 makes modelID-match-required. Threat: provider lies about modelID. Does the SPEC have any provider-side modelID verification, or is this client-trust-the-provider? If the latter, document the residual threat (mitigated by §10a #2 model-hash binding in v0.2).
   - §8.4 commit-worthy validation: is there a downgrade attack where a provider sends a *valid* tool_call delta that turns out to be semantically nonsense (e.g. valid shape but `function.name = "../../../etc/passwd"`)? Tool-name injection vs argument-string injection. §1 buyer-side validation obligation absorbs this; should the SPEC explicitly name function-name injection as a buyer-side concern?
   - §10a items individually: any of the v0.2 commitments themselves introduce a new attack surface that should be flagged at design time?

3. **Net residual threat model for v0.1.1.** Summarize: with all v0.1.1 mitigations active, what's the maximum-realistic attack a buyer pointing Cline at macprovider could face? Are users adequately warned?

## Output format

```
# SPEC-018 v0.1.1 — Security-lane round-2 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- Threat model:
- SPEC location:
- Code location (if relevant):
- Exploit sketch:
- Severity rationale:
- Recommended fix:

## Net residual threat model for v0.1.1
[2-4 sentences naming the worst realistic v0.1.1 attack]

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in security lane.

## Final prompt

# SPEC-018 v0.1.1 — SECURITY-lane round-2 audit

You are the **security** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 security findings: `specs/SPEC-018-security-r1-audit.md`
- Round-1 absorbed: C-1, H-1, M-1, M-2, M-3, m-1, m-2, Q-1, Q-2 all marked absorbed in the round narrative.

## Round-2 lane scope

1. **Verify r1 absorption fidelity (security-lane lens).**
   - **r1 C-1** (Q6 prompt-injection): v0.1 path chosen is (a)+(b) — §3.2 makes modelID-match-required normative; §1 buyer-side validation obligation; §10a #2 model-hash → family registry; §10a #3 prompt-echo guard. Is this actually a sufficient v0.1 mitigation, or does (a)+(b) leave a usable attack window (e.g. a tool-call-capable-modelID-matched legitimate provider's model can still echo hostile content)? If the residual window is non-trivial, flag it explicitly — even though v0.2 (c)+prompt-echo-guard closes it, v0.1 may need a §1 callout that strongly warns users.
   - **r1 H-1** (commit-on-malformed-delta): §8.4 + AC-21 add the minimal-shape validator. Verify the validator's shape requirements (integer `index`, non-empty `id`, `type=="function"`, non-empty `function.name`, parseable `function.arguments`) are sufficient to reject the `{"choices":[{"delta":{"tool_calls":[{}]}}]}` exploit. Are there shape variations that still pass the validator and commit-billing settle?
   - **r1 M-1** (arguments size cap): rolled into §10a #7. Verify §10a #7 is genuinely a v0.2 gating item, not a "we'll get to it" — does the SPEC commit to fail-closed semantics?
   - **r1 M-2** (ID namespace + entropy): partially addressed (§2.1 now says ≥122 bits entropy; full `(provider_id, request_id, choice_index)` scope moved to §10b future). Is "partial absorption" the right v0.1 stance, or is the residual a v0.1 risk?
   - **r1 M-3** (silent fallback observability): rolled into §10a #5 (structured `malformed_tool_call` signal). v0.1 stays silent. Acceptable for a "wire-shape certificate" framing?
   - **r1 m-1** (mixed-sentinel suppression): §3.6 + AC-22. Verify the rule actually prevents both bypass directions (Qwen sentinel suppresses Llama, Llama suppresses Qwen).
   - **r1 m-2** (string arguments validation-only): §2.3 now says "Validation-only — not re-canonicalized; SDKs MUST JSON-parse and schema-validate before execution." Is the wording strong enough?
   - **r1 Q-1** (model-hash binding): committed to §10a #2. Verify the v0.2 commitment is concrete enough that an implementer in 2026-Q3 can act on it.

2. **New content security lens.**
   - §3.2 makes modelID-match-required. Threat: provider lies about modelID. Does the SPEC have any provider-side modelID verification, or is this client-trust-the-provider? If the latter, document the residual threat (mitigated by §10a #2 model-hash binding in v0.2).
   - §8.4 commit-worthy validation: is there a downgrade attack where a provider sends a *valid* tool_call delta that turns out to be semantically nonsense (e.g. valid shape but `function.name = "../../../etc/passwd"`)? Tool-name injection vs argument-string injection. §1 buyer-side validation obligation absorbs this; should the SPEC explicitly name function-name injection as a buyer-side concern?
   - §10a items individually: any of the v0.2 commitments themselves introduce a new attack surface that should be flagged at design time?

3. **Net residual threat model for v0.1.1.** Summarize: with all v0.1.1 mitigations active, what's the maximum-realistic attack a buyer pointing Cline at macprovider could face? Are users adequately warned?

## Output format

```
# SPEC-018 v0.1.1 — Security-lane round-2 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- Threat model:
- SPEC location:
- Code location (if relevant):
- Exploit sketch:
- Severity rationale:
- Recommended fix:

## Net residual threat model for v0.1.1
[2-4 sentences naming the worst realistic v0.1.1 attack]

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in security lane.

## Raw output

```text
# SPEC-018 v0.1.1 — Security-lane round-2 audit

## Counts
CRITICAL: 0
HIGH: 0
MEDIUM: 0
MINOR: 2
QUESTIONS: 1

## r1-absorption verification
C-1: CONFIRMED. v0.1.1 closes content-sentinel-only synthesis via §3.2/AC-19 and adds buyer-side validation via §1/AC-20. Residual prompt-echo by a legitimate tool-call-capable model remains, but §1.1 explicitly warns users and §10a #2/#3 gates the v0.2 fix.

H-1: CONFIRMED with MINOR residual. §8.4/AC-21 rejects the `[{}]` commit exploit. The remaining wording gap is that `function.arguments` only has to be parseable JSON, not specifically a JSON-object string.

M-1: CONFIRMED with MINOR cleanup. §10a #7 is v0.2-gating and says fail-closed, but §5 still says the arguments cap is a §10b future candidate.

M-2: CONFIRMED. ≥122-bit UUID entropy is enough for v0.1 first-turn scope. Full `(provider_id, request_id, choice_index)` scoping can remain future because v0.1 rejects second-turn tool messages.

M-3: CONFIRMED. Silent fallback is acceptable for the narrowed wire-shape certificate because §1.1 names it and §10a #5 makes structured `malformed_tool_call` v0.2-gating.

m-1: CONFIRMED. §3.6/AC-22 blocks both bypass directions by making any mixed-family sentinel output fall back to plain content.

m-2: CONFIRMED. §2.3 wording is strong enough: validation-only, no re-canonicalization, SDKs MUST parse and schema-validate before execution.

Q-1: CONFIRMED with QUESTION. §10a #2 is concrete enough to implement a model-hash family registry, but v0.2 design must answer unknown-hash behavior as fail-closed/no tool-call synthesis.

## Findings

### H-1 — Commit-worthy validator should require JSON-object `arguments`, not merely parseable JSON
- Threat model: malicious or buggy direct-streaming provider sends a syntactically shaped `delta.tool_calls[]` that commits billing but is still non-compliant with SPEC-018’s provider wire contract.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:273-281`, `:341`; compare §2.3 at `:83-95`.
- Code location (if relevant): coordinator commit-signal path cited by SPEC at `phase4-coordinator/internal/buyer/server.go:2482-2605`.
- Exploit sketch: `{"index":0,"id":"call_x","type":"function","function":{"name":"foo","arguments":"[]"}}` appears to pass “parseable JSON string” even though §2.3 requires a JSON object string.
- Severity rationale: MINOR. The original `[{}]` commit exploit is closed, and buyer-side validation should reject bad arguments before tool execution. This is a spec precision issue for provider-positive settlement.
- Recommended fix: Change §8.4/AC-21 to require `function.arguments` to be a string whose decoded value is a JSON object.

### M-1 — Stale §5 text contradicts v0.2-gating argument size cap
- Threat model: implementers treat parser DoS caps as non-committed future work instead of a required v0.2 release gate.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:211` conflicts with `:347-357` and `:395`.
- Code location (if relevant): not relevant; spec consistency.
- Exploit sketch: A v0.2 implementer follows §5’s “§10b reserves” wording and ships Ring-1 without fail-closed per-call/per-response `function.arguments` byte caps.
- Severity rationale: MINOR. §10a #7 is explicit and fail-closed, so the normative intent is clear, but the stale §5 sentence undermines absorption fidelity.
- Recommended fix: Update §5 to say v0.1 has no cap, while §10a #7 makes `function.arguments` caps v0.2-gating; leave only `max_tool_calls` in §10b if that is intended.

### Q-1 — v0.2 model-hash registry needs fail-closed unknown-hash behavior
- Threat model: provider advertises a tool-call-capable modelID while serving a different or unregistered model; grammar selection proceeds without a trusted model-family binding.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:40`, `:352`, `:391`.
- Code location (if relevant): not relevant for v0.1.1.
- Exploit sketch: If v0.2 treats unknown `model_hash` as “fall back to modelID substring,” it reopens the provider-lies-about-modelID path.
- Severity rationale: QUESTION. This does not block v0.1.1 because v0.1 explicitly documents modelID-level trust, but v0.2 must decide this before implementation.
- Recommended fix: In the v0.2 SPEC, require unknown or unregistered `model_hash` to fail closed for tool-call synthesis unless an explicit operator override is logged and buyer-visible.

## Net residual threat model for v0.1.1
With v0.1.1 mitigations active, the worst realistic buyer-facing attack is a prompt-echo or malicious-model tool call from a legitimate tool-call-capable, modelID-matched provider, causing a buyer agent to consider a hostile but declared local tool invocation. macprovider does not execute the tool; the buyer-side agent’s policy/schema validation is the execution boundary. Users are adequately warned for a first-turn wire-shape certificate, but this is not safe to market as a full Ring-1 agent product until §10a #2/#3/#5/#7 land.

## Verdict
READY TO LOCK


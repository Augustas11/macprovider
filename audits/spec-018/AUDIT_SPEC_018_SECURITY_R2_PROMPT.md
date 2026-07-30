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

# SPEC-018 v0.1.2 — Claude critic (adversarial verifier) blind-spot pass

You are the **adversarial verifier** lane. You exist because codex's four-lane audit (architect / code / security / product-design) converged in 3 rounds and returned READY TO LOCK on v0.1.2, but codex consistently misses certain classes of issues. Your job is to refute every codex absorption and find what they missed.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round-1 narrative: `specs/SPEC-018-r1-audit.md`
- Round-2 narrative: `specs/SPEC-018-r2-audit.md`
- Round-3 narrative: `specs/SPEC-018-r3-audit.md`
- Per-lane round files: `specs/SPEC-018-{architect,code,security,product-design}-r{1,2,3}-audit.md`

## What codex four-lane converged on

- All 4 lanes returned READY TO LOCK against v0.1.2 in r3
- 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 4 lanes
- Only residual: Architect m-1 (move JSON-first/Python-style precedence from §3.1 table cell to §3.3) — deferrable polish

## Your adversarial lens

Codex blind spots, ordered by what to hunt for first:

### CRITIC-1. Cross-section consistency at distance
Codex's architect lane checks adjacent sections; it does not reliably catch contradictions between distant sections. v0.1.2 is 428 lines. Read it top to bottom and find any place where §1 and §10 contradict, §3 and §8 contradict, §5 and §9 contradict, or where a §11 open question implicitly conflicts with a §9 AC. Examples of what to look for:
- An AC that asserts behavior the corresponding §2-§8 section doesn't normatively pin
- A §10a v0.2 commitment that retroactively reads as "v0.1.2 is doing this wrong"
- A §12 non-goal that contradicts a §10a or §10b reservation
- A definition in §1 that's used differently in §6 or §10

### CRITIC-2. Adversarial refutation of every normative claim
For each MUST / MUST NOT / SHOULD in v0.1.2 (search for these tokens), ask:
- Is the claim actually true of the as-built (for ratification claims)?
- Is the claim implementable (for IMPL-delta claims)?
- Is there an easy reading of the claim that lets a bad actor or a confused implementer do the wrong thing while technically complying?
- If the claim is "compositional" (e.g. "MUST validate X AND Y AND Z"), is there an order-of-evaluation issue?

Focus especially on:
- §3.2 (modelID-match-required) — how does it interact with §3.7 (adding a family)?
- §3.6 (mixed-sentinel fallback) — what if a model output contains the Qwen open sentinel `<tool_call>` but NO close sentinel, plus a Llama sentinel? Is "mixed" defined precisely?
- §8.4 (commit-worthy validator) — what about race conditions between provider sending a partial valid delta and the validator's evaluation point?
- §10c (additive invariant) — what about removing fields (vs adding)? Is field removal forbidden?
- AC-21 — "JSON string whose decoded value is a JSON object" — what about JSON with depth > some implementation limit?

### CRITIC-3. Resolved-but-not-really
For every "RESOLVED in v0.1.x" or "absorbed" or "closed by" claim, ask: did v0.1.2 actually resolve it, or did it just relabel the problem?
- §11 Q6 marked RESOLVED — is the resolution complete, or does the v0.2 prompt-echo guard commitment leave v0.1.2 users vulnerable in a way the SPEC doesn't acknowledge?
- §1.1 #4 "no model-hash-bound grammar selection" — is this honestly communicated as a risk, or is it documented as a feature gap?
- §10a #2 "v0.2 MUST require unknown-or-unregistered model_hash to fail closed" — is "fail closed for tool-call synthesis" precise enough, or could a v0.2 implementer fail-closed to "no tool calls" but still leak the request?

### CRITIC-4. Cardinality and edge cases in ACs
For each AC-1 through AC-23, imagine the most adversarial test input:
- AC-3 multi-call ordering — what about 0 tool calls? 100 tool calls? Tool calls split across SSE event boundaries (in v0.2 token-incremental)?
- AC-4 `id` collision — what's the probability calculation? Are we within UUID collision risk for normal traffic?
- AC-5 duplicate keys — does it cover nested ambiguity (e.g. `{"a": {"a": 1, "a": 2}}` where the duplicate is at depth-1)?
- AC-9 streaming concatenation byte-for-byte — what about UTF-8 BOMs, zero-width spaces, escaped sequences that have multiple valid encodings?
- AC-16b framework-level smoke — what does "passes" mean precisely? First tool call recognized? Or a full request/response cycle? Pin it.
- AC-22 mixed-sentinel — what if a Qwen sentinel appears in a `function.arguments` JSON string (i.e. valid model output where Qwen markup is itself data the model wants to discuss)?

### CRITIC-5. Honest scope assessment
v0.1.2 calls itself a "first-turn OpenAI tool-call wire-shape compatibility certificate." Is that label honest, or does it still overclaim?
- AC-16a tests the OpenAI Python SDK 1.x parsing. Does the AC also assert that *every* OpenAI-shape framework parses identically? Or only one?
- §1 names Cline, Cursor, Aider, Claude Code, Continue, Zed, OpenCode, Vercel AI SDK, LangChain, LlamaIndex, Pydantic-AI, n8n. Are these all genuinely OpenAI-wire-compatible, or do some have framework-specific extensions that v0.1.2 doesn't certify?
- "compatibility certificate" — if I'm a buyer and I read this, do I conclude "my framework will work" or "my framework will parse one response"? Is the distinction crisp?

### CRITIC-6. What v0.1.2 commits future versions to
v0.1.2 contains forward commitments: §10a #2 says "v0.2 MUST require unknown-or-unregistered model_hash to fail closed." §10c says "v0.2 and beyond MUST preserve v0.1.2 non-streaming response shape." Are these the right commitments to make in v0.1.2? Could they tie a future SPEC-018 v0.2 author's hands inappropriately?

## What you are NOT auditing (out of lane)

You are NOT a fifth codex lane. Don't reverify file:line citations or code drift — code lane did that. Don't restate Ring-1 framing concerns — PD lane did that. Find what THEY missed, not what they covered.

## Output format

```
# SPEC-018 v0.1.2 — Critic blind-spot pass

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- Codex blind-spot category: [CRITIC-1..6]
- SPEC location:
- The claim:
- The refutation / edge case / cross-section conflict:
- Severity rationale:
- Recommended fix:

## Codex-coverage critique
[1-2 paragraph honest assessment: which codex lanes covered their lens well, where were the gaps, and what does this audit add that codex couldn't.]

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay adversarial; default to refuted.

# AUDIT_SPEC_018_v0_2 — Claude Critic Blind-Spot Pass

## Task

You are a Claude critic running an adversarial-verifier blind-spot audit on `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 AFTER codex 4-lane converged 0/0/0 across 3 rounds.

Your job: **find what codex's four lanes missed**. The v0.1.5 precedent for this exact audit step found 3 lock-blocking HIGH issues (AC-23 tautology, Claude Code overclaim, mixed-sentinel DoS) that codex's architect+code+security+product-design lanes ALL missed across 4 rounds. Replicate that level of skepticism on v0.2.2.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.2 SPEC body. Codex says READY TO LOCK.
2. `specs/SPEC-018-v0_2-{architect,code,security,product-design}-r3-audit.md` — codex's r3 verdicts (all 0/0/0 READY TO LOCK).
3. `specs/SPEC-018-v0_2-r1-audit.md`, `specs/SPEC-018-v0_2-r2-audit.md` — round narratives.
4. `specs/SPEC-018-v0_2-design-synthesis.md` — original design source.
5. v0.1.5 precedent: `specs/SPEC-018-critic-blindspot-audit.md` — your prior critic pass on v0.1; the kinds of issues it found.

## Your adversarial lens

Codex is good at lane-specific correctness. Codex is bad at:
- **Tautological ACs** — an AC that can't fail because of how it's written (v0.1.5 AC-23 was a tautology codex missed for 4 rounds).
- **Mechanical-but-unimplementable ACs** — an AC that LOOKS testable but the test would prove nothing.
- **Cross-section consistency** — codex audits sections independently; contradictions ACROSS sections survive.
- **Claims-vs-reality** — codex audits internal consistency, not whether real frameworks/tools behave as the SPEC assumes.
- **Threat-model holes** — codex's security lane finds known attack patterns; new attack patterns hidden in v0.2 additions slip through.
- **Locked-content drift** — codex avoids touching v0.1.5; if v0.2 additions break v0.1.5 invariants in subtle ways, codex doesn't catch it.

Be aggressive. Try to refute every load-bearing v0.2 claim.

## Specific things to attack

1. **AC-46 `usage.macprovider_model_hash_observed`** — does this field actually do useful security work, or is it security theater? If buyers don't act on it (and §10d.0.1 says they MUST NOT in v0.2), what's the actual mitigation? Is this a v0.2 deliverable or a v0.3 dependency disguised as a v0.2 deliverable?
2. **AC-25a CI fixture** — can a Cline session actually be deterministically recorded? Cline's UI involves LLM responses (non-deterministic). Pinning Cline version + repo + prompt doesn't pin the model output. How does AC-25a actually pass deterministically?
3. **AC-44 1500ms p95** — is this measured against the same provider+model+hardware on every CI run? CI runs on shared infrastructure with variable load. Is the p95 statistically meaningful with the sample size the AC implies?
4. **AC-47/AC-48** — the §8.4.2 / §8.4.3 split rests on "buyer-visible commit" before settlement. Codex called this elegant. **Is it actually safe in adversarial cases?** What if openai-python v2.44.0's behavior on the terminal SSE error frame is different from what the SPEC assumes? What if Cline doesn't surface the exception (e.g., Cline catches all errors and shows generic "API failure")? The negative AC-48 says "no dispatchable tool_calls reach framework's tool-execution boundary" — but Cline is open-source; can we actually verify this against current Cline code?
5. **Minimal prompt-echo guard (§3.9)** — "complete native sentinel+body+close sequence appears VERBATIM" — what if Qwen3 emits `<tool_call>` with ASCII variations (full-width Unicode that looks identical)? What if the request contains a UTF-8 BOM that disappears after JSON parse but appears in the model's seen-context? The byte-match semantics need adversarial probing.
6. **Path B precedent** — v0.2.1 set the precedent that locked invariants CAN be amended via change-log entry. Is this safe? Future SPEC versions might exploit this precedent to silently move requirements around. The v0.2.1 narrative says "explicit named amendment with rationale" — is that strong enough? Or did we just open a door we can't close?
7. **§10d.4 streaming kill switch** — the operator can force buffered-to-end behavior. Per-provider auto-downgrade can trigger on "malformed stream history." What's the auto-downgrade attack surface? Could a malicious buyer trigger downgrades against a competitor's provider by submitting requests likely to produce malformed streams?
8. **Aggregate caps** — 4 MiB body / 1 MiB tool content / 2 MiB args / 256 messages / 128 tool calls. Are these caps interrelated correctly? Can a buyer construct a request that passes every individual cap but exceeds a reasonable total resource budget? (E.g., 256 messages each with 4 KiB content + 128 tool calls each near per-call cap = ~256 MiB of decoded prompt material.)
9. **Cline reality check** — go look at actual Cline source code if possible (https://github.com/cline/cline). Does Cline:
   - Send `messages[]` arrays larger than 256 entries in long sessions?
   - Send aggregate tool-result content > 1 MiB after multiple `read_file` calls?
   - Tolerate the terminal SSE error frame as a non-success?
   - Reach `t_first_gateway_byte` within 1500ms in realistic local-model usage?
   - Use OpenAI-wire correctly per v2.44.0 baseline?
   Any mismatch between SPEC assumption and Cline reality = HIGH.

## Output format

Write findings to `specs/SPEC-018-v0_2-critic-blindspot-audit.md`:

```markdown
# SPEC-018 v0.2.2 — Critic Blind-Spot Audit

**Date:** 2026-06-27
**Reviewer:** Claude critic blind-spot pass
**Verdict:** {READY TO LOCK | FIX REQUIRED}

## Tally: C/H/M/m/Q

## CRITICAL findings
## HIGH findings
## MEDIUM findings
## Minor findings
## Open questions

## Codex blind-spots verified
(state which of the 9 "specific things to attack" above are clean vs problematic)

## Verdict justification
```

## Severity bar

Same as r1 (CRITICAL/HIGH/MEDIUM/minor/Q). HIGH = something a Cline integrator could be blindsided by; security-relevant pattern codex missed.

Goal: find AT LEAST one HIGH if anything is wrong. If genuinely nothing's wrong, return 0/0/0 + explain why each of the 9 attack vectors is clean. (Codex returning 0/0/0 across 4 lanes is RARE for a v0.X.Y SPEC of this scope.)

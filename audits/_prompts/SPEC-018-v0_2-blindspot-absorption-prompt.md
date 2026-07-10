# SPEC-018 v0.2.3 — Blind-Spot Absorption Prompt

## Your task

Absorb 11 Claude blind-spot findings (4 HIGH + 7 MEDIUM + 5 minor + 3 Q) into `specs/SPEC-018-agentic-tool-calling.md`, bumping the SPEC to v0.2.3.

**Two LOAD-BEARING changes:**
1. Path (a) §3.9 minimal prompt-echo guard deletion + §10c second-amendment narrative.
2. §10c.1 lock-amendment discipline rule (converging Critic M-4 + Narrative M-2 finding).

Everything else is mechanical.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — current v0.2.2 SPEC.
2. `specs/SPEC-018-v0_2-blindspot-audit.md` — blind-spot narrative.
3. `specs/SPEC-018-v0_2-critic-blindspot-audit.md` — critic findings.
4. `specs/SPEC-018-v0_2-product-narrative-blindspot-audit.md` — narrative analyst findings.
5. Cline `main@92806c60` SDK reference: `sdk/packages/llms/src/providers/vendors/openai-compatible.ts` uses `@ai-sdk/openai-compatible` (Vercel AI SDK), NOT openai-python.

## Path (a) decision recorded

User chose **Path (a)** for Critic H-2: drop the v0.2 minimal prompt-echo guard entirely. Document as residual risk in §10c amendment style. v0.3 delivers full guard.

Rationale: minimal guard creates self-DoS (Cline `read_file` on SPEC-018.md suppresses legitimate follow-up tool calls because SPEC-018 contains `<tool_call>` examples) worse than the attack it closes. Same honesty pattern as model-hash registry Path B in v0.2.1.

## 11 absorptions

### LOAD-BEARING edits

**1. §3.9 deletion + §10c second amendment (Path (a) for Critic H-2).**

- DELETE §3.9 (minimal prompt-echo guard) entirely from the SPEC.
- DELETE AC-49 (Cline-shaped echo guard test).
- Add to §10c amendment list as **Amendment 2**: "v0.2.3 amends §3.9 (v0.2.1-introduced minimal prompt-echo guard) — DELETED. v0.2.3 ships WITHOUT prompt-echo mitigation. Residual risk: a same-family model may emit a tool call whose markup appears verbatim in untrusted prompt content (e.g., `role:"tool"` content from a `read_file` of a file containing native tool-call markup). v0.3 delivers the full guard with whitespace normalization, tool-description scope coverage, Cline-shaped false-positive testing, and proven absence of self-DoS via SPEC-018-self-reading case. Rationale: the v0.2 minimal guard (deleted) had three exploitable defects (whitespace bypass on single newline, scope-incomplete around tools[]/function.parameters/function.arguments, self-DoS on legitimate Cline `read_file` of SPEC-018.md). Shipping the minimal guard was strictly worse than not shipping a guard. Path (a) precedent: when a defense feature is found to be net-negative under realistic conditions, delete it and document residual risk explicitly."
- Update v0.2.3 change-log entry to lead with this amendment.

**2. §10c.1 lock-amendment discipline rule (Critic M-4 + Narrative M-2 convergent).**

Promote the lock-amendment discipline rule from v0.2.1 change-log prose to a named §10c.1 section. Concrete content:

```
### 10c.1 Lock-amendment discipline

SPEC-018 v0.2 introduces and exercises a lock-amendment precedent: a previously LOCKED normative claim (introduced as MUST in a prior SPEC version) CAN be amended in a later version IF AND ONLY IF the change-log entry for that later version:

(a) Names the specific clause being amended (cite the original version + section).
(b) States the strategic rationale (why the amendment is needed; what scope or product decision drove it).
(c) Names the replacement mitigation OR explicitly documents the residual risk.
(d) Carries the amendment label "AMENDED v<X.Y.Z>" in the original clause's location (preserved as historical text + amendment paragraph).

Silent scope cuts of locked invariants are NON-COMPLIANT. Future SPEC-018 versions invoking this precedent MUST satisfy (a)-(d) AND enumerate the amendment in this section's amendment log.

Amendment log:
- Amendment 1 (v0.2.1): §10c v0.1.3-locked model-hash registry requirement → deferred to v0.3. Rationale: narrow v0.2 scope makes registry curation strategically premature. Mitigation: AC-46 model-hash observation channel + §8.4.2 final-close tightening.
- Amendment 2 (v0.2.3): §3.9 v0.2.1-introduced minimal prompt-echo guard → DELETED. Rationale: minimal guard had three exploitable defects making it net-negative vs. no guard (whitespace bypass; scope incomplete; self-DoS via Cline reading SPEC-018.md). Residual risk: same-family echo attack remains unmitigated in v0.2. Mitigation: deferred to v0.3 full guard.

Future SPEC-018 v0.X.Y versions exercising this precedent MUST add an enumerated entry here.
```

### MECHANICAL edits

**3. Critic H-1: split openai-python vs Cline ACs.**

Update AC-39: "OpenAI-wire SDK ecosystem (openai-python v2.44.0+, openai-node) may surface the terminal SSE error frame as an exception or failed stream. AC-39 verifies this for the openai-python ecosystem."

Update AC-43: keep openai-python-baseline as forward-compat regression for the broad SDK ecosystem (no change to the AC itself).

Split AC-48 into:
- **AC-48a (openai-python ecosystem)**: post-final-close-error stream + openai-python v2.44.0 reader → no assistant message with dispatchable tool_calls reaches accumulator. Generic SDK-side gate.
- **AC-48b (Cline integration)**: post-final-close-error stream + Cline VS Code extension v4.0.0 using `@ai-sdk/openai-compatible` (Vercel AI SDK) → no dispatchable tool_calls reach Cline's `AgentRuntime`. Cline-specific gate. Cite live Cline import path `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`.

This closes the H-1 mutually-exclusive-stack issue while keeping the broad-ecosystem regression gate intact.

**4. Critic H-3: bound auto-downgrade per-buyer.**

Update §10d.4 auto-downgrade language:
- Add attribution: downgrade is per-(buyer, provider) tuple, NOT per-provider for all buyers.
- Threshold: 3 malformed streams from same buyer to same provider within 5-minute window → downgrade for THAT buyer's future requests to THAT provider only.
- Recovery: downgrade lifts after 10 minutes of no further malformed streams from same buyer.
- AC-45 extended: new sub-fixture AC-45c — adversarial buyer cannot trigger downgrade for OTHER buyers sticky-routed to same provider.

**5. Critic M-1: bound AC-44 clock skew.**

Update AC-44: timing measurements use NTP-anchored clock skew assumption `|t_provider - t_gateway| ≤ 100 ms` at request start (verified via heartbeat). p95 ≤ 1500 ms on M4 and ≤ 3000 ms on M2/M3 is measured **with skew correction** (i.e., `t_first_gateway_byte - t_tool_call_open_detected - clock_skew_offset` where `clock_skew_offset` is measured at request start).

Add note: NTP sync precondition is the SPEC-006 buyer-API requirement; v0.2 inherits it.

**6. Critic M-2: total decoded prompt cap.**

Add to §10d.1 aggregate caps: total decoded prompt content cap = 6 MiB (sum of `messages[].content` decoded UTF-8 + assistant-history `tool_calls[].function.arguments` decoded UTF-8 + `role:"tool".content` decoded UTF-8). Failure: HTTP 413 `prompt_aggregate_too_large`.

Add to §10d.0 stable code table: `prompt_aggregate_too_large` — retryable: false.

Add AC-56: prompt aggregate > 6 MiB rejected with HTTP 413.

**7. Critic M-3: AC-46 reframe as provider self-test.**

Update AC-46 normative text:
- Buyer-visible behavior: every v0.2 response includes `usage.macprovider_model_hash_observed`, JSON type `null | "^[a-f0-9]{64}$"`. Buyer-side verification is field-present + type-correct only.
- Provider self-test: when the provider's own `model_hash` subsystem reports a known hash, the field MUST be that hex value. When unknown, the field MUST be `null`. This is a provider-side log/release-gate assertion.
- AC-46 fixture coverage explicit: (a) buyer-side type assertion (every v0.2 response has field present, type null or hex); (b) provider-side self-test asserting the known/unknown branch matches the provider's local hash subsystem state.

**8. Narrative H-1: Quick orientation block.**

Insert immediately after Status line (line ~5), before the Change log heading:

```
## Quick orientation

SPEC-018 is the **provider-side response synthesis contract** for OpenAI-wire tool-call compatibility. It tells provider Macs how to translate native LLM tool-call markup (Qwen3/Llama-3.3 family sentinels) into the OpenAI `tool_calls[]` JSON shape that buyer-side SDKs and agentic-coding frameworks expect.

- **v0.1.5 LOCKED** (`9e6f089` 2026-06-27): first-turn OpenAI tool-call wire-shape certificate. 9 OpenAI-wire frameworks listed as expected-compatible.
- **v0.2 SHIPS NOW**: Cline drop-in works. Anchor framework = Cline (https://github.com/cline/cline, ~1M+ VS Code marketplace installs). 4 deliverables: multi-turn provider acceptance, token-incremental streaming, `tool_call_id` validation, raised byte cap (1 MiB per-call / 2 MiB per-response).
- **v0.3 DEFERRED**: model-hash → family registry (curation governance), full prompt-echo guard (whitespace-normalized + tool-scope-complete + self-DoS-tested), structured `usage.macprovider_malformed_tool_call` signal, framework-compatibility matrix beyond Cline.

**Lock-amendment precedent**: v0.2 deliberately amends 2 locked v0.1.x invariants via explicit named change-log entries with rationale (see §10c.1). v0.2 ships narrow + honest, not silently scope-cut.

**Money-path**: all v0.2 changes preserve v0.1.5 settlement protection (`FaultBreakerQualifying` + zero credits on malformed streams via `billing_recorder.go:176` + `formula.go:112`).
```

**9. Narrative M-1: v0.2.3 buyer-visible deltas lead with lock-candidate role.**

v0.2.3 change-log entry MUST lead the buyer-visible bullet list with: "v0.2.3 is the codex-converged + Claude-blind-spot-absorbed lock candidate." Then enumerate edits.

**10. Narrative M-3: §10a reader note.**

Add 1-line reader-note at §10a heading: "**Reader note**: §10a is locked v0.1.5 historical content. For v0.2.0+ active scope and the lock-amendment status of items listed here, see §10d.0 reader note + §10c.1 amendment log."

**11. Critic m-1, m-2, m-3 + Narrative m-1, m-2 + Q-1 (polish).**

- Critic m-1: add §10c.1 sentence "AC numbers are stable across SPEC-018 versions; once an AC is assigned a number, that number is never reused or renumbered, even if the AC content is amended."
- Critic m-2: add to §10d.1 a note that `messages[]` > 256 returns HTTP 400 (user-actionable; Cline can split long sessions).
- Critic m-3: subsumed by M-1 absorption.
- Narrative m-1: with §3.9 deletion, §3.8 stands alone as v0.2-additive before locked §3.7. The existing §3.8 doc-order note stays accurate.
- Narrative m-2: covered by Critic m-1.
- Narrative Q-1: update Status line to remove "pending round-3 four-lane audit" → "Draft — codex 4-lane r3 0/0/0; Claude blind-spot pass absorbed in v0.2.3; pending r4 confirmation."
- Critic Q-1: add to AC-25a transcript schema requirement: workspace must include SPEC-018.md as a possible `read_file` target. This validates H-2 self-DoS is closed by guard deletion (since guard no longer exists, the test now passes by construction).
- Critic Q-2: add to §10c.1: "Future SPEC versions invoking this precedent for OTHER v0.2 invariants MUST satisfy the same (a)-(d) rules and add an enumerated entry."

## Version bump + change-log

- Header `**Version:**` → `0.2.3 (2026-06-27, blind-spot absorption — Path (a) §3.9 deletion + §10c.1 discipline rule + 9 mechanical edits)`.
- Status line per item 11 above.
- New v0.2.3 change-log entry at top.
- Buyer-visible delta bullets lead with "v0.2.3 is the codex-converged + Claude-blind-spot-absorbed lock candidate."

## Additional output

Write `specs/SPEC-018-v0_2_3-DRAFT-NOTES.md` listing each absorption with finding ID + location + any loose interpretation.

## Constraints

- DO NOT alter locked v0.1.5 content except as explicitly directed (item 8 Quick-orientation block insertion is AFTER Status line, BEFORE change log — does NOT touch locked v0.1.5 sections).
- §3.9 deletion IS a v0.2.1-content amendment (NOT v0.1.5 content); consistent with item 1 Path (a).
- §10c.1 is NEW content at v0.2.3, not amendment of locked content.
- Money-path settlement protection MUST be preserved across all changes.

## What this produces

A v0.2.3 draft. Then:
1. Codex 4-lane r4 (defensive confirmation, expect 0/0/0).
2. Claude critic + narrative blind-spot r2 (defensive confirmation, expect READY TO LOCK).
3. If both pass, declare LOCKED → open SPEC PR.

Confidence: v0.2.3 IS the lock candidate.

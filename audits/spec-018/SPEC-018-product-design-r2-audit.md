# SPEC-018 v0.1.1 — PRODUCT-DESIGN-lane round-2 audit

You are the **product-design** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 PD findings: `specs/SPEC-018-product-design-r1-audit.md`
- Round-1 absorbed: C-1, H-1, H-2, M-1, M-2, M-3, Q-1 all marked absorbed.

## The anchor example you're auditing against (unchanged from r1)

A developer opens Cline / Cursor / Aider / Claude Code / Continue / OpenCode / Zed. Configures `OPENAI_BASE_URL=https://api.malibu.tech/v1` + buyer token. Picks `qwen3-coder` (or similar). Asks: "refactor this file, run the tests, commit the result."

Question against v0.1.1: does the SPEC honestly describe what that user gets?

## Round-2 lane scope

1. **Verify r1 absorption.**
   - **r1 C-1** (Ring-1 framing): v0.1.1 §1 now says "first-turn OpenAI tool-call wire-shape compatibility certificate." §1.1 has a Known v0.1 limitations callout. §10a #1 names multi-turn as v0.2 gate. §12 reinforces. Read §1 + §1.1 + §10a #1 + §12 together: does a buyer skim and understand they're getting first-turn-only, OR is there still ambiguity that overclaims?
   - **r1 H-1** (AC-16 demo vs product): AC-16a is renamed "first-turn wire-shape smoke" and AC-16b adds framework-level smoke. Is AC-16b strong enough to actually validate the product story, or is "first turn parses without adapters against ONE of [list]" weaker than a full integration?
   - **r1 H-2** (§10 split): §10a + §10b are now distinct. Read §10a carefully. Are all 7 items genuinely v0.2-gating (i.e., a real Cline user needs them), or did some §10b candidates drift into §10a?
   - **r1 M-1** (buffered streaming UX callout): §1.1 #2 names buffered streaming as a Known limitation. Is the user-impact statement strong enough — do they understand they'll see a pause?
   - **r1 M-2** (model SKU guidance): SPEC-018 v0.1.1 still does NOT name specific SKU `mlx-community/...` IDs. §3.1 still describes families. Is this a residual M-2 (codex r1 recommended a SKU table), or has the scope re-framing absorbed it (a "wire-shape certificate" doesn't promise specific SKU availability — that's SPEC-010 catalog's job)?
   - **r1 M-3** (limitations discoverability): §1.1 callout is added. Read it. Does it match what a user reading top-to-bottom needs to know?
   - **r1 Q-1** (v0.2 additive invariant): v0.1.1 does not explicitly add the "v0.2 MUST preserve v0.1 non-streaming response shape" invariant. Should this still go in?

2. **New product-design lens checks for v0.1.1.**
   - **Framing honesty.** v0.1.1 calls itself a "wire-shape compatibility certificate." Does that language honor product reality, or is "certificate" still marketing-flavored? Would "wire-shape compatibility snapshot" or "first-turn ratification" be more honest?
   - **§1.1 placement.** "Known v0.1 limitations" is at §1.1 — does it belong even higher (e.g. as a callout box right under the change log, before §1.0 starts), so a user can't miss it?
   - **§10a #2 — model-hash → family registry.** This is a real product feature. Is the SPEC's explanation accessible to a non-architect reader (e.g. someone considering whether to invest in macprovider as a Cline backend)?
   - **AC-16b release-readiness signal.** §11 Q1 now asks "which framework's incremental tool-call rendering is the v0.2 release-readiness signal — Cline, Aider, OpenCode, or all of them?" Is this the right v0.2 product gate, or should v0.2 lock require *all* of them?
   - **The "should I use this in production" test.** A startup CTO evaluating macprovider for their agent stack reads §1 + §1.1 + §10a. Do they correctly conclude: "v0.1 is a wire-shape compatibility certificate; v0.2 is the actual product; we should wait for v0.2 to integrate"?

3. **Final anchor walk-through (v0.1.1).** Walk the same Cline session against v0.1.1 as written. Does the user now understand what's coming?

## Output format

```
# SPEC-018 v0.1.1 — Product-design-lane round-2 audit

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
- User impact:
- SPEC location:
- Current framing:
- Reality from anchor example:
- Recommended fix:

## Anchor-example walk-through (v0.1.1)
[2-3 sentence honest reassessment]

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in product-design lane.

## Final prompt

# SPEC-018 v0.1.1 — PRODUCT-DESIGN-lane round-2 audit

You are the **product-design** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 PD findings: `specs/SPEC-018-product-design-r1-audit.md`
- Round-1 absorbed: C-1, H-1, H-2, M-1, M-2, M-3, Q-1 all marked absorbed.

## The anchor example you're auditing against (unchanged from r1)

A developer opens Cline / Cursor / Aider / Claude Code / Continue / OpenCode / Zed. Configures `OPENAI_BASE_URL=https://api.malibu.tech/v1` + buyer token. Picks `qwen3-coder` (or similar). Asks: "refactor this file, run the tests, commit the result."

Question against v0.1.1: does the SPEC honestly describe what that user gets?

## Round-2 lane scope

1. **Verify r1 absorption.**
   - **r1 C-1** (Ring-1 framing): v0.1.1 §1 now says "first-turn OpenAI tool-call wire-shape compatibility certificate." §1.1 has a Known v0.1 limitations callout. §10a #1 names multi-turn as v0.2 gate. §12 reinforces. Read §1 + §1.1 + §10a #1 + §12 together: does a buyer skim and understand they're getting first-turn-only, OR is there still ambiguity that overclaims?
   - **r1 H-1** (AC-16 demo vs product): AC-16a is renamed "first-turn wire-shape smoke" and AC-16b adds framework-level smoke. Is AC-16b strong enough to actually validate the product story, or is "first turn parses without adapters against ONE of [list]" weaker than a full integration?
   - **r1 H-2** (§10 split): §10a + §10b are now distinct. Read §10a carefully. Are all 7 items genuinely v0.2-gating (i.e., a real Cline user needs them), or did some §10b candidates drift into §10a?
   - **r1 M-1** (buffered streaming UX callout): §1.1 #2 names buffered streaming as a Known limitation. Is the user-impact statement strong enough — do they understand they'll see a pause?
   - **r1 M-2** (model SKU guidance): SPEC-018 v0.1.1 still does NOT name specific SKU `mlx-community/...` IDs. §3.1 still describes families. Is this a residual M-2 (codex r1 recommended a SKU table), or has the scope re-framing absorbed it (a "wire-shape certificate" doesn't promise specific SKU availability — that's SPEC-010 catalog's job)?
   - **r1 M-3** (limitations discoverability): §1.1 callout is added. Read it. Does it match what a user reading top-to-bottom needs to know?
   - **r1 Q-1** (v0.2 additive invariant): v0.1.1 does not explicitly add the "v0.2 MUST preserve v0.1 non-streaming response shape" invariant. Should this still go in?

2. **New product-design lens checks for v0.1.1.**
   - **Framing honesty.** v0.1.1 calls itself a "wire-shape compatibility certificate." Does that language honor product reality, or is "certificate" still marketing-flavored? Would "wire-shape compatibility snapshot" or "first-turn ratification" be more honest?
   - **§1.1 placement.** "Known v0.1 limitations" is at §1.1 — does it belong even higher (e.g. as a callout box right under the change log, before §1.0 starts), so a user can't miss it?
   - **§10a #2 — model-hash → family registry.** This is a real product feature. Is the SPEC's explanation accessible to a non-architect reader (e.g. someone considering whether to invest in macprovider as a Cline backend)?
   - **AC-16b release-readiness signal.** §11 Q1 now asks "which framework's incremental tool-call rendering is the v0.2 release-readiness signal — Cline, Aider, OpenCode, or all of them?" Is this the right v0.2 product gate, or should v0.2 lock require *all* of them?
   - **The "should I use this in production" test.** A startup CTO evaluating macprovider for their agent stack reads §1 + §1.1 + §10a. Do they correctly conclude: "v0.1 is a wire-shape compatibility certificate; v0.2 is the actual product; we should wait for v0.2 to integrate"?

3. **Final anchor walk-through (v0.1.1).** Walk the same Cline session against v0.1.1 as written. Does the user now understand what's coming?

## Output format

```
# SPEC-018 v0.1.1 — Product-design-lane round-2 audit

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
- User impact:
- SPEC location:
- Current framing:
- Reality from anchor example:
- Recommended fix:

## Anchor-example walk-through (v0.1.1)
[2-3 sentence honest reassessment]

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in product-design lane.

## Raw output

```text
# SPEC-018 v0.1.1 — Product-design-lane round-2 audit

## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 0  
MINOR: 2  
QUESTIONS: 2  

## r1-absorption verification
- r1 C-1: CONFIRMED. §1, §1.1, §10a #1, and §12 now plainly say first-turn-only; no remaining product overclaim.
- r1 H-1: CONFIRMED. AC-16a/16b are honestly scoped as first-turn smoke, not full integration. AC-16b is weaker than full integration, but that now matches v0.1 framing.
- r1 H-2: CONFIRMED. §10a/§10b split is materially better; the seven §10a items are defensible v0.2 gates for a production-grade Ring-1 product.
- r1 M-1: CONFIRMED. §1.1 #2 says users see a pause, then the complete tool call.
- r1 M-2: CONFIRMED AS ABSORBED. Exact SKU IDs belong in catalog / deployment evidence, not this re-scoped wire-shape certificate. AC-18’s artifact must record the tested SKU.
- r1 M-3: CONFIRMED. §1.1 is early and explicit enough.
- r1 Q-1: RESIDUAL QUESTION. The v0.2 additive compatibility invariant is still absent.

## Findings

### m-1 — “Certificate” Still Slightly Overstates Formality
- User impact: A buyer may read “certificate” as broader compatibility certification across agent frameworks, even though v0.1 certifies first-turn wire shape plus one framework smoke.
- SPEC location: §1, §1.1, AC-16a, AC-16b.
- Current framing: “first-turn OpenAI tool-call wire-shape compatibility certificate.”
- Reality from anchor example: The Cline-style workflow still fails on turn 2; v0.1 proves parse shape, not agent-loop readiness.
- Recommended fix: Prefer “first-turn wire-shape compatibility snapshot” or define “certificate” narrowly as “AC-16a + AC-16b first-turn evidence only.”

### m-2 — §10a #2 Is Correct But Too Architect-Centric
- User impact: A CTO can see that model-hash binding matters, but the buyer consequence is buried under SPEC/file-path language.
- SPEC location: §1.1 #4, §10a #2.
- Current framing: Explains `model_hash` infrastructure and registry design questions.
- Reality from anchor example: In v0.1, grammar choice trusts the advertised `modelID`; v0.2 should bind grammar choice to the actually loaded model.
- Recommended fix: Add one buyer-facing sentence: “This prevents a provider from advertising a tool-call-capable model family while running a different model or grammar.”

### Q-1 — Additive v0.2 Compatibility Invariant Still Missing
- User impact: Buyers do not get an explicit promise that adopting v0.1 non-streaming response shape will remain safe when v0.2 lands.
- SPEC location: §10 or §12.
- Current framing: v0.2 work appears additive but is not stated as an invariant.
- Reality from anchor example: Multi-turn enablement should not break first-turn clients; streaming may add deltas but should preserve OpenAI concatenation semantics.
- Recommended fix: Add: “Future SPEC-018 versions MUST preserve v0.1 non-streaming response shape. Streaming improvements MAY add incremental deltas but MUST preserve OpenAI-compatible delta concatenation semantics.”

### Q-2 — v0.2 Framework Readiness Signal Needs A Product Decision
- User impact: “Actual Ring-1 product” could either lock too narrowly after one framework smoke or overpromise across named clients without testing them.
- SPEC location: §11 Q1, §10a #4, AC-16b.
- Current framing: Asks whether Cline, Aider, OpenCode, or all are the release-readiness signal.
- Reality from anchor example: Cline compatibility is not automatically equivalent to Aider/OpenCode/Continue compatibility.
- Recommended fix: For v0.2, name one primary release framework if positioning is narrow; if §1 continues naming many frameworks as product targets, require a compatibility matrix and at least smoke evidence for each named target.

## Anchor-example walk-through (v0.1.1)
The Cline/Cursor/Aider user now gets an honest story: first assistant tool-call response can parse, tool execution happens client-side, then the second provider turn is expected to fail with `unsupported_tool_messages`. They also know streaming will pause and emit the complete tool call at once, so v0.1 reads as a wire-shape milestone, not a production agent backend.

## Verdict
READY TO LOCK.


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

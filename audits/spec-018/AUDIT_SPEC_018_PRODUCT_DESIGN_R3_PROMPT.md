# SPEC-018 v0.1.2 — PRODUCT-DESIGN-lane round-3 audit (lock confirmation)

You are the **product-design** lane of a round-3 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.2. This is a lock confirmation round — your r2 verdict was READY TO LOCK; r3 verifies the v0.1.2 polish does not regress anything.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round-2 PD findings: `specs/SPEC-018-product-design-r2-audit.md` (m-1, m-2, Q-1, Q-2 all marked absorbed in v0.1.2)

## The anchor example (unchanged)

A developer opens Cline / Cursor / Aider. Configures `OPENAI_BASE_URL=https://api.malibu.tech/v1` + buyer token. Picks Qwen3-Coder. Asks for a refactor.

## Round-3 lane scope

1. **Verify r2 absorption.**
   - **m-1** ("certificate" overstates): §1 now narrowly defines "certificate" = AC-16a + AC-16b first-turn-parse evidence only. Adequate?
   - **m-2** (§10a #2 architect-centric): §10a #2 now includes the buyer-facing sentence "prevents a provider from advertising a tool-call-capable model family while running a different model or grammar." Adequate buyer translation?
   - **Q-1** (additive v0.2 invariant): §10c is new — "v0.2 and beyond MUST preserve v0.1.2 non-streaming response shape." AC-23 verifies via regression test. Adequate?
   - **Q-2** (v0.2 framework readiness signal): §11 Q1 reframed as v0.2 product decision with three named options (a/b/c). Adequate?
2. **Read v0.1.2 top to bottom as a buyer would.** Does it now read as honest product positioning, or has the polish introduced new wording drift?
3. **The "Qwen3-Coder works with macprovider" buyer question.** v0.1.2 §3.1 now collapses Qwen2.5 + Qwen3 + Coder variants into one family. A buyer asking "is Qwen3-Coder-32B supported?" can find the answer by §3.1 + the SKU note. Is the answer clear without code-reading?

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

## Anchor-example walk-through (v0.1.2)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

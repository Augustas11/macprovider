# AUDIT_SPEC_018_v0_2_PRODUCT_DESIGN_r3

## Task

Round 3 product-design lane audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 after r2 absorption.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.2 SPEC body.
2. `specs/SPEC-018-v0_2-product-design-r2-audit.md` — your r2 findings: 0C / 0H / 1M / 0m / 0Q.
3. `specs/SPEC-018-v0_2-r2-audit.md` — r2 narrative.
4. `specs/SPEC-018-v0_2-r2-absorption-prompt.md` — r2 absorption instructions.
5. `specs/SPEC-018-v0_2_2-DRAFT-NOTES.md` — codex absorption notes.

## Your tasks

1. **Confirm r2 PD finding closed:**
   - MEDIUM-1: AC-46 captured in AC-25a transcript schema + buyer-side guidance (Cline does not branch on the field; observation-only for v0.2)

2. **Fresh r3 PD-lens sweep:**
   - AC-50 through AC-55 aggregate caps: Cline UX impact — does a Cline coding session realistically approach 4 MiB raw body, 1 MiB tool content aggregate, 2 MiB args aggregate, 256 messages, 128 tool calls? Are the caps generous enough that legitimate Cline sessions don't hit them?
   - AC-46 `null` sentinel: Cline UX — does Cline see this and need to do anything? (Should be: no — observation-only per §10d.0.1.)
   - `prompt_echo_blocked` moved to internal-only: Cline UX impact when guard fires — Cline sees plain-content response, no `tool_calls[]`, no error. Is the silent fallback acceptable for Cline UX? (Auditor previously argued for richer signal but accepted internal-only as v0.3 candidate. Re-verify acceptance.)

3. **Final lock-readiness assessment:** if r3 returns 0/0/0 from PD lens, READY TO LOCK signal.

## Scope

Only v0.2.2 additions. Locked v0.1.5 still LOCKED.

## Output

Write `specs/SPEC-018-v0_2-product-design-r3-audit.md` with standard structure.

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK from PD lens.

# AUDIT_SPEC_018_v0_2_PRODUCT_DESIGN_r2

## Task

Round 2 product-design lane audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.1 after r1 absorption.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.1 SPEC body.
2. `specs/SPEC-018-v0_2-product-design-r1-audit.md` — your prior round findings: 4 HIGH + 3 MEDIUM + 1 minor + 2 Q.
3. `specs/SPEC-018-v0_2-r1-audit.md` — r1 narrative (Path B decision).
4. `specs/SPEC-018-v0_2-r1-absorption-prompt.md` — absorption instructions.
5. `specs/SPEC-018-v0_2_1-DRAFT-NOTES.md` — codex absorption notes.

Cline reference docs as needed.

## Your tasks

1. **Confirm or reject each prior PD r1 finding** as CLOSED or NOT CLOSED with v0.2.1 citation:
   - HIGH-1: AC-25 split into CI fixture + manual smoke
   - HIGH-2: AC-44 instrumented + benchmarked per-class hardware target
   - HIGH-3: operator kill switch buyer-visibility (`X-MacProvider-Streaming-Mode` header)
   - HIGH-4: thicker error envelope (codes, retryable, request_id, inference/settlement state)
   - MEDIUM-1: v0.2 reader note re §10a vs §10d
   - MEDIUM-2: "Why Cline gates v0.2" paragraph
   - MEDIUM-3: Cline tool category mapping (legacy vs ClineCore)
   - minor-1: duplicate §3.7 → §3.8 renumber
   - Q-1: buffered-mode UX notice
   - Q-2: 256 KiB tool-result cap vs real Cline file reads

2. **Fresh PD-lens findings** on v0.2.1 edits: AC-46 `model_hash_observed` field UX (does Cline need to do anything with it?), error envelope minimum fields covers real Cline retry/abandon decision space, AC-25a CI fixture pinned Cline version + ClineCore tools mapping completeness.

3. **Path B narrative honesty**: v0.2.1 explicitly amends locked §10c. Audit whether the buyer-visible change log narrates this in language a Cline integrator (not just a SPEC reviewer) understands. Is the rationale clear enough that integrators don't feel scope-cut blindsided?

## Scope

Round 2 focus: prior-round closure + fresh-finding sweep on v0.2.1 additions. Locked v0.1.5 LOCKED.

## Output format

Write to `specs/SPEC-018-v0_2-product-design-r2-audit.md` with standard structure.

Cline-user experience perspective remains primary. If v0.2.1 Cline UX gaps remain (especially around graceful degradation), that's HIGH minimum. Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK from PD lens.

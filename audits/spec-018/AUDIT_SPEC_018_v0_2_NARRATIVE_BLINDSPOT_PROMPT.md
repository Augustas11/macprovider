# AUDIT_SPEC_018_v0_2 — Claude Narrative Blind-Spot Pass

## Task

You are a Claude narrative analyst running a coherence audit on `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 AFTER codex 4-lane converged 0/0/0 across 3 rounds.

Your job: **assess whether v0.2.2 reads coherently for a real reader**. Codex is good at internal consistency within sections. Codex is bad at:
- **Cross-section narrative flow** — does a reader who starts at the top arrive at understanding by the end?
- **Version-layer navigation** — v0.2.2 has 3 layers (locked v0.1.5 + v0.2.0 + v0.2.1/2.2 amendments). Can a reader navigate without help?
- **Audience fit** — does it work for a Cline integrator who doesn't know SPEC archaeology? For a security reviewer doing pre-PR review? For a future-Claude doing IMPL prompt?
- **Lock-amendment precedent honesty** — v0.2.1 set the precedent that locked invariants CAN be amended. Is that explained well enough that future readers won't be confused about what's actually locked?

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.2 SPEC body.
2. `specs/SPEC-018-v0_2-{architect,code,security,product-design}-r3-audit.md` — codex r3 verdicts (all READY TO LOCK).
3. `specs/SPEC-018-v0_2-r1-audit.md`, `specs/SPEC-018-v0_2-r2-audit.md` — round narratives.
4. v0.1.5 precedent: `specs/SPEC-018-product-narrative-blindspot-audit.md` — your prior narrative pass.

## Your narrative-analyst lens

Read the SPEC top-to-bottom as a Cline integrator who's never seen it before. Ask:

1. **Opening clarity** — do the first 50 lines (header, change-log, "buyer-visible deltas") give a Cline integrator enough to know whether they care about v0.2.2?
2. **Version-layer navigability** — locked v0.1.5 content (§1-§10b, AC-1 through AC-24) sits next to v0.2.0-additive content (§3.8, §8.4.1/.2/.3, §10d, AC-25 through AC-49) sits next to v0.2.1/2.2-additive content (AC-50 through AC-55, §10c amendment paragraph). Can a reader tell which content is which version's responsibility? Do version-applicability notes appear where needed?
3. **§3.8 doc-order** — codex previously noted §3.8 physically precedes §3.7. The cosmetic note was added in r2. Does it read coherently? Or does the §3 section flow weirdly?
4. **§10d subsection numbering** — §10d.0 / §10d.0.1 / §10d.1 / §10d.4 / §10d.6 / §10d.7 / §10d.8. The r2 explanatory note maps to deliverable IDs. Does that map work for a reader who didn't read the design synthesis?
5. **§10c amendment narrative** — "AMENDED v0.2.0/v0.2.1: ..." paragraph in §10c. Is this honest? Does it leave a future reader unclear about what's currently required vs deferred?
6. **AC numbering jumps** — AC-1 through AC-24 (locked), then AC-25 through AC-49 (v0.2.0/2.1), then AC-50 through AC-55 (v0.2.2). Logical groupings? Or arbitrary?
7. **Buyer-visible delta lists** — v0.2.0 + v0.2.1 + v0.2.2 each have their own. Do they read coherently if read top-to-bottom (newest first)? Do they accidentally repeat or contradict?
8. **§10a contradiction handling** — §10a still names #2/#3/#5 as v0.2 deliverables (locked content). §10d says they're v0.3. Does the reader-note at §10d.0 close this honestly? Or does it require the reader to mentally hold two timelines?
9. **Scope-narrowing honesty** — does the SPEC convey that v0.2 was deliberately narrowed (from 7 deliverables to 4 to ship "Cline drop-in" faster), or does it read as if scope shrunk due to engineering limitations?

## Specific checks

- **First-time-reader test**: would a Cline integrator who reads only the top 100 lines understand whether v0.2 works for their use case?
- **SPEC-archaeology test**: can a future-Claude (e.g., me a year from now) read v0.2.2 cold and write a correct IMPL prompt without help?
- **PR-reviewer test**: can a security reviewer doing pre-PR review answer "does this break any v0.1 guarantee?" by reading the SPEC + change-log alone?

## Output format

Write findings to `specs/SPEC-018-v0_2-product-narrative-blindspot-audit.md`:

```markdown
# SPEC-018 v0.2.2 — Narrative Blind-Spot Audit

**Date:** 2026-06-27
**Reviewer:** Claude narrative analyst blind-spot pass
**Verdict:** {READY TO LOCK | FIX REQUIRED}

## Tally: C/H/M/m/Q

## Findings (severity-ordered)

## First-time-reader test result
## SPEC-archaeology test result
## PR-reviewer test result

## Verdict justification
```

## Severity bar

- **HIGH** — a Cline integrator or PR reviewer would be misled in a way that costs them real time or causes incorrect IMPL.
- **MEDIUM** — narrative gap that costs reviewer cycles but doesn't mislead.
- **minor** — polish.
- **Q** — open narrative trade-off.

Goal: catch what codex missed about reader experience. If genuinely clean, return 0/0/0 with reasoning.

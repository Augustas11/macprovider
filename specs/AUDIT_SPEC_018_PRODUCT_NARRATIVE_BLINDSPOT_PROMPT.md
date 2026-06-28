# SPEC-018 v0.1.2 — Claude product-narrative blind-spot pass

You are the **product narrative coherence** lane. You exist because codex's product-design lane (which returned READY TO LOCK in r2 and r3) checks against an anchor example, but does not reliably catch how the SPEC reads to a real-world reader making a real decision. Your job is to read v0.1.2 as the people who will actually read it — and tell us what they conclude.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round narratives + per-lane round files in `specs/SPEC-018-r{1,2,3}-audit.md` and `specs/SPEC-018-{architect,code,security,product-design}-r{1,2,3}-audit.md`.

## Three real-world readers — read the SPEC AS each of them

### READER 1 — Cline-power-user (the buyer)
A senior engineer running Cline / Cursor / Aider for 4-6 hours a day on real coding work. Pays $20/mo for Claude Pro. Has heard "macprovider lets you point Cline at your own M4 and pay per-token" and is curious. Opens v0.1.2.

What do they understand? What surprises them? Where do they get the wrong impression? In their first 5 minutes of reading, do they:
- Correctly conclude "v0.1 is first-turn only; I should wait for v0.2 before integrating"?
- Or mistakenly conclude "v0.1 is ready and I can switch Cline to it today"?
- Or get confused enough to close the tab and try OpenRouter instead?

Quote specific sentences/sections that work or don't work for this reader.

### READER 2 — Startup CTO evaluating macprovider
Building an AI-agent product. Looking for inference providers that won't lock them into one vendor. Reading SPEC-018 to evaluate "is macprovider a real platform, or a research project?" They care about:
- Stability of the wire contract (will my integration break?)
- Production-readiness (is this serving real traffic?)
- Roadmap clarity (what's v0.2? when?)
- Security posture (what's my exposure surface?)

In their first 15 minutes of reading the full SPEC + the round narratives, do they conclude "real platform" or "research project"? Quote the sentences that pushed them one way or the other.

### READER 3 — macprovider-SPEC-author-future
An engineer in 4 months who has to write SPEC-018 v0.2. They've never read v0.1.2 before. They open it cold. The forward commitments in v0.1.2 (§10a items, §10c invariant) are their inheritance. Do they understand:
- What v0.2 MUST deliver?
- What the §10a #2 model-hash registry design space looks like?
- Why §10c additive invariant matters?
- What ACs from v0.1.2 must still pass after their changes?

What's confusing? What's underspecified for the v0.2 author? What's overspecified (would prevent them from making a reasonable design choice)?

## What you are NOT doing (out of lane)

You are NOT:
- A fifth codex lane (don't reverify citations, ACs, or normative claims)
- The critic lane (don't try to refute every MUST or find edge cases)
- Re-doing PD anchor-example walk-through (codex PD already did that)

You ARE: reading the SPEC as a single coherent document and reporting where comprehension breaks for each of the three named readers.

## Specific narrative-coherence checks

Beyond the three reader perspectives, look for:

### NARR-1. The "certificate" framing through the whole doc
§1 defines "certificate" narrowly. Does that definition hold up across §3.7, §6, §10a, §11, §12? If a reader encounters "certificate" later in the doc, do they remember the §1 definition or substitute a more colloquial meaning?

### NARR-2. The "first-turn only" reality
§1, §1.1, §6, AC-14, §10a #1 all touch this. Does the doc consistently say "first-turn only" or does any sentence accidentally imply otherwise? Look for words like "agent loop," "drop-in," "compatible" without "first-turn" qualifier.

### NARR-3. The model-hash story
§1.1 #4, §10a #2 reference model-hash binding. Does the SPEC tell a coherent story across these sections about:
- What model-hash binding IS
- Why it matters (security threat)
- Where the infrastructure already exists (SPEC-008/011)
- What v0.2 adds on top
- What buyer impact looks like

A reader who only reads §1.1 should understand the basic risk. A reader who reads §1.1 + §10a #2 should understand the full v0.1→v0.2 trajectory.

### NARR-4. §10a vs §10b boundary
v0.1.2 splits these into "required for v0.2" vs "future enhancements." Is the boundary defensible to a reader who doesn't know your audit history? Could any §10a item plausibly be §10b, or vice versa?

### NARR-5. The change log as a story
v0.1.2 change log entries are dense paragraphs. If a reader only reads the change log to understand "what happened in v0.1.1 and v0.1.2," do they get the right summary? Or is the change log so audit-finding-flavored that the actual product evolution is lost?

### NARR-6. Title and §1 first paragraph
A reader's first impression. Read the first 5 lines of v0.1.2 (title + version + depends-on + status + change-log H2). What do they think SPEC-018 is about? Is it clear enough?

## Output format

```
# SPEC-018 v0.1.2 — Product narrative blind-spot pass

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Three readers — quote-grounded assessment

### READER 1 — Cline power user
[2-4 sentences. What they conclude. Quote 1-2 specific lines.]

### READER 2 — Startup CTO
[2-4 sentences. Real platform or research project?]

### READER 3 — v0.2 SPEC author
[2-4 sentences. What's clear, what's not.]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- Reader / narrative-coherence category: [READER N | NARR-1..6]
- SPEC location:
- What the SPEC says:
- What the reader concludes / where comprehension breaks:
- Recommended fix:

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable.

Stay in lane: real-reader comprehension, not technical correctness.

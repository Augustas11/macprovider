# AUDIT_SPEC_018_v0_2 r4 — Defensive Lock Confirmation (4 codex lanes + 2 Claude lanes shared brief)

## Task

Round 4 (defensive) audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.3 after blind-spot absorption.

v0.2.3 is the lock candidate. Your job: confirm no regression from your r3 / blind-spot verdict, AND sweep v0.2.3 additions for fresh findings.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.3 SPEC body.
2. Your prior round verdict:
   - Codex r3 (all 4 lanes): `specs/SPEC-018-v0_2-{architect,code,security,product-design}-r3-audit.md` — all READY TO LOCK (0/0/0)
   - Claude critic: `specs/SPEC-018-v0_2-critic-blindspot-audit.md` — 3H + 4M + 3m + 2Q
   - Claude narrative: `specs/SPEC-018-v0_2-product-narrative-blindspot-audit.md` — 1H + 3M + 2m + 1Q
3. `specs/SPEC-018-v0_2-blindspot-audit.md` — blind-spot narrative.
4. `specs/SPEC-018-v0_2-blindspot-absorption-prompt.md` — codex absorption instructions.
5. `specs/SPEC-018-v0_2_3-DRAFT-NOTES.md` — codex absorption notes.

## v0.2.3 changes (what to verify)

**LOAD-BEARING:**
- §3.9 DELETED (Path a — minimal echo guard removed)
- §10c.1 NEW (lock-amendment discipline rule + Amendment log: Amendment 1 = §10c model-hash; Amendment 2 = §3.9 deletion)
- Quick orientation block at top (line 7-17)

**MECHANICAL:**
- AC-48 split into AC-48a (openai-python ecosystem) + AC-48b (Cline-direct via @ai-sdk/openai-compatible)
- §10d.4 auto-downgrade attribution: per-(buyer, provider) tuple, 3-in-5min threshold, 10min recovery, AC-45c adversarial test
- AC-44 clock-skew bound: NTP-anchored, |t_provider - t_gateway| ≤ 100 ms
- AC-56 new: 6 MiB total decoded prompt aggregate cap, `prompt_aggregate_too_large` code
- AC-46 reframed: buyer-side type assertion + provider-side self-test
- §10a reader-note added
- AC numbers stable across versions (Critic m-1 note in §10c.1)
- AC-25a workspace can include SPEC-018.md as `read_file` target (Critic Q-1 closure)

## Your task

**Per your lane** (the prompt's lane variable selects which to focus on):

**For codex 4 lanes (architect/code/security/PD):**
1. Re-read your r3 audit. Confirm your r3 verdict still holds against v0.2.3 (no regression).
2. Sweep v0.2.3 NEW additions (listed above) for fresh findings within your lane lens.

**For Claude critic:**
1. Verify your 3 HIGH findings (H-1 openai-python/Cline mismatch, H-2 echo guard self-DoS, H-3 per-provider downgrade DoS) are CLOSED.
2. Verify the §10c.1 lock-amendment discipline rule satisfies Critic M-4 (precedent under-specified for future amendments).
3. Fresh adversarial sweep on v0.2.3 additions — especially §10c.1 (does the discipline rule open new exploit paths?) and AC-48 split (does the openai-python+Cline split actually gate the money-path question?).

**For Claude narrative:**
1. Verify the Quick orientation block closes Narrative H-1 + M-1 (first-time-reader test now passes).
2. Verify §10c.1 closes Narrative M-2 (lock-amendment discipline promoted to named section).
3. Verify §10a reader-note closes Narrative M-3.
4. Re-run the 3 reader tests (first-time-reader / SPEC-archaeology / PR-reviewer).

## Scope

Only v0.2.3 additions and prior-finding closures. Locked v0.1.5 still LOCKED.

## Output

Write findings to `specs/SPEC-018-v0_2-{lane}-r4-audit.md` (for codex: lane ∈ {architect, code, security, product-design}; for Claude: lane ∈ {critic, narrative}) with standard structure (verdict, tally, closure status + fresh findings).

## Bar

0 CRITICAL + 0 HIGH + 0 MEDIUM = LOCK CANDIDATE.

If all 6 lanes return 0/0/0, declare v0.2.3 LOCKED → open SPEC PR.

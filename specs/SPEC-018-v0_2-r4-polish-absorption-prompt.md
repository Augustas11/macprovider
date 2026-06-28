# SPEC-018 v0.2.4 — r4 Polish Absorption Prompt

## Your task

Apply 5 polish edits to `specs/SPEC-018-agentic-tool-calling.md`, bumping to v0.2.4. All 6 r4 audit lanes returned READY TO LOCK. These are non-blocking polish that should still land before SPEC PR opens to avoid IMPL-reviewer questions.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — current v0.2.3.
2. `specs/SPEC-018-v0_2-critic-r2-blindspot-audit.md` — flagged m-2 + m-3 + m-1.
3. `specs/SPEC-018-v0_2-architect-r4-audit.md` — flagged m-1.
4. `specs/SPEC-018-v0_2-narrative-r2-blindspot-audit.md` — flagged m-1.
5. `specs/SPEC-006-buyer-api.md` — verify (via grep) it does NOT contain NTP/clock/skew/time-sync language. Critic verified this; you must too before editing AC-44.

## 5 polish edits

**1. Critic m-2 — AC-44 fabricated SPEC-006 NTP citation.**

Critic grepped `specs/SPEC-006-buyer-api.md` and `specs/SPEC-006-design.md` for NTP/clock/skew/time-sync and found zero hits. The citation in AC-44 (or wherever the "NTP sync precondition is the SPEC-006 buyer-API requirement; v0.2 inherits it" sentence lives) is fabricated.

Fix: REMOVE the SPEC-006 inheritance citation. The technical content (100 ms skew bound, NTP-anchored, skew-corrected p95) is self-contained and sound — keep it. Replace the inheritance sentence with: "Operators MUST run NTP on provider Macs and gateway hosts. v0.2 does NOT inherit this from another SPEC; it is a v0.2 prerequisite for AC-44 to be measurable. IMPL prompt will add `chrony` / `timesyncd` to the deployment checklist."

Before editing, GREP `specs/SPEC-006-buyer-api.md` and `specs/SPEC-006-design.md` yourself to confirm critic's finding. If your grep finds the language, document the actual location and adjust the fix accordingly.

**2. Critic m-3 — AC-56 vacuous total-decoded-prompt cap.**

AC-50 caps raw request body at 4 MiB. AC-56 caps total decoded prompt at 6 MiB. Decoded ≤ raw (JSON unescaping strictly shrinks), so 6 MiB cap is unreachable.

Fix: DELETE AC-56 entirely. Remove the corresponding §10d.1 paragraph adding the 6 MiB cap. Remove `prompt_aggregate_too_large` from the §10d.0 stable code table.

Note: this was added in v0.2.3 (Critic M-2). The intent (bound aggregate prompt material) is already covered by AC-50 (4 MiB raw body) + AC-51 (1 MiB tool content aggregate) + AC-52 (2 MiB args aggregate). AC-56 was redundant + vacuously framed.

If preferred alternative: REFRAME AC-56 to cap the rendered chat-template prompt size AFTER template-rendering (which CAN expand vs raw body if templates duplicate content). Cap value = 8 MiB rendered. But this introduces template-dependent variance that's hard to test. Recommendation: DELETE AC-56.

**3. Architect m-1 — §3 subsection ordering callout.**

Architect noted that §3 subsections jump §3.6 → §3.8 → §3.7 (since §3.9 was deleted, and §3.8 physically precedes §3.7 per the v0.2.1 lock-amendment).

Fix: Add a 1-line note at §3 heading: "**Subsection note**: §3 numbering is non-sequential (§3.1–§3.6, then §3.8, then §3.7) by intentional v0.2.1 lock-amendment (§3.8 inserted before §3.7 to avoid moving locked v0.1.5 content). §3.9 (v0.2.1-introduced minimal prompt-echo guard) was DELETED in v0.2.3 — see §10c.1 Amendment 2."

**4. Critic m-1 + Narrative m-1 (convergent) — §3.9-deleted breadcrumb in §3.**

Both critic and narrative flagged: §3 has no in-place breadcrumb where §3.9 used to live (only the §10c.1 Amendment 2 entry signals the deletion).

Fix: Add a stub heading + 2-line note at the position §3.9 used to occupy (after §3.7 "Adding a new family"):

```
### 3.9 [DELETED v0.2.3]

The v0.2.1-introduced minimal prompt-echo guard was DELETED in v0.2.3. See §10c.1 Amendment 2 for rationale (minimal guard had three exploitable defects: whitespace bypass, scope-incomplete, self-DoS via Cline reading SPEC-018.md). Full echo guard is a v0.3 deliverable.
```

**5. Critic Q-1 deferred to v0.3 governance.**

Q-1 asked about §10c.1 mixing locked-content amendments (Amendment 1) and draft-content revisions (Amendment 2 — §3.9 was v0.2.1 not yet locked).

Fix: Add a 1-line note to §10c.1 (after the amendment log, before the future-version obligation): "Note: §10c.1 covers both locked-content amendments (e.g., Amendment 1 amended §10c which was v0.1.3-locked) AND in-flight draft-content revisions (e.g., Amendment 2 deleted §3.9 which was v0.2.1-introduced and not yet locked). v0.3 governance MAY refine this distinction; v0.2.4 treats both classes under the same (a)-(d) discipline."

## Version bump + change-log

- Header `**Version:**` → `0.2.4 (2026-06-27, r4 polish — AC-44 citation fix + AC-56 deletion + §3 ordering note + §3.9-deleted breadcrumb + §10c.1 governance note)`.
- Status: `Draft — codex 4-lane r4 0/0/0; Claude blind-spot r2 0/0/0; v0.2.4 r4 polish absorbed; LOCK CANDIDATE pending PR.`
- New v0.2.4 change-log entry at top.
- Buyer-visible delta bullets lead with: "v0.2.4 is the SPEC PR candidate."

## Additional output

Write `specs/SPEC-018-v0_2_4-DRAFT-NOTES.md` listing each polish edit with finding ID + location + any verification check performed (especially the SPEC-006 grep result for item 1).

## Constraints

- Do NOT alter locked v0.1.5 content.
- AC-56 deletion IS the right call per critic m-3; do not re-introduce the vacuous AC.
- §3.9 stub heading is the right place to signal deletion; do not omit it.
- All 5 edits are mechanical; no strategic decisions.

## What this produces

v0.2.4 LOCKED. Ready for SPEC PR.

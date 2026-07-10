# SPEC-018 v0.2.3 — Narrative Blind-Spot Audit r2 (Defensive Lock Confirmation)

**Date:** 2026-06-28
**Reviewer:** Claude narrative analyst r2 defensive pass (post v0.2.3 blind-spot absorption)
**Verdict:** READY TO LOCK — 0 CRITICAL + 0 HIGH + 0 MEDIUM. Prior HIGH and all 3 MEDIUMs CLOSED. No fresh narrative defects in v0.2.3 additions.

## Tally: C/H/M/m/Q

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| minor | 1 |
| Q | 0 |

**Lock bar (0/0/0) MET.** v0.2.3 is a LOCK CANDIDATE on the narrative lane.

---

## Prior-finding closure verification

### H-1 — Quick orientation block (first-time-reader test) → CLOSED

**Prior finding:** First-time-reader test FAILED because seven stacked change-log entries pushed §1 product framing to ~line 54; a Cline integrator opening the SPEC could not answer "does multi-turn Cline work?" from the top 100 lines.

**v0.2.3 evidence (lines 7-17):** A `## Quick orientation` section is inserted immediately after the Status line and before the Change log. It delivers exactly the four-axis answer the prior finding requested:

- Line 9: one-sentence definition of what SPEC-018 is ("provider-side response synthesis contract for OpenAI-wire tool-call compatibility").
- Line 11: v0.1.5 LOCKED + commit hash + one-line scope.
- Line 12: **v0.2 SHIPS NOW: Cline drop-in works** + anchor framework named + 4 deliverables enumerated. This is the exact sentence a Cline integrator needs in the first 30 seconds.
- Line 13: v0.3 DEFERRED list (registry, full prompt-echo guard, structured malformed signal, framework matrix).
- Line 15: Lock-amendment precedent in one sentence + forward-reference to §10c.1.
- Line 17: Money-path invariant + concrete file:line citations.

**Closure verdict:** CLOSED. The block answers all three reader-test concerns (Cline integrator, PR reviewer, future-Claude IMPL author) in 11 lines without using audit-lineage jargon. Better than the prior recommendation: the prior fix proposed 4-6 lines; v0.2.3 delivered 11 lines that cover money-path + locked-content + amendment-precedent + ship-now scope, all forward-pointed to the appropriate section.

### M-1 — v0.2.3 buyer-visible deltas correctly framed → CLOSED

**Prior finding:** v0.2.2 buyer-visible deltas read as "three obscure edge-case fixes," misleading a Cline integrator about whether v0.2.2 mattered to them.

**v0.2.3 evidence (lines 21-27):** v0.2.3's buyer-visible deltas open with the correct framing:
- Line 22: *"v0.2.3 is the codex-converged + Claude-blind-spot-absorbed lock candidate."* This is the lede the prior finding recommended.
- Lines 23-27 then enumerate the substantive deltas (§3.9 deletion + residual-risk honesty; §10c.1 discipline named; AC-48 split for Cline; per-buyer/provider downgrade attribution; 6 MiB aggregate cap + NTP skew bound).

**Closure verdict:** CLOSED. The lede framing now signals lock-candidate status before the bullet list. Bullets enumerate substantive product/security deltas, not edge cases. Note: the orientation block (lines 7-17) ALSO carries the lock-candidate signal upstream, so even a reader who skips the change log gets the right framing.

### M-2 — §10c.1 Lock-amendment discipline → CLOSED

**Prior finding:** Lock-amendment discipline rule lived only in v0.2.1 change-log prose (~line 25), not at §10c. PR reviewer landing on §10c saw "MUST + AMENDED paragraph" without any way to assess whether the amendment process itself was sound.

**v0.2.3 evidence (lines 692-707):** A new `### 10c.1 Lock-amendment discipline` subsection delivers exactly the rule the prior finding requested:

- Lines 694-700: the four-rule discipline (name the clause; state strategic rationale; name replacement mitigation OR document residual risk; carry "AMENDED v<X.Y.Z>" prefix in-place) — explicitly numbered (a)-(d).
- Line 701: *"Silent scope cuts of locked invariants are NON-COMPLIANT."* + AC-stability rule (closes prior m-2).
- Lines 703-705: enumerated amendment log with both Amendment 1 (v0.2.1 registry deferral) and Amendment 2 (v0.2.3 §3.9 deletion), each with rationale + mitigation/residual-risk.
- Line 707: forward obligation on future SPEC-018 versions invoking the precedent.

**Closure verdict:** CLOSED, exceeds the prior recommendation. The prior finding suggested a single 100-word paragraph; v0.2.3 promoted the rule to a named subsection with an enumerated amendment log. PR reviewer landing at §10c now sees: (a) the MUST, (b) the AMENDED paragraph, (c) §10c.1 immediately after with discipline rule + enumerated precedent. PR-reviewer test passes cleanly.

### M-3 — §10a reader note → CLOSED

**Prior finding:** §10a still framed all 7 items as "v0.2 deliverable"; a reader landing on §10a cold had to remember the §10d.0 supersession note 30+ lines later.

**v0.2.3 evidence (line 646):** Immediately under the `### 10a. Required for full Ring-1 product (v0.2 normative targets)` heading:

> **Reader note**: §10a is locked v0.1.5 historical content. For v0.2.0+ active scope and the lock-amendment status of items listed here, see §10d.0 reader note + §10c.1 amendment log.

**Closure verdict:** CLOSED. A reader landing on §10a cold now gets the locked-historical framing in the first line and is forward-pointed to both §10d.0 (active scope) AND §10c.1 (amendment log). The dual forward-reference is better than the prior single-pointer recommendation: it splits "what is the active scope" from "which locked clauses are amended" into the two correct destinations.

---

## v0.2.3 fresh-additions narrative sweep

Per the audit prompt's three-reader-test methodology, I swept the v0.2.3 additions (Quick orientation, §10c.1, §10a reader note, §3.9 deletion, AC-48 split, AC-44 NTP skew bound, AC-45 per-buyer/provider attribution, AC-46 reframe, AC-56 aggregate cap) for fresh narrative defects within the v0.2.3 surface area.

**No fresh CRITICAL / HIGH / MEDIUM narrative defects found.** Specifically:

1. **§10c.1 discipline rule does not open new narrative exploit paths.** The (a)-(d) discipline is internally consistent. The "Silent scope cuts of locked invariants are NON-COMPLIANT" sentence is the right narrative guard against future SPEC-018 v0.X versions trying to amend invariants without naming them. Amendment log enumerated; future versions explicitly obligated to add entries.

2. **The §3.9 deletion narrative is honest.** Line 23 (Quick orientation), line 29 (v0.2.3 change-log entry), line 686 (§10c AMENDED v0.2.3 paragraph), line 705 (§10c.1 Amendment 2), line 740 (§10d.0 error-envelope note), and line 976 (§10d.8 v0.3 candidates) all consistently say the same thing: minimal guard had three exploitable defects, deleted, residual risk = same-family echo attack, v0.3 owns full guard. Six narration sites all agree.

3. **AC-48 split (a/b) closes the Cline / openai-python narrative ambiguity.** AC-48a explicitly names the openai-python ecosystem; AC-48b explicitly cites Cline v4.0.0 + Vercel AI SDK with the exact `@ai-sdk/openai-compatible` file path. A PR reviewer can now answer "is Cline's money-path tool-call rejection actually gated?" with a single AC citation rather than inferring from openai-python coverage.

4. **AC-45 per-(buyer, provider) attribution narrative is internally complete.** AC-45c adversarial fixture explicitly named, recovery interval (10 minutes) explicit, threshold (3 in 5 minutes) explicit. No narrative ambiguity about cross-buyer downgrade risk.

5. **AC-44 NTP-skew bound (≤ 100 ms) is anchored to SPEC-006 buyer-API NTP precondition.** Provides a normative source for the clock-skew assumption.

6. **AC-46 reframe (buyer-side type assertion + provider self-test).** Splits the field-presence guarantee from the provider-internal correctness guarantee. Both fixtures explicitly named.

7. **AC-56 aggregate cap (6 MiB total decoded prompt).** Single fail condition, single error code (`prompt_aggregate_too_large`), measured domain enumerated explicitly (`messages[].content`, assistant-history `tool_calls[].function.arguments`, `role:"tool".content`).

---

### m-1 — §3.9 ghost in §3 numbering (truly minor, advisory only)

**Severity:** minor (not a lock blocker; absorbed in v0.3 if convenient)
**SPEC location:** §3 reading flow

**Observation:** §3 subsection ordering after v0.2.3 is §3.1 → §3.2 → §3.3 → §3.4 → §3.5 → §3.6 → §3.8 → §3.7. There is no §3.9 anywhere (deleted in v0.2.3). The §3.8 editorial note at line 252 explains why §3.8 physically precedes §3.7. But no note at §3.8 / §3.7 / §3.6 says "§3.9 was deleted in v0.2.3; the gap is intentional and AC-22's number-stability rule applies."

For a future-Claude doing §3-section archaeology, the §3.9 gap reads as "where did §3.9 go?" — the answer is in §10c.1 Amendment 2 at line 705 and the v0.2.3 change-log at line 29, but those are not local to §3.

**Why this is only minor (and not MEDIUM):**
- AC-22 already establishes the number-stability principle at line 566 ("AC numbers are stable across SPEC-018 versions; once assigned, an AC number is never reused or renumbered"). The same principle implicitly extends to §3 numbering.
- §10c.1 Amendment 2 is the authoritative narration; a curious reader chasing §3.9 will find §10c.1 within one cross-reference.
- The v0.2.3 change-log entry (line 29) names the §3.9 deletion as load-bearing.

**Recommended fix (truly minor, not gating lock):** at §3.7 or §3.8 add one parenthetical: *"(§3.9 was deleted in v0.2.3; see §10c.1 Amendment 2. SPEC-018 section numbers, like AC numbers, are stable once assigned; the §3.9 gap is intentional.)"*. This is a 25-word polish that future-proofs §3-numbering archaeology. Defer to v0.3 housekeeping pass if v0.2.3 lock is fired.

**Not blocking lock.** This is the exact category of narrative debt that the §10c.1 discipline rule prevents from compounding; the deletion is named in five other sites already.

---

## First-time-reader test result (re-run on v0.2.3)

**Reader:** Cline integrator, never read SPEC-018, opens v0.2.3 to answer "does this work for my multi-turn coding agent?"

**Result:** PASS.

- Line 3 Status line is still audit-jargon (`0.2.3 (2026-06-27, blind-spot absorption — Path (a) §3.9 deletion + §10c.1 discipline rule + 9 mechanical edits)`), but the Quick orientation block at lines 7-17 catches the reader before the change log.
- Line 12 delivers the answer in one sentence: **"v0.2 SHIPS NOW: Cline drop-in works. Anchor framework = Cline... 4 deliverables: multi-turn provider acceptance, token-incremental streaming, `tool_call_id` validation, raised byte cap."** A Cline integrator can stop reading after line 12 with confidence and follow the §10d.1 / §10d.4 / §10d.6 / §10d.7 pointers if they need IMPL detail.
- Line 13 explicitly names what is DEFERRED to v0.3 (registry, full prompt-echo guard, structured malformed signal, framework matrix). A reader using Aider or OpenCode now knows their framework is "expected-compatible observation" not "v0.2-gated."
- Line 17 anchors the money-path invariant with concrete file:line citations. A PR reviewer doing a 60-second skim now has the answer to "does v0.2 preserve settlement protection?"
- The reader does not need to scroll past line 17 to make a go/no-go decision.

**Comparison to prior (v0.2.2) result:** v0.2.2 returned PARTIAL FAIL because the top 100 lines failed to surface "Cline drop-in works." v0.2.3 surfaces this in line 12 (within the top 20 lines). The fix is over-delivered relative to the prior recommendation.

## SPEC-archaeology test result (re-run on v0.2.3)

**Reader:** future-Claude (or future-codex), 6 months from now, asked to write an IMPL prompt for v0.2.3.

**Result:** PASS.

- The Quick orientation block at line 11 cites the v0.1.5 lock commit (`9e6f089`) explicitly — a future-Claude can `git show 9e6f089` to verify locked content.
- Line 12 enumerates the 4 v0.2 deliverables in order. Line 13 enumerates the 3 v0.3-deferred items. Together these compress the v0.2 vs v0.3 scope reconstruction from prior "15 minutes of stacked change-log reading" to ~30 seconds.
- §10c.1 Amendment log (lines 703-705) provides the canonical list of all locked-invariant amendments in v0.2 (Amendment 1 = registry deferral, Amendment 2 = §3.9 deletion). A future-Claude inheriting a v0.3 SPEC author role knows precisely which invariants were amended and the discipline rules they must follow.
- AC-22 (line 566) explicitly states AC-number stability. The pattern is now established for both AC numbers and §-section numbers (modulo the minor m-1 above about §3.9).
- §10a reader note (line 646) prevents a future-Claude from misreading §10a's 7-item list as v0.2 commitments.

**Comparison to prior (v0.2.2) result:** v0.2.2 was PASS with friction (~15 minutes to reconstruct lock state). v0.2.3 is PASS with negligible friction (~2 minutes) because the Quick orientation + §10c.1 amendment log together provide the complete lock-state mental model in two SPEC sites.

## PR-reviewer test result (re-run on v0.2.3)

**Reader:** security reviewer, asked to assess "does v0.2.3 break any v0.1 or v0.2.x guarantee?" by reading SPEC + change-log alone.

**Result:** PASS.

- The Quick orientation block at line 15 names lock-amendment precedent up front with forward-reference to §10c.1.
- §10c forward-compatibility invariant is unchanged. The `id` value format protection (line 672) is unchanged. The cap invariant (line 688) is unchanged. v0.2.3 adds NO new amendments to v0.1.x-locked clauses; the only v0.2.3 amendment (§3.9 deletion) is to a v0.2.1-introduced clause, not v0.1-locked content.
- The §10c AMENDED v0.2.3 paragraph (line 686) and the §10c.1 Amendment 2 entry (line 705) consistently narrate the residual risk (same-family echo attack) and the mitigation (deferred to v0.3 full guard). A reviewer can verify the discipline (a)-(d) rules are satisfied for Amendment 2 by inspection.
- The AMENDED v0.2.0/v0.2.1 paragraph (line 684) for Amendment 1 is unchanged from v0.2.2; reviewer can verify the discipline rules apply equally.
- A security reviewer doing pre-merge review now has the complete amendment history in one place (§10c.1) without having to read all 1000+ SPEC lines.

**Comparison to prior (v0.2.2) result:** v0.2.2 was PASS only after reading the v0.2.1 change-log prose at line 25 to find the amendment-discipline rule. v0.2.3 is PASS by §10c.1 inspection alone. The prior MEDIUM-severity gap is closed.

---

## Verdict justification

**READY TO LOCK on the narrative lane.** 0 CRITICAL + 0 HIGH + 0 MEDIUM. The single m-1 (§3.9 ghost in §3 numbering) is advisory polish, not a lock blocker.

Justification:

1. **All three reader tests now PASS** on v0.2.3 where one FAILED (first-time-reader) and two PASSED-with-friction (SPEC-archaeology, PR-reviewer) on v0.2.2.
2. **Every prior-round narrative finding is CLOSED with evidence cited.** Quick orientation block closes H-1 + M-1; §10c.1 closes M-2; §10a reader note closes M-3.
3. **v0.2.3 fresh additions surface no new narrative defects** that meet MEDIUM-or-higher severity. The §10c.1 discipline rule strengthens narrative coherence rather than introducing new ambiguity. The §3.9 deletion is honestly narrated at six SPEC sites with consistent wording.
4. **The §3.9 deletion is the right call.** v0.2.3's narrative does NOT pretend prompt-echo is mitigated; it explicitly says v0.2 ships without prompt-echo mitigation and v0.3 owns the full guard. The Quick orientation block (line 13) and §10d.8 (line 976) both reinforce this. A reader cannot accidentally conclude v0.2 has prompt-echo protection.
5. **Lock-amendment precedent is now structurally protected.** §10c.1 with enumerated amendment log + future-version obligation means v0.3 SPEC author cannot silently amend v0.2 invariants without satisfying (a)-(d) and appending to the log. The pattern compounds well across versions.

**Recommendation:** LOCK v0.2.3 as the v0.2 lock candidate. If all 6 r4 lanes return 0/0/0, fire the SPEC PR.

If the m-1 polish (§3.9-ghost note in §3) is wanted before lock, it is a single-line addition; otherwise defer to v0.3 housekeeping pass.

---

## Open Questions

None. (Prior Q-1 about Status-line update was a process question; the Status line at line 5 still reads "Draft — codex 4-lane r3 0/0/0; Claude blind-spot pass absorbed in v0.2.3; pending r4 confirmation." If r4 returns 0/0/0/0/0/0, the lock-finalization step should update this to "Locked v0.2.3 (codex-4-lane r3 0/0/0 + Claude blind-spot pass + codex-4-lane r4 defensive 0/0/0 + Claude narrative r2 0/0/0)." That is a lock-finalization mechanical step, not a narrative defect.)

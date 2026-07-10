# SPEC-018 v0.2.2 — Narrative Blind-Spot Audit

**Date:** 2026-06-27
**Reviewer:** Claude narrative analyst blind-spot pass (post codex 4-lane r3 0/0/0)
**Verdict:** READY TO LOCK (with 1 HIGH polish strongly recommended, 3 MEDIUM advisory, 2 minor, 1 Q)

## Tally: C/H/M/m/Q

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 1 |
| MEDIUM | 3 |
| minor | 2 |
| Q | 1 |

The single HIGH is a reader-experience finding, not a normative defect: codex correctly verified internal consistency in r3, but the top-of-document layering does not give a first-time reader (Cline integrator, security PR reviewer) the orientation they need in the first 100 lines. The SPEC is currently navigable only by a reader who already knows the v0.1.5 → v0.2.0 → v0.2.1 → v0.2.2 amendment lineage.

## Findings (severity-ordered)

---

### H-1 — Three stacked v0.2.x change-log entries plus four v0.1.x entries push the scope section past line 54; first-time-reader test fails

**Severity:** HIGH (reader experience — costs every new reader real time)
**SPEC location:** lines 7–52 (change log block) → §1 Scope starts at line 54
**Reader/category:** READER 1 (Cline integrator) + READER 2 (PR reviewer); NARR — opening clarity

**What the SPEC does:** the front matter is correctly stacked newest-first (v0.2.2 deltas → v0.2.2 prose → v0.2.1 deltas → v0.2.1 prose → v0.2.0 deltas → v0.2.0 prose → v0.1.5 → v0.1.4 → v0.1.3 deltas → v0.1.3 prose → v0.1.2 → v0.1.1 → v0.1), totaling ~46 lines before §1 begins. Each historical entry is dense, audit-trail-flavored prose ("Code lane round-5 caught the single residual MEDIUM…", "Critic adversarial-verifier lane found 3 lock-blocking HIGH issues…").

**What a real reader does:**
- A Cline integrator opening this file lands on **line 3** (`Version: 0.2.2 (... r2 absorption — AC-46 unknown-hash semantics + prompt_echo_blocked code domain + 5 mechanical edits)`). The version-suffix phrase is audit-jargon ("r2 absorption", "AC-46 unknown-hash semantics") — they do not know what to do with this.
- They scroll down looking for "does this work for Cline yet?" and hit `v0.2.2 buyer-visible deltas` at line 9 — three bullets, all about model-hash observation and aggregate caps. **None of the three v0.2.2 buyer bullets answer "does multi-turn Cline work in v0.2.2."** The actual answer ("yes, v0.2 is the narrow Cline drop-in release") lives ~20 lines below in the v0.2.0 bullets.
- They scroll further and the v0.1.5/v0.1.4/v0.1.3 historical entries are 100% audit-process prose ("Code r5 verified all r4 absorptions otherwise CONFIRMED…"). For a first-time reader, this is pure noise that delays the moment they reach the §1 product framing to roughly line 54.
- A PR reviewer doing pre-merge review wants to answer "does v0.2.2 break any v0.1 guarantee?" The honest answer is in `§10c` ~line 651 + `§10a` AMENDED paragraph ~line 666, requiring the reviewer to read all ~650 lines of intervening content to get to it.

**What the reader concludes / where comprehension breaks:**
- A Cline integrator scanning the top 100 lines cannot tell that v0.2 IS "Cline drop-in works." They read three layers of buyer-visible-deltas in newest-first order and the most important one (v0.2.0 — "Cline drop-in is the v0.2 release") is the third one they encounter. By the time they reach it, they have already absorbed a paragraph about `null`-vs-hex `model_hash_observed` semantics that is irrelevant to their decision.
- A future-Claude doing IMPL-prompt archaeology has to read 7 stacked change-log entries to construct a mental model of the lock state. The v0.1.5 entry is locked content; v0.2.0+ amend it. There is no single sentence that says "if you are integrating against v0.2.2, your normative obligations are: AC-1 through AC-24 (locked) AND AC-25 through AC-55 (v0.2-additive); §10d supersedes §10a for v0.2 scope."

**Recommended fix (minimal, polish-only — not blocking lock):**

Insert a **single 4–6 line orientation block immediately after the Status line and before the change log**, e.g.:

```
## Quick orientation (read this if v0.2.2 is your first encounter with SPEC-018)
- **What v0.2 is:** the narrow "point Cline at macprovider and complete a real multi-turn coding session" release. Cline is the release-gate framework; v0.2 is not yet a general multi-framework certification.
- **Locked content:** §2-§10b + AC-1 through AC-24 are v0.1.5-locked and unchanged in v0.2.
- **v0.2 additive content:** §3.8, §3.9, §8.4.1/.2/.3, §10c amendments, §10d, AC-25 through AC-55. These supersede the §10a seven-item v0.2 target list for v0.2.0 scope determination (see §10d.0 reader note).
- **Lock-amendment precedent:** v0.2.1 explicitly amends two locked v0.1.3 clauses (registry fail-closed → deferred to v0.3; duplicate §3.7 → renumbered §3.8). Locked invariants are NOT immutable but require explicit named amendment. v0.2.2 introduces no new amendments — only mechanical absorption of r2 findings.
- **Reader flow for IMPL:** §1 → §1.1 → §10d → AC-25 through AC-55.
```

This single insertion solves three reader problems at once: (a) Cline integrator gets the "yes, v0.2 is for you" answer in 30 seconds; (b) PR reviewer gets the lock-amendment lineage explicitly; (c) future-Claude IMPL-prompt author gets a navigation index without having to reconstruct it from 7 change-log entries. **Without this block, every first-time reader pays the cost of inferring it.** Codex r3 cannot catch this because each change-log entry is internally consistent — the gap is in cross-entry orientation.

---

### M-1 — v0.2.2 "buyer-visible deltas" are three bullets about edge cases, not v0.2.2's actual scope

**Severity:** MEDIUM
**SPEC location:** lines 9–12 (v0.2.2 buyer-visible deltas)
**Reader/category:** READER 1 (Cline integrator); NARR — buyer-visible delta lists, contradiction risk

**What the SPEC says:**
```
**v0.2.2 buyer-visible deltas (read this if you're skimming):**
- AC-46 now requires `usage.macprovider_model_hash_observed` on every v0.2 provider response...
- `prompt_echo_blocked` is an internal plain-content fallback/log reason in v0.2, not a buyer-visible HTTP/SSE error-envelope code.
- Aggregate request-cap and linear-validation release gates are now explicit in AC-50 through AC-55...
```

**What the reader concludes:** the three bullets read as "v0.2.2 is about fixing three obscure edge-case ambiguities from r2 audit findings." This is technically accurate but narratively misleading. The framing implies v0.2.2 is a tactical patch on v0.2.1; a Cline integrator skimming would conclude "v0.2.2 doesn't matter to me." That is wrong: v0.2.2 is the **lock candidate** for the narrow Cline drop-in slice. The bullets do not say so.

Cross-check: the v0.2.1 bullets (lines 16–24) cover 7 substantive product-visible deltas (registry deferral, prompt-echo guard, final-close protocol, error envelopes, release evidence split, streaming-mode header, DoS bounds). The v0.2.0 bullets (lines 27–34) cover the "Cline drop-in" headline. Reading top-to-bottom (newest first), a reader gets edge cases → product → mission, which is backwards.

**No contradiction across the three lists** (verified: AC-46 is only in v0.2.2; `prompt_echo_blocked` is consistently demoted in v0.2.2; aggregate caps are introduced in v0.2.1 prose and made AC-explicit in v0.2.2). Narrative ordering is the issue, not factual divergence.

**Recommended fix:** prepend a 1-line lede to the v0.2.2 bullets: *"v0.2.2 is the codex-4-lane convergence + Claude blind-spot pass lock candidate for the narrow Cline drop-in v0.2 release. The buyer-visible deltas vs. v0.2.1 are:"* — context, then the three bullets. Optionally collapse all three v0.2.x bullet lists into a single hoisted "**v0.2 buyer summary**" block that reads top-down chronologically (v0.2.0 mission → v0.2.1 hardening → v0.2.2 absorbed audit findings).

---

### M-2 — §10c "AMENDED v0.2.0/v0.2.1" paragraph is the only place lock-amendment precedent is explained, and a reader who skips it sees contradictory MUSTs

**Severity:** MEDIUM (PR-reviewer test partially fails)
**SPEC location:** §10c lines 664–666
**Reader/category:** READER 2 (PR reviewer) + READER 3 (future-Claude IMPL author); NARR — lock-amendment honesty

**What the SPEC says:**
- §10c lines 664–665 carry the v0.1.3-locked MUST: *"The v0.2 model-hash → family registry MUST require unknown-or-unregistered model_hash to fail closed for tool-call synthesis..."*
- §10c line 666 then says: *"AMENDED v0.2.0/v0.2.1: the v0.1.3-locked clause requiring v0.2 to enforce unknown-model_hash fail-closed via a registry is amended to defer registry to v0.3."*

**What a PR reviewer sees:** a normative MUST followed by a paragraph that amends it. The amendment is honestly narrated — rationale + precedent + what replaces it (§3.9 + §8.4.2 + AC-46) — and codex-r3 correctly verified internal consistency. But a security PR reviewer doing pre-merge review reads MUSTs as immutable contracts. The phrase "first such amendment in SPEC-018" (line 25, v0.2.1 prose) buries the precedent in a paragraph titled "v0.2.1 (2026-06-27, r1 absorption)." A reviewer who lands on §10c without having read the v0.2.1 prose at line 25 sees one MUST and one AMENDMENT and has no way to assess: **is the amendment process itself sound? What stops future v0.2.x from amending any other locked invariant?**

**The honest answer is in the SPEC** — "locked invariants are NOT immutable, but they require an explicit named amendment with rationale" — but it appears only at line 25, inside the v0.2.1 change-log prose. It is not in §10c, not in §1, not in any "How to read this SPEC" section.

**Why this matters for v0.3 archaeology:** A v0.3 SPEC author will inherit §10c's `function.arguments` cap invariant (line 668: *"Future v0.2.x versions MUST NOT lower either cap..."*). If they conclude "well, v0.2.1 amended a v0.1.3 MUST, so v0.3 can amend any v0.2 MUST," that is the wrong conclusion — the v0.2.1 amendment was specifically named, with rationale, before lock. The amendment-discipline rule needs to be in §10c itself, not in the change-log prose.

**Recommended fix:** promote the amendment-precedent sentence from the v0.2.1 change-log entry into a `§10c.1 Lock-amendment discipline` subsection (or a single paragraph at the top of §10c). One paragraph, 3–4 sentences:

> Locked invariants in this SPEC are normatively binding but not immutable. They MAY be amended by a later version subject to three discipline rules: (1) the amendment MUST be explicitly named in the amending version's change-log with rationale, (2) the amended §10c clause MUST carry an "AMENDED vN.M" prefix paragraph at the lock-clause site so a reader of §10c sees the amendment lineage in-place, and (3) the amendment MUST replace the amended obligation with named alternative mitigations (not a silent scope cut). Precedent: v0.2.1 amended the v0.1.3-locked model-hash registry fail-closed clause, deferring registry curation to v0.3 and replacing it with §3.9 + §8.4.2 + AC-46.

This costs 100 words and closes the PR-reviewer test cleanly.

---

### M-3 — §10a vs §10d two-timeline contradiction is reader-noted but not fully resolved

**Severity:** MEDIUM
**SPEC location:** §10a lines 632–639 (seven items, all "v0.2 deliverable") + §10d.0 line 676 ("§10d supersedes §10a's earlier seven-item v0.2 target list...") + §10d.8 lines 930–934
**Reader/category:** READER 3 (future-Claude IMPL author); NARR — §10a contradiction handling, scope-narrowing honesty

**What the SPEC does:** §10a still reads as if 7 deliverables are v0.2 targets ("Each item below is a v0.2 deliverable that gates the 'actual Ring-1 product' release..."). §10d.0 then says §10d supersedes §10a for v0.2.0 scope. §10d.8 explicitly defers #2 (registry), #3 (prompt-echo full version), and #5 (structured signal) to v0.3.

**What a reader experiences:** §10a is **locked v0.1.5 content** by structure — the "v0.2 deliverable" framing was true at v0.1.5 lock time when 7 items WERE the v0.2 plan. v0.2.0 narrowed to 4. The SPEC's solution is to leave §10a alone and add §10d with a reader note ("§10a is preserved as v0.1.5 locked-content historical reference" at line 676).

**The honest answer the SPEC is trying to convey:** v0.2 was deliberately scope-narrowed — not engineering-limited. §10d.0 narrates this ("narrow Cline-drop-in v0.2.0 product scope") and the §10c amendment paragraph reinforces it. **But §10a itself does not signal it.** A reader hitting §10a cold (say, via the §1.1 #4 cross-reference "closed in §10a as a v0.2 deliverable") reads 7 items framed as commitments. They have to remember the §10d.0 note 30+ lines later to know 3 of the 7 are no longer v0.2 commitments.

**Recommended fix:** add a single sentence at the top of §10a heading itself:

```
### 10a. Required for full Ring-1 product (v0.2 normative targets as of v0.1.5 lock — see §10d for the v0.2.0+ narrowed scope: #2, #3, #5 deferred to v0.3)
```

Or, more visibly, a 1-line italic note immediately under §10a:

```
*Reader note: §10a enumerates the v0.2 target list as of v0.1.5 lock. The v0.2.0 release narrowed scope to four deliverables (#1, #4, #6, #7); #2 / #3 / #5 are deferred to v0.3 per §10c amendment and §10d.8. §10a is preserved for lock-discipline historical reference.*
```

This honesty also serves the **scope-narrowing-honesty** check (audit prompt #9): the v0.2 scope cut was deliberate strategic narrowing for faster Cline drop-in, not engineering inability. The SPEC narrates this in §10d.0 ("Cline is the v0.2 anchor framework because (a) ~1M+ VS Code marketplace installs..."). Adding the reader note at §10a connects that strategic narrative to the actual deferred-items list.

---

### m-1 — §3.8 doc-order editorial note works, but §3.7 lands as a "stub after the long thing"

**Severity:** minor
**SPEC location:** §3.8 lines 226–230 (editorial note) + §3.7 at line 307 (after §3.8 + §3.9)
**Reader/category:** NARR — §3.8 doc-order check

**What the SPEC does:** lines 228–230 carry the r2-added editorial note explaining §3.8 physically precedes §3.7 to avoid moving locked content.

**Reader experience:** the note works for a careful reader. But §3 reading flow is: §3.1 (family table) → §3.2 (modelID match) → §3.3-§3.5 (parsing rules) → §3.6 (multi-family priority) → §3.8 (~80 lines of multi-turn rendering, v0.2 additive) → §3.9 (prompt-echo guard, v0.2.1 additive) → §3.7 (12 lines, locked v0.1.5 "Adding a new family"). After reading 80+ lines of v0.2 additive content, hitting locked §3.7 feels like a tail stub.

The editorial note solves the **lock-discipline** concern (don't move locked content) and codex correctly verified this is internally consistent. The narrative cost is that the locked §3.7 invariant ("New rows MUST be appended... major SPEC-018 version bump for substring overlap") is in the structurally weakest reader position. A reader doing v0.3 grammar-family work might miss it.

**Recommended fix (truly minor):** in §3.7, prepend one phrase: *"§3.7 is locked v0.1.5 content; v0.2 additive §3.8 and §3.9 above precede it in document order per §3.8 editorial note. The row-ordering invariant below applies to all future SPEC-018 versions, including v0.3 registry-driven family additions."*

This links the locked content forward to v0.3 work explicitly.

---

### m-2 — AC-22 placeholder ghost

**Severity:** minor
**SPEC location:** AC-22 at line 552
**Reader/category:** NARR — AC numbering jumps

**What the SPEC says:** *"AC-22 (formerly mixed-sentinel fallback): REMOVED in v0.1.3... AC-22 is intentionally left as a placeholder so that downstream SPEC consumers tracking AC numbers do not silently re-index."*

**Reader experience:** for a Cline integrator scanning AC-1 through AC-55, AC-22 reads as a deliberate gap. The change-log explains it (v0.1.3 entry, line 49). The placeholder note in AC-22 itself is sufficient.

**Minor concern:** AC numbering goes AC-1 → AC-24 (locked v0.1.5), AC-25a/AC-25b → AC-49 (v0.2.0/v0.2.1), AC-50 → AC-55 (v0.2.2). The three groupings are logical. AC-22's placeholder is the only structural anomaly. A future v0.3 might be tempted to renumber; the SPEC should pre-empt this. **Recommended fix:** in AC-22 placeholder, add *"AC numbers are stable across SPEC-018 versions; renumbering is non-compliant."* If this is already implicit via lock discipline, no edit needed.

---

### Q-1 — Where does the v0.2.2 lock cite live after lock?

**Severity:** Q (open trade-off, not defect)
**SPEC location:** N/A (process question)

**Observation:** Once v0.2.2 locks via this Claude blind-spot pass + codex 0/0/0, the SPEC body should arguably name v0.2.2 as the lock version explicitly. Line 5 currently says *"Status: Draft — extends locked v0.1.5; v0.2.2 absorbs round-2 audit findings on top of v0.2.1's explicit amendments... pending round-3 four-lane audit."* That status string is stale once r3 lands 0/0/0 (which it has). **Question:** does the IMPL prompt for v0.2.2 update the Status line to *"Locked v0.2.2 (codex-4-lane r3 0/0/0 + Claude blind-spot pass)"*, or does that happen in a subsequent housekeeping pass? Not a defect — just confirming the lock-finalization step exists in the workflow.

---

## First-time-reader test result

**Reader:** Cline integrator, never read SPEC-018, opens v0.2.2 to answer "does this work for my multi-turn coding agent?"

**Result:** PARTIAL FAIL.

- The first 50 lines (header + change log) do **not** give them the answer. Line 3 version string is audit-jargon. Lines 9–12 (v0.2.2 buyer bullets) are about edge cases, not "Cline works now." Lines 16–24 (v0.2.1) and 27–34 (v0.2.0) eventually answer the question, but only if the reader keeps scrolling past 34 lines of stacked deltas.
- The actual orientation arrives at **§1 line 54** ("first-turn ... certificate") and §1.1 lines 75–84 (the 5 v0.1 limitations list). Lines 75–84 are excellent — they correctly anchor "v0.1 first-turn-only; v0.2 closes multi-turn." This is the v0.1.5 narrative inheritance.
- For v0.2, the corresponding orientation is in §10d.0 line 676 ("§10d supersedes §10a..."), almost 600 lines below.
- **A Cline integrator reading only the top 100 lines would conclude:** "this SPEC is in heavy flux with three layered amendments; I'm not sure if multi-turn works." That conclusion is wrong — multi-turn DOES work in v0.2 — but the top 100 lines do not surface that.
- **Fix:** the H-1 quick-orientation block resolves this in 4–6 lines.

## SPEC-archaeology test result

**Reader:** future-Claude (or future-codex), 6 months from now, asked to write an IMPL prompt for v0.2.2.

**Result:** PASS with friction.

- The SPEC is *internally* sufficient — file:line citations are precise, AC coverage is dense, §10d deliverable-numbered subsections map to design synthesis IDs. A future-Claude could write a correct IMPL prompt.
- **Friction:** reconstructing the lock state requires reading 7 stacked change-log entries to figure out which AC numbers are locked-v0.1.5 vs v0.2-additive. The §10d.0 reader note + §10c amendment paragraph are correct but spread across 600+ lines.
- A future-Claude landing at AC-25a (line 560) needs to know it depends on §3.8 (line 226), §10d.1 (line 732), and AC-46 (line 606). The cross-references exist but require chasing.
- **Fix:** the H-1 orientation block plus M-3 §10a reader-note inline would compress reconstruction time from ~15 minutes to ~2 minutes.

## PR-reviewer test result

**Reader:** security reviewer, asked to assess "does v0.2.2 break any v0.1 guarantee?" by reading SPEC + change-log alone.

**Result:** PASS with one HIGH-severity gap closed only by reading the v0.2.1 change-log prose.

- §10c is the right place to answer this question and it does the work correctly: additive-only forward-compat invariant, `id` value format protection, cap invariants, AMENDED paragraph for the registry deferral.
- **Gap:** the lock-amendment discipline rule (named amendment + rationale + alternative mitigations) lives at **line 25** inside the v0.2.1 change-log prose, NOT at §10c where the security reviewer looks. A reviewer who jumps straight to §10c sees the AMENDED paragraph but cannot assess: "is this a one-off, or are all locked MUSTs negotiable?"
- **Fix:** M-2 promotes the discipline rule into §10c.1 (or a §10c paragraph). 100 words.

After that single fix, a PR reviewer reading SPEC + change-log can confidently answer "no v0.1 guarantee is silently broken; one v0.1.3-locked clause is explicitly amended via §10c.1 discipline with named alternative mitigations (§3.9 + §8.4.2 + AC-46)." That is the right outcome.

---

## Verdict justification

**READY TO LOCK** with H-1 strongly recommended as polish before lock and M-1 / M-2 / M-3 advisable for narrative hygiene.

Justification:
1. **Codex r3 0/0/0 across 4 lanes is real:** the SPEC has no normative defects, no internal contradictions, no security/architectural/PD gaps. The IMPL prompt that a future-Claude writes against v0.2.2 will produce correct code.
2. **The HIGH finding is reader-experience, not normative:** H-1 is a layering problem (7 stacked change-log entries before §1) that costs every new reader 5–15 minutes of orientation. It does not produce incorrect IMPL or mislead. A 4–6 line orientation block fixes it.
3. **The 3 MEDIUMs are narrative-coherence improvements** that close the PR-reviewer test cleanly (M-2), make the deliberate scope narrowing honest at the §10a site (M-3), and prevent the v0.2.2 buyer bullets from misleading a skimmer about v0.2.2's role as the lock candidate (M-1). None of them block lock.
4. **The v0.1.5 narrative-audit precedent** (`SPEC-018-product-narrative-blindspot-audit.md`) flagged 5 minors and 2 Qs and returned READY TO LOCK. v0.2.2's 1 HIGH + 3 MEDIUM tally is higher than v0.1.5, but the SPEC has also grown ~3x in scope (added v0.2.0 / v0.2.1 / v0.2.2 layers + 31 new ACs). Per-line finding rate is comparable; the HIGH is specifically a v0.2 multi-layer artifact that did not exist at v0.1.5 single-layer lock.
5. **None of the findings reflect work codex missed:** all are cross-section narrative flow, version-layer navigation, lock-amendment-discipline-in-the-§10c-site, and reader-orientation. These are the exact categories the audit prompt named as codex blind spots.

**Recommendation:** Lock v0.2.2 as-is for IMPL purposes (the SPEC is correct). For polish, fold H-1 (quick-orientation block) + M-2 (§10c.1 lock-amendment discipline) + M-3 (§10a reader note) into a small v0.2.3 narrative polish pass before IMPL fires, if the polish budget allows. M-1, m-1, m-2 are nice-to-haves.

If polish-pass is not feasible: lock v0.2.2 as-is, file H-1 + M-2 + M-3 as named follow-ups for v0.3 SPEC author to land at v0.3.0 (since v0.3 will add another change-log layer and the orientation problem compounds).

---

## Open Questions

- [ ] Confirm v0.2.2 Status line is updated to "Locked v0.2.2 (codex-4-lane r3 0/0/0 + Claude blind-spot pass)" as part of lock-finalization (Q-1). — Without this, line 5 reads stale as "pending round-3 four-lane audit" after r3 returned clean.
- [ ] Decide whether H-1 / M-2 / M-3 polish lands as v0.2.3 narrative pass before IMPL or as v0.3.0 SPEC-author follow-up. — Affects IMPL-prompt reader experience but not IMPL correctness.

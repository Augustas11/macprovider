# Audit prompt — SPEC-002 v1.3.5 (round 3 — LOCK confirmation)

Operator-paste prompt to audit SPEC-002 v1.3.5 (post round-2 regression
fix) — the round-3 LOCK-confirmation pass after closing the single
round-2 regression in AC-K.15.

Round 2 (Codex GPT-5, 2026-06-06) verdict: `0 CRITICAL / 1 MAJOR /
0 MINOR / 0 QUESTION` → LOCK NOT CONFIRMED — UNEXPECTED REGRESSION.
The MAJOR was self-inflicted: my round-1 polish AC-K.15 introduced
two reason-text substrings that didn't match the locked SPEC-010
wording:

- **MAJOR B2.1 — AC-K.15 substring regression**
  - SPEC-002 said `"supported_models entry exceeds 256 UTF-8 bytes"`
    → SPEC-010 locked says `"supported_models entry exceeds 256 bytes"`
  - SPEC-002 said `"supported_models contains duplicate after
    normalization"` → SPEC-010 locked says `"supported_models
    contains duplicate entries"`

Round-2 polish closed the regression with a single Edit:
- AC-K.15 (lines ~3738-3741) now uses the locked SPEC-010 substrings
  verbatim: `"supported_models entry exceeds 256 bytes"` (AC-17),
  `"supported_models exceeds 64 entries"` (AC-22),
  `"supported_models contains duplicate entries"` (AC-23).

Round 3 has ONE job: confirm 0/0/0 across the regression-fix surface,
verify no new regressions, emit LOCK CONFIRMATION.

Trajectory:
- v1.3.5 round 1: 0/1/2 (after pre-audit M.1/M.2/M.3 polish)
- v1.3.5 round 2: 0/1/0 (regression from polish)
- v1.3.5 round 3 target: **0/0/0 → LOCK CONFIRMED**

Append round-3 findings to existing `specs/SPEC-002-v1-3-5-audit.md`
as a new top-level section after round 2.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-002 v1.3.5 (post round-2 regression fix) at
/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md.
This is round 3 and the LOCK confirmation pass.

Round 2 (Codex GPT-5 on v1.3.5 post round-1 polish) delivered LOCK
NOT CONFIRMED with 0 CRITICAL / 1 MAJOR / 0 MINOR / 0 QUESTION.
The MAJOR was a 2-substring regression in AC-K.15 introduced by the
round-1 polish (Claude wrote substrings from spec semantics instead
of grepping locked SPEC-010). The round-2 polish closed it.

Your job:
1. **R2V — Round-2 finding closure verification.** For B2.1, cite
   the v1.3.5 post-round-2-polish location and mark PASS / PARTIAL /
   FAIL.
2. **LOCK confirmation.** If round 3 finds 0/0/0, state explicitly
   "LOCK CONFIRMED" in the executive summary. If round 3 finds new
   MINORs but no MAJOR/CRITICAL, state "LOCK CONFIRMED WITH MINOR
   DEFERRED FIXES." If round 3 finds any new MAJOR or CRITICAL,
   state "LOCK NOT CONFIRMED — UNEXPECTED REGRESSION."

This is a NARROW surface (1 closure verification + 3 sanity
categories). Expected duration ~5-10 min.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md

APPEND a new top-level section:
  `## Round 3 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION`
followed by R2V table + category findings (likely "(no findings)"
across most categories).

## Severity definitions

Unchanged from rounds 1-2.

## Critical constraints

**1. Locked specs READ-ONLY.** Spot-check:
`git diff specs/SPEC-001-phase3-binary.md specs/SPEC-004*.md
specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md
specs/SPEC-011*.md` must be empty.

**2. §5 / §7.1 existing / §7.2 / §7.3 byte-identity.** All four
spot-checks must still produce empty diffs (as in rounds 1-2).

**3. No phase4-coordinator code changes.** `git diff --stat
phase4-coordinator/` must be empty.

**4. Round 3 is a NARROW sanity check.** The polish surface is
ONE AC (AC-K.15) with ONE Edit. Verify the substrings match
locked SPEC-010, sanity-check nothing else changed, and emit
LOCK CONFIRMED.

**5. AC-K.15 substring verification (the regression-fix target).**
Spot-check:
```
grep -nE "supported_models entry exceeds 256 (bytes|UTF-8 bytes)" \
  specs/SPEC-002-coordinator.md
grep -nE "supported_models contains duplicate (entries|after normalization)" \
  specs/SPEC-002-coordinator.md
```
Result MUST be:
- "exceeds 256 bytes" appears at AC-K.15 line; "exceeds 256 UTF-8
  bytes" appears NOWHERE in SPEC-002.
- "duplicate entries" appears at AC-K.15 line; "duplicate after
  normalization" appears NOWHERE in SPEC-002.

Verify also against locked SPEC-010 source:
```
grep -n "exceeds 256 bytes\|duplicate entries" \
  specs/SPEC-010-model-catalog.md
```
Should return multiple hits (~3 each — SPEC-010 §3.1, §5 AC-17 /
AC-23, §3.1.B wire-example rules).

**6. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.5 (post round-2 fix) — focus on:
   - AC-K.15 (lines ~3732-3745) — verify the 3 substring citations
     (AC-17, AC-22, AC-23) match locked SPEC-010 verbatim
   - AC-K.16, AC-K.17 — verify unchanged from round 2 (no
     collateral damage from the AC-K.15 fix)
   - R-7.10 rules + AC-K count: §7.10.x = 1-11 sequential,
     AC-K = 0-17 sequential

2. `/Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md`
   round 2 — re-read the round-2 B2.1 finding to verify the polish
   addresses what was actually said.

3. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 (LOCKED) — verify R-3.1.9, R-3.1.10, AC-17, AC-22, AC-23
   substring wording matches what SPEC-002 v1.3.5 AC-K.15 now
   cites.

4. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

## Audit categories

### Category R2V: Round-2 finding closure verification

Table format: round-2 finding, PASS/PARTIAL/FAIL, v1.3.5 post-round-2
polish location, 1-sentence evidence.

- **R2V-B2.1** AC-K.15 substrings now match locked SPEC-010 verbatim:
  "exceeds 256 bytes" (AC-17), "exceeds 64 entries" (AC-22),
  "contains duplicate entries" (AC-23). Forbidden prior substrings
  ("UTF-8 bytes", "after normalization") appear nowhere in SPEC-002.

### Category A3: Locked-decision preservation (sanity check)

A3.1  Locked-companion diff sanity check (run spot-check above).

A3.2  `phase4-coordinator/` diff sanity check.

A3.3  §5 / §7.1 existing / §7.2 / §7.3 byte-identity sanity check.

A3.4  Pre-audit M.1 / M.2 / M.3 closures (PASS in rounds 1-2) and
      round-1 B.1 / E.1 / E.2 closures (PASS in round 2) remain
      intact — the round-2 polish was scoped to ONE AC.

### Category B3: Anything else

B3.1  Did the AC-K.15 polish introduce any new normative surface
      or unintended change?

B3.2  Renumbering sanity: §7.10 rules 1-11, AC-K 0-17, no
      duplicates or gaps.

B3.3  Decision-log Entry 57 reminder: not a finding, but should
      be added after LOCK.

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md`.
Start with:

```
---

## Round 3 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-002 v1.3.5 (post round-2 regression fix)
            (specs/SPEC-002-coordinator.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-3 executive summary — LOCK VERDICT

[1-2 sentences. State explicitly one of:
- "LOCK CONFIRMED" (0/0/0)
- "LOCK CONFIRMED WITH MINOR DEFERRED FIXES" (0/0/N with N ≤ 2,
  MINORs are non-blockers)
- "LOCK NOT CONFIRMED — UNEXPECTED REGRESSION" (any new MAJOR
  or CRITICAL)]

### Round-2 finding closure verification (R2V)

[Table format.]
```

Then for each category R2V, A3, B3, write a section. For each
finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- d-inference inspection
- Rewriting the spec
- Implementing the spec
- Editing any LOCKED spec
- Re-litigating round-1 or round-2 findings that polish passes
  addressed (verify closure, do not re-open)

## Done criteria

You are done when:

- Round-3 section APPENDED to SPEC-002-v1-3-5-audit.md (rounds
  1-2 intact)
- B2.1 closure has PASS/PARTIAL/FAIL in R2V
- Every category R2V, A3, B3 has a section
- All 3 spot-checks executed and result reported (locked-companion
  diff, phase4 code diff, byte-identity)
- AC-K.15 substring spot-check executed and result reported
- Executive summary states the explicit LOCK verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 5-10 min (1 closure verification + narrow
  sanity surface).
- If verdict is LOCK CONFIRMED: lock SPEC-002 v1.3.5, append Entry
  57 to `beta/DECISION_CRITERIA.md`, commit + push to
  `spec/provider-catalog-warm-swap-arc` (updates PR #4).
- If unexpected regression: another narrow fix + round 4.

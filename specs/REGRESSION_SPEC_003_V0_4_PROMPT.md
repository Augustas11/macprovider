# Regression check prompt — SPEC-003 v0.4 closing pass

Operator-paste prompt for **targeted regression check** of the v0.4
closing fixes (commit `71a4fad`). The round-2 auditor explicitly
recommended this in lieu of a full third audit round:

> "After those edits, the corpus should be ready for build planning
> without another full redistribution audit; a targeted regression
> check against this Round-2 section should be sufficient."

Scope: verify the four v0.4 fixes (CRITICAL-2.1 + MAJOR-2.1 +
MAJOR-2.2 + MINOR-2.1) are correctly applied AND no regressions
were introduced elsewhere. Much narrower than the prior audits.

Run with **Codex CLI**. Expected duration: **~15-20 min**.

Output: append a "Round 3 regression check" section to existing
`specs/SPEC-003-audit.md`. Verdict: READY TO BUILD or NEEDS REVISION.

Paste everything between the markers into a fresh Codex CLI session
rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are performing a targeted regression check on the SPEC-003 corpus
after the v0.4 closing fixes landed at commit 71a4fad. This is NOT a
full audit — it's a focused verification that the four prescribed
round-2 fixes are correct AND no regressions were introduced.

Spec versions to check:
  SPEC-001 v1.2.1 (commit 71a4fad — should be UNTOUCHED since 74cf00b)
  SPEC-002 v1.1.2 (commit 71a4fad)
  SPEC-003 v0.4   (commit 71a4fad)

The four prescribed fixes from the round-2 audit
(specs/SPEC-003-audit.md "Round 2 (v0.3) Audit Report" section):

  CRITICAL-2.1  SPEC-002 § 7.1 validation wording — accept optional
                endpoint_url, normalize absent to null
  MAJOR-2.1     SPEC-002 § 5 routing pseudocode — define
                quota_blocked_candidates explicitly
  MAJOR-2.2     SPEC-003 §§ 2 and 9 — reference SPEC-002 AC-11
                through AC-15 (not AC-14)
  MINOR-2.1     SPEC-002 dependency line — SPEC-001 v1.2.1

Plus one cosmetic finding flagged by the operator post-fix: SPEC-003
line 26 change-log entry has a self-referencing typo
("from AC-11 through AC-15 to AC-11 through AC-15"; the "from"
should say AC-11 through AC-14).

## Critical constraints (unchanged)

**1. Backward-compat invariant.** SPEC-001 v1.2.1 must be UNTOUCHED.
Verify via `git diff 74cf00b..71a4fad specs/SPEC-001-phase3-binary.md`
returning empty. Any diff = CRITICAL finding.

**2. d-inference clean-room.** Do not inspect d-inference source.

**3. Buyer API stability.** Zero observable change to
POST /v1/chat/completions, GET /v1/models, GET /healthz.

## Required reading (compact)

1. /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md
   — read the "Round 2 (v0.3) Audit Report" section, especially
   the four findings + recommendation.

2. /Users/augstar/macprovider-poc/specs/FIX_SPEC_003_V0_3_PROMPT.md
   — what the fix agent was instructed to produce. The fix
   directions are explicit; verify each was followed.

3. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md v1.1.2
   — focus on:
     Header (Depends on line)
     § 7.1 (FR-P2 validation wording)
     § 5 (routing pseudocode with quota_blocked_candidates)

4. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md v0.4
   — focus on:
     Header (version line)
     § 2 (companion AC range references)
     § 9 (build-complete gate AC range references)
     Change-log entry (cosmetic typo check)

5. Diff context (use git):
     git diff 74cf00b..71a4fad specs/SPEC-001-phase3-binary.md   # must be empty
     git diff 74cf00b..71a4fad specs/SPEC-002-coordinator.md
     git diff 74cf00b..71a4fad specs/SPEC-003-open-onboarding.md

You do NOT need to re-read SPEC-001 v1.2.1 in detail (it should be
untouched). Confirm via diff and move on.

## Regression check categories

### Category V: v0.4 fix verification

V.1  CRITICAL-2.1 closed?
     - § 7.1 validation language now distinguishes REQUIRED from
       OPTIONAL fields?
     - Absent endpoint_url normalization to null explicitly stated?
     - The wording would not cause v1.1.x binaries (which omit
       endpoint_url) to fail registration?
     CLOSED / PARTIAL / UNCLOSED.

V.2  MAJOR-2.1 closed?
     - pre_quota_candidates / quota_blocked_candidates defined in
       pseudocode?
     - all_filtered_by_quota symbol removed?
     - HTTP 429 vs HTTP 503 disambiguation: 429 only when 100% of
       pre-quota candidates are quota-blocked?
     - Retry-After header specified?
     CLOSED / PARTIAL / UNCLOSED.

V.3  MAJOR-2.2 closed?
     - SPEC-003 § 2 companion AC range says AC-11 through AC-15?
     - SPEC-003 § 9 build-complete gate says AC-11 through AC-15?
     - Stale v0.2 label updated to v0.4?
     - No remaining "AC-11 through AC-14" anywhere in SPEC-003?
       (Run grep.)
     CLOSED / PARTIAL / UNCLOSED.

V.4  MINOR-2.1 closed?
     - SPEC-002 "Depends on:" line says SPEC-001 v1.2.1?
     CLOSED / PARTIAL / UNCLOSED.

### Category D: SPEC-001 untouched

D.1  Run `git diff 74cf00b..71a4fad specs/SPEC-001-phase3-binary.md`.
     Empty? CRITICAL finding if any diff appears.

### Category R: Regression detection (narrow)

R.1  Diff SPEC-002 (`git diff 74cf00b..71a4fad
     specs/SPEC-002-coordinator.md`). Every changed hunk should
     correspond to V.1, V.2, V.4, or the change-log entry. Any
     other change = REGRESSION = MAJOR finding.

R.2  Diff SPEC-003 (`git diff 74cf00b..71a4fad
     specs/SPEC-003-open-onboarding.md`). Every changed hunk should
     correspond to V.3 or the change-log entry. Any other change =
     REGRESSION = MAJOR finding.

R.3  Verbatim backward-compat statement at SPEC-001 v1.2.1 lines
     20-38 still intact. (Trivially true if D.1 passes, but
     double-check character-by-character if D.1 fails.)

### Category C: Cosmetic

C.1  SPEC-003 change-log entry typo on line 26 (or wherever it is
     in v0.4): does it say `from "AC-11 through AC-15" to
     "AC-11 through AC-15"` (self-referencing)? If yes, MINOR
     finding to fix opportunistically (the "from" should be
     AC-11 through AC-14).

C.2  Any other cosmetic glitches introduced by the fix (broken
     markdown, stray whitespace, mis-aligned tables)? MINOR if
     present.

## Severity rubric (regression-check edition)

  CRITICAL — SPEC-001 touched (D.1 fails); backward-compat
             statement altered; one of V.1/V.2/V.3/V.4 marked
             UNCLOSED; regression detected by R.1/R.2.

  MAJOR    — V.1/V.2/V.3/V.4 marked PARTIAL; significant
             ambiguity introduced by fix.

  MINOR    — cosmetic typos (C.1, C.2); change-log readability.

  QUESTION — uncertain. Spell out the source-material gap.

## Output format

APPEND to /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md.
Do NOT overwrite. Append after the round-2 section, separated by
`---`.

Append this structure:

  ---

  # Round 3 (v0.4) Regression Check Report

  Auditor: <model + version>
  Specs checked at commit 71a4fad:
    SPEC-001 v1.2.1 (expected: untouched since 74cf00b)
    SPEC-002 v1.1.2
    SPEC-003 v0.4
  Reference: Round-2 report above + FIX_SPEC_003_V0_3_PROMPT.md
  Check completed: <UTC timestamp>

  ## TL;DR verdict
  READY TO BUILD | NEEDS REVISION

  ## Fix closure (round-2 findings)

  | ID | Round-2 issue | Round-3 verdict |
  |---|---|---|
  | CRITICAL-2.1 | § 7.1 optional field validation | CLOSED / ... |
  | MAJOR-2.1 | quota pseudocode undefined | CLOSED / ... |
  | MAJOR-2.2 | SPEC-003 AC range omits AC-15 | CLOSED / ... |
  | MINOR-2.1 | dependency line stale | CLOSED / ... |

  ## Diff scope verification

  - SPEC-001 v1.2.1 untouched: YES / NO
  - SPEC-002 diff stays within V.1/V.2/V.4 + change-log: YES / NO
  - SPEC-003 diff stays within V.3 + change-log: YES / NO

  ## New findings

  (Typically empty or 1-2 MINORs at this stage.)

  ### CRITICAL (N) — should be 0
  ### MAJOR (N) — should be 0
  ### MINOR (N)
  ### QUESTIONS (N)

  ## Recommendation

  If verdict READY TO BUILD: proceed to writing build prompts
  (BUILD_SPEC_001_V1_2_1_PROMPT.md, BUILD_SPEC_002_V1_1_2_PROMPT.md,
  BUILD_SPEC_003_V0_4_PROMPT.md). The audit cycle is complete.

  If verdict NEEDS REVISION: identify the must-fix items and
  recommend a v0.5 patch.

## What NOT to do

- Do NOT re-audit content untouched by the v0.4 fix.
- Do NOT modify any spec yourself.
- Do NOT overwrite the audit report file — append.
- Do NOT browse d-inference repos.
- Do NOT expand scope beyond verifying the four prescribed fixes
  and detecting regressions.

When done, print a 100-word summary to stdout: verdict, fix-closure
rate (X/4), any new findings, recommendation (proceed to build /
v0.5 patch). Then stop.

=== END PROMPT ===
```

---

## After running this prompt

If verdict = **READY TO BUILD** (expected):
- Audit cycle complete (15/15 round-1 + 4/4 round-2 + 0 round-3)
- Move to drafting three build prompts:
  - `BUILD_SPEC_001_V1_2_1_PROMPT.md` (phase3-binary v1.2 work)
  - `BUILD_SPEC_002_V1_1_2_PROMPT.md` (coordinator v0.2 work)
  - `BUILD_SPEC_003_V0_4_PROMPT.md` (install.sh + launchd + GitHub releases)

If verdict = **NEEDS REVISION** (unlikely):
- Draft narrow v0.5 fix prompt covering the new findings
- Re-run this regression check after v0.5

The audit cycle convergence has been clean: 15 → 4 → 0 (projected).
Matches SPEC-001/002's 3-round pattern.

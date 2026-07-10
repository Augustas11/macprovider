# Re-audit prompt — SPEC-001 v1.1

This is the operator-paste prompt for a second-pass audit of SPEC-001
after v1.1 has been produced. Run with **Codex CLI** (same model that
ran the first audit, for continuity).

The re-audit is targeted: did v1.1 actually fix what the first audit
flagged, and did the fixes introduce new problems? It is NOT a fresh
audit from scratch.

Expected duration: ~30 minutes (versus ~45min for the original audit —
narrower scope, focused diff).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You audited SPEC-001 v1.0 and produced specs/SPEC-001-audit.md identifying
2 CRITICAL, 17 MAJOR, 9 MINOR findings, plus 3 operator questions.
SPEC-001 v1.1 has now been produced to address those findings. Your job
is a focused re-audit: verify v1.1 actually fixed what was flagged, catch
regressions introduced by the fixes, and decide if v1.1 is build-ready.

This is NOT a re-do of the original audit. Do not re-walk every category
unless v1.1 changed it. Focus on the delta.

## Required reading (in order)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md
   — your prior findings. Memorize the finding ids (D1, E1, C1, B2, B3,
   B4, B5, B6, A1-A6, E2, E3, F1, F2, G1, G2, H1, H2, I1, I2, plus minors).

2. /Users/augstar/macprovider-poc/specs/FIX_SPEC_001_V1_1_PROMPT.md
   — the instructions the fixer was given. Pinned operator decisions:
     A1: provider auth deferred to SPEC-002
     A2: HTTP 500 disallowed during adversarial acceptance
     A3: Tier 2 decrypt before token pre-flight (hard constraint)
   Plus the strict clean-room § 7.2 replacement text (verbatim, must
   match exactly in v1.1).

3. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   — v1.1 under audit. Check the version metadata says "v1.1, 2026-05-27".

4. /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html
   — should contain a new "SPEC-001 v1.1 revision" section at top. Verify
   it lists resolved decisions, addressed findings, and any knowingly
   deferred minor findings.

5. /Users/augstar/macprovider-poc/specs/README.md
   — should show SPEC-001 row updated to "v1.1, reviewed against audit".

6. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — re-verify decision log → FR mapping is complete.

You may not need to re-read all of HANDOFF.md, REPORT.md, or the harness
code unless a specific check requires it.

## Re-audit structure — three parts

### Part 1 — Verify prior findings are addressed

For EVERY finding in specs/SPEC-001-audit.md (use the ids), produce a
one-line verdict:

  CRITICAL findings (D1, E1) — must be ADDRESSED.
    For each: ADDRESSED | PARTIAL | NOT ADDRESSED, with section
    reference in v1.1 and a one-line justification.

  MAJOR findings (A1, A2, A4, A5, B2, B3, B4, B5, B6, C1, E2, E3, F1,
  G2, H1, H2, I1) — should be ADDRESSED or DEFERRED.
    For each: ADDRESSED | DEFERRED (with reason from
    implementation-notes.html) | NOT ADDRESSED, with section reference.

  MINOR findings (A3, A6, B1, C2, C3, D2, F2, G1, I2) — may be deferred.
    For each: ADDRESSED | KNOWINGLY DEFERRED (verify entry in
    implementation-notes.html) | UNADDRESSED & UNDEFERRED (this is a
    finding in itself).

  QUESTIONS (Q1, Q2, Q3) — must be RESOLVED.
    Verify each is no longer an open question in SPEC-001 § 10. The
    pinned answers per the fix prompt:
      Q1 (auth) → deferred to SPEC-002 (no coordinator_token in FRs/config)
      Q2 (HTTP 500) → AC-2 says 500 is a hard failure
      Q3 (decrypt ordering) → request chain has decrypt before pre-flight

### Part 2 — Regression check

For each fix the fixer applied, check whether it introduced new problems.
Common regression categories to look for:

R1 — A new FR contradicts an existing FR (e.g. § 6 schema is now
     specific about a field, but FR-N still uses old loose language).

R2 — A renamed field, message type, or enum value in one section is
     not propagated to all other references (search for any string that
     used to appear and check it's consistently updated OR consistently
     removed).

R3 — An open question converted to a default in § 9 or § 10 added a
     constraint that conflicts with another section.

R4 — A removed `coordinator_token` reference left a dangling field in
     a JSON schema or config example.

R5 — The clean-room § 7.2 replacement left d-inference URLs / references
     elsewhere in the spec (Section 11 hand-off, Appendix A, or
     example dependency declarations). Run a global text search in v1.1
     for "d-inference" and "darkbloom" (case-insensitive). Any non-§7.2
     occurrence outside attribution context is a regression.

R6 — The new full OpenAI request schema in § 6.2 introduced a field
     (e.g. `n: must be 1`) that breaks an existing AC that fires harness
     workloads (do they ever pass n>1?).

R7 — The two-stage pre-flight in FR-8 changed the order in which 413
     errors fire. Does any AC test the old order?

R8 — Dependency pins (H1 fix) — are the version numbers actually valid
     releases? (e.g. swift-nio 2.65.0 must exist on
     github.com/apple/swift-nio/releases). Spot-check 2-3.

R9 — The new AC-6 through AC-10 reference test scripts
     (soak-test.sh, test-coordinator.sh) that don't yet exist. Verify
     SPEC-001 either flags them as build-session outputs OR doesn't
     reference paths that won't exist at v1.1 commit time.

R10 — The "knowingly deferred minor findings" list in
      implementation-notes.html: are the deferrals justified, or did
      the fixer dodge work?

### Part 3 — Final implementability check (focused)

Re-evaluate H1 (dependency pinning) and H2 (implementability) from your
original audit:

  H1 v2 — Are mlx-swift-lm, swift-nio, swift-log, ArgumentParser, Yams
          pinned to actual versions/tags/commits?
  H2 v2 — Could a competent Swift dev (or fresh Claude/Codex session)
          now build from v1.1 with ≤3 clarifying questions to the
          operator? List the ≤3 clarifications they would still need.

## Severity rubric

Same as the first audit:
  CRITICAL — build-blocking regression OR original CRITICAL not addressed.
  MAJOR    — build-degrading regression OR original MAJOR not addressed
             without justified deferral.
  MINOR    — friction-causing regression OR unaddressed MINOR with no
             deferral entry.
  QUESTION — re-auditor's question for the operator.

For v1.1 we expect: 0 CRITICAL, ≤5 MAJOR, ≤10 MINOR. If you find more,
that's a signal the fix introduced significant new issues.

## Output format

Write your re-audit to:

  /Users/augstar/macprovider-poc/specs/SPEC-001-v1-1-audit.md

Structure:

  # SPEC-001 v1.1 Re-audit Report
  Auditor: <model name + version>
  Prior audit: specs/SPEC-001-audit.md
  Re-audit completed: <UTC timestamp>

  ## TL;DR verdict
  One of: READY TO BUILD | NEEDS MINOR REVISION | NEEDS MAJOR REVISION
          | RESTART (unlikely)
  One paragraph justification, including how many original findings were
  resolved vs deferred vs unaddressed, and how many regressions found.

  ## Part 1 — Prior findings verification table

  | Finding | Severity | v1.1 status | Section ref | Note |
  |---|---|---|---|---|
  | D1 | CRITICAL | ADDRESSED | § 7.2 | License recorded as NOASSERTION + URL |
  | E1 | CRITICAL | ... | ... | ... |
  | ... | ... | ... | ... | ... |

  (Every finding from the original audit gets one row. Use uppercase status
  values for grep-ability.)

  ## Part 2 — Regressions found

  ### CRITICAL regressions (N)
  ### MAJOR regressions (N)
  ### MINOR regressions (N)

  (Use the regression categories R1-R10 from above as guidance. Each
  regression cited with section reference + quoted text + what it conflicts
  with.)

  ## Part 3 — Implementability verdict

  H1 v2: pinning status of each dependency.
  H2 v2: list of ≤3 clarifications still needed for build to start, or
  "build can start without further clarification."

  ## Coverage matrix delta
  Compared to your original audit's coverage matrix, which decision log
  rows moved from Partial/Uncovered to Covered? Which remain uncovered?

  ## What the v1.1 revision did well
  3-5 specific things the fixer got right. Same rationale as before:
  prevents one-sided audit.

  ## Final verdict recommendation
  Concrete next step for operator:
    - READY TO BUILD → "Commit v1.1 and start binary build per § 0"
    - NEEDS MINOR REVISION → list the ≤3 minor items to patch in-place
    - NEEDS MAJOR REVISION → list the issues and recommend another
      FIX_SPEC_001_V1_2 round

## Hard rules

1. Do NOT re-walk audit categories that v1.1 did not change. The diff
   is the focus.
2. Do NOT rewrite SPEC-001 or propose alternative spec text. Same as
   before: identify problems, the operator decides fixes.
3. Cite sections and quote text. Vague findings drop out.
4. You MAY check version pins by querying github.com via gh CLI for
   release/tag existence. Do NOT clone any d-inference content (per
   v1.1's strict clean-room policy — this rule now applies to YOU too).
5. If a finding from the original audit was MARKED ADDRESSED in
   implementation-notes.html but you can't verify it in SPEC-001 v1.1
   itself, that's a finding ("claimed but not visible").

## Anti-rules

- Don't audit the FIX_SPEC_001_V1_1_PROMPT.md itself. It's instructions
  to the fixer; you're reviewing the fixer's output, not its inputs.
- Don't speculate about what v1.2 should look like. Just identify what
  v1.1 missed.
- Don't ask the operator questions during the audit. Put them in the
  re-audit's QUESTIONS section if any.

## When you finish

1. Re-read your re-audit. Confirm every Part-1 finding has explicit
   ADDRESSED / DEFERRED / NOT ADDRESSED verdict.
2. Confirm Part-2 regressions are cited with quote + section ref.
3. Print to stdout:
   - The TL;DR verdict
   - Counts: original findings ADDRESSED / DEFERRED / NOT ADDRESSED
   - Count of regressions by severity
   - Top 3 items for operator focus, or "ready to build"

Begin by reading the required files in order. Most of your time should be
in Part 1 (verification table) and Part 2 (regression check), not on
re-evaluating things v1.1 didn't change.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc

# After SPEC-001 v1.1 has been written by Claude, re-audit with Codex:
codex < specs/AUDIT_SPEC_001_V1_1_PROMPT.md
```

## What you'll get back

- `specs/SPEC-001-v1-1-audit.md` — focused re-audit report (~5-10KB, smaller than the first audit)
- A `<200 word` summary in Codex's final reply with the verdict + counts

## Expected outcomes

| Outcome | What it means | Next action |
|---|---|---|
| **READY TO BUILD** | All CRITICAL addressed, <5 MAJOR open with justified deferrals, no significant regressions | Commit v1.1, start binary build |
| **NEEDS MINOR REVISION** | 1-3 small items missed; nothing build-blocking | Edit those items in-place, no need for a v1.2 prompt |
| **NEEDS MAJOR REVISION** | A CRITICAL is not actually addressed, or fixes introduced new MAJOR issues | Run a FIX_SPEC_001_V1_2_PROMPT (which I'd draft based on the re-audit) |
| **RESTART** | Unlikely; would mean v1.1 made things worse than v1.0 | Discard v1.1, re-start from v1.0 with a different fix strategy |

## What this re-audit catches that the first one couldn't

1. **Stealth deferrals** — fixer marked a finding "deferred" without justified entry in implementation-notes.html
2. **Renaming regressions** — fixer renamed a field in one section but missed propagating to others (very common)
3. **Stale clean-room leaks** — d-inference URLs surviving in non-§7.2 sections after the rewrite
4. **Phantom test artifacts** — ACs referencing scripts that won't exist at commit time
5. **Version-pin validity** — checking that swift-nio 2.65.0 actually exists as a release (cheap gh API call)

## Why Codex again, not a fresh Claude

- Codex saw the original spec problems and named them. It's the natural party to verify they're fixed.
- Cross-model audit happened on round 1. Round 2 is correctness verification, which benefits from continuity.
- If something Codex flagged is "addressed" but doesn't actually fix the underlying issue, Codex is uniquely positioned to recognize that.

## Tomorrow's full flow

```
Step                                                                Wall time
──────────────────────────────────────────────────────────────────────────
1. claude < specs/FIX_SPEC_001_V1_1_PROMPT.md                       ~1.5h
   → produces SPEC-001 v1.1, updates impl-notes.html

2. Operator reads v1.1                                              ~20min

3. codex < specs/AUDIT_SPEC_001_V1_1_PROMPT.md                      ~30min
   → produces SPEC-001-v1-1-audit.md

4. Operator reads re-audit                                          ~15min

5. IF READY → commit v1.1, write SPEC-002 build prompt              same day
   IF MINOR REVISION → patch in-place, skip re-audit                +30min
   IF MAJOR REVISION → draft FIX_SPEC_001_V1_2_PROMPT, run again    +2-3h
```

Most likely path: READY TO BUILD by mid-afternoon, then SPEC-002 prep in the evening.
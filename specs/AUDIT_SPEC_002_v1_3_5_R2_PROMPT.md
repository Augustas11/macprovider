# Audit prompt — SPEC-002 v1.3.5 (round 2 — LOCK confirmation)

Operator-paste prompt to audit SPEC-002 v1.3.5 (post round-1 polish)
— the round-2 LOCK-confirmation pass after closing the 1 MAJOR and
2 MINOR findings from round 1.

Round 1 (Codex GPT-5, 2026-06-06) verdict: `0 CRITICAL / 1 MAJOR /
2 MINOR / 0 QUESTION` → POLISH ROUND REQUIRED. Round-1 findings
in `specs/SPEC-002-v1-3-5-audit.md`:

- **MAJOR B.1** — R-7.8.7 + AC-K.3 used `"supported_models mismatch
  between initial and proof stages"`; locked SPEC-010 v1.5 R-3.1.10
  + AC-18(c) require `"supported_models mismatch between auth_request
  stages"`.
- **MINOR E.1** — AC-K coverage gap for R-7.8.4 SPEC-010
  validation-order pass-through and R-7.9.6 retention-bound
  rejection.
- **MINOR E.2** — AC-K coverage gap for §7.10.1 `audit_log` table
  schema / indexes and §7.10.2 `ts_utc` RFC3339 UTC format.

Polish pass closed all 3 findings:
- **B.1 fix** — both R-7.8.7 (line 2724-2727) and AC-K.3 (line
  3623-3632) now use the locked SPEC-010 substring
  `"supported_models mismatch between auth_request stages"`.
- **E.1 fix** — AC-K.15 added (SPEC-010 validation-order pass-
  through with AC-17 / AC-22 / AC-23 reason-text first-failure
  ordering) and AC-K.16 added (R-7.9.6 retention-bound
  `too_many_auth_attempts` rejection with no off-by-one growth).
- **E.2 fix** — AC-K.17 added (audit_log table schema + 3 indexes
  + RFC3339-UTC `ts_utc` format assertion).

AC-K now goes 0-17 sequential (was 0-14; added 3 new).

Round 2 has ONE job: confirm `0 CRITICAL / 0 MAJOR / 0 MINOR` across
the round-1-finding closure surface, and emit a LOCK CONFIRMATION
verdict — mirroring SPEC-001 v1.3 round 2.

Trajectory:
- v1.3.5 round 1: 0/1/2 (after pre-audit polish closed 3 MAJORs
  M.1/M.2/M.3)
- v1.3.5 round 2 target: **0/0/0 → LOCK CONFIRMED**

Append round-2 findings to existing `specs/SPEC-002-v1-3-5-audit.md`
as a new top-level section after round 1.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-002 v1.3.5 (post round-1 polish) at
/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md.
This is round 2 and the LOCK confirmation pass.

Round 1 (Codex GPT-5 on the pre-audit-polished v1.3.5) delivered
POLISH ROUND REQUIRED with 0 CRITICAL / 1 MAJOR / 2 MINOR / 0
QUESTION. The polish pass closed all 3 findings via spec-text-only
edits.

Your job:
1. **R1V — Round-1 finding closure verification.** For each of
   B.1, E.1, E.2, cite the v1.3.5 (post-polish) location and mark
   PASS / PARTIAL / FAIL.
2. **LOCK confirmation.** If round 2 finds 0 CRITICAL / 0 MAJOR /
   0 MINOR, state explicitly "LOCK CONFIRMED" in the executive
   summary. If round 2 finds new MINORs but no MAJOR/CRITICAL,
   state "LOCK CONFIRMED WITH MINOR DEFERRED FIXES." If round 2
   finds any new MAJOR or CRITICAL, state "LOCK NOT CONFIRMED —
   UNEXPECTED REGRESSION."

This is a narrow surface to audit (3 closure verifications + 4
sanity-check categories). Expected duration ~10-15 min.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md

APPEND a new top-level section:
  `## Round 2 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION`
followed by R1V table + category findings (likely "(no findings)"
across most categories).

## Severity definitions

Unchanged from round 1.

## Critical constraints

**1. Locked specs READ-ONLY.** Spot-check:
`git diff specs/SPEC-001-phase3-binary.md specs/SPEC-004*.md
specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md
specs/SPEC-011*.md` must be empty.

**2. §5 / §7.1 existing / §7.2 / §7.3 byte-identity invariants.**
Spot-checks:
```
git show HEAD:specs/SPEC-002-coordinator.md > /tmp/spec002-head.md
diff <(awk '/^## 5\./,/^## 6\./' /tmp/spec002-head.md) \
     <(awk '/^## 5\./,/^## 6\./' specs/SPEC-002-coordinator.md)
diff <(awk '/^### 7\.2/,/^### 7\.3/' /tmp/spec002-head.md) \
     <(awk '/^### 7\.2/,/^### 7\.3/' specs/SPEC-002-coordinator.md)
diff <(awk '/^### 7\.3/,/^### 7\.4/' /tmp/spec002-head.md) \
     <(awk '/^### 7\.3/,/^### 7\.4/' specs/SPEC-002-coordinator.md)
```
For §7.1, compare HEAD §7.1 against the current §7.1 up to (but
not including) the v1.3.5 "Heartbeat field extension" sub-section.
Any non-empty diff = CRITICAL.

**3. No phase4-coordinator code changes.** Spot-check:
`git diff --stat phase4-coordinator/` must be empty.

**4. Round 2 is a sanity check, not a deep audit.** If nothing new
surfaces in the closure-verification + sanity categories, the
verdict is LOCK CONFIRMED.

**5. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.5 (post-polish) — focus on the specific lines that closed
   each round-1 finding:
   - **B.1 closure** — R-7.8.7 (lines ~2719-2727) and AC-K.3
     (lines ~3623-3631) — both now use the SPEC-010-locked
     substring `"supported_models mismatch between auth_request
     stages"`.
   - **E.1 closure** — new AC-K.15 (validation-order pass-through
     with AC-17 / AC-22 / AC-23 reason-text ordering) and AC-K.16
     (retention-bound `too_many_auth_attempts` rejection per
     R-7.9.6).
   - **E.2 closure** — new AC-K.17 (audit_log table schema + 3
     indexes + `ts_utc` RFC3339 UTC format per R-7.10.1 / R-7.10.2).

2. `/Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md`
   round 1 — re-read the round-1 B.1, E.1, E.2 findings to verify
   the polish addresses what was actually said.

3. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 (LOCKED) — verify R-3.1.10 clause 4 / AC-18(c) / AC-17 /
   AC-22 / AC-23 reason-text wording matches what SPEC-002 v1.3.5
   post-polish now cites.

4. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 (LOCKED) — sanity-check that the pre-audit M.1/M.2/M.3
   closures (verified PASS in round 1) remain intact in the
   post-polish file.

5. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

## Audit categories

### Category R1V: Round-1 finding closure verification

Table format: round-1 finding, PASS/PARTIAL/FAIL, v1.3.5 post-polish
location, 1-sentence evidence.

- **R1V-B.1** Both R-7.8.7 and AC-K.3 use the SPEC-010-locked
  substring `"supported_models mismatch between auth_request
  stages"`; the prior "between initial and proof stages" wording
  appears nowhere.
- **R1V-E.1** AC-K.15 (validation-order pass-through, traces AC-17 /
  AC-22 / AC-23) and AC-K.16 (retention-bound rejection, traces
  R-7.9.6) present.
- **R1V-E.2** AC-K.17 (audit_log schema/indexes + ts_utc RFC3339
  UTC) present.

### Category A2: Locked-decision preservation (sanity check)

A2.1  Locked-companion diff sanity check (run spot-check above).

A2.2  `phase4-coordinator/` diff sanity check (run spot-check
      above).

A2.3  §5 / §7.1 existing / §7.2 / §7.3 byte-identity sanity check
      (run spot-check above).

A2.4  Pre-audit M.1 / M.2 / M.3 closures (verified PASS in round 1)
      remain intact: §7.10.2 8 REQUIRED + 2 OPTIONAL payload schema
      unchanged, R-7.10.9 F-1.5 invariants intact, R-7.10.10
      conditional emission intact.

### Category B2: New AC tracing and operational testability

B2.1  AC-K.15 cites SPEC-010 v1.5 R-3.1.9 / AC-17 / AC-22 / AC-23.
      Verify each cite exists in the locked SPEC-010 and matches
      the reason-text substring in AC-K.15.

B2.2  AC-K.16 cites SPEC-002 v1.3.5 R-7.9.6 and SPEC-010 v1.5
      R-3.1.10. Verify R-7.9.6 contains the recommended 1024 bound
      and `too_many_auth_attempts` rejection text.

B2.3  AC-K.17 cites SPEC-002 v1.3.5 R-7.10.1 / R-7.10.2. Verify
      R-7.10.1 contains the 5-column schema + 3 indexes and
      R-7.10.2 contains the RFC3339 UTC requirement.

### Category C2: Anything else

C2.1  Did the polish pass introduce any new normative surface that
      should be audited?

C2.2  Documentation drift on the closure surface.

C2.3  Renumbering sanity: §7.10 rules still 1-11 sequential;
      AC-K now 0-17 sequential (was 0-14; added 3).

C2.4  Decision-log entry: NOT a finding, but reminder that one
      should be added after LOCK (Entry 57 mirroring Entry 54 /
      55 / 56 format).

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md`.
Start with:

```
---

## Round 2 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-002 v1.3.5 (post round-1 polish)
            (specs/SPEC-002-coordinator.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-2 executive summary — LOCK VERDICT

[1-2 sentences. State explicitly one of:
- "LOCK CONFIRMED" (0/0/0)
- "LOCK CONFIRMED WITH MINOR DEFERRED FIXES" (0/0/N with N ≤ 2,
  MINORs are non-blockers)
- "LOCK NOT CONFIRMED — UNEXPECTED REGRESSION" (any new MAJOR
  or CRITICAL)]

### Round-1 finding closure verification (R1V)

[Table format.]
```

Then for each category R1V, A2-C2, write a section. For each finding:
severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- d-inference inspection
- Rewriting the spec
- Implementing the spec
- Editing SPEC-001 v1.3, SPEC-004, SPEC-005, SPEC-006, SPEC-008,
  SPEC-010, SPEC-011 (all LOCKED)
- Re-litigating round-1 findings that the polish addressed

## Done criteria

You are done when:

- Round-2 section APPENDED to SPEC-002-v1-3-5-audit.md (round 1
  intact)
- Every round-1 finding (B.1, E.1, E.2) has PASS/PARTIAL/FAIL in
  R1V
- Every category R1V, A2-C2 has a section
- All 3 spot-checks executed and result reported
- Executive summary states the explicit LOCK verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 10-15 min (3 closure verifications + 4
  sanity categories).
- If verdict is LOCK CONFIRMED: lock SPEC-002 v1.3.5, append
  Entry 57 to `beta/DECISION_CRITERIA.md`, commit + push to
  `spec/provider-catalog-warm-swap-arc` (updates PR #4).
- If unexpected regression: narrow v1.3.6 fix + round 3.

# Audit prompt — SPEC-010 v1.5 (narrow scope, round 6 — LOCK confirmation)

Operator-paste prompt to audit SPEC-010 v1.5
(`specs/SPEC-010-model-catalog.md`).

**Round 6 — LOCK confirmation.** Round 5 (Codex on v1.4)
delivered the verdict **READY TO LOCK** with 0 CRITICAL / 0
MAJOR / 3 MINOR / 0 QUESTION. v1.5 is a 3-edit polish pass
that closes the 3 remaining MINORs:
- A5.1: R-3.1.10 clause 1 now explicitly gates retention
  creation on SPEC-010 field presence
- D5.3: AC-18(f) replaces arbitrary 1s settlement with
  deterministic `sync.WaitGroup`-based join
- G5.1: §6.1 stale "SPEC-010 v1.2" citation → "v1.x locked"

Round 6 has ONE job: confirm 0 CRITICAL / 0 MAJOR / 0 MINOR
across the v1.5 surface, and emit a **LOCK confirmation**
verdict.

Trajectory:
- v1.0 round 1: 0 / 3 / 1
- v1.1 round 2: 0 / 3 / 2
- v1.2 round 3: 0 / 5 / 0
- v1.3 round 4: 0 / 2 / 5
- v1.4 round 5: 0 / 0 / 3 — READY TO LOCK (per Codex round-5
  executive summary)
- v1.5 round 6 target: **0 / 0 / 0 → LOCK CONFIRMED**

Append round-6 findings to existing
`specs/SPEC-010-audit.md` as a new top-level section after
round 5. Do not touch rounds 1-5.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted
at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v1.5 at /Users/augstar/macprovider-poc/
specs/SPEC-010-model-catalog.md. This is round 6 and the LOCK
confirmation pass.

Round 5 (Codex GPT-5 on v1.4) delivered READY TO LOCK with
0 CRITICAL / 0 MAJOR / 3 MINOR. v1.5 is a polish pass closing
all 3 round-5 MINORs (A5.1, D5.3, G5.1).

Your job:
1. **R5V — Round-5 MINOR fix verification.** For each of
   A5.1, D5.3, G5.1, cite v1.5 location and mark PASS /
   PARTIAL / FAIL.
2. **LOCK confirmation.** If round 6 finds 0 CRITICAL / 0
   MAJOR / 0 MINOR, state explicitly "LOCK CONFIRMED" in the
   executive summary. If round 6 finds new MINORs, state
   "LOCK CONFIRMED WITH MINOR DEFERRED FIXES" (acceptable
   since round 5 already cleared MAJOR/CRITICAL). If round 6
   finds any new MAJOR or CRITICAL, state "LOCK NOT
   CONFIRMED — UNEXPECTED REGRESSION."

This is a small surface to audit (3 edits). Expected
duration ~10-15 min.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

APPEND a new top-level section:
  `## Round 6 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION`
followed by R5V table + category findings (likely "(no
findings)" across most categories).

## Severity definitions

Unchanged from rounds 1-5.

## Critical constraints

**1. Locked decisions (§2 L-1..L-6) READ-ONLY.**

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4 LOCKED.** v1.5
candidate annotations in §6.x are unchanged from v1.4
except for G5.1 citation fix.

**3. v1.5's scope is unchanged from v1.4.** This is purely
a polish pass.

**4. Code-grounding remains relevant** but the surface
v1.5 touches is small:
- R-3.1.10 clause 1 presence gate — verify the gate
  doesn't accidentally exclude a valid SPEC-010 case
- AC-18(f) WaitGroup join — verify it's actually
  implementable against the existing `handleV2Conn`
  return semantics

**5. Round 6 is a sanity check, not a deep audit.** If
nothing new surfaces, the verdict is LOCK CONFIRMED.

**6. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 — focus on:
   - v1.5 change log
   - R-3.1.10 clause 1 (presence gate addition)
   - AC-18(f) (WaitGroup join rewrite)
   - §6.1 SPEC-001 v1.2.5 candidate (citation fix)

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`
   round 5 — find `### A5.1`, `### D5.3`, `### G5.1` to
   verify the v1.5 fixes address Codex's actual concerns.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

4. Code spot-checks (light):
   - `phase4-coordinator/internal/ws/server.go` lines
     315-460 (`handleV2Conn` — verify WaitGroup join
     idiom in AC-18(f) is feasible)
   - `phase4-coordinator/internal/ws/messages.go` lines
     333-388 (`parseAuthInitial` — verify the presence
     gate in R-3.1.10 clause 1 can be checked from the
     parser output)

## Audit categories

### Category R5V: Round-5 fix verification

Table format: round-5 finding, PASS/PARTIAL/FAIL, v1.5
location, 1-sentence evidence.

- **R5V-A5.1** retention/defer creation gate explicit →
  v1.5 R-3.1.10 clause 1 presence gate paragraph
- **R5V-D5.3** AC-18(f) deterministic harness join →
  v1.5 AC-18(f) WaitGroup join procedure
- **R5V-G5.1** §6.1 stale "v1.2" citation → v1.5 §6.1
  "v1.x locked" citation

### Category A6: Locked-decision preservation (sanity check)

A6.1  R-3.1.10 clause 1 presence gate doesn't accidentally
      change behavior for any case the v1.4 contract
      already specified. Specifically: when SPEC-010 fields
      ARE present on the initial frame, the retention
      creation and defer install fire exactly as v1.4
      specified.

A6.2  L-1 is strengthened by the presence gate. Verify the
      gate produces NO observable change for legacy
      (no-SPEC-010-fields) initial frames.

### Category B6: AC-18(f) implementability (sanity check)

B6.1  `sync.WaitGroup` + `handlerJoined(authAttemptID)` test
      hook: is this implementable against `handleV2Conn`'s
      actual return path? If the function returns and the
      test hook fires synchronously on return, the
      WaitGroup join is deterministic.

B6.2  The "test-only `handlerJoined` hook that fires on
      `handleV2Conn` return": is this consistent with the
      package-internal test accessor pattern AC-18(d)
      established? Same package, same idiom?

### Category C6: §6.1 citation correctness (sanity check)

C6.1  "SPEC-010 v1.x locked §3.1 and §3.6" — does this
      version-agnostic form correctly anchor on the locked
      v1.5 (which would become v1.x once locked)? Or does
      it accidentally reference a not-yet-existing v1.x
      that hasn't locked yet? The intent is "whatever
      version of SPEC-010 ultimately locks," which v1.x
      captures.

### Category D6: Anything else

D6.1  Has the v1.5 polish pass introduced any new surface
      that should be audited?

D6.2  Documentation drift.

D6.3  Decision-log entry: NOT a finding, but reminder
      that one should be added to
      `beta/DECISION_CRITERIA.md` after lock.

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Start with:

```
---

## Round 6 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-010 v1.5 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 6 of N (LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-6 executive summary — LOCK VERDICT

[1-2 sentences. State explicitly one of:
- "LOCK CONFIRMED" (0/0/0)
- "LOCK CONFIRMED WITH MINOR DEFERRED FIXES" (0/0/N with
  N ≤ 2, MINORs are non-blockers)
- "LOCK NOT CONFIRMED — UNEXPECTED REGRESSION" (any new
  MAJOR or CRITICAL)]

### Round-5 fix verification (R5V)

[Table format.]
```

Then for each category R5V, A6-D6, write a section. For
each finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008
  themselves
- Auditing SPEC-011 (separate cycle)
- Re-litigating rounds 1-5 findings marked PASS

## Done criteria

You are done when:

- Round-6 section APPENDED to SPEC-010-audit.md (rounds
  1-5 intact)
- Every round-5 MINOR has PASS/PARTIAL/FAIL in R5V
- Every category R5V, A6-D6 has a section
- Executive summary states the explicit LOCK verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 10-15 min (3 micro-edits to verify).
- If verdict is LOCK CONFIRMED: lock SPEC-010 v1.5,
  append decision-log entry to
  `beta/DECISION_CRITERIA.md`, proceed to SPEC-001
  v1.2.5 / SPEC-002 v1.3.5 BUILD prompts.
- If unexpected regression: narrow v1.6 fix + round 7.

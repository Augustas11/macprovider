# Implementation audit prompt — SPEC-013 Step 11 round 2 (closure verification)

Round 1 (codex on 254d651) returned `0 CRITICAL / 2 MAJOR / 3 MINOR /
1 QUESTION`, verdict FIX REQUIRED. Commit e4f7bc3 claims to close
all 6 findings.

Round 2 verifies the closures and spot-checks the new surface:

- AC-17 deviation re-documented in implementation-notes with v0.4
  fix path (C.1).
- AC-6 mapping tests renamed; 3 new XCTSkip placeholders for real
  detection (A.1 + E.1).
- AC-8 Shape A exclusion now in test comments (D.1).
- AC-7 real-subprocess placeholder added (E.1).
- Post-build checklist added to implementation-notes (H.1).

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-20
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 11 implementation audit on
branch `feat/cli-autotune-impl`. Round 1 (Codex on 254d651) is at
specs/SPEC-013-impl-audit.md § Round 20 and returned
0 CRITICAL / 2 MAJOR / 3 MINOR / 1 QUESTION. Commit e4f7bc3
closes all 6 findings.

Round 2 has two questions:
1. Did e4f7bc3 actually close A.1 (MAJOR), C.1 (MAJOR), D.1
   (MINOR), E.1 (MINOR), and H.1 (MINOR)? Plus the C.2
   QUESTION resolution?
2. Did the fix-pass introduce any NEW gap?

This is a **read-only review**.

## Required reading

1. The audit-response commit via `git show e4f7bc3`.
2. Round-1 report: specs/SPEC-013-impl-audit.md § Round 20.
3. Step 11 source as patched:
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_Stage1Tests.swift`
     (AC-8 method comments now document Shape A exclusion).
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_IntegrationTests.swift`
     (AC-6 mapping tests renamed; 3 new XCTSkip real-detection
     placeholders).
   - `phase3-binary/implementation-notes.html`
     spec013-autotune-step11 section (AC-17 deviation rewritten;
     AC-6 scope clarification; AC-7 placeholder note; post-build
     checklist).

4. Run `swift test --package-path phase3-binary` — fix-pass
   claims 393 tests, 7 skipped (was 4; +3 always-skip
   placeholders), 0 failures.

5. Verify NO LOCKED source file was modified:
   `git diff fdb07ff..e4f7bc3 -- phase3-binary/Sources/`
   should be EMPTY (Step 11 + its fix-pass are test-only).

## Severity definitions (unchanged)

- **CRITICAL** — round-1 finding remains open; LOCKED source
  was modified; new tests break anti-regression.
- **MAJOR** — closure incomplete; documentation still
  contradicts the test intent; new tests are tautological.
- **MINOR** — quality issues.
- **QUESTION** — design choice.

## Round 2 audit categories

### Category Z-CLOSURE

**C.1 (MAJOR) — implementation-notes AC-17 deviation rewrite.**
Verify:
- The previous "1 strict AC-17 failure" language is GONE.
- The new section explicitly:
  (a) Reframes the deviation as an ACCEPTED v1 limitation.
  (b) Names the deviation case (chosen=1B with operator
      `[1B, 32B]` → v1 alternates = `[32B]`, spec requires
      `[]`).
  (c) Names the v0.4 candidate fix path (size-parsed
      orderings via candidatesBySize + parseSizeB extension).
  (d) Resolves C.2 (the QUESTION) explicitly with the
      deferral rationale.
- The AC-17 test method/in-line comments remain consistent
  with the notes.

**A.1 (MAJOR) — AC-6 tests reframed + placeholders added.**
Verify:
- The two existing AC-6 tests are RENAMED to
  testAC6ProviderConflictMapping{LaunchdManaged,Foreground}
  with method comments clearly stating they are mapping
  tests, not real-detection tests.
- A top-of-file documentation comment explains the audit-
  driven scope split.
- Three new XCTSkip placeholders exist:
  testAC6RealSubprocessLaunchdDetection,
  testAC6RealSubprocessForegroundDetection,
  testAC7RealSubprocessNoJoinPlusCoordinatorPoolUnaffected.
- Each placeholder's XCTSkip message names the v2-expansion
  reason AND points at the existing Step 5 unit coverage
  (`ProviderConflictDetectorTests`).
- The placeholders ALWAYS skip (not env-gated), reflecting
  that real-spawn is not implemented.

**D.1 (MINOR) — AC-8 Shape A exclusion in comments.**
Verify:
- testAC8PreWarmTransientFailureAdvancesToNextCandidate
  method comment now documents Shape A exclusion.
- testAC8PreWarmIntegrityFailureAbortsTheWholeRun same.
- The comments name Step 6's Shape B selection.

**E.1 (MINOR) — AC-7 real-subprocess placeholder.**
Verify:
- testAC7RealSubprocessNoJoinPlusCoordinatorPoolUnaffected
  exists in AutotuneAC_IntegrationTests.
- It always skips with explicit v2-expansion reason.
- It references the existing unit coverage
  (testAC7NoJoinIsSetOnEveryCandidate in Stage1Tests).

**H.1 (MINOR) — post-build checklist in implementation-notes.**
Verify:
- The Step 11 implementation-notes entry includes an "After
  Step 11 LOCKS" section.
- The checklist lists all 5 items: SPEC-003 install note,
  beta/DECISION_CRITERIA.md entry, PR #103 disposition,
  push branch, open implementation PR.

**C.2 (QUESTION) — resolved as v0.4 deferral.**
Verify the implementation-notes explicitly resolves C.2 (the
"should AC-17 be tightened now" question) with the deferral
rationale.

### Category R-REGRESSION-V11F1

- swift test reports 393 + 7 skipped, 0 failures.
- The skipped count increase (4 → 7) reflects the 3 new
  XCTSkip placeholders.
- The 2 AC-6 mapping tests STILL skip when
  AUTOTUNE_INTEGRATION_TESTS is unset (they're in the
  same class which gates via setUp).
- Pre-existing Step 1-10 tests still pass.

### Category N-NEWGAPS-V11F1

- **Placeholder XCTSkip messages — quality check.** Walk
  each XCTSkip message. It should:
  - Name the AC under coverage.
  - State why it's deferred (v2 expansion, not implemented).
  - Point at the existing unit coverage that fills the gap.
- **Test class gating interaction.** When
  AUTOTUNE_INTEGRATION_TESTS=1, the setUpWithError gate
  PASSES, and the 3 placeholder methods still XCTSkip
  individually. Verify the placeholder skips run AFTER the
  class gate (not before, which would mask them).
- **NO LOCKED source modification.** `git diff fdb07ff..e4f7bc3
  -- phase3-binary/Sources/` is EMPTY.

### Category O-OTHER-V11F1

Use sparingly.

## Output structure

APPEND to specs/SPEC-013-impl-audit.md:

```
---

## Round 21 audit (Codex on e4f7bc3 — Step 11 round 2 closure verification)

**Audited:** commit e4f7bc3 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 11, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 6 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 11 readiness:** [READY TO PROCEED TO POST-BUILD / NARROW V3 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

A.1, C.1, C.2, D.1, E.1, H.1: closure verdict + short paragraph
each.

### Round-2 new findings

Group by category Z / R / N / O.

### Step 11 readiness verdict

State READY TO PROCEED TO POST-BUILD or NARROW V3 REQUIRED.
```

## Out of scope

- Re-litigating Steps 1-10 (LOCKED)
- Re-litigating round-1 closures already verified
- Inspecting d-inference source

## Done criteria

- New `## Round 21 audit ...` section appended
- Earlier rounds (1-20) unchanged
- A.1 + C.1 + D.1 + E.1 + H.1 + C.2 closure verdicts
- `git diff fdb07ff..e4f7bc3 -- phase3-binary/Sources/` empty
  check
- `swift test --package-path phase3-binary` run
- Verdict line states READY TO PROCEED TO POST-BUILD or
  NARROW V3 REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~15-20 min.
- C.1's implementation-notes rewrite is the load-bearing
  documentation fix.
- If verdict is READY TO PROCEED TO POST-BUILD: Step 11 LOCKS
  and the post-build checklist begins.
- If verdict is NARROW V3 REQUIRED: tiny fix-pass + round-3.

# Implementation audit prompt — SPEC-013 Step 8 round 2 (closure verification)

Round 1 (codex on 118599e) returned `0 CRITICAL / 1 MAJOR (D.1) /
1 MINOR (J.1) / 0 QUESTION`, verdict FIX REQUIRED. Commit 022e8a3
claims to close both. Round 2 verifies the closures and
spot-checks the additive `AutotuneDB.markStage2WinnerCell` method.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~10-15 min.
**Read-only review**.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 8 implementation audit on
branch `feat/cli-autotune-impl`. Round 1 (Codex on 118599e) is at
specs/SPEC-013-impl-audit.md § Round 14 and returned 1 MAJOR (D.1)
+ 1 MINOR (J.1). Commit 022e8a3 closes both.

Round 2 has two questions:
1. Did 022e8a3 actually close D.1 and J.1?
2. Did the fix-pass introduce any NEW precision gap? The
   additive `AutotuneDB.markStage2WinnerCell` method is new
   surface (Step 3 is locked at d0029e9, but additive methods
   are permitted matching the Step 5 PortProbe extraction
   pattern).

This is a **read-only review**.

## Required reading

1. The audit-response commit via `git show 022e8a3`.
2. Round-1 report: specs/SPEC-013-impl-audit.md § Round 14.
3. Step 8 source under audit:
   - `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`
   - `phase3-binary/Sources/macprovider-cli/AutotuneDB.swift`
     (new `markStage2WinnerCell` method)
   - `phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift`
   - `phase3-binary/implementation-notes.html` Step 8 round-1 entry

4. Run `swift test --package-path phase3-binary` — fix-pass
   claims 322 tests, 2 skipped, 0 failures.

## Severity definitions (unchanged)

- **CRITICAL** — D.1 closure is cosmetic and multiple kept=true
  rows still appear; the `markStage2WinnerCell` UPDATE SQL has
  injection or matches wrong rows; J.1 tests pass tautologically
  without exercising the named branches; anti-regression broke
  a test.
- **MAJOR** — closure incomplete; the markStage2WinnerCell SQL
  is brittle (e.g. NULL handling wrong); a Step 3 contract is
  silently weakened.
- **MINOR** — quality issues.
- **QUESTION** — design choice.

## Round 2 audit categories

### Category Z-CLOSURE

**D.1 (MAJOR)** Multiple Stage 2 rows had kept=true → 022e8a3:
- Adds `AutotuneDB.markStage2WinnerCell(runID:kvBits:maxBatch:maxContextCap:)`
  with kv_bits NULL/non-NULL handled at SQL-clause level (`= ?`
  vs `IS NULL`).
- `Stage2HillClimb.run()` inserts all rows with kept=false
  during loop; after loop, calls markStage2WinnerCell with
  winner's knobs AND mutates trialRows[bestRowIndex].kept in
  memory.

Verify:
- Walk the `markStage2WinnerCell` SQL. The UPDATE filters on
  run_id + stage=2 + kv_bits clause + max_batch + max_context_cap.
  No SQL injection (all values bound via withStatement/bind).
- The kv_bits NULL handling uses `IS NULL` not `= NULL`. Critical
  because `kv_bits = NULL` matches NOTHING in SQLite.
- The bindIndex starts at 1 (SQLite is 1-indexed). Skips
  binding kv_bits when nil. Verify the index arithmetic is
  correct for both branches.
- Idempotent: calling twice with same args should result in
  one row with kept=1 (verified by SQL semantics — UPDATE
  matching same row sets kept=1 again).
- The test
  `testStage2HillClimbPersistsAllCellTrialsWithStageTwo` asserts
  exactly one row has kept=1.

**J.1 (MINOR)** isNewBest edge-branch tests missing → 022e8a3
adds 5 new tests. Verify each:
- testIsNewBestAcceptsPositiveTPSWhenBestTPSIsZero: asserts
  true for (tps=0.1, best=0) and (tps=5.0, best=0/bestTTFT=500).
- testIsNewBestRejectsZeroTPSWhenBestTPSIsZero: asserts false
  for (tps=0, best=0) and (tps=-1.0, best=0).
- testIsNewBestWinsTieBandWhenBestTTFTIsNil: asserts true for
  (tps=10.05, ttft=800, best=10, bestTTFT=nil) — tie band, new
  TTFT measurable, best unmeasurable.
- testIsNewBestHoldsWhenBothTTFTsAreNilInTieBand: asserts false
  for (tps=10.05, ttft=nil, best=10, bestTTFT=nil) — both
  unmeasurable, incumbent holds.
- testIsNewBestHoldsWhenNewTTFTIsNilInTieBand: asserts false
  for (tps=10.05, ttft=nil, best=10, bestTTFT=800) — new
  unmeasurable, best measurable, incumbent holds.

Each test would fail if the corresponding `isNewBest` branch
was broken.

### Category R-REGRESSION-V08F1

- swift test reports 322 + 2 skipped, 0 failures.
- Pre-existing Step 1-7 tests still pass.
- The Step 3 AutotuneDB extension is purely additive — verify
  no existing method signature changed.
- The updated Step 8 tests (kept assertions flipped) still
  exercise the named contracts.

### Category N-NEWGAPS-V08F1

- **markStage2WinnerCell SQL injection.** All inputs are typed
  (String for runID, Int? for kvBits, Int for maxBatch/maxContextCap)
  and bound, NOT interpolated. The only interpolated piece is
  the `kvBitsClause` which is one of two constant strings.
  Safe.
- **In-memory cellTrials consistency.** After
  `trialRows[bestRowIndex].kept = true` in Stage2HillClimb,
  the result.cellTrials[bestRowIndex].kept is true. Other
  cells are false. Matches the DB state.
- **Edge: no feasible cell, no marker call.** If no cell wins
  (all infeasible), markStage2WinnerCell is NOT called — the
  iterator throws .noFeasibleCell before reaching that code
  path. Verify.
- **Edge: in-memory mutation when result is thrown.** If a
  later step throws (none currently does), the in-memory
  trialRows might be inconsistent with the DB. Acceptable.
- **AutotuneDB pattern matching.** The new method uses the
  same withStatement + bind pattern as insertTrial/insertRun.
  No new C-interop. Acceptable additive change.

### Category O-OTHER-V08F1

Use sparingly.

## Output structure

APPEND to specs/SPEC-013-impl-audit.md:

```
---

## Round 15 audit (Codex on 022e8a3 — Step 8 round 2 closure verification)

**Audited:** commit 022e8a3 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 8, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 2 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 8 readiness:** [READY TO PROCEED TO STEP 9 / NARROW V2 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

D.1 + J.1: closure verdict + paragraph.

### Round-2 new findings

Group by category Z / R / N / O.

### Step 8 readiness verdict

State READY TO PROCEED TO STEP 9 or NARROW V2 REQUIRED.
```

## Out of scope

- Re-litigating Steps 1-7 (LOCKED)
- Auditing Steps 9-11
- Re-litigating round-1 closures already verified
- Inspecting d-inference source

## Done criteria

- New `## Round 15 audit ...` section appended
- Earlier rounds (1-14) unchanged
- D.1 + J.1 closure verdicts
- `swift test --package-path phase3-binary` run
- Verdict line states READY TO PROCEED TO STEP 9 or NARROW V2
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~10-15 min.
- The markStage2WinnerCell SQL is the highest-risk new surface
  (NULL handling + idempotency).
- If verdict is READY TO PROCEED TO STEP 9: Claude commits and
  fires Step 9 (recommendation surface + JSON + recipe_hash +
  --apply).
- If verdict is NARROW V2 REQUIRED: tiny fix-pass + round-3.

# Implementation audit prompt — SPEC-013 Step 1 round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify the round-1 audit
closures landed in commit 02b038d on branch
`feat/cli-autotune-impl`.

Round 1 (codex on facbaef) returned `0 CRITICAL / 1 MAJOR / 3 MINOR
/ 0 QUESTION`, verdict FIX REQUIRED. Round 2 verifies the 4
closures and checks the fix-pass didn't introduce new gaps.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~10-15 min
(narrow scope — verify 4 specific closures + spot-check the
fix-pass for new gaps). This is a **read-only review** — Codex
MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 1 implementation audit on
branch `feat/cli-autotune-impl`. The branch is already checked
out at `/Users/augstar/macprovider-poc`.

Round 1 was you (Codex) on commit facbaef; the report is at
specs/SPEC-013-impl-audit.md. Round 1 returned 0 CRITICAL / 1
MAJOR (A.4) / 3 MINOR (B.2, B.5, C.2) / 0 QUESTION with verdict
FIX REQUIRED. Commit 02b038d is the audit-response fix-pass; it
claims to close all 4 findings without architecture change.

Round 2 has two questions:

1. Did 02b038d actually close each of the 4 round-1 findings?
   "Closed" means the new code does not admit the failure mode
   round-1 named.
2. Did the fix-pass introduce any NEW contract precision gap or
   Swift-idiom regression?

Round 2 is NARROWER than round 1. Findings unrelated to the 4
round-1 closures or the 02b038d edits are accepted but should
be rare.

This is a **read-only review**. You MUST NOT edit any file, commit,
push, or modify the git state. Output is the appended report
section only.

## Required reading (narrow)

1. The audit-response commit via `git show 02b038d`. The commit
   message enumerates each closure claim.

2. The round-1 report:
   `specs/SPEC-013-impl-audit.md` — input to this round.

3. The Step 1 source under audit (post-fix):
   - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandTests.swift`
   - `phase3-binary/implementation-notes.html` (the new Step 1
     audit-response entry)

4. The locked SPEC (READ-ONLY):
   `specs/SPEC-013-cli-autotune.md` v0.3 — particularly
   FR-A.1, FR-B.1 (note v0.3 round-2 Z-B.1 closure on
   --max-context-axis), FR-C.1, FR-C.2.

5. Run `swift test --package-path phase3-binary` and report the
   result in the round-2 executive summary. The fix-pass claims
   253 tests passing (8 new added to the 245 baseline).

## Severity definitions (unchanged from round 1)

- **CRITICAL** — round-1 closure claim is COSMETIC and the
  original failure mode still applies; OR the fix-pass
  introduced a contract violation in a previously-correct FR;
  OR anti-regression broke a test that was passing in facbaef.
- **MAJOR** — round-1 closure is incomplete; OR the fix-pass
  introduced a new precision gap; OR a new test added in the
  fix-pass passes by tautology (doesn't actually exercise the
  intended contract).
- **MINOR** — quality issues that don't block Step 2. Cleaner
  alternative phrasing, missed test edge case, etc.
- **QUESTION** — design choice the fix-pass made where the
  spec was silent.

## Critical constraints (unchanged from round 1)

1. SPEC-013 v0.3 is LOCKED.
2. Biggest-fit, not max-tps — parser MUST NOT pre-sort
   `--candidate-models`.
3. Anti-regression discipline.
4. Strict clean-room on d-inference.
5. Read-only.

## Round 2 audit categories — narrow

### Category Z-CLOSURE: did 02b038d close the round-1 four?

For each round-1 finding, write CLOSED / PARTIAL / NOT CLOSED /
OVER-CLOSED verdict with a one-paragraph rationale:

- **A.4 (MAJOR)** — `--max-context-axis` empty cell now thrown
  at flag-parse time. Verify by:
  - Read `parseCSVStrict` — does it use
    `omittingEmptySubsequences: false`?
  - Read `parseMaxContextAxis` — does it call `parseCSVStrict`
    AFTER the empty-default short-circuit check?
  - Run the smoke check codex did in round 1:
    `phase3-binary/.build/debug/macprovider-cli autotune
    --max-context-axis 4000,,8000 --dry-run` — must exit
    non-zero with a clear error naming the flag.
  - Verify the empty-default case still works:
    `--max-context-axis ""` (default) MUST map to
    `[--target-context]` (covered by
    `testMaxContextAxisEmptyDefaultMapsToTargetContext`).
- **B.5 (MINOR)** — `--candidate-models` empty cell now thrown.
  Verify the same smoke pattern:
  `--candidate-models one,,two` exits non-zero. Also verify
  the `parseKvBitsAxis` and `parsePositiveIntAxis` migration
  to `parseCSVStrict` is correct.
- **B.2 (MINOR)** — `run()` no longer double-validates. Verify
  the line `try validateBasicInputs()` is GONE from `run()` and
  that `validate()` is called by ArgumentParser at parse time
  (the existing test for below-target `--max-context-axis`
  proves this is the case — it uses
  `AutotuneCommand.parse(...)` and throws).
- **C.2 (MINOR)** — 8 new tests added. Verify EACH new test
  actually exercises the intended contract:
  - `testMaxContextAxisRejectsEmptyCell` — A.4 regression lock
  - `testMaxContextAxisSortsAscending` — FR-B.1 sort
  - `testMaxContextAxisRejectsDuplicates` — FR-B.1 dedup
  - `testMaxContextAxisEmptyDefaultMapsToTargetContext`
  - `testCandidateModelsRejectsEmptyCell` — B.5 regression lock
  - `testExplicitCandidateOrderPreservesSmallFirst` — AC-17
    prep (an implementation that pre-sorts by param count
    MUST fail this)
  - `testDryRunLinesContainCandidatePlanInOrder` — dry-run
    output contract
  - `testRestartForegroundFlagParses` — Step 1 flag set
  Look for any test that asserts only on construction without
  exercising the actual rule (tautology test).

### Category R-REGRESSION-V01F1: anti-regression in unchanged Step 1 surface

- Verify all 5 original round-1 tests still pass (they should
  — the fix-pass added tests, didn't remove any).
- Verify the 23-flag CLI surface in §7 is still complete after
  the fix-pass (no flag accidentally dropped).
- Verify `swift test --package-path phase3-binary` reports
  253 tests, 0 failures.

### Category N-NEWGAPS-V01F1: precision gaps introduced by the fix-pass

The fix-pass made these specific edits — spot-check each for
new gaps:

- **`parseCSVStrict` addition.** Does the helper correctly
  reject the all-whitespace case (e.g. `"   "`)? After trim,
  the single token becomes `""`, which the loop rejects.
  Good. Does it correctly reject a leading/trailing comma like
  `,a` or `a,`? After split with
  `omittingEmptySubsequences: false`, these produce `["", "a"]`
  and `["a", ""]`, both rejected. Good.
- **`parseMaxContextAxis` empty-default short-circuit.** The
  check is `if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`.
  Is this a behavior change from round-1's `parseCSV` empty
  case? Verify the prior behavior (empty raw → `[]` cells →
  early `return [targetContext]`) is preserved.
- **`validate()` call to `candidatePlan()`.** This means
  `candidatePlan()` runs twice in the dry-run path (once at
  parse time via `validate()`, once at `run()` time). Is this
  performance-meaningful? No — the function is pure and fast.
  Is the double-throw at the right boundary?
  ArgumentParser-thrown errors at parse time exit with code
  64 (validation error), while runtime errors would exit with
  code 1 (general failure). The fix-pass moves the throw
  earlier — verify the exit code is correct (64) for
  parse-time-class errors.
- **`dryRunLines` refactor.** `printDryRun` now calls
  `dryRunLines(plan)` and iterates. Behaviorally identical?
  Verify no line is dropped or reordered.
- **Test: `testExplicitCandidateOrderPreservesSmallFirst`.**
  This is the AC-17 prep test. Verify it actually fails under
  a parser-level re-rank: imagine a malicious refactor that
  sorts the explicit list by some heuristic. With input
  `1B,32B`, a size-descending sort would produce `32B,1B`,
  failing the test. Good. A no-op (identity) sort would still
  pass. The test is conservative but correct.
- **Test: `testDryRunLinesContainCandidatePlanInOrder`.**
  Verify the test asserts on the EXACT formatted line, not
  just on substring presence. The assertion
  `lines.contains("  1. mlx-community/Qwen2.5-32B-Instruct-4bit")`
  is exact (whitespace + index + id). Good.

### Category O-OTHER-V01F1: catch-all

Use sparingly. Round 2 is narrow.

Examples that DO belong here:
- Commit message references a wrong audit-finding ID
- implementation-notes.html SPEC-013 section has a typo or
  references the wrong audit document

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`
(do NOT overwrite round 1):

```
---

## Round 2 audit (Codex on 02b038d — Step 1 closure verification)

**Audited:** commit 02b038d on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 1, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 4 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 1 readiness:** [READY TO PROCEED TO STEP 2 / NARROW V1F2
                       REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

For each of the 4 round-1 findings (A.4, B.5, B.2, C.2): closure
verdict + one-paragraph rationale.

### Round-2 new findings

Group by category Z / R / N / O. Empty categories: `(no findings)`.

### Step 1 readiness verdict

State READY TO PROCEED TO STEP 2 or NARROW V1F2 REQUIRED.
```

## Out of scope for round 2

- Re-litigating round-1 findings already closed
- Rewriting the code
- Auditing Steps 2-11 (not yet started)
- Inspecting d-inference source

## Done criteria

You are done when:

- The new `## Round 2 audit ...` section is appended to
  `/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`.
- Round-1 sections are unchanged.
- Each of 4 round-1 findings has an explicit closure verdict.
- Each round-2 new finding (if any) has severity, location,
  what / why / recommendation.
- `swift test --package-path phase3-binary` was run and the
  result is reported in the executive summary.
- The verdict line states READY TO PROCEED TO STEP 2 or
  NARROW V1F2 REQUIRED.

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: ~10-15 min.
- If round 2 returns READY TO PROCEED TO STEP 2: Claude commits
  the audit prompt + report and immediately starts the Step 2
  build (`--no-join` on ServeCommand).
- If round 2 returns NARROW V1F2 REQUIRED: Claude rolls another
  fix-pass + a round-3 prompt. Loop until 0 CRITICAL / 0 MAJOR.

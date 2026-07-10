# Implementation audit prompt — SPEC-013 Step 11 (AC suite, FINAL step)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**test coverage / AC-contract review** of the Step 11 commit on
branch `feat/cli-autotune-impl`.

Step 11 is the FINAL BUILD step. It carries:

| Commit  | Step | Scope |
|---------|------|-------|
| 254d651 | 11   | 5 new test files under `AutotuneACTests/` covering AC-1 through AC-19 (24 new tests, 2 new skipped integration-gated tests). 1301 added lines. |

Full `phase3-binary` test suite passes per the commit's
`Tested:` line (390 tests executed, 4 skipped, 0 failures —
matching the 366-baseline + 24 new + 2 additional skipped tests
from integration gating).

The audit MUST verify two surfaces:

1. **Every AC has at least one named test that asserts the AC's
   specific contract.** AC tests use `testAC<N><DescriptiveName>`
   naming and method-level comments naming the SPEC line range.
2. **The AC-17 v1 deviation is correctly documented.** SPEC-013
   FR-F.1 requires `alternates` to be SMALLER candidates only;
   v1's position-based slice mis-surfaces 32B as an "alternate"
   when chosen=1B in operator override `[1B, 32B]`. The
   commit ships an `XCTAssertEqual(alternates, [thirtyTwoB])`
   assertion that LOCKS the v1 behavior, NOT the spec-required
   `[]`. This is acceptable as a documented v1 limitation but
   the audit must:
   - Verify implementation-notes documents the deviation
     explicitly + names the v0.4 candidate fix.
   - Verify NO LOCKED Step 9 file was modified (the deviation
     is held outside the LOCKED surface and noted for v2).
   - Flag a QUESTION if the deviation should be tightened
     (e.g. by adding a v1 size-extractor) — it's the operator's
     call whether to bump to v0.4 now or defer.

Operator wants a final independent adversarial pass BEFORE the
post-build checklist (SPEC-003 install note,
beta/DECISION_CRITERIA.md, PR #103 disposition) and PR open
begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~35-45
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial test-coverage review of the
Step 11 commit (254d651) on branch `feat/cli-autotune-impl` in
the Augustas11/macprovider repository. The branch is already
checked out at `/Users/augstar/macprovider-poc`. Steps 1-10 are
LOCKED.

This is the FINAL BUILD step. Your scope is exclusively the
Step 11 commit. This is a **read-only review**.

## Context

Step 11 adds explicit AC-tagged acceptance tests for AC-1
through AC-19 from SPEC-013 v0.3 §8. Some ACs are also covered
by component tests in Steps 1-10; Step 11 re-asserts at the
full-pipeline level for unambiguous AC coverage.

The 5 new test files:

- `AutotuneAC_Stage1Tests.swift` — AC-1, AC-2, AC-3, AC-7
  (unit variant), AC-8 (Shape B transient + integrity), AC-14,
  AC-15, AC-17, AC-19.
- `AutotuneAC_Stage2Tests.swift` — AC-4, AC-5, AC-16, AC-18.
- `AutotuneAC_LifecycleTests.swift` — AC-10, AC-13 (both
  mid-Stage-1 and mid-Stage-2 budget variants).
- `AutotuneAC_OutputTests.swift` — AC-9, AC-11, AC-12.
- `AutotuneAC_IntegrationTests.swift` — AC-6 (launchd +
  foreground variants), AC-7 real-subprocess variant; gated
  behind `AUTOTUNE_INTEGRATION_TESTS=1` env var.

Default `swift test` skips the integration tests; baseline
skipped count grew from 2 to 4 (additive).

## Required reading (in this order)

1. The Step 11 commit via `git show 254d651`.

2. The Step 11 test files (NEW):
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_Stage1Tests.swift`
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_Stage2Tests.swift`
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_LifecycleTests.swift`
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_OutputTests.swift`
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_IntegrationTests.swift`
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step11` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` §8 (AC-1 through AC-19)
     at lines 1357-1602. Cross-check each AC against its
     test.

4. Verify NO LOCKED source file changed (Steps 1-10 LOCKED):
   `git diff fdb07ff..254d651 -- phase3-binary/Sources/`
   should be EMPTY (Step 11 is test-only).

5. Run `swift test --package-path phase3-binary` and confirm
   390 tests + 4 skipped, 0 failures.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — AC contract gap (the AC's specific assertion
  is missing or tautological); a LOCKED Step 1-10 source file
  was modified by Step 11; the AC suite swallows an existing
  failure as a skip; anti-regression broke any Step 1-10 test.
- **MAJOR** — AC test asserts a proxy contract rather than the
  documented one; the integration-gating logic skips tests
  when AUTOTUNE_INTEGRATION_TESTS=1 (inverted polarity); the
  AC-17 v1 deviation is asserted but NOT documented in
  implementation-notes.
- **MINOR** — quality issues, naming, test edge cases,
  missing fixture coverage.
- **QUESTION** — design choice where the SPEC was silent OR a
  v1 limitation that could be tightened.

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — 390 tests must pass (366 baseline + 24
   new), 4 skipped (2 baseline + 2 new integration-gated).
3. Strict clean-room on d-inference.
4. Read-only.
5. NO SIGKILL escalation in v1.
6. Step 11 is TEST-ONLY: no LOCKED Step 1-10 source change.

## Audit categories — work through each

### Category A: Per-AC coverage (AC-1 through AC-19)

For each AC, verify:
- At least one named test method exists.
- The method's name includes the AC number.
- The method-level comment names the SPEC §8 line range.
- The assertion exercises the AC's specific contract (not a
  proxy like "didn't throw").

**AC-1** (largest-first STOPS on first feasible):
testAC1LargestFirstIterationStopsOnFirstFeasible. Verify
mocks set X=infeasible, Y=feasible; assertion checks no Z
trial row, alternates=[Z], recommendation names Y.

**AC-2** (largest-first ITERATES past infeasible):
testAC2LargestFirstIterationIteratesPastInfeasible. Mocks
set X=infeasible, Y=infeasible, Z=feasible; assertion checks
trial rows for X and Y with notes populated, recommendation
names Z, alternates is empty (Z is last in input).

**AC-3** (all-infeasible exits non-zero smallest-first):
testAC3AllInfeasibleExitsNonZeroWithSmallestFirstReason.
Assertion: exit non-zero, stderr leads with smallest reason,
tune_runs.exit_reason='no_feasible', recommendation_json IS
NULL.

**AC-4** (Stage 2 median + strict-all-feasible):
testAC4Stage2UsesMedianAndStrictAllFeasible. Assertion: median
of [2.0, 2.1, 2.05] = 2.05; with one replicate erroring,
fits=0.

**AC-5** (TPS tiebreak by TTFT):
testAC5TPSTiebreakByTTFT. Assertion: cell A
tps=10.0/ttft=4000ms vs cell B tps=10.05/ttft=3000ms → B
wins; with B's ttft=4500ms → A wins.

**AC-6** (provider conflict pre-flight): integration-gated.
testAC6ProviderConflictLaunchdManagedRefusesByDefault,
testAC6ProviderConflictForegroundRefusesByDefault. Both
spawn real subprocess + assert exit_reason='provider_conflict'.

**AC-7** (--no-join on every candidate):
testAC7NoJoinIsSetOnEveryCandidate (unit variant). Verify
the assertion inspects spawn argv (via mock runner) for
--no-join presence on every candidate.

**AC-8** (pre-warm failure):
testAC8PreWarmTransientFailureAdvancesToNextCandidate,
testAC8PreWarmIntegrityFailureAbortsTheWholeRun. Shape B
variants. Assertions: transient advances + populates notes;
integrity aborts + sets pre_warm_integrity_failure.

**AC-9** (apply atomic + backup + idempotent):
testAC9ApplyIsAtomicAndBacksUpAndIsIdempotent. Assertion:
two consecutive --apply runs → backup-0 and backup-1, neither
overwritten, config byte-identical after both runs.

**AC-10** (Ctrl-C cleanup):
testAC10CtrlCCleanup. Assertion: port free post-interrupt,
exit_reason='interrupted', endedAtUTC IS NULL, subsequent
autotune opens DB without errors.

**AC-11** (JSON schema stability):
testAC11JSONOutputSchemaStability. Assertion: emitted JSON
validates against the documented schema (Set(keys) ==
expected lock).

**AC-12** (recipe hash determinism):
testAC12RecipeHashDeterminism. Assertion: two identical-flag
runs produce identical recipe_hash; regex matches
^sha256:[0-9a-f]{64}$.

**AC-13** (wall-clock budget):
testAC13WallClockBudgetEnforcementMidStage1 and
testAC13WallClockBudgetEnforcementMidStage2. Assertions:
mid-Stage-1 sets budget_exhausted_no_model_selected, JSON
recommendation null; mid-Stage-2 sets
budget_exhausted_with_partial_recommendation, JSON
recommendation.partial=true.

**AC-14** (default candidate list honored):
testAC14DefaultCandidateListIsHonored. Assertion: first
iterated candidate is mlx-community/Qwen2.5-32B-Instruct-4bit.

**AC-15** (operator override beats size flags):
testAC15OperatorOverrideBeatsSizeFlags. Assertion: stderr
contains documented warning; iterated candidates are exactly
[a, b, c].

**AC-16** (tune_trials.stage):
testAC16TuneTrialsStagePopulatesCorrectly. Assertion: Stage
1 rows have stage=1, Stage 2 rows have stage=2; counts match
expected.

**AC-17** (operator order honored verbatim):
testAC17OperatorOrderHonoredVerbatim. Assertion: iteration
order is operator's [1B, 32B], NOT internally reranked to
largest-first. Note: alternates assertion locks the LOCKED
v1 position-based slice (alternates=[32B]) — see Category C
for the documented deviation.

**AC-18** (--max-context-axis evaluates extra cells):
testAC18MaxContextAxisEvaluatesExtraCellsAndCanWin and
testAC18InvalidMaxContextAxisFailsAtFlagParseTime.

**AC-19** (--max-model-size trims default):
testAC19MaxModelSizeAloneTrimsTheDefaultList and
testAC19MaxAndMinModelSizeTrimsBothEnds.

Each missing AC test = CRITICAL. Each tautological assertion
= MAJOR.

### Category B: Integration gating

B.1  Walk
     `AutotuneAC_IntegrationTests.swift`. Verify the setUp
     gates with:
     ```swift
     guard ProcessInfo.processInfo.environment["AUTOTUNE_INTEGRATION_TESTS"] == "1" else {
         throw XCTSkip("...")
     }
     ```
     The polarity must be: skip when env var is unset; run
     when env var == "1". Inverted polarity (run when unset)
     = CRITICAL.

B.2  Confirm the 4-skipped baseline post-Step-11 is correct:
     2 pre-existing skipped (Step 1-10) + 2 new from AC-6 +
     AC-7 integration variants = 4. The test run summary should
     say "4 tests skipped".

B.3  Verify AUTOTUNE_INTEGRATION_TESTS is the env var name
     (not a different name like AUTOTUNE_INTEGRATION or
     AUTOTUNE_INTEGRATION_TEST — minor noise).

### Category C: AC-17 v1 deviation documentation

C.1  Walk the AC-17 test's method-level comment + the
     in-line assertion comment + implementation-notes.html
     section. ALL THREE must document:
     - The deviation (v1 position-based slice vs FR-F.1
       size-based requirement).
     - The behavior (32B appears as "alternate" even though
       larger than 1B chosen).
     - The v0.4 candidate fix path (plumb size-parsed
       orderings).

C.2  Verify implementation-notes.html includes the AC-17
     deviation note in the spec013-autotune-step11 section.

C.3  Verify NO LOCKED Step 9 file was modified:
     `git diff d6c634c..254d651 --
     phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
     should be EMPTY.

C.4  Flag a QUESTION asking whether to tighten the deviation
     (add a v1 HF-ID size extractor) OR defer to v0.4.

### Category D: AC-8 Shape A scope decision

D.1  Step 6 chose Shape B (ProviderPreWarmer + HuggingFaceCacheChecker).
     The AC-8 SPEC §8 says both Shape A and Shape B variants
     must be exercised. Verify the Shape A exclusion is
     documented in:
     - The AC-8 test method comment.
     - implementation-notes.html.

D.2  Verify the Shape B AC-8 tests cover BOTH transient (advance
     to next) AND integrity (abort whole run) classes.

### Category E: AC-7 unit vs integration

E.1  AC-7's unit-test variant
     (testAC7NoJoinIsSetOnEveryCandidate in
     AutotuneAC_Stage1Tests) inspects the spawn argv via a
     mock runner. Walk the test to verify the mock actually
     records the argv and the assertion checks --no-join is
     present on EVERY candidate (not just the first).

E.2  The integration variant in
     AutotuneAC_IntegrationTests should be present as a
     skipped placeholder for a future real-subprocess check.

### Category F: Fixture reuse vs duplication

F.1  The AC tests should reuse the existing `Fixture` pattern
     from `AutotuneCommandRunTests.swift`. Walk the new
     fixture (`AutotuneACTestFixture`) to verify it follows
     the same DI seam pattern.

F.2  Verify the fixture doesn't introduce parallel
     infrastructure that diverges from the locked
     AutotuneRunDependencies seam.

### Category G: Anti-regression on Steps 1-10

G.1  Run `swift test --package-path phase3-binary` and verify
     390 tests + 4 skipped, 0 failures.

G.2  Run `git diff fdb07ff..254d651 -- phase3-binary/Sources/`
     and confirm NO LOCKED source files were modified.

G.3  Verify no test file from Steps 1-10 was modified.

### Category H: Forward-compatibility (post-build checklist)

H.1  After Step 11 LOCKS, the operator's post-build checklist
     includes:
     - SPEC-003 install note.
     - beta/DECISION_CRITERIA.md entry.
     - PR #103 disposition.
     - Push feat/cli-autotune-impl.
     - Open implementation PR.

H.2  Verify implementation-notes.html documents the post-build
     checklist as the next operator action.

### Category I: Anything else

Examples:
- The 5 new test files are well-organized by SPEC concern.
- Naming consistency across files.
- Test files don't shadow each other (no duplicate AC
  numbers across files).

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 20 audit (Codex on 254d651 — Step 11 round 1)

**Audited:** commit 254d651 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 11, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 11 readiness:** [READY TO PROCEED TO POST-BUILD / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-I.
```

## Out of scope

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1-10 (LOCKED)
- Re-litigating SPEC-013 v0.3 LOCK

## Done criteria

- New `## Round 20 audit ...` section appended
- Earlier rounds (1-19) unchanged
- Every category A-I has a section (even if `(no findings)`)
- Every finding has severity, location, what / why /
  recommendation
- `swift test --package-path phase3-binary` was run and the
  result reported
- The `git diff fdb07ff..254d651 -- phase3-binary/Sources/`
  empty-diff check was performed
- Verdict line states READY TO PROCEED TO POST-BUILD or FIX
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~35-45 min.
- This is the FINAL build-step audit. After Step 11 LOCKS, the
  branch goes through the post-build checklist + PR open.
- The highest-stakes verification is per-AC coverage (Category A)
  and the LOCKED-source no-modification check (Category G).
- If verdict is READY TO PROCEED TO POST-BUILD: Claude commits
  the LOCK report and begins the post-build checklist.
- If verdict is FIX REQUIRED: fix-pass + next round.

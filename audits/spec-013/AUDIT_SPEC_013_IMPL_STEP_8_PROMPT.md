# Implementation audit prompt — SPEC-013 Step 8 (Stage 2 knob hill-climb)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / orchestration / measurement review** of the Step 8 commit
on branch `feat/cli-autotune-impl`.

Step 8 carries:

| Commit | Step | Scope |
|---|---|---|
| 118599e | 8 | `Stage2HillClimb` + `Stage2Prober` + `WinningKnobs` + `Stage2HillClimbResult` + `isNewBest` + 7 unit tests (520 src + 334 test lines) |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (317 tests, 2 skipped). Codex (the implementer)
raised zero Open Questions. Operator wants an independent
adversarial pass BEFORE Step 9 (recommendation surface + JSON +
recipe_hash + `--apply`) begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~25-35
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
8 commit (118599e) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Steps 1-7 are LOCKED.

Steps 9-11 have NOT landed yet — your scope is exclusively the
Step 8 commit. This is a **read-only review**.

## Context

Step 8 implements Stage 2 of the autotune pipeline: WITHIN the
model that Stage 1 chose, hill-climb the knob cells
(kv_bits × max_batch × max_context) to find the best
performing tuple. Per SPEC-013 v0.3 §5.2 FR-B.1:

- kv_bits axis: `{unset, 4, 8}` (3 cells)
- max_batch axis: `{1, 2}` (2 cells default)
- max_context axis: `[target_context]` single cell by default

Cartesian = 6 cells minimum. Each cell:
1. Start a fresh provider with the cell's knobs.
2. Wait for ready.
3. Fire `stage2_replicates` HTTP requests.
4. Strict-all-feasible per FR-B.2 — every replicate must pass
   the FR-A.3 gate.
5. Median TPS + p95 TTFT recorded.
6. Apply `isNewBest` semantics to keep-best.

`isNewBest` port from the PR #103 prototype:
- tps None → false
- best None → true (first feasible becomes baseline)
- best_tps ≤ 0 → tps > 0
- relGap > TPS_TIE_EPSILON → new wins on throughput
- |relGap| ≤ TPS_TIE_EPSILON → TTFT tiebreak (lower wins)

TPS_TIE_EPSILON default = 0.02 (FR-B.2 + OQ-A placeholder).

## Required reading (in this order)

1. The Step 8 commit via `git show 118599e`.

2. The Step 8 source under audit:
   - `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`
     (520 lines, NEW).
   - `phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift`
     (334 lines, NEW; 7 unit tests).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step8` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §5.2 FR-B.1 (knob
     search space + max-context-axis parse rules), FR-B.2
     (keep-best decision with strict-all-feasible per cell),
     FR-B.3 (Stage 2 output tuple).
   - §5.7 FR-G.1 (`tune_trials` schema; stage=2 for Stage 2
     cells; kv_bits/max_context_cap/max_batch populated).
   - §9 OQ-A (`TPS_TIE_EPSILON` default 0.02).

4. The PR #103 prototype reference (clean-room safe; not
   d-inference):
   `git show origin/spike/provider-model-autotune:beta/autotune.py
   | grep -A 20 "_is_new_best"`. The Swift `isNewBest` MUST
   match this Python verbatim.

5. The Step 7 source for forward-compat context:
   - `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
     — Stage1Prober's SSE/TTFT measurement that Step 8 may
     mirror or share.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation of FR-B.2 (e.g.
  `isNewBest` deviates from the prototype semantics in a
  measurable way); the strict-all-feasible-per-cell rule is
  not enforced; cartesian product is non-deterministic;
  silent contract violation of FR-G.1 (e.g. stage=1 written
  for Stage 2 cells); anti-regression broke any Step 1-7
  test; the `_is_new_best` tie-band wrongly resolved (a real
  tie returns true).
- **MAJOR** — Step 8 contract gap; `isNewBest` port has a
  subtle off-by-one or asymmetric semantics; per-cell
  trial-row fields wrong (e.g. max_batch field swapped with
  kv_bits); test gap that hides a likely production failure;
  cell-order determinism not enforced.
- **MINOR** — quality issues, naming, test edge cases.
- **QUESTION** — design choice where the SPEC was silent.

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — 317 tests must pass.
3. Strict clean-room on d-inference (mlx-swift / prototype OK).
4. Read-only.
5. NO SIGKILL escalation in v1.
6. Operator order is the contract for Stage 1 (AC-17); Stage 2
   is per-cell within the chosen model and operator order
   doesn't apply.

## Audit categories — work through each

### Category A: isNewBest semantics port

A.1  Walk `Stage2HillClimb.isNewBest(tps:ttft:bestTPS:bestTTFT:tpsTieEpsilon:)`
     line by line. Cross-check against the prototype's Python:
     ```python
     def _is_new_best(tps, ttft, best):
         if tps is None: return False
         if best is None: return True
         best_tps = best.get("tps") or 0.0
         if best_tps <= 0: return tps > 0
         rel_gap = (tps - best_tps) / best_tps
         if rel_gap > TPS_TIE_EPSILON: return True
         if abs(rel_gap) <= TPS_TIE_EPSILON:
             best_ttft = best.get("ttft")
             if ttft is not None and (best_ttft is None or ttft < best_ttft):
                 return True
         return False
     ```
     Verify each branch in the Swift port:
     - `tps None → false` ✓
     - `bestTPS None → true` (first feasible)
     - `bestTPS ≤ 0 → tps > 0` (edge: best had unmeasurable tps)
     - `relGap > epsilon → true` (clear win)
     - `|relGap| ≤ epsilon` (tie band):
       - `ttft != nil AND (bestTTFT == nil OR ttft < bestTTFT) → true`
     - Otherwise → false
     ANY deviation = MAJOR. A deviation that flips the verdict
     for a real-world tie = CRITICAL (the recommendation could
     pick the wrong knob combo).

A.2  Walk the 3 isNewBest-related tests:
     - `testStage2HillClimbAppliesIsNewBestThroughputPrimary`
       — cell A TPS=10, cell B TPS=12; verify B wins (>2% gap).
     - `testStage2HillClimbAppliesIsNewBestTTFTTiebreak` —
       cell A TPS=10/TTFT=1000, cell B TPS=10.1/TTFT=800;
       within tie band, B wins on lower TTFT.
     - `testStage2HillClimbHonorsTPSTieEpsilon` — cell A
       TPS=10, cell B TPS=10.05 (0.5% gap), B's TTFT higher;
       A stays winner.
     Verify each test's TPS gap calculation matches the
     epsilon boundary correctly.

A.3  Edge case: what if BOTH cells have identical TPS AND
     identical TTFT? Returns false (best holds). Good — the
     FIRST feasible holds in true ties.

A.4  Edge case: TPS in tie band, but new TTFT == best TTFT.
     `ttft < bestTTFT` is strict less-than, so false. Best
     holds. Good — symmetric tie holds the incumbent.

### Category B: Strict-all-feasible per cell (FR-B.2)

B.1  Walk how Stage2 evaluates a cell. The prober fires
     `stage2_replicates` requests. If ANY request fails the
     FR-A.3 gate, the cell is marked infeasible. The
     median/p95 should ONLY be computed when ALL replicates
     passed.

B.2  Walk the test
     `testStage2HillClimbRejectsCellWhenAnyReplicateInfeasible`.
     Verify the test setup forces ONE of N replicates to
     fail and asserts the cell is marked infeasible without
     contributing to the median.

B.3  Verify the FR-A.3 four-condition gate is applied per
     replicate (HTTP 2xx + TTFT ≤ gate + no stop-token leak +
     no process exit). The Stage2Prober should mirror
     Stage1Prober's gate logic. If Stage2 has its own gate
     that drifts from Stage 1's = MAJOR.

### Category C: Cartesian product determinism

C.1  Walk the iteration order of `(kvBitsAxis, maxBatchAxis,
     maxContextAxis)`. The order MUST be deterministic so
     operators can replay the same run.

C.2  Verify the test
     `testStage2HillClimbPersistsAllCellTrialsWithStageTwo`
     asserts the trial rows appear in a deterministic order
     in tune_trials (e.g. by row id ascending).

C.3  If iteration uses nested for loops, the outer axis
     determines coarsest grouping; verify this is documented
     (the order doesn't matter as long as it's deterministic
     and operator can predict it).

### Category D: AutotuneDB persistence

D.1  Walk how the iterator builds `AutotuneTrialRow` for each
     cell. Verify:
     - `stage = 2` for every cell row.
     - `runID` is consistent across all cells in a single
       Stage 2 invocation.
     - `kvBits` reflects the cell's kv_bits value (`nil` for
       unset).
     - `maxBatch` reflects the cell's max_batch value.
     - `maxContextCap` reflects the cell's max_context (NOT
       the iterator's targetContext — this is the per-cell
       cap from FR-B.1's optional max-context-axis).
     - `replicatesN = stage2Replicates`.
     - `fits = true` iff the cell passed strict-all-feasible.
     - `aggThroughputTPS = median across feasible replicates`.
     - `ttftP95MS = p95 across feasible replicates`.
     - `kept = true` for the FINAL winning cell row only?
       Or do all cell rows get `kept = false` (matching the
       Step 7 H.1 closure that said Stage 1 always uses
       kept=false)? SPEC-013 §5.7 FR-G.1 schema comment said
       "Stage 2 only" for `kept`. So Stage 2 IS where kept
       comes in — the winning cell row gets kept = true,
       others get kept = false. Verify this distinction.

D.2  If Stage 8 writes `kept = false` for all cells (including
     winner) and relies on `Stage2HillClimbResult.winningKnobs`
     for Step 9 to derive the chosen cell, that's also OK but
     contradicts the SPEC schema comment. Flag whichever
     interpretation Step 8 chose and whether it matches §5.7.

D.3  Walk the persistence test
     `testStage2HillClimbPersistsAllCellTrialsWithStageTwo`.
     Verify it asserts ALL the fields above for each cell row.

### Category E: noFeasibleCell error

E.1  `Stage2HillClimbError.noFeasibleCell` is thrown when no
     cell passes. Verify:
     - The error carries a reason string summarizing why
       (e.g. counts of cells, last failure reason).
     - The error is distinct from Stage 1's noFeasible (so
       Step 10 can branch on it for tune_runs.exit_reason).

E.2  Walk `testStage2HillClimbAllCellsInfeasibleThrowsNoFeasibleCell`.
     Verify it asserts the specific error type and reason
     content.

E.3  Forward-compat for Step 10's exit_reason mapping: what
     exit_reason should noFeasibleCell map to? SPEC-013's
     enum has `ok / interrupted / no_feasible /
     budget_exhausted_no_model_selected /
     budget_exhausted_with_partial_recommendation /
     pre_warm_integrity_failure / provider_conflict /
     config_error / internal_error`. There's no
     "stage2_all_cells_infeasible" enum value. Should it map
     to `no_feasible` (same as Stage 1)? Or is this a new
     enum value needed? Step 10 will decide; flag as QUESTION
     if you think Step 8 should pre-commit.

### Category F: Provider lifecycle per cell

F.1  Each cell starts a FRESH provider with the cell's knobs.
     Verify the runner factory closure is called for each
     cell (not shared across cells).

F.2  Per cell defer-stop pattern: each cell's provider stops
     after evaluation. Verify the defer-stop matches Step
     7's Stage1Prober pattern.

F.3  Single-provider invariant: between cells, the prior
     provider MUST be stopped before the next starts. The
     defer-stop guarantees this. Good.

### Category G: SSE/TTFT measurement reuse

G.1  Does Stage 2's prober reuse Stage 1's SSE parsing /
     TTFT measurement code? Either by:
     - Sharing a static helper (preferred).
     - Reimplementing identically (acceptable but lossy
       maintenance).
     - Reimplementing with subtle differences (MAJOR —
       Stage 2 metrics would drift from Stage 1).
     Verify by spot-check.

G.2  TTFT calculation: from request start to first content
     delta (matches Stage 1).

G.3  TPS calculation: whitespace-token count over wall-clock
     (matches Stage 1's approximation).

### Category H: Anti-regression on Steps 1-7

H.1  Run `swift test --package-path phase3-binary` and verify
     317 tests + 2 skipped, 0 failures.

H.2  `git show 118599e --stat` adds 3 files; verify no
     existing source modifications.

H.3  Stage1Iterator + AutotuneDB + ProviderPreWarmer +
     CandidateProviderRunner unchanged.

### Category I: Forward-compatibility (Steps 9, 10)

I.1  Step 9 (recommendation surface) needs:
     - The winning model (from Stage 1, passed through).
     - The winning knobs (kvBits, maxBatch, maxContext).
     - The median TPS + p95 TTFT.
     - The replicate count.
     Stage2HillClimbResult provides all of these. Good.

I.2  Step 10 (signal handling + tune_runs) needs to wire
     Stage 1 → Stage 2 sequentially. The interface is clean:
     Stage1IteratorResult.selectedModel → Stage2HillClimb's
     init.selectedModel.

I.3  Step 10 must derive the kvBitsAxis, maxBatchAxis,
     maxContextAxis from AutotuneCommand's parsed flags
     (--kv-bits-axis, --max-batch-axis, --max-context-axis).
     The iterator accepts these as [Int?] / [Int] arrays.
     Step 1 already parses them. Good.

### Category J: Test fixtures

J.1  Walk each of the 7 tests:
     - `testStage2HillClimbPicksFirstFeasibleAsBaseline`
     - `testStage2HillClimbAppliesIsNewBestThroughputPrimary`
     - `testStage2HillClimbAppliesIsNewBestTTFTTiebreak`
     - `testStage2HillClimbRejectsCellWhenAnyReplicateInfeasible`
     - `testStage2HillClimbAllCellsInfeasibleThrowsNoFeasibleCell`
     - `testStage2HillClimbPersistsAllCellTrialsWithStageTwo`
     - `testStage2HillClimbHonorsTPSTieEpsilon`

     For each, verify:
     - The mock setup matches the named scenario.
     - The assertion exercises the named contract (not just
       "didn't throw").
     - The test would FAIL if the corresponding code path
       broke.

J.2  Coverage gaps to flag:
     - Is there a test for the bestTPS<=0 edge case?
     - Is there a test for ttft None handling in the tie
       branch?
     - Is there a test for kv_bits = nil (unset) cell winning?
     Each missing test = MINOR.

### Category K: Anything else

Examples:
- The implementation-notes section accurately describes the
  cartesian iteration order + isNewBest port + persistence
  fields.
- Naming consistency with Step 7 (Stage1Iterator vs
  Stage2HillClimb naming — different verbs are intentional
  since stage 1 ITERATES candidates and stage 2 HILL-CLIMBS
  knobs).

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 14 audit (Codex on 118599e — Step 8 round 1)

**Audited:** commit 118599e on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 8, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 8 readiness:** [READY TO PROCEED TO STEP 9 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-K.
```

## Out of scope

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1-7 (LOCKED)
- Auditing Steps 9-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK

## Done criteria

- New `## Round 14 audit ...` section appended
- Earlier rounds (1-13) unchanged
- Every category A-K has a section (even if `(no findings)`)
- Every finding has severity, location, what / why /
  recommendation
- `swift test --package-path phase3-binary` was run and the
  result reported
- Verdict line states READY TO PROCEED TO STEP 9 or FIX
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: 25-35 min.
- The isNewBest port (Category A) is the load-bearing FR-B.2
  contract. A subtle deviation could silently pick the wrong
  knob combo.
- If verdict is READY TO PROCEED TO STEP 9: Claude commits and
  fires Step 9 (recommendation surface — terminal block + JSON
  + recipe_hash + --apply).
- If verdict is FIX REQUIRED: fix-pass + next round.

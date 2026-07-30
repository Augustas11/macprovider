# Implementation audit prompt — SPEC-013 Step 7 round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify the round-1 audit
closures landed in commit a9da9e5 on branch
`feat/cli-autotune-impl`.

Round 1 (codex on 98d7079) returned `1 CRITICAL (E.1) / 1 MAJOR
(F.1) / 4 MINOR (D.1, G.1, H.1, K.1) / 0 QUESTION`, verdict FIX
REQUIRED. The E.1 CRITICAL was the asymmetric design risk the
audit prompt explicitly named: `failureReasons.last` violated
FR-A.4 / FR-H.4 under operator-supplied smallest-first order.

Round 2 verifies the 6 closures and checks the fix-pass didn't
introduce new gaps in the iterator's core contract.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-20
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 7 implementation audit on
branch `feat/cli-autotune-impl`.

Round 1 was you (Codex) on commit 98d7079; the report is at
specs/SPEC-013-impl-audit.md § Round 12. Round 1 returned
1 CRITICAL (E.1) / 1 MAJOR (F.1) / 4 MINOR (D.1, G.1, H.1, K.1)
/ 0 QUESTION, verdict FIX REQUIRED. Commit a9da9e5 is the
audit-response fix-pass; it claims to close all 6.

Round 2 has two questions:

1. Did a9da9e5 actually close each of the 6 round-1 findings?
2. Did the fix-pass introduce any NEW contract precision gap?
   The E.1 fix added a new init parameter (`candidatesBySize`)
   and changed two key code paths (integrity-abort row insertion
   + size-ordered failure surface). Check for regressions on
   FR-A.1 / FR-A.2 / FR-A.4 / AC-17.

This is a **read-only review**.

## Required reading (narrow)

1. The audit-response commit via `git show a9da9e5`.

2. The round-1 report:
   `specs/SPEC-013-impl-audit.md` § Round 12.

3. The Step 7 source under audit (post-fix):
   - `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
     — modified init signature, integrity-abort path, all-infeasible
     surface logic, ProviderPreWarmer extension doc.
   - `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
     — 4 new test methods + 2 fixture helpers + 1 row-reader helper.
   - `phase3-binary/implementation-notes.html` — Step 7 round-1
     audit-response entry.

4. Run `swift test --package-path phase3-binary` and report the
   result. Fix-pass claims 310 tests (306 baseline + 4 new), 2
   skipped integration-gated.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — round-1 closure claim is COSMETIC and the
  failure mode still applies; the E.1 fix actually breaks under
  some other valid operator order (e.g. a `candidatesBySize`
  with NO failed candidates returns wrong surface);
  anti-regression broke a test that was passing in 98d7079.
- **MAJOR** — closure is incomplete; fix-pass introduced a new
  precision gap (e.g. the size-ordered failure surface forgets
  pre-warm transient failures); a new test passes by tautology;
  AC-17 / FR-A.1 / FR-A.2 / FR-A.4 contract is weakened.
- **MINOR** — quality issues; new tests could be tighter.
- **QUESTION** — design choice the fix-pass made where the spec
  was silent.

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression discipline — 310 tests must pass.
3. Strict clean-room on d-inference.
4. Read-only.
5. Biggest-fit, not max-tps: AC-17 / FR-A.1 must hold.
6. STOP-on-first-feasible: FR-A.2 must hold.
7. NO SIGKILL escalation in v1.

## Round 2 audit categories

### Category Z-CLOSURE

For each of the 6 round-1 findings:

- **E.1 (CRITICAL)** failureReasons.last → 
  Verify the new `candidatesBySize` parameter logic:
  - Default fallback: when `candidatesBySize == nil`, the init
    sets `self.candidatesBySize = Array(candidates.reversed())`.
    For largest-first defaults this gives smallest-first. Good.
  - All-infeasible throw walks `candidatesBySize.first { ... }`
    to find the smallest failed candidate. The surface text is
    `"<smallest>: <reason>"`.
  - The `trials` list in the error is built via
    `candidatesBySize.compactMap { failureReasonsByCandidate[$0] }`
    — size-ordered (smallest-first).
  - New test `testStage1IteratorAllInfeasibleWithOperatorOverrideSurfacesSmallestBySize`
    passes both `candidates: ["1b", "32b"]` AND `candidatesBySize:
    ["1b", "32b"]`, makes BOTH fail, asserts surfaced reason
    starts with "1b:" not "32b:".
  - Updated test
    `testStage1IteratorAllInfeasibleSurfacesSmallestFirstReason`
    uses the default-list largest-first iteration order
    `["32b", "14b", "1b"]`. The default `candidatesBySize` is
    the reversed list `["1b", "14b", "32b"]`. Asserts
    surfaced reason is "1b: 1b leaked stop token", trials is
    `["1b leaked stop token", "14b too slow", "32b too slow"]`.

  Edge cases to spot-check:
  - What if `candidatesBySize` contains a model NOT in
    `candidates`? The lookup returns nil for that model; the
    `.first { reasonsByCandidate[$0] != nil }` keeps walking.
    Behavior is correct but not tested.
  - What if `candidatesBySize` is MISSING a model that IS in
    `candidates`? That model's failure is silently lost from
    the surface. Behavior is graceful but should be documented
    or covered.
  - What if the operator passes a `candidatesBySize` where
    multiple models fail? The first match (smallest) wins.
    Correct.

- **F.1 (MAJOR)** Integrity abort lost trial row → a9da9e5
  inserts the row BEFORE throwing. Verify:
  - The `case .failed(.integrity, ...)` branch calls
    `makeTrialRow` → `autotuneDB.insertTrial` → `trialRows.append`
    → THEN throws.
  - Notes carry `"pre-warm integrity: <reason>"` prefix.
  - Test `testStage1IteratorAbortsOnIntegrity` asserts
    `trialModels(at: dbURL) == ["model-a"]` (was `[]`).
  - Verify the second candidate ("model-b") is still NEVER
    pre-warmed (`prewarmer.models == ["model-a"]`) and never
    probed.

- **H.1 (MINOR)** Stage 1 kept=true conflicted with SPEC
  schema comment → a9da9e5 always passes `kept: false` for
  Stage 1 rows. Verify:
  - The probe-feasible branch's `makeTrialRow` call uses
    `kept: false` (not `kept: probeResult.isFeasible`).
  - The trial row for the chosen feasible candidate has
    `kept = false` in the DB.
  - The chosen model is still surfaced via
    `Stage1IteratorResult.selectedModel` for Step 9.

- **D.1 (MINOR)** SSE edge cases untested → a9da9e5 adds 2
  tests:
  - `testStage1ProberClassifiesHTTPNon2xxAsInfeasible`:
    HTTP 503 → infeasible with "HTTP 503" in reason.
  - `testStage1ProberAcceptsCompletionsStyleTextSSE`:
    completions-style `choices[0].text` → feasible. Also
    exercises SSE comments and malformed JSON via fixture.
  - Verify the fixtures actually serve the named shapes (read
    the fixture Python).

- **K.1 (MINOR)** Persistence fields partly asserted →
  a9da9e5 adds `testStage1IteratorPersistsFullStage1FieldSet`
  with `assertSingleTrialRow` helper. Verify:
  - The helper reads stage, run_id, fits, n_err, kept,
    replicates_n, max_context_cap, kv_bits, max_batch from
    SQLite directly.
  - The test asserts stage=1, runID="stage1-test-run",
    fits=true, nErr=0, kept=false (per H.1 closure),
    replicatesN=3, maxContextCap=4_000, kvBits=nil, maxBatch=nil.
  - A future regression writing stage=0 or losing
    replicates_n would fail.

- **G.1 (MINOR)** ProviderPreWarmer DI cast leaks → a9da9e5
  adds a doc block on the extension explaining production-only
  cast. Verify the comment is informative and the runtime
  behavior is unchanged (no new code).

### Category R-REGRESSION-V07F1: anti-regression

- Run `swift test --package-path phase3-binary` and verify
  310 tests + 2 skipped, 0 failures.
- The 7 original Step 7 tests still pass (some had their
  assertions updated to match the new contract; verify those
  updates are correct, not silent loosening).
- Walk Step 1-6 tests for any incidental failure (none expected
  since Step 7 is additive).

### Category N-NEWGAPS-V07F1: precision gaps introduced by the fix-pass

- **candidatesBySize default fallback.** When init is called
  with `candidatesBySize: nil` and the operator passes a
  smallest-first override like `["1b", "32b"]`, the default
  `reversed()` gives `["32b", "1b"]` — which means
  `candidatesBySize.first { ... }` returns 32b first (wrong).
  Is this a problem?
  - In production, Step 10 should pass an explicit
    `candidatesBySize` from `AutotuneCommand.defaultCandidates`
    sorted by `sizeB`. The nil fallback is only correct for the
    default-list path.
  - The new regression test
    `testStage1IteratorAllInfeasibleWithOperatorOverrideSurfacesSmallestBySize`
    explicitly passes `candidatesBySize: ["1b", "32b"]` to
    cover the override case.
  - The fallback `candidates.reversed()` is documented in the
    init comment. Step 10 will need to pass the explicit param
    to honor AC-17 under operator override; the test guards
    this path.
  - If Step 10 forgets to pass `candidatesBySize`, the
    operator-override scenario regresses. Is there a way to
    fail-fast at the type level? Probably not without bigger
    API changes. The comment is the warning.
  - Acceptable for v1; flag as MINOR if you think the API
    is brittle.

- **Integrity row insertion happens BEFORE throw.** If the
  insert itself throws (e.g. DB error), the iterator surfaces
  the DB error instead of `preWarmIntegrityFailure`. The
  caller would then NOT see the integrity classification.
  Is this acceptable? In practice, AutotuneDB.insertTrial
  doesn't typically fail; if it does, the operator likely has
  bigger problems. Flag as QUESTION if you think the spec
  demands stronger.

- **The completions-style SSE fixture sends a comment line
  (`: keep-alive`) and a malformed JSON `data:` payload
  (`data: not-valid-json`).** Verify the parser handles both
  gracefully (skips). The test should still observe `.feasible`
  for the real content delta that follows.

- **assertSingleTrialRow helper.** Inspect the SQL and the
  field mapping for any column index mistakes (off-by-one).

### Category O-OTHER-V07F1: catch-all

Use sparingly.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 13 audit (Codex on a9da9e5 — Step 7 round 2 closure verification)

**Audited:** commit a9da9e5 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 7, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 6 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 7 readiness:** [READY TO PROCEED TO STEP 8 / NARROW V2 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

For each of E.1, F.1, H.1, D.1, K.1, G.1: closure verdict +
one-paragraph rationale.

### Round-2 new findings

Group by category Z / R / N / O.

### Step 7 readiness verdict

State READY TO PROCEED TO STEP 8 or NARROW V2 REQUIRED.
```

## Out of scope

- Re-litigating round-1 findings already closed
- Auditing Steps 8-11 (not yet started)
- Inspecting d-inference source

## Done criteria

- New `## Round 13 audit ...` section appended
- Earlier rounds (1-12) unchanged
- Each of 6 round-1 findings has closure verdict
- Each round-2 new finding (if any) has severity, location,
  what / why / recommendation
- `swift test --package-path phase3-binary` was run
- Verdict line states READY TO PROCEED TO STEP 8 or NARROW V2
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~15-20 min.
- The candidatesBySize API design is the highest-risk new
  surface. Codex should flag any case where the default fallback
  + operator override interact wrong.
- If verdict is READY TO PROCEED TO STEP 8: Claude commits and
  fires Step 8 (Stage 2 knob hill-climb).
- If verdict is NARROW V2 REQUIRED: another fix-pass + round-3.

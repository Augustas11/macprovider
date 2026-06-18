# Implementation audit prompt — SPEC-013 Step 10 round 2 (closure verification)

Round 1 (codex on 79d48ca) returned `1 CRITICAL / 2 MAJOR / 1 MINOR /
0 QUESTION`, verdict FIX REQUIRED. Commit fdb07ff claims to close
all 4 findings.

Round 2 verifies the closures and spot-checks the new surface:

- The LOCKED Stage1Iterator nil fallback is restored to
  `Array(candidates.reversed())` (M.1).
- The Step 7 test is reverted to NOT pass `candidatesBySize`
  explicitly (M.1).
- AutotuneCommand.candidatesBySize(for:) now ALWAYS returns
  non-nil — input order for operator override, sorted-ascending
  for default (M.1).
- Two cooperative-cancellation poll points added after Stage 2
  and before applyConfig (B.1).
- `dependencies.drainConflict(...)` wrapped in do/catch inside
  the conflict branch (J.1).
- `MachineFingerprinter.ramGB()` returns 1 (not 0) on sysctl
  failure (K.1).
- 3 new regression-lock tests + 1 test renamed.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~20-30
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 10 implementation audit on
branch `feat/cli-autotune-impl`. Round 1 (Codex on 79d48ca) is at
specs/SPEC-013-impl-audit.md § Round 18 and returned
1 CRITICAL / 2 MAJOR / 1 MINOR / 0 QUESTION. Commit fdb07ff
closes all 4 findings.

Round 2 has two questions:
1. Did fdb07ff actually close M.1 (CRITICAL), B.1 (MAJOR),
   J.1 (MAJOR), and K.1 (MINOR)?
2. Did the fix-pass introduce any NEW precision gap?

This is a **read-only review**.

## Required reading

1. The audit-response commit via `git show fdb07ff`.
2. Round-1 report: specs/SPEC-013-impl-audit.md § Round 18.
3. Step 10 source as patched:
   - `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
     (line 178 nil fallback restored to
     `candidatesBySize ?? Array(candidates.reversed())`).
   - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
     (candidatesBySize(for:) now switches on plan.source and
     returns non-nil for both branches; two cancellation polls
     after Stage 2 / before applyConfig; drainConflict wrapped
     in do/catch).
   - `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift`
     (ramGB sysctl-fail fallback returns 1, not 0).
   - `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
     (all-infeasible test reverted to NOT pass candidatesBySize
     explicitly).
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandRunTests.swift`
     (testCandidatesBySizeReturnsInputOrderForOperatorOverride
     replaces the old nil-assertion test; new
     testInterruptionAfterStage2CancelsBeforeApply,
     testDrainConflictThrowFinalizesAsProviderConflict,
     testMachineFingerprinterRAMNeverReturnsZero).
   - `phase3-binary/implementation-notes.html` Step 10 round-1
     audit-response entry.

4. Run `swift test --package-path phase3-binary` — fix-pass
   claims 366 tests, 2 skipped, 0 failures.

5. Verify the LOCKED file diffs are now additive-only:
   - `git diff a9da9e5 fdb07ff -- phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
   - `git diff 022e8a3 fdb07ff -- phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`
   The diff to the original Step 7/Step 8 LOCKED contracts
   should now be PURELY ADDITIVE (new init params with defaults,
   new error cases, new poll points; NO changed semantics on
   existing branches).

## Severity definitions (unchanged)

- **CRITICAL** — any of the round-1 findings remains open OR a
  new contract regression appeared; the LOCKED file diffs are
  still not additive-only; the cancellation polls don't fire in
  the documented window; the drainConflict do/catch routes to
  the wrong exit_reason.
- **MAJOR** — closure incomplete; the polls fire but in the
  wrong location; new tests pass tautologically; the rename
  drops a test branch.
- **MINOR** — quality issues.
- **QUESTION** — design choice.

## Round 2 audit categories

### Category Z-CLOSURE

**M.1 (CRITICAL) — LOCKED-file diff additive-only.** Verify:
- `git diff a9da9e5 fdb07ff --
  phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
  shows ONLY additive changes: new error cases
  (`.interrupted`, `.budgetExhaustedNoModelSelected`), a
  defaulted `cancellationReason` init parameter, a
  candidate-boundary poll, and supporting branch logic. The
  nil fallback line MUST be back to
  `candidatesBySize ?? Array(candidates.reversed())`.
- The Step 7 all-infeasible test
  (`testStage1IteratorAllInfeasibleSurfacesSmallestModelFirst`
  or similarly named at
  Stage1IteratorTests.swift:110-135) does NOT pass
  `candidatesBySize` explicitly — it relies on the LOCKED nil
  fallback to produce the smallest-first order.
- `AutotuneCommand.candidatesBySize(for:)` switches on
  `plan.source`: default → sorted-ascending size order; explicit
  → `plan.candidates` (input order). It returns non-nil for
  both. The renamed test
  `testCandidatesBySizeReturnsInputOrderForOperatorOverride`
  asserts `["a", "b"]` for operator override `a,b`.

**B.1 (MAJOR) — interruption polls after Stage 2 / before apply.**
Verify:
- AutotuneCommand.run() has a `cancellationReason() ==
  .interrupted` poll immediately after
  `dependencies.runStage2(...)` returns. On flag set:
  `updateRun(endedAtUTC: nil, exitReason: .interrupted, ...)`
  + `throw ExitCode(130)`.
- A SECOND poll exists inside the `if apply { ... }` branch,
  right before `dependencies.applyConfig(...)` is called.
- Test `testInterruptionAfterStage2CancelsBeforeApply` flips
  the flag AFTER the injected `runStage2` returns (it wraps
  the closure to call `flag.set()` post-return). The test
  asserts `applyCalls == 0`, `exitCode == 130`, and the row's
  `exit_reason == "interrupted"` with `endedAtUTC == nil`.
- The new poll points do NOT poll INSIDE
  `dependencies.applyConfig`'s async work (which would
  partial-apply); they are pre-call gates only.

**J.1 (MAJOR) — drain throws classify as provider_conflict.**
Verify:
- Inside the `conflict != .none` + `--drain` branch,
  `dependencies.drainConflict(...)` is now called inside a
  `do { ... } catch { ... }` block.
- On throw: `updateRun(endedAtUTC: <now>, exitReason:
  .providerConflict, ...)`; stderr writes a message containing
  `--drain failed`; `throw ExitCode(1)`.
- Test `testDrainConflictThrowFinalizesAsProviderConflict`
  injects a throwing closure for `drainConflict`, asserts
  `exit_reason == "provider_conflict"`, asserts stderr
  contains `--drain failed`.
- The do/catch is INSIDE the conflict branch (not wrapping
  the whole `if conflict != .none` block), so the
  no-conflict path is unaffected.

**K.1 (MINOR) — ramGB fallback returns 1.** Verify:
- `MachineFingerprinter.ramGB()`'s `guard rc == 0, memsize > 0
  else { return 1 }` (was `return 0`).
- The success-path `max(1, ...)` clamp is preserved.
- Test `testMachineFingerprinterRAMNeverReturnsZero` exercises
  the real `MachineFingerprinter().sample()` and asserts
  `ramGB >= 1`.

### Category R-REGRESSION-V10F1

- swift test reports 366 + 2 skipped, 0 failures.
- Pre-existing Step 1-9 tests still pass.
- The renamed test
  `testCandidatesBySizeReturnsInputOrderForOperatorOverride`
  has the same RUN-LEVEL coverage as the old
  `testCandidatesBySizeIsNilWhenOperatorOverride` — the
  assertion changed but the call path is the same.
- The reverted Step 7 test still exercises the same
  end-to-end smallest-first surface (because the LOCKED nil
  fallback is restored).

### Category N-NEWGAPS-V10F1

- **Cancellation poll location precision.** Walk both new
  polls. The first should be after Stage 2's catch block, NOT
  inside it. The second should be at the top of the
  `if apply { ... }` block. Any inside-the-catch poll could
  interfere with the budget-exhausted-partial path which
  emits a partial recommendation INTENTIONALLY.
- **drainConflict catch boundary.** The do/catch should ONLY
  catch the throws from `drainConflict(...)`. It should NOT
  catch `try updateRun(...)` failures in the conflict branch
  (those should still propagate as internal errors).
- **candidatesBySize for `--candidate-models a,b` correctness.**
  The new path passes `plan.candidates` for operator override.
  Verify the Stage1Iterator receives the input order
  (`["a", "b"]`) and the FR-H.4 surface respects this order,
  not the reversed form.
- **MachineFingerprinter test environment-dependency.** The
  new test samples the REAL `MachineFingerprinter` on the
  host. On real macOS hosts ramGB is always > 1, so the test
  primarily catches the regression of returning 0. Acceptable
  for v1 — a fully-injectable sysctl reader would be cleaner
  but is out of scope.

### Category O-OTHER-V10F1

Use sparingly.

## Output structure

APPEND to specs/SPEC-013-impl-audit.md:

```
---

## Round 19 audit (Codex on fdb07ff — Step 10 round 2 closure verification)

**Audited:** commit fdb07ff on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 10, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 4 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 10 readiness:** [READY TO PROCEED TO STEP 11 / NARROW V3 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

M.1, B.1, J.1, K.1: closure verdict + short paragraph each.

### Round-2 new findings

Group by category Z / R / N / O.

### Step 10 readiness verdict

State READY TO PROCEED TO STEP 11 or NARROW V3 REQUIRED.
```

## Out of scope

- Re-litigating Steps 1-9 (LOCKED)
- Auditing Step 11 (not yet started)
- Re-litigating round-1 closures already verified
- Inspecting d-inference source

## Done criteria

- New `## Round 19 audit ...` section appended
- Earlier rounds (1-18) unchanged
- M.1 + B.1 + J.1 + K.1 closure verdicts
- `git diff a9da9e5 fdb07ff -- Stage1Iterator.swift` confirmed
  additive-only
- `swift test --package-path phase3-binary` run
- Verdict line states READY TO PROCEED TO STEP 11 or
  NARROW V3 REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~20-30 min.
- The Stage1Iterator additive-only verification (M.1) is the
  highest-stakes check — a residual non-additive line would
  block the LOCK.
- If verdict is READY TO PROCEED TO STEP 11: Claude commits and
  fires Step 11 (acceptance test suite for AC-1 through AC-19).
- If verdict is NARROW V3 REQUIRED: tiny fix-pass + round-3.

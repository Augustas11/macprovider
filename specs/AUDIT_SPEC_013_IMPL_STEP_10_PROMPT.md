# Implementation audit prompt — SPEC-013 Step 10 (run lifecycle wiring)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / orchestration / lifecycle review** of the Step 10 commit
on branch `feat/cli-autotune-impl`.

Step 10 is the integration step — the largest single build
stretch in the project. It carries:

| Commit  | Step | Scope |
|---------|------|-------|
| 79d48ca | 10   | `AutotuneCommand.run()` wiring + `AutotuneRuntimeSupport` (interrupt flag + signal sources + machine fingerprinter) + `AutotuneDB.updateRun(...)` + `partial: Bool` on `RecommendationCore` + cooperative cancellation hooks in `Stage1Iterator`/`Stage2HillClimb` + 15 new wiring tests. 531 src + 400 test lines. |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (363 tests, 2 skipped, 0 failures). Codex (the
implementer) raised zero Open Questions but flagged one explicit
design rejection in the commit:

1. **DELETE+INSERT tune_runs finalization REJECTED** — would make
   the run row disappear briefly and weaken lifecycle
   observability. Went with UPDATE pattern via the new
   `AutotuneDB.updateRun(...)` method.

The audit must scrutinize three high-risk surfaces:

- **Signal handler async-safety**: the `DispatchSource` handler
  is required to ONLY set a thread-safe flag; any other call
  (SQLite, print, file I/O) violates async-signal-safety.
- **Cooperative cancellation in LOCKED files**: Step 10 added
  41 lines to Stage1Iterator.swift and 53 lines to
  Stage2HillClimb.swift. Both are LOCKED. Verify the additions
  are purely additive — new init parameters with default values,
  new poll-points at boundaries — and do NOT alter any LOCKED
  contract.
- **tune_runs row lifecycle**: the provisional `internal_error`
  tripwire pattern + UPDATE-at-exit needs full coverage. Every
  exit path (ok, interrupted, no_feasible, budget_exhausted_*,
  pre_warm_integrity_failure, provider_conflict, config_error,
  internal_error) must terminate in a final `UPDATE tune_runs`
  call with the correct `exit_reason` enum value.

Operator wants an independent adversarial pass BEFORE Step 11
(acceptance test suite for AC-1 through AC-19) begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~40-50
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
10 commit (79d48ca) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Steps 1-9 are LOCKED.

Step 11 has NOT landed yet — your scope is exclusively the
Step 10 commit. This is a **read-only review**.

## Context

Step 10 wires the autotune pipeline:

1. Pre-run: open `AutotuneDB`, insert provisional `tune_runs`
   row with `exit_reason = 'internal_error'` (the tripwire),
   apply retention, install SIGINT/SIGTERM `DispatchSource`
   handlers via `AutotuneSignalSources`, sample machine
   fingerprint via `MachineFingerprinter.sample()`, compute
   wall-clock deadline.
2. Provider conflict preflight (FR-E.1): on conflict without
   `--drain` → `exit_reason = 'provider_conflict'`; with
   `--drain` → call `ProviderDrainer.drain(...)`.
3. Stage 1: `Stage1Iterator.run(...)` with `candidatesBySize`
   derived from defaults (sorted ascending) or nil under
   operator override. On `noModelFeasible` → `'no_feasible'`;
   on `preWarmIntegrityFailure` → `'pre_warm_integrity_failure'`;
   budget-mid-Stage-1 → `'budget_exhausted_no_model_selected'`.
4. Stage 2: `Stage2HillClimb.run(...)`. On `noFeasibleCell` →
   `'no_feasible'`; budget-mid-Stage-2 →
   `'budget_exhausted_with_partial_recommendation'` with
   best-so-far emitted (new `partial: Bool` field on
   `RecommendationCore`).
5. Recommendation emission via `RecommendationEmitter.build(...)`.
   Print terminal block to stdout. If `--json`: print JSON. If
   `--apply`: call `ConfigApplier.apply(...)`; print summary;
   if NOT `--drain`: print launchd restart hint to stderr.
6. Finalize: `AutotuneDB.updateRun(...)` with the final
   `exit_reason` enum value.

Interruption: `AutotuneInterruptFlag` (NSLock-guarded Bool) is
set by the `DispatchSource` handler; the main loop polls it at
Stage 1 candidate boundaries and Stage 2 cell boundaries. On
flag set: stop current provider, write `tune_runs.exit_reason
= 'interrupted'`, `endedAtUTC = nil`, exit code 130.

## Required reading (in this order)

1. The Step 10 commit via `git show 79d48ca`.

2. The Step 10 source under audit:
   - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
     (~531 lines added; the wired `run()` plus
     `AutotuneRunDependencies` injection seam).
   - `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift`
     (NEW; 87 lines: `AutotuneInterruptFlag`,
     `AutotuneSignalSources`, `MachineFingerprinter`).
   - `phase3-binary/Sources/macprovider-cli/AutotuneDB.swift`
     (+35 lines; new `updateRun(...)` method).
   - `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
     (+41 lines; cooperative cancellation hooks).
   - `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`
     (+53 lines; cooperative cancellation hooks).
   - `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
     (+8 lines; `partial: Bool` field on
     `RecommendationCore`).
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandRunTests.swift`
     (NEW; 400 lines, 15 wiring tests).
   - `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift`
     (+11 lines; new cancellation-related tests).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step10` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` §5.7 FR-G.2 (`tune_runs`
     table + normative `exit_reason` enum at lines 1108-1158).
   - §5.8 FR-H.1-4 (Ctrl-C safe, midway crash, pre-warm class,
     all-infeasible size-ordered surface at lines 1162-1207).
   - §5.6 FR-F.2 (`partial: true` is NOT documented in v0.3 —
     it's a v0.4 additive-field candidate per the BUILD
     instructions; verify implementation-notes captures this).
   - §8 AC-10 (Ctrl-C cleanup), AC-13 (wall-clock budget),
     AC-16 (stage column correctness).

4. The LOCKED Step 7 source for the additive-only check:
   `git show HEAD:phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
   vs the pre-Step-10 baseline
   `git show a9da9e5:phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`.
   Verify diff is additive-only.

5. The LOCKED Step 8 source for the additive-only check:
   `git diff 022e8a3 HEAD --
   phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`.
   Verify diff is additive-only.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation of FR-G.2 (e.g.
  exit_reason set incorrectly, endedAtUTC null when it shouldn't
  be); signal handler calls a non-async-signal-safe function;
  the LOCKED Stage1Iterator or Stage2HillClimb contracts are
  silently broken; the provisional internal_error tripwire is
  missing so a -9 kill yields a stale 'ok'; anti-regression
  broke any Step 1-9 test; recipe_hash leaks observation data
  via tune_runs.recipe_hash.
- **MAJOR** — Step 10 contract gap; an exit path is missing
  an UPDATE call; the interrupt flag is not polled at one of
  the documented boundaries; budget-mid-Stage-2 doesn't emit
  best-so-far; `partial: true` is emitted when budget did NOT
  exhaust; `--apply` failure escalates to wrong exit_reason;
  candidatesBySize derivation produces wrong order.
- **MINOR** — quality issues, naming, test edge cases.
- **QUESTION** — design choice where the SPEC was silent.

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — 363 tests must pass.
3. Strict clean-room on d-inference.
4. Read-only.
5. NO SIGKILL escalation in v1.
6. The provisional `tune_runs` row's `exit_reason =
   'internal_error'` tripwire MUST be in place.
7. Stage1Iterator + Stage2HillClimb contract changes MUST be
   additive (new init params with defaults, new poll points;
   NO removal/rename of LOCKED surface).

## Audit categories — work through each

### Category A: Signal handler async-signal-safety

A.1  Walk `AutotuneSignalSources.init`. The
     `setEventHandler` callback MUST only call
     `AutotuneInterruptFlag.set()`. Verify:
     - No `print()`, no `FileHandle.write()`, no `sqlite3_*`
       calls, no `Foundation.Date()`, no logging.
     - Only `flag.set()` which is `NSLock.lock() + value =
       true + NSLock.unlock()` — async-signal-safe by virtue
       of being a simple memory write under a pthread_mutex.

A.2  `signal(SIGINT, SIG_IGN)` and `signal(SIGTERM, SIG_IGN)`
     are called AFTER `setEventHandler` is wired but BEFORE
     `resume()`. Verify the order is safe — there should be
     no window where the signal arrives, the default handler
     terminates the process, and the DispatchSource never
     observes it.

A.3  `DispatchSourceSignal.cancel()` in `deinit` releases
     the kernel signal subscription. Verify the cancel/cancel
     order is safe.

A.4  Is there a test that synthetically exercises the
     signal-handler path? The audit prompt allows for "no
     real SIGINT" synthetic tests. Verify
     `AutotuneCommandRunTests` includes one or more tests
     that pre-set the interrupt flag and assert the main
     loop respects it.

### Category B: Cooperative interruption polling

B.1  Walk `AutotuneCommand.run()`. Identify the
     `cancellationReason()` (or equivalent) helper. It MUST
     check BOTH the interrupt flag AND the wall-clock
     deadline. Verify the poll points:
     - Before each Stage 1 candidate probe.
     - Before each Stage 2 cell.
     - Between major substeps (before --apply, etc.).

B.2  On `cancellationReason() == .interrupted`:
     - Stop the in-flight provider via
       `CandidateProviderRunner.stop(grace:)` with
       `--drain-grace`.
     - Call `updateRun(endedAtUTC: nil, exitReason:
       .interrupted, ...)`.
     - Exit with code 130.
     Walk each branch and verify.

B.3  Exit code 130 is the standard UNIX convention for SIGINT
     (128 + signal number 2). Verify the
     `ExitCode(130)` or `exit(130)` call is in place.

B.4  Does `cancellationReason()` distinguish `.interrupted`
     vs `.budgetExhausted`? Walk the enum. The distinction
     drives the exit_reason mapping (interrupted →
     'interrupted', budgetExhausted → 'budget_exhausted_*').

B.5  Stage1Iterator.swift +41 lines — verify the cooperative
     hooks. The iterator must check the cancellation predicate
     between candidates. Walk the diff and verify:
     - The new init parameter (cancellation closure?) has a
       sensible default that preserves prior test behavior.
     - The check is at the candidate-boundary, not inside the
       probe (which could leave the provider in a bad state).

B.6  Stage2HillClimb.swift +53 lines — same check at cell
     boundaries.

### Category C: Wall-clock budget enforcement (FR-H.4 / AC-13)

C.1  Walk the deadline computation:
     `deadline = startedAt.addingTimeInterval(maxDuration)`.
     Verify `startedAt` is the actual start (`Date()` at top
     of `run()`), not a later sample.

C.2  Verify the deadline check at each poll point uses
     `Date() > deadline` (or `dependencies.now() > deadline`
     for injection).

C.3  Mid-Stage-1 budget exhaustion:
     - `cancellationReason() == .budgetExhausted` while no
       model is selected.
     - `updateRun(exitReason: .budgetExhaustedNoModelSelected,
       recommendationJSON: nil, recipeHash: nil)`.
     - Emit JSON with `recommendation: null`.
     - Exit non-zero.

C.4  Mid-Stage-2 budget exhaustion:
     - At least one Stage 2 cell has been evaluated AND
       `best` is non-nil.
     - Emit the best-so-far recommendation with
       `RecommendationCore.partial = true`.
     - `updateRun(exitReason:
       .budgetExhaustedWithPartialRecommendation, ...)`.
     - Exit non-zero.

C.5  Edge: mid-Stage-2 budget hits BEFORE any cell is
     feasible. There is no best-so-far. What happens?
     - Either fall through to noFeasibleCell (one design),
     - Or emit a degenerate "no recommendation" + budget
       exhausted classification (another design).
     Walk the code and document which choice Step 10 made.
     If undefined, flag as QUESTION.

### Category D: tune_runs row lifecycle (FR-G.2)

D.1  Pre-run provisional insert:
     - `insertRun(...)` is called with `exitReason =
       'internal_error'` as the tripwire.
     - `endedAtUTC` is nil at insert time.
     Walk the insert call and verify both fields.

D.2  Final UPDATE on every exit path:
     - ok → `updateRun(endedAtUTC: <now>, exitReason: .ok,
       recommendationJSON: <json>, recipeHash: <hash>,
       applied: ...)`
     - interrupted → `updateRun(endedAtUTC: nil, exitReason:
       .interrupted, ...)` per FR-G.2 "NULL if interrupted"
     - no_feasible → `updateRun(endedAtUTC: <now>,
       exitReason: .noFeasible, recommendationJSON: nil,
       recipeHash: nil, ...)`
     - budget_exhausted_no_model_selected → ditto
     - budget_exhausted_with_partial_recommendation →
       `updateRun(endedAtUTC: <now>, exitReason:
       .budgetExhaustedWithPartialRecommendation,
       recommendationJSON: <partial-json>, recipeHash:
       <hash>, applied: ...)`. Note: the partial
       recommendation DOES have a recipe_hash (it identifies
       the recipe even though measurement was partial).
       Verify this is what Step 10 does.
     - pre_warm_integrity_failure → ditto with no
       recommendation.
     - provider_conflict → ditto.
     - config_error → if reachable (typically at flag-parse
       time which doesn't open the DB, so this enum value may
       be reserved for v2's --report-only or config write
       failures). Verify whether Step 10 emits it.
     - internal_error → fall-through path; if an unexpected
       exception throws, the provisional row's tripwire is
       what survives. Verify no exit path silently leaves
       the provisional in place.

D.3  endedAtUTC nullability. FR-G.2 schema says "NULL if
     interrupted". Verify:
     - `interrupted` → endedAtUTC = nil.
     - Every other exit_reason → endedAtUTC = <actual end
       time>.
     A drift here violates the schema comment.

D.4  Walk the test
     `testRunWritesTuneRunRowOnInterrupted` (or equivalent).
     Verify it asserts `endedAtUTC == nil` AND
     `exitReason == "interrupted"`.

### Category E: tune_runs.applied semantics

E.1  `applied = 1` ONLY when:
     - `--apply` flag is set, AND
     - `ConfigApplier.apply(...)` returned successfully.

E.2  Apply failure (e.g.
     `ConfigApplierError.backupCollisionsExhausted`):
     - `applied = 0` in tune_runs.
     - `exit_reason` is... what? Step 10 BUILD instructions
       defaulted to "do NOT escalate" — recommendation is
       still good, apply is best-effort. Verify Step 10
       chose this. If it escalates to `config_error`, flag
       as QUESTION + document the choice in
       implementation-notes.

E.3  `testApplyFlagSetsAppliedColumnInTuneRuns` and
     `testApplyFailureDoesNotSetAppliedColumn` (or
     equivalent) must cover both paths.

### Category F: exit_reason enum coverage

F.1  Walk every exit path in `AutotuneCommand.run()` and the
     wired `Stage1Iterator` / `Stage2HillClimb` error
     handling. Map each path to an `AutotuneExitReason`
     case. The 9 enum values:
     - ok
     - interrupted
     - noFeasible (= "no_feasible")
     - budgetExhaustedNoModelSelected
     - budgetExhaustedWithPartialRecommendation
     - preWarmIntegrityFailure
     - providerConflict
     - configError
     - internalError

     Every exit path must terminate in one of these. If any
     path falls through without calling `updateRun`, the
     provisional `internal_error` survives — that's the
     tripwire, not a contract violation. But missing an
     `updateRun` for a known-classifiable exit IS a contract
     gap (MAJOR).

F.2  Verify the rawValue mapping is correct (e.g.
     `noFeasible.rawValue == "no_feasible"`,
     `budgetExhaustedNoModelSelected.rawValue ==
     "budget_exhausted_no_model_selected"`).

### Category G: candidatesBySize derivation (FR-H.4)

G.1  Walk the derivation. Per the BUILD instructions:
     - When `--candidate-models` is set: `candidatesBySize =
       nil` (no size info; iterator falls back to input order
       for the error surface).
     - When the default list is used: sorted ascending by
       `sizeB`: `[1B, 3B, 7B, 14B, 32B]`.

G.2  `testCandidatesBySizeIsSortedAscendingFromDefaultList`
     verifies the sort order.

G.3  `testCandidatesBySizeIsNilWhenOperatorOverride` verifies
     the nil case.

G.4  FR-H.4 terminal output: when Stage 1 throws all-infeasible
     with the size-ordered list, the terminal block must
     lead with the SMALLEST candidate's failure reason.
     Verify by spot-checking
     `testTerminalOutputForAllInfeasibleLeadsWithSmallestSize`.

### Category H: FR-H.4 size-ordered terminal output

H.1  Walk the all-infeasible terminal block emission. The
     order MUST be smallest → largest, matching the audit
     prompt's example:
     ```
     1B (smallest): provider exited rc=137...
     3B: ttft p95 95234ms > gate...
     ...
     ```

H.2  Verify the error message hints (e.g. "lower
     --target-context or pass --candidate-models with a
     smaller model.") are emitted.

### Category I: --apply integration with ConfigApplier

I.1  Walk the apply branch in `run()`. Verify:
     - `ConfigApplier(configPath: ..., ...)` is constructed
       with the operator's config path (the existing
       constant — likely
       `~/.config/macprovider/config.yaml`).
     - On success: print `AppliedConfig.summary` to stdout.
     - On failure: print error to stderr, set
       `applied = false`, continue to finalize (per E.2
       above).

I.2  If `--apply` AND NOT `--drain`: print
     `RecommendationEmitter.launchdRestartHint()` to STDERR
     (not stdout — operator's pipeline shouldn't see the
     hint).

I.3  `testApplyFlagInvokesConfigApplier` (or equivalent) —
     verify the test injects a mock ConfigApplier and
     asserts it was called.

### Category J: --drain integration with ProviderDrainer

J.1  Walk the conflict-preflight branch. On conflict +
     `--drain`:
     - Call `ProviderDrainer.drain(...)` with appropriate
       parameters.
     - On success: continue to Stage 1.
     - On drain failure: set `exit_reason = 'provider_conflict'`
       (it's still a conflict scenario), exit non-zero.

J.2  `testDrainFlagInvokesProviderDrainerOnConflict` (or
     equivalent) — verify.

### Category K: MachineFingerprinter (resilience)

K.1  Walk `MachineFingerprinter.sample()`. Verify:
     - RAM via `sysctlbyname("hw.memsize", ...)`.
     - On sysctl failure: returns 0, then
       `max(1, ...)` ensures at least 1 GB. (Or does it
       return 0? Verify the behavior.)
     - Chip via `sysctlbyname("machdep.cpu.brand_string")`.
       Fallback to "unknown" on failure.
     - OS version via
       `ProcessInfo.processInfo.operatingSystemVersionString`.
       Always succeeds.
     - Binary version: `CoordinatorClient.binaryVersion` —
       verify this constant exists and is the canonical
       binary version (e.g. "1.4.0").

K.2  Edge: if RAM detection returns 0, the
     `MachineFingerprint.ramGB` is 1 (from the `max(1, ...)`).
     Does this break the `tune_runs.machine_ram_gb NOT NULL`
     constraint? No — 1 is non-NULL. But it would corrupt
     the recipe_hash (different machines hashing the same).
     Documented limitation acceptable for v1, but flag as
     MINOR if there's no test for this.

K.3  Is there a test for the fingerprinter's fallback paths?
     If not, MINOR.

### Category L: partial: Bool additive field

L.1  Walk the `RecommendationCore.partial: Bool = false`
     addition. Verify:
     - Default value is `false` (does not break existing
       constructors).
     - The terminal block emits the warning line
       ("warning: partial recommendation; wall-clock budget
       exhausted before Stage 2 completed.") ONLY when
       `partial == true`.
     - The JSON encoder emits `partial: true` ONLY when
       true (omit when false to keep schema clean per BUILD
       instructions). Walk the JSON encoder.

L.2  implementation-notes.html must document this as a
     SPEC-013 v0.4 additive-field candidate. Verify.

L.3  Is `partial` excluded from the recipe_hash domain? It
     SHOULD be — the recipe identifies the machine + recipe,
     not the measurement quality. Verify by reading
     `recipeHashInput(_:)`.

### Category M: LOCKED file additive-only check (Stage1Iterator + Stage2HillClimb)

M.1  Run `git diff a9da9e5
     phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`.
     The diff must show:
     - New init parameter(s) with default values (so the
       Step 7-era tests still compile).
     - New cancellation poll points at candidate boundaries.
     - NO modification to the LOCKED `Stage1IteratorResult`
       or `Stage1IteratorError` shapes.
     - NO removal of any LOCKED public method.

M.2  Run `git diff 022e8a3
     phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift`.
     Same check.

M.3  Verify the LOCKED tests for Stage 1 and Stage 2 still
     pass with the same assertions (i.e. no test had to be
     UPDATED to accept new behavior). The +11 line diff to
     Stage1IteratorTests.swift is acceptable IF it ONLY adds
     new tests for the cancellation hook AND does NOT alter
     existing test assertions.

### Category N: Anti-regression on Steps 1-9

N.1  Run `swift test --package-path phase3-binary` and verify
     363 tests + 2 skipped, 0 failures.

N.2  Verify no test file from Steps 1-9 was modified except
     Stage1IteratorTests.swift (+11 lines for the new
     cancellation tests).

### Category O: Forward-compatibility (Step 11)

O.1  Step 11 (acceptance test suite) needs:
     - The full `run()` wiring (this is Step 10's job).
     - The ability to inject mocks via
       `AutotuneRunDependencies` or equivalent for AC tests
       that don't fire real providers.
     - The `--enable-integration` flag for AC-6 / AC-7 (real
       provider tests).
     Walk the `AutotuneRunDependencies` struct (the codex
     commit message references it as a DI seam). Verify
     it's sufficient for Step 11 to construct mocked
     pipelines.

O.2  Verify `tune_runs.recipe_hash` is the correct column
     for AC-12's same-machine determinism test (Step 11
     will assert two runs produce the same recipe_hash).

### Category P: Anything else

Examples:
- implementation-notes.html accurately describes signal
  handling pattern, provisional-row tripwire, partial: true
  additive field, candidatesBySize derivation, applied
  semantics on apply failure, --report-only v1 decision.
- Naming consistency with prior steps.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 18 audit (Codex on 79d48ca — Step 10 round 1)

**Audited:** commit 79d48ca on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 10, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 10 readiness:** [READY TO PROCEED TO STEP 11 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-P.
```

## Out of scope

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1-9 (LOCKED)
- Auditing Step 11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK

## Done criteria

- New `## Round 18 audit ...` section appended
- Earlier rounds (1-17) unchanged
- Every category A-P has a section (even if `(no findings)`)
- Every finding has severity, location, what / why /
  recommendation
- `swift test --package-path phase3-binary` was run and the
  result reported
- The `git diff a9da9e5 ... Stage1Iterator.swift` and
  `git diff 022e8a3 ... Stage2HillClimb.swift` LOCKED-file
  additive-only checks were performed
- Verdict line states READY TO PROCEED TO STEP 11 or FIX
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~40-50 min.
- The signal-handler async-safety (Category A) and the
  LOCKED-file additive-only check (Category M) are the
  highest-stakes surfaces. A non-async-safe signal handler is
  CRITICAL; a non-additive Step 7/8 change unwinds the LOCKs.
- The tune_runs row lifecycle (Category D) is the load-bearing
  observability surface. Every exit path must terminate in an
  UPDATE.
- If verdict is READY TO PROCEED TO STEP 11: Claude commits and
  fires Step 11 (acceptance test suite for AC-1 through AC-19).
- If verdict is FIX REQUIRED: fix-pass + next round.

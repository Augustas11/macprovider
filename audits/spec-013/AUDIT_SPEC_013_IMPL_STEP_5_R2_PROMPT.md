# Implementation audit prompt — SPEC-013 Step 5 round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify the round-1 audit
closures landed in commit 3adddbf on branch
`feat/cli-autotune-impl`.

Round 1 (codex on d40a6f7) returned `0 CRITICAL / 0 MAJOR / 4
MINOR / 0 QUESTION`, verdict READY TO PROCEED. The round-1
verdict already allowed Step 6 to begin, but the fix-pass closed
3 of 4 MINORs as pure test-coverage locks (matching the Step 1
discipline). The 4th MINOR (H.1 restore idempotency) is deferred
to Step 10 with a forward-compat note.

Round 2 verifies the 3 closures and confirms H.1's Step-10
deferral is well-justified.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~8-12
min (test-only fix-pass; narrow review surface). This is a
**read-only review**.

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 5 implementation audit on
branch `feat/cli-autotune-impl`. The branch is already checked
out at `/Users/augstar/macprovider-poc`.

Round 1 was you (Codex) on commit d40a6f7; the report is at
specs/SPEC-013-impl-audit.md § Round 7. Round 1 returned 0
CRITICAL / 0 MAJOR / 4 MINOR (G.1, G.2, G.3, H.1) / 0 QUESTION,
verdict READY TO PROCEED. Commit 3adddbf is the audit-response
fix-pass; it claims to close G.1 + G.2 + G.3 (pure test
additions) and defer H.1 to Step 10 with a documented note.

Round 2 has two questions:

1. Did 3adddbf actually close G.1, G.2, G.3 with meaningful
   tests (not tautological)?
2. Is the H.1 deferral well-justified, and is there a
   forward-compat note that Step 10 can find?

Round 2 is NARROW — only test additions + a documentation
entry to spot-check.

This is a **read-only review**.

## Required reading (narrow)

1. The audit-response commit via `git show 3adddbf`.

2. The round-1 report:
   `specs/SPEC-013-impl-audit.md` § Round 7.

3. The Step 5 source under audit (post-fix; production code
   was NOT touched, only tests + notes):
   - `phase3-binary/Tests/macprovider-cliTests/ProviderConflictDetectorTests.swift`
     — the 3 new test methods.
   - `phase3-binary/implementation-notes.html` — the new
     `Step 5 round-1 audit response` entry.

4. The unchanged production sources for cross-reference:
   - `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift`
     — the parser, detector, and drainer the new tests
     exercise.

5. Run `swift test --package-path phase3-binary` and report
   the result. Fix-pass claims 286 tests (283 baseline + 3
   new), 2 skipped integration-gated.

## Severity definitions (unchanged)

- **CRITICAL** — round-1 closure claim is COSMETIC; production
  code regressed; anti-regression broke a test.
- **MAJOR** — closure is incomplete; new test passes by
  tautology (constructs an object without exercising the
  claimed contract); fix-pass introduced a precision gap.
- **MINOR** — quality issues.
- **QUESTION** — design choice the deferral made where Step
  10's contract isn't yet pinned.

## Critical constraints (unchanged)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — 286 tests must pass; production code
   change list MUST be empty (verify via
   `git diff d40a6f7 3adddbf -- phase3-binary/Sources/`).
3. Strict clean-room on d-inference.
4. Read-only.

## Round 2 audit categories — very narrow

### Category Z-CLOSURE

For each of the 3 round-1 MINOR closures (and the 1 deferral):

- **G.1 (MINOR)** Inactive launchd PID untested → 3adddbf
  added `testParseLaunchdManagedInactivePIDReturnsNil` in
  `ProviderConflictDetectorTests`. Verify:
  - The test inputs `-\t-\tlive.streamvc.macprovider\n` to
    `parseLaunchdManagedPID(from:)`.
  - Asserts `(found: true, pid: nil)` — both fields.
  - Lives in the DETECTOR test class (not the drainer class).

- **G.2 (MINOR)** Helper-binary false-positive untested →
  3adddbf added `testHelperBinaryDoesNotMatchForegroundServe`.
  Verify:
  - The test constructs a detector with a process list
    containing `["/usr/local/bin/macprovider-cli-helper", "serve"]`.
  - Asserts `try detector.detect()` returns `.none`.
  - The test would FAIL if `isForegroundServe` used substring
    matching instead of `lastPathComponent` equality.

- **G.3 (MINOR)** SIGKILL-disabled warning untested → 3adddbf
  added
  `testForegroundDrainEmitsNoSIGKILLWarningWhenProcessRemainsAfterGrace`
  in `ProviderDrainerTests`. Verify:
  - The test injects `processIsRunning: {_ in true}` (sticks
    alive) + `portIsOpen: {_ in false}` (port released).
  - Asserts `signalSender` received SIGTERM.
  - Asserts `warningWriter` received a message containing the
    PID and `SIGKILL is disabled in v1`.
  - Asserts the result is `.drained` (port-free wins the enum)
    rather than `.portStillOpen`.

- **H.1 (MINOR) DEFERRED**: round-1 noted restore isn't
  idempotent. 3adddbf does NOT fix the production code; it
  adds a forward-compat note to implementation-notes.html
  saying Step 10 owns the call-once discipline. Verify:
  - The implementation-notes entry exists and is precisely
    worded.
  - The deferral rationale is sound (Step 10 is the
    appropriate owner because it wires lifecycle cleanup).

### Category R-REGRESSION-V05F1

Run `git diff d40a6f7 3adddbf -- phase3-binary/Sources/`. The
diff should be EMPTY — production code was not touched. Any
unintended production change = CRITICAL.

Run `swift test` and verify 286 passing + 2 skipped, 0
failures.

### Category N-NEWGAPS-V05F1

Are the new tests well-formed?

- Test class placement: the parser test and helper-binary
  test belong in `ProviderConflictDetectorTests`; the warning
  test belongs in `ProviderDrainerTests`. Verify by reading
  the file structure.
- Tautology check: each test must assert behavior that would
  CHANGE if the corresponding implementation was broken.
- DI surface use: the warning test correctly uses ALL the
  necessary injectors (`signalSender`, `processIsRunning`,
  `portIsOpen`, `warningWriter`).

### Category O-OTHER-V05F1

Use sparingly.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 8 audit (Codex on 3adddbf — Step 5 round 2 closure verification)

**Audited:** commit 3adddbf on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 5, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED / N DEFERRED] across the 4 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 5 readiness:** [READY TO PROCEED TO STEP 6 / NARROW V2 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

For each of the 4 round-1 findings (G.1, G.2, G.3, H.1):
closure / deferral verdict + one-paragraph rationale.

### Round-2 new findings

Group by category Z / R / N / O.

### Step 5 readiness verdict

State READY TO PROCEED TO STEP 6 or NARROW V2 REQUIRED.
```

## Out of scope

- Re-litigating round-1 findings already closed
- Rewriting code
- Auditing Steps 6-11 (not yet started)

## Done criteria

- New section appended to the audit file
- Rounds 1-7 unchanged
- 4 round-1 findings have closure / deferral verdicts
- Anti-regression confirmed (286 tests, 0 production diff in
  Sources/)
- Verdict line states READY TO PROCEED TO STEP 6 or NARROW V2
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: ~8-12 min.
- If verdict is READY TO PROCEED TO STEP 6: Claude commits and
  fires Step 6 (pre-warm — Shape A vs Shape B).
- If verdict is NARROW V2 REQUIRED: tiny fix-pass + round-3.

# Implementation audit prompt — SPEC-013 Step 4 round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify the round-1 audit
closures landed in commit 4bcef89 on branch
`feat/cli-autotune-impl`.

Round 1 (codex on 994c7ee) returned `0 CRITICAL / 2 MAJOR / 2
MINOR / 1 QUESTION`, verdict FIX REQUIRED. Round 2 verifies the
5 closures and checks the fix-pass didn't introduce new gaps.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~10-15
min (narrow scope — verify 5 specific closures + spot-check the
fix-pass).

---

```
=== BEGIN PROMPT ===

You are running round 2 of the Step 4 implementation audit on
branch `feat/cli-autotune-impl`. The branch is already checked
out at `/Users/augstar/macprovider-poc`.

Round 1 was you (Codex) on commit 994c7ee; the report is at
specs/SPEC-013-impl-audit.md § Round 5. Round 1 returned
0 CRITICAL / 2 MAJOR (B.1, C.1) / 2 MINOR (E.1, I.1) /
1 QUESTION (A.1) with verdict FIX REQUIRED. Commit 4bcef89 is
the audit-response fix-pass; it claims to close all 5.

Round 2 has two questions:

1. Did 4bcef89 actually close each of the 5 round-1 findings?
2. Did the fix-pass introduce any NEW contract precision gap?

Round 2 is NARROWER than round 1. Findings unrelated to the
5 round-1 closures are accepted but should be rare.

This is a **read-only review**. You MUST NOT edit any file,
commit, push, or modify the git state.

## Required reading (narrow)

1. The audit-response commit via `git show 4bcef89`. The commit
   message enumerates each closure claim with specific test
   names.

2. The round-1 report (round 5 in the audit history):
   `specs/SPEC-013-impl-audit.md` § Round 5.

3. The Step 4 source under audit (post-fix):
   - `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift`
   - `phase3-binary/Tests/macprovider-cliTests/CandidateProviderRunnerTests.swift`
   - `phase3-binary/implementation-notes.html` (new Step 4
     audit-response entry).

4. Run `swift test --package-path phase3-binary` and report the
   result in the round-2 executive summary. The fix-pass claims
   273 tests passing (266 baseline + 7 new), 1 skipped
   integration-gated test.

## Severity definitions (unchanged from round 1)

- **CRITICAL** — round-1 closure claim is COSMETIC and the
  failure mode still applies; fix-pass introduced a contract
  violation; anti-regression broke a test that was passing in
  994c7ee.
- **MAJOR** — round-1 closure is incomplete; fix-pass introduced
  a new precision gap; a new test passes by tautology.
- **MINOR** — quality issues that don't block Step 5.
- **QUESTION** — design choice the fix-pass made where the spec
  was silent.

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Biggest-fit, not max-tps.
3. Anti-regression discipline — 273 tests must pass.
4. Strict clean-room on d-inference.
5. Read-only.
6. NO SIGKILL escalation in v1 (Step 4 forbids; Step 5 will
   own launchd-specific paths). Verify the fix-pass did NOT
   add SIGKILL.

## Round 2 audit categories — narrow

### Category Z-CLOSURE: did 4bcef89 close the round-1 five?

For each round-1 finding, write CLOSED / PARTIAL / NOT CLOSED /
OVER-CLOSED with a one-paragraph rationale:

- **B.1 (MAJOR)** Spawn-failure pipe-drain hang → 4bcef89
  added `RunningProvider.discardLogging(reason:)` which closes
  the log file without calling `readDataToEndOfFile()`. The
  catch path in `start()` now calls `discardLogging` instead
  of `finishLogging`. Verify:
  - The fix doesn't drain the pipes (no readDataToEndOfFile
    call in discardLogging).
  - The log file is still closed with synchronizeFile (no
    sync-deferred handle leak).
  - The test
    `testStartFailsPromptlyWithMissingBinary` actually
    exercises the no-binary path AND asserts < 1s elapsed.
  - Try reproducing the 2-second hang: with a missing binary
    path, run `start()` synchronously — should throw promptly.

- **C.1 (MAJOR)** waitForReady skips post-200 isRunning check
  → 4bcef89 added an explicit isRunning check after the HTTP
  200 branch. Verify:
  - The check is BEFORE `return .ready`.
  - On `false`, it returns `.processExited(rc:stderrTail:)`
    with the same fields as the pre-loop check.
  - It calls `clearCurrentIfSame(provider)` like the other
    exit paths to maintain invariant.
  - The test
    `testWaitForReadyHandlesImmediateExitAfterFirstResponse`
    uses a Python stub. Verify the stub correctly responds
    200 and immediately exits.
  - The test asserts non-timeout outcome but accepts both
    .ready and .processExited (the race winner). Is this
    contract-meaningful? YES — the pre-fix bug was timeouts
    or silent .ready-on-dead. The test locks both regression
    classes.

- **A.1 (QUESTION)** stop() lacked stuck-provider signal →
  4bcef89 changed return type to `StopResult` enum
  (.stopped / .stuck(pid:)) with `@discardableResult`.
  Verify:
  - Existing callers (`runner.stop(graceSeconds: 2)` ignored
    returns) still compile.
  - The `.stuck` case is returned ONLY when grace expires
    with process still running (not when port-only-held).
  - The new test
    `testStopReturnsStoppedForNeverStartedRunner` covers the
    .stopped happy path. (The .stuck path being hard to
    deterministically reach is documented in the commit
    message; acceptable.)

- **E.1 (MINOR)** argv tests covered only kvBits → 4bcef89
  added 3 new tests: invalidPort (0 and 65_536),
  invalidMaxContext (0), invalidMaxBatch (0). Verify all 3
  hit `CandidateProviderRunnerError` cases with the right
  enum case.

- **I.1 (MINOR)** log filename collision → 4bcef89 appended
  the first 8 chars of a UUID. Verify:
  - The UUID is generated EACH CALL to logFileURL (not cached).
  - The new test
    `testLogFileURLsDoNotCollideWithinOneSecond` actually
    builds two URLs in quick succession and asserts distinct
    last path components.

### Category R-REGRESSION-V04F1: anti-regression on the unchanged Step 4 surface

The fix-pass edited specific lines in
`CandidateProviderRunner.swift` and added one new method. Spot-
check that nothing else was incidentally edited:

- The single-provider invariant (lock discipline) — unchanged.
- The `stop()` core logic (terminate, polls, port check) —
  unchanged except for the new return value.
- The argv assembly (`serveArguments`) — unchanged; only the
  test coverage extended.
- The `RunningProvider` `finishLogging()` — unchanged; the
  new `discardLogging` is a sibling method.

If any of these surfaces was incidentally weakened = CRITICAL
anti-regression.

### Category N-NEWGAPS-V04F1: precision gaps introduced by the fix-pass

Spot-check the fix-pass's specific edits:

- **`discardLogging(reason:)`.** Does it correctly clear BOTH
  stdout and stderr readability handlers? Does it write the
  failure note to the log file? Does it close the file with
  synchronizeFile? Is the `closed = true` guard in place?
- **Post-200 isRunning check.** What if the process exits
  EXACTLY between the isRunning check and the return? This is
  the same race the fix tries to close; the race window is
  now microseconds instead of milliseconds. Acceptable per
  practical engineering; flag as QUESTION if you think the
  spec demands stronger.
- **StopResult.stuck pid.** Is `provider.process.processIdentifier`
  valid AFTER the grace window expires? Apple docs say it's
  valid during the process lifetime; after exit it's
  undefined. The .stuck case fires only when isRunning is
  true at end of grace, so PID should be valid.
- **UUID suffix.** Does the 8-character UUID prefix have
  enough entropy? 32 bits = 4 billion combinations; collision
  probability for ~10 concurrent starts is negligible.
  Acceptable.
- **`logFileURLForTesting` test accessor.** The function is
  added to the production source file but only intended for
  tests. Is there a risk of production code calling it? The
  naming convention suggests no; acceptable.
- **Python stub fixture.** Hard-codes `#!/usr/bin/env python3`.
  On a Mac without python3, the test fails. macOS ships
  python3 by default (Xcode dependency); acceptable. Flag as
  MINOR if you think CI environments might lack it.

### Category O-OTHER-V04F1: catch-all

Use sparingly.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 6 audit (Codex on 4bcef89 — Step 4 round 2 closure verification)

**Audited:** commit 4bcef89 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 4, round 2 of N
**Date:** 2026-06-18
**Closure summary:** [N CLOSED / N PARTIAL / N NOT CLOSED /
                     N OVER-CLOSED] across the 5 round-1 findings
**Round-2 findings:** [N CRITICAL anti-regression / N MAJOR new /
                      N MINOR new]
**Step 4 readiness:** [READY TO PROCEED TO STEP 5 / NARROW V2 REQUIRED]

### Executive summary

[1-2 paragraphs.]

### Round-1 finding closures

For each of the 5 round-1 findings (B.1, C.1, A.1, E.1, I.1):
closure verdict + one-paragraph rationale.

### Round-2 new findings

Group by category Z / R / N / O. Empty categories: `(no findings)`.

### Step 4 readiness verdict

State READY TO PROCEED TO STEP 5 or NARROW V2 REQUIRED.
```

## Out of scope for round 2

- Re-litigating round-1 findings already closed
- Rewriting the code
- Auditing Steps 5-11 (not yet started)
- Inspecting d-inference source

## Done criteria

You are done when:

- The new `## Round 6 audit ...` section is appended
- Earlier rounds (1-5) are unchanged
- Each of 5 round-1 findings has an explicit closure verdict
- Each round-2 new finding (if any) has severity, location,
  what / why / recommendation
- `swift test --package-path phase3-binary` was run and the
  result is reported in the executive summary
- The verdict line states READY TO PROCEED TO STEP 5 or
  NARROW V2 REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: ~10-15 min.
- If verdict is READY TO PROCEED TO STEP 5: Claude commits the
  audit report and fires Step 5 (provider-conflict pre-flight +
  launchd drain).
- If verdict is NARROW V2 REQUIRED: Claude rolls another
  fix-pass + a round-3 prompt. Loop until 0 CRITICAL / 0 MAJOR.

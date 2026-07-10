# Implementation audit prompt — SPEC-013 Step 2 (`serve --no-join`)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / Swift-idiom review** of the Step 2 commit that
landed `serve --no-join` on branch `feat/cli-autotune-impl`.

Step 2 carries:

| Commit | Step | Scope |
|---|---|---|
| ffb00fb | 2 | `--no-join` flag on `ServeCommand`; `makeCoordinatorClient(noJoin:factory:)` testable guard; `coordinatorClient` made optional in the serve path |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line. Codex (the implementer) raised zero Open Questions.
Operator wants an independent adversarial pass BEFORE Step 3
(SQLite DB layer) begins, so any contract or quality defect in the
serve-path change is caught before later steps build on it.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-25 min
(narrow scope — one flag + one helper + 3 tests + downstream
`?.`-call propagation). This is a **read-only review** — Codex
MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
2 commit (ffb00fb) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Step 1 (commit 02b038d) is
LOCKED after a 2-round audit cycle; full Step-1 audit history at
specs/SPEC-013-impl-audit.md.

Steps 3-11 have NOT landed yet — your scope is exclusively the
Step 2 commit and its anti-regression impact on the existing
`ServeCommand` runtime path.

This is a **read-only review**. You MUST NOT edit any file,
commit, push, or modify the git state. Your only output is the
appended findings section.

## Context

Step 2 of `specs/BUILD_SPEC_013_PROMPT.md` calls for adding a
`--no-join` flag to `macprovider-cli serve`. SPEC-013 FR-E.2
requires:
- When `--no-join` is set: the binary does NOT establish a WS
  session with the coordinator.
- Local `/v1/models`, `/v1/chat/completions` etc. surfaces
  remain reachable on `127.0.0.1:<port>`.
- On exit, no `state_update reason: "shutdown"` flows (because no
  WS session existed).
- This is the DEFAULT for autotune candidate providers (Step 7
  Stage 1 iteration spawns providers with `--no-join`).

Step 2 is ADDITIVE. With `--no-join` ABSENT (the default), every
existing `serve` behavior MUST be byte-identical to pre-Step-2.
This is the load-bearing anti-regression invariant.

The code style guide is the existing
`phase3-binary/Sources/macprovider-cli/` (MacProviderCLI.swift,
SelfUpdate.swift, UninstallCommand.swift).

## Required reading (narrow)

1. The Step 2 commit via `git show ffb00fb`. The commit message
   contains the testing claims and the picked design (a
   testable static guard `makeCoordinatorClient(noJoin:factory:)`).

2. The Step 2 source under audit:
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     — the `ServeCommand` flag set + the new guard + the
     downstream `?.` propagation on `coordinatorClient`.
   - `phase3-binary/Tests/macprovider-cliTests/ServeCommandTests.swift`
     (NEW, 40 lines, 3 tests).
   - `phase3-binary/implementation-notes.html` — the new
     `spec013-autotune-step2` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §5.5 FR-E.2 — the
     three sub-bullets that define `--no-join` semantics:
     - no WS session
     - local /v1/* still reachable
     - no `state_update reason: "shutdown"` on exit
   - §3 architecture "Coordinator-pool invariant" — the
     reason `--no-join` is required.

4. Existing serve-path code that the change touched
   downstream:
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     lines 188-330 — verify every former
     `coordinatorClient.X` call is now correctly `coordinatorClient?.X`
     and no required call was missed.
   - `installTerminationHandlers` (line 306) — its signature
     accepted `CoordinatorClient` before; now takes
     `CoordinatorClient?`. Verify callers' compatibility.

5. Local style guide:
   - `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` /
     `UninstallCommand.swift` — patterns for flag declaration
     style, help-string conventions.
   - SPEC-013 Step 1 commit (02b038d) `AutotuneCommand.swift`
     — the recent Swift idioms in this codebase.

You do NOT need to re-read SPEC-001 § 6 (`/v1/*` surface), the
prototype `beta/autotune.py`, or other SPECs unrelated to FR-E.2.

## Severity definitions (unchanged from Step 1)

- **CRITICAL** — silent contract violation of FR-E.2 (e.g.
  `--no-join` is set but the coordinator client IS instantiated
  somewhere); anti-regression broke an existing serve-path
  test; introduces a security hole; the default no-flag serve
  path no longer creates a coordinator client (silent regression
  on every existing operator install).
- **MAJOR** — Step 2 contract gap (e.g. `--no-join` skips the
  coordinator but the local /v1/* surfaces also fail to come
  up); Swift-idiom mismatch (e.g. force-unwrap on the now-optional
  `coordinatorClient`); test gap that lets a silent regression
  land (e.g. no test confirms the default `noJoin = false` path
  still produces a non-nil client); a downstream call site that
  needed `?.` but got `.` and now crashes on `--no-join` runs.
- **MINOR** — quality issues that don't block Step 3.
- **QUESTION** — design choice Step 2 made where the spec was
  silent.

## Critical constraints (unchanged from Step 1)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression discipline — the default no-flag serve path
   MUST be byte-identical to pre-Step-2. Run `swift test
   --package-path phase3-binary` and verify ALL existing tests
   still pass; the commit claims 256 (245 baseline + 8 from Step
   1 fix-pass + 3 from Step 2 = 256).
3. Strict clean-room on d-inference.
4. Read-only.

Additionally for Step 2:

5. **Optional propagation discipline.** The change made
   `coordinatorClient: CoordinatorClient?`. Every downstream call
   site MUST use `?.` (or a `guard let` / `if let`) — a direct
   `.` call would crash on `--no-join` runs. Grep for any
   `coordinatorClient.` (no `?`) usage post-Step-2 and flag as
   CRITICAL.

## Audit categories — narrow

### Category A: SPEC-013 FR-E.2 coverage for Step 2 scope

A.1  FR-E.2 sub-bullet 1: "the candidate binary does NOT
     establish a WS session with the coordinator." Verify the
     guard short-circuits BEFORE `CoordinatorClient.init`. If
     the factory closure is invoked when `noJoin` is true (even
     if the result is discarded), the side effects of init
     (e.g. WS dial, key generation) would have already happened
     = MAJOR.

A.2  FR-E.2 sub-bullet 2: "local /v1/models, /v1/chat/completions
     etc. surfaces remain reachable on 127.0.0.1:<port>." The
     local HTTP server is set up earlier in `run()` and is
     unaffected by `coordinatorClient`. Verify by reading the
     `run()` body — the HTTP server setup MUST sit before or
     parallel to the coordinator client and MUST NOT be gated
     on `noJoin`. If `--no-join` accidentally skips local
     serving = CRITICAL.

A.3  FR-E.2 sub-bullet 3: "on exit, no `state_update reason:
     \"shutdown\"` flows." The shutdown path is in
     `installTerminationHandlers` — verify it now uses
     `coordinatorClient?.drainAndExit(...)` so the call is a
     no-op when no client exists. If the call is `.` instead of
     `?.` = CRITICAL (crash on `--no-join` shutdown). If the
     call is `?.` but the test doesn't actually exercise this =
     MINOR.

A.4  `--no-join` ABSENT default: `noJoin: Bool = false`. Verify
     the default works as before. `testDefaultServePathInvokesCoordinatorClientFactory`
     covers this. If the default in `@Flag` is missing or wrong
     type = CRITICAL.

A.5  Implementation precondition status: SPEC-013 §5.5 FR-E.2
     names `--no-join` as an implementation precondition. Step
     2 adds it. Verify the resulting CLI surface
     (`macprovider-cli serve --help`) does include `--no-join`
     in the help text. If the flag is declared but not visible
     in `--help` (e.g. due to `@Flag` configuration) = MAJOR.

A.6  Compatibility with other ServeCommand flags. Step 2
     defines `--no-join` AFTER all the PR #105 flags
     (`--kv-bits`, `--max-context`, `--max-batch`) and the
     SPEC-011 warm-swap flag. Verify the new flag does not
     conflict with `--enable-warm-swap` (SPEC-011 v0.5) — e.g.
     `serve --no-join --enable-warm-swap` should still parse;
     warm-swap's control socket is independent of the coordinator
     WS session.

### Category B: Code quality (Swift idioms)

B.1  Static helper `makeCoordinatorClient(noJoin:factory:)`:
     using a closure-factory for testability is a clean
     dependency-injection pattern. Verify the closure has no
     side effects when called (it does — it creates a
     CoordinatorClient). The test
     `testNoJoinSkipsCoordinatorClientInstantiation` correctly
     asserts the factory closure is NOT invoked when `noJoin
     = true`. Good.

B.2  Optional propagation: every callsite of `coordinatorClient`
     that was previously `.X` MUST now be `?.X`. Specifically
     verify lines 216, 222, 315. Grep for the exact strings:
     - `coordinatorClient.start` (no `?`) — should be 0 occurrences
     - `coordinatorClient.stop` — should be 0 occurrences
     - `coordinatorClient.drainAndExit` — should be 0 occurrences
     If ANY direct call survives = CRITICAL.

B.3  `installTerminationHandlers` signature update: parameter
     type changed to `CoordinatorClient?`. Verify the function
     body's internal use of the parameter also uses `?.` and
     not unwrap. If it does `coordinatorClient!.X` anywhere =
     MAJOR.

B.4  `@Flag(help: ...)` style: verify the help string is
     consistent with sibling flags in `ServeCommand`. The
     current string is "Run only the local HTTP server; do not
     establish a coordinator WebSocket session." — clear and
     operator-readable.

B.5  Force-unwraps: search the diff for any `!` outside type
     ascription. The commit has none — verify.

B.6  Race-condition risk: `coordinatorClient?.stop()` on
     shutdown — is there a race where `coordinatorClient` could
     be `nil` AFTER being set (e.g. via an async assignment)?
     No — it's a `let` constant. Good.

### Category C: Test coverage

C.1  Walk `ServeCommandTests.swift`:
     - `testNoJoinFlagParses` — flag declared correctly
     - `testNoJoinSkipsCoordinatorClientInstantiation` —
       factory NOT invoked when noJoin = true. Verifies FR-E.2
       sub-bullet 1.
     - `testDefaultServePathInvokesCoordinatorClientFactory` —
       factory IS invoked when noJoin = false. Anti-regression
       lock on the default path.

C.2  Coverage gaps for Step 2's scope:
     - Is there a test that the LOCAL HTTP surfaces still come
       up under `--no-join`? Step 2 cannot easily test this
       without actually running a real `serve` (which loads a
       model), so this is acceptable as an integration-test
       deferral. But the commit message should note it (it does
       — `Not-tested: Live model-serving smoke with real
       weights`).
     - Is there a test that an exit path with `--no-join` does
       NOT crash? The optional propagation tests cover this at
       the type-system level (a `?.` chain on nil is a no-op),
       but an end-to-end SIGTERM test would be more
       convincing. Acceptable as integration deferral; flag as
       MINOR if you think it should be unit-tested.
     - Is there a test of `--no-join --enable-warm-swap`
       coexistence? Probably overkill for Step 2; flag as
       MINOR or QUESTION if you think it matters.

C.3  Anti-regression: run `swift test --package-path
     phase3-binary` and verify ALL existing tests still pass.
     A new test failure outside ServeCommandTests = CRITICAL
     anti-regression.

### Category D: Anti-regression on the existing serve path

D.1  Read the MacProviderCLI.swift diff carefully. The change
     is supposed to be minimal and additive. List every
     non-flag-addition edit and verify each is justified by the
     optional-propagation cascade. Any other edit (e.g. a
     reformatted line, a renamed variable) = MINOR (or MAJOR
     if it's behavioral).

D.2  The control-socket / warm-swap setup at line 192 is
     downstream of coordinator-client setup. Verify it still
     gets reached on both `--no-join` and default paths. If
     `--no-join` accidentally short-circuits the control
     socket = MAJOR.

D.3  Did adding the flag change the `ServeCommand` argument
     parser's behavior for OTHER flags? E.g. did it shift the
     subcommand's help output column alignment, surprise
     alphabetization, etc.? Minor formatting drift = MINOR.

D.4  Run `phase3-binary/.build/debug/macprovider-cli serve
     --help` and verify the flag list still contains all PR
     #105 flags (`--kv-bits`, `--max-context`, `--max-batch`),
     all SPEC-011 flags (`--enable-warm-swap`,
     `--ctl-socket-path`), and the new `--no-join`. Any flag
     accidentally dropped = CRITICAL.

### Category E: Forward-compatibility (does Step 2 paint Step 3+ into a corner?)

E.1  Step 7 (Stage 1 iteration) will spawn `serve --no-join`
     as subprocess and probe `127.0.0.1:<port>/v1/models`. Step
     2's no-join semantics must support this. The factory-guard
     pattern leaves the rest of the serve setup intact, so
     Step 7's subprocess pattern will work. = no finding.

E.2  Step 5 (`--drain` semantics) needs to interact with a
     running `serve` — possibly a `--no-join` one. The drain
     path uses `coordinatorClient?.drainAndExit(...)` which is
     a no-op for `--no-join` providers; this is correct (no
     coordinator to drain), but Step 5 will need to drain the
     LOCAL HTTP server separately if needed for autotune. This
     is a Step 5 concern, not a Step 2 finding.

### Category O: Anything else

Use sparingly. Examples that DO belong here:
- Step 2 implementation-notes section has a typo or references
  the wrong audit document
- Commit message references a wrong audit-finding ID
- Help string for the flag is grammatically incorrect

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 3 audit (Codex on ffb00fb — Step 2 round 1)

**Audited:** commit ffb00fb on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 2, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 2 readiness:** [READY TO PROCEED TO STEP 3 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs. Was Step 2 implemented to the BUILD prompt's
contract? Are there blockers for Step 3? Be specific.]

### Findings

Group by category A-E + O. Same finding format as the prior
audits in this file (severity, location, what / why /
recommendation).
```

## Out of scope for this audit

- Inspecting d-inference source
- Modifying any file
- Re-litigating Step 1 (LOCKED)
- Auditing Steps 3-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK

## Done criteria

You are done when:

- The new `## Round 3 audit ...` section is appended to
  `/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`.
- Earlier sections (round 1, round 2 of Step 1) are unchanged.
- Every category A-E + O has a section (even if "(no findings)")
- Every finding has severity, location, what / why /
  recommendation
- The verdict line states READY TO PROCEED TO STEP 3 or
  FIX REQUIRED
- `swift test --package-path phase3-binary` was run and the
  result reported in the executive summary

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 15-25 min (narrow scope — one flag + one
  helper + 3 tests + the optional-propagation cascade).
- If verdict is READY TO PROCEED TO STEP 3: Claude commits the
  audit prompt + report and immediately fires codex on Step 3
  (SQLite DB layer — the heaviest step so far).
- If verdict is FIX REQUIRED: Claude rolls a fix-pass + the
  next round prompt. Loop until 0 CRITICAL / 0 MAJOR.

# SPEC-013 implementation audit — Step 1

**Audited:** commit facbaef on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 1, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 1 MAJOR / 3 MINOR / 0 QUESTION
**Step 1 readiness:** FIX REQUIRED
**Verdict:** FIX REQUIRED

---

## Executive summary

FIX REQUIRED. Step 1 correctly adds the `autotune` parser scaffold, registers it under `macprovider-cli`, exposes all 23 SPEC-013 §7 flags with the expected defaults, preserves explicit candidate order in the normal case, prints the default dry-run candidate plan, and exits non-zero on non-dry-run execution paths. The Step 1 commit does not introduce an anti-regression failure: `swift test --package-path phase3-binary` passed on 2026-06-18 with 245 XCTest tests, 0 failures, and the Swift Testing runner also passed with 0 tests.

One MAJOR parser contract gap blocks proceeding to Step 2: `--max-context-axis` silently accepts empty cells inside a non-empty CSV, e.g. `--max-context-axis 4000,,8000`, because the shared CSV helper drops empty tokens. SPEC-013 FR-B.1 requires a provided `--max-context-axis` to be a comma-separated list of positive integers, with invalid cells rejected at flag-parse time; accepting a missing cell changes the Stage 2 search space silently.

Other findings are non-blocking but should be closed with the parser fix: explicit candidate CSVs also drop empty tokens, `run()` redundantly revalidates after ArgumentParser validation, and the new tests do not yet pin several Step 1 contracts that this scaffold is meant to protect.

## Category A: SPEC-013 FR coverage for Step 1 scope

### A.4  `--max-context-axis` accepts empty CSV cells   MAJOR
Location: `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift` lines 198-201 and 247-264

`parseCSV` uses `split(separator: ",")` and filters empty cells, so `parseMaxContextAxis` never sees empty cells inside a non-empty axis. In a smoke check, `phase3-binary/.build/debug/macprovider-cli autotune --target-context 4000 --max-context-axis 4000,,8000 --dry-run` exited 0 and printed `max_context_axis=4000,,8000`.

FR-B.1 requires a provided `--max-context-axis <csv>` to parse as positive integers, sort ascending, reject below-target cells, reject duplicates, and reject invalid cells at flag-parse time. A missing cell in a non-empty CSV is not a positive integer; silently dropping it lets an operator typo alter the Stage 2 search space without a `config_error`.

Recommendation: make the axis parser preserve empty subsequences and reject empty cells for non-empty `--max-context-axis` values. Keep the raw empty string as the single supported empty-axis default that maps to `[--target-context]`.

## Category B: Code quality (Swift idioms vs local style guide)

### B.2  `run()` repeats ArgumentParser validation   MINOR
Location: `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift` lines 93-99

`AutotuneCommand` implements `mutating func validate()` and also calls `validateBasicInputs()` at the top of `run()`. The pinned `swift-argument-parser` version is 1.8.2, and the current test `XCTAssertThrowsError(try AutotuneCommand.parse(...))` for a below-target `--max-context-axis` confirms validation runs during parse.

The duplicate validation is harmless while the validators are pure, but it is redundant and creates a future footgun if later Step 3+ validation grows side effects, filesystem checks, DB writes, or expensive probes.

Recommendation: rely on `validate()` for parser-time checks, or keep a clearly named pure shared validator only if later code paths need to call it outside ArgumentParser.

### B.5  Explicit candidate CSV drops empty tokens silently   MINOR
Location: `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift` lines 115-124 and 198-201

The same `parseCSV` helper also drives `--candidate-models`. A smoke check with `phase3-binary/.build/debug/macprovider-cli autotune --candidate-models one,,two --dry-run` exited 0 and produced an explicit plan containing `one` then `two`.

FR-A.1's load-bearing rule is order preservation, and this code does preserve the surviving token order. The issue is that a typo in an operator-supplied ordered list is hidden instead of reported; later tuning would run a different list than the operator typed.

Recommendation: reject empty tokens for `--candidate-models` when the raw value contains separators, or split candidate parsing from the tolerant helper so operator typos are not silently normalized away.

## Category C: Test coverage

### C.2  Step 1 parser contracts are under-tested   MINOR
Location: `phase3-binary/Tests/macprovider-cliTests/AutotuneCommandTests.swift` lines 5-61

The new test file covers the default candidate list, the basic explicit-list precedence warning, max-size trimming, below-target `--max-context-axis` rejection, and `unset,4,8` parsing. It does not cover `--max-context-axis` ascending sort, duplicate rejection, empty-axis default, non-empty-axis empty-cell rejection, `--restart-foreground` parsing, actual `--dry-run` stdout, or an AC-17-shaped explicit list such as `1B,32B` to make future parser-level re-ranking obvious.

This gap allowed the A.4 parser violation to land while the new AutotuneCommandTests still passed. Because Step 1's purpose is to freeze the parser surface before later runtime steps build on it, these tests should pin the parser rules now rather than rely on later integration coverage.

Recommendation: add focused unit tests for FR-B.1 sort / duplicate / empty-axis / empty-cell behavior, an explicit-list order test using model IDs or size-like names that would fail under a size sort, and a dry-run output smoke test that asserts the candidate order printed to stdout.

## Category D: Anti-regression on the existing CLI

(no findings)

Verification notes:
- `MacProviderCLI.swift` changed only the top-level subcommand list by appending `AutotuneCommand.self`.
- `swift test --package-path phase3-binary` passed with 245 XCTest tests and 0 failures.
- `phase3-binary/.build/debug/macprovider-cli autotune --help` showed all 23 Step 1 flags, plus standard `--version` / `--help`.
- `phase3-binary/.build/debug/macprovider-cli autotune --dry-run` exited 0 and printed the five default candidates in SPEC-013 FR-C.1 order.

## Category E: Forward-compatibility

(no findings)

Verification notes:
- `candidatePlan()` is an instance method reusable by later runtime steps, not nested under `dryRun`.
- `--drain`, `--drain-grace`, and `--restart-foreground` are parser-only flags with no early binding that would constrain Step 5.
- `AutotunePlan` and `AutotuneCandidate` are top-level Swift types and can be moved later if Step 3+ needs a separate autotune core file.
- The test file imports only `ArgumentParser`, `XCTest`, and the package under test.

## Category O: Anything else

(no findings)

Verification notes:
- `phase3-binary/implementation-notes.html` follows the existing section / entry / time structure used by prior notes and clearly marks runtime tuning, SQLite, provider lifecycle, `serve --no-join`, and `--apply` as future work.
- The Step 1 commit message follows the repo's Lore-style trailer protocol and records the expected Step 1 verification commands.
- `git diff --check facbaef^ facbaef` produced no whitespace errors.
- No d-inference source was inspected.

---

## Round 2 audit (Codex on 02b038d — Step 1 closure verification)

**Audited:** commit 02b038d on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 1, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 4 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 4 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 1 readiness:** READY TO PROCEED TO STEP 2

### Executive summary

READY TO PROCEED TO STEP 2. Commit 02b038d closes the four round-1 findings without changing the SPEC-013 Step 1 architecture: strict CSV parsing now rejects empty cells for `--max-context-axis`, `--candidate-models`, `--kv-bits-axis`, and positive-int axes; `run()` no longer repeats basic validation; and the 8 added tests exercise the intended parser, ordering, dry-run, and flag-surface contracts rather than asserting only construction.

`swift test --package-path phase3-binary` passed on 2026-06-18 with 253 XCTest tests, 0 failures, and the Swift Testing runner passed with 0 tests. CLI smoke checks confirmed `--max-context-axis 4000,,8000 --dry-run` and `--candidate-models one,,two --dry-run` both exit 64 with flag-named validation errors, while `--max-context-axis "" --dry-run` still exits 0 and maps the empty default to the target-context case.

### Round-1 finding closures

**A.4 (MAJOR) — CLOSED.** `parseCSVStrict(_:flag:)` uses `split(separator: ",", omittingEmptySubsequences: false)` and rejects trimmed empty tokens with a `ValidationError` naming the flag. `parseMaxContextAxis` preserves the empty-default behavior by checking `raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` before calling the strict parser, then sorts values, rejects below-target cells, and rejects duplicates. The required smoke `phase3-binary/.build/debug/macprovider-cli autotune --max-context-axis 4000,,8000 --dry-run` exited 64 with `--max-context-axis contains an empty cell; check for stray commas`; `--max-context-axis "" --dry-run` exited 0 and printed the target-context default.

**B.5 (MINOR) — CLOSED.** `candidatePlan()` now parses explicit `--candidate-models` through `parseCSVStrict`, so `one,,two` no longer silently becomes `["one", "two"]`. The smoke `phase3-binary/.build/debug/macprovider-cli autotune --candidate-models one,,two --dry-run` exited 64 with `--candidate-models contains an empty cell; check for stray commas`. The same strict helper was correctly applied to `parseKvBitsAxis` and `parsePositiveIntAxis`; spot checks for `--kv-bits-axis unset,,4` and `--max-batch-axis 1,,2` also exited 64 with flag-named empty-cell errors.

**B.2 (MINOR) — CLOSED.** The duplicate `try validateBasicInputs()` call is gone from `run()`, and `validate()` remains the parser-time gate for basic inputs plus `_ = try candidatePlan()` for candidate-list errors. The existing below-target `--max-context-axis` test still uses `AutotuneCommand.parse(...)` and throws, proving ArgumentParser invokes `validate()` during parse. The moved errors now surface as parse-time validation failures with exit code 64 in CLI smoke checks.

**C.2 (MINOR) — CLOSED.** The 8 named tests were added and are meaningful regression locks: empty-cell rejection for max-context and candidate models, max-context sort/dedup/default behavior, explicit small-first candidate order preservation, exact dry-run candidate line assertions for the first and fifth default candidates, and `--restart-foreground` parsing. The tests exercise parser calls or `candidatePlan()`/`dryRunLines(_:)` behavior directly; none is a tautological construction-only assertion. `AutotuneCommandTests` now runs 13 tests, and all 253 package tests passed.

### Round-2 new findings

**Category Z-CLOSURE:** (no findings)

**Category R-REGRESSION-V01F1:** (no findings)

Verification notes:
- The 5 original round-1 `AutotuneCommandTests` still passed as part of the 13-test class.
- `phase3-binary/.build/debug/macprovider-cli autotune --help` still exposes all 23 SPEC-013 Step 1 flags, plus standard `--version` / `--help`.
- `git diff --check 02b038d^ 02b038d` produced no whitespace errors.

**Category N-NEWGAPS-V01F1:** (no findings)

Verification notes:
- `parseCSVStrict` rejects empty interior, leading, and trailing cells; the max-context empty-default short-circuit preserves the prior empty-axis mapping.
- `candidatePlan()` running in `validate()` and again in `run()` is pure, fast, and correctly moves parse-class errors to ArgumentParser exit code 64.
- `dryRunLines(_:)` preserves the previous dry-run line order and content while making output testable.

**Category O-OTHER-V01F1:** (no findings)

Verification notes:
- `phase3-binary/implementation-notes.html` correctly records the Step 1 round-1 audit response and references `specs/SPEC-013-impl-audit.md`.
- No d-inference source was inspected.

### Step 1 readiness verdict

READY TO PROCEED TO STEP 2.

---

## Round 3 audit (Codex on ffb00fb — Step 2 round 1)

**Audited:** commit ffb00fb on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 2, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 0 MAJOR / 0 MINOR / 0 QUESTION
**Step 2 readiness:** READY TO PROCEED TO STEP 3

### Executive summary

READY TO PROCEED TO STEP 3. Step 2 implements `serve --no-join` to the SPEC-013 FR-E.2 contract without changing the default serve path beyond the required optional coordinator propagation. The guard at `ServeCommand.makeCoordinatorClient(noJoin:factory:)` returns `nil` before invoking the factory when `--no-join` is set, so `CoordinatorClient.init` cannot run and no coordinator WebSocket session can start. With the flag absent, the same factory path is invoked, preserving the existing coordinator-client construction branch.

The highest-risk optional-propagation surface is clean. A literal grep for direct `coordinatorClient.start`, `coordinatorClient.stop`, `coordinatorClient.drainAndExit`, `coordinatorClient!`, and generic `coordinatorClient.` usage in the CLI sources/tests returned 0 matches; the live call sites use `coordinatorClient?.start()`, `coordinatorClient?.stop()`, and `coordinatorClient?.drainAndExit(...)`. `swift test --package-path phase3-binary` passed on 2026-06-18 with 256 XCTest tests, 0 failures, and the Swift Testing runner passed with 0 tests.

CLI help verification showed `serve --help` still exposes PR #105 flags (`--kv-bits`, `--max-context`, `--max-batch`), SPEC-011 flags (`--enable-warm-swap`, `--ctl-socket-path`), and the new `--no-join` flag. `serve --no-join --enable-warm-swap --help` exited 0, confirming the new flag does not conflict with the warm-swap parser surface.

### Findings

#### Category A: SPEC-013 FR-E.2 coverage for Step 2 scope

(no findings)

Verification notes:
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` lines 127-132 short-circuit before invoking the coordinator factory when `noJoin` is true.
- The local serving path remains after model/runtime setup and is not gated on `noJoin`: the `HTTPServer` is still constructed at line 217 and run at line 227.
- Shutdown uses `coordinatorClient?.drainAndExit(...)` at line 315, so no shutdown state update can flow when no coordinator client exists.
- `noJoin` is declared as `var noJoin = false` at lines 76-77, and `ServeCommandTests.testDefaultServePathInvokesCoordinatorClientFactory` proves the default path still invokes the factory.
- `phase3-binary/.build/debug/macprovider-cli serve --help` includes `--no-join`.

#### Category B: Code quality (Swift idioms)

(no findings)

Verification notes:
- The static closure factory is small and testable, and `ServeCommandTests.testNoJoinSkipsCoordinatorClientInstantiation` proves the closure is not invoked on the no-join branch.
- Optional propagation is complete at the audited call sites: `coordinatorClient?.start()` at line 216, `coordinatorClient?.stop()` at line 222, and `coordinatorClient?.drainAndExit(...)` at line 315.
- `installTerminationHandlers` accepts `CoordinatorClient?` at lines 305-307 and does not force unwrap it.
- The help string matches the local `@Flag(help:)` style used by sibling command files.
- The Step 2 diff introduces no force unwraps outside type syntax, and `coordinatorClient` is a `let` constant, so there is no async reassignment race.

#### Category C: Test coverage

(no findings)

Verification notes:
- `ServeCommandTests.testNoJoinFlagParses` covers the parser surface.
- `ServeCommandTests.testNoJoinSkipsCoordinatorClientInstantiation` covers FR-E.2 sub-bullet 1 by proving the factory is not called.
- `ServeCommandTests.testDefaultServePathInvokesCoordinatorClientFactory` locks the default no-flag anti-regression behavior.
- Live no-join model-serving and SIGTERM smoke coverage remains an acceptable integration deferral for Step 7/Step 5 because Step 2 cannot exercise real serving without loading model weights; the commit's `Not-tested:` trailer records that gap.
- `swift test --package-path phase3-binary` passed 256 tests with 0 failures.

#### Category D: Anti-regression on the existing serve path

(no findings)

Verification notes:
- The `MacProviderCLI.swift` diff is limited to adding the flag, adding the testable coordinator factory guard, replacing coordinator construction with the guard call, and making the existing start/stop/drain call sites optional.
- Warm-swap control socket setup remains independent of the coordinator client and still executes before `coordinatorClient?.start()` when `resolved.enableWarmSwap` is true.
- `phase3-binary/.build/debug/macprovider-cli serve --help` still contains `--kv-bits`, `--max-context`, `--max-batch`, `--enable-warm-swap`, `--ctl-socket-path`, and `--no-join`.
- `phase3-binary/.build/debug/macprovider-cli serve --no-join --enable-warm-swap --help` exited 0.

#### Category E: Forward-compatibility

(no findings)

Verification notes:
- Step 7 can spawn `serve --no-join` and probe local HTTP because the no-join guard suppresses only coordinator-client construction/start, not model/runtime/server setup.
- Step 5 drain work remains unconstrained by Step 2: coordinator drain is a no-op for no-join providers, and any future local HTTP drain behavior can be added separately.

#### Category O: Anything else

(no findings)

Verification notes:
- `phase3-binary/implementation-notes.html` adds a `spec013-autotune-step2` section that accurately describes scope, guard design, deviations, and verification.
- The Step 2 commit message uses the repo's Lore-style trailers and records the relevant test/help checks.
- No d-inference source was inspected.

### Step 2 readiness verdict

READY TO PROCEED TO STEP 3.

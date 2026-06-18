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

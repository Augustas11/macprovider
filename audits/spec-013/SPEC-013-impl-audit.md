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

---

## Round 4 audit (Codex on d0029e9 — Step 3 round 1)

**Audited:** commit d0029e9 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 3, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 0 MAJOR / 0 MINOR / 0 QUESTION
**Step 3 readiness:** READY TO PROCEED TO STEP 4

### Executive summary

READY TO PROCEED TO STEP 4. Step 3 implements the additive `AutotuneDB` SQLite writer surface for SPEC-013 FR-G.1 and FR-G.2 without wiring runtime autotune execution yet. The audited schema covers every required `tune_trials` and `tune_runs` column, creates both required trial indexes, adds the v0.3 `stage INTEGER NOT NULL DEFAULT 1` migration, and enforces the 9-value `exit_reason` enum at the application layer before inserting run rows.

The transactional-retention and C-interop surfaces are clean. `applyRetentionInTransaction(retainRuns:)` rejects `N < 1` before opening a transaction, runs `BEGIN IMMEDIATE TRANSACTION`, deletes stale `tune_trials` before stale `tune_runs`, commits on success, and rolls back on error. Every successful `sqlite3_prepare_v2` is finalized through `defer`, every opened DB handle is closed in `deinit` or on migration/open failure, and the only string-interpolated retention SQL value is the already-typed `Int` `retainRuns`.

`swift test --package-path phase3-binary` passed on 2026-06-18 with 260 XCTest tests, 0 failures, including the 4 new `AutotuneDBTests`; the Swift Testing runner also passed with 0 tests. `git diff --check d0029e9^ d0029e9` produced no whitespace errors. No d-inference source was inspected.

### Findings

#### Category A: SPEC-013 FR-G.1 / FR-G.2 schema coverage

(no findings)

Verification notes:
- `phase3-binary/Sources/macprovider-cli/AutotuneDB.swift` lines 210-262 create `tune_trials` and `tune_runs` with all FR-G.1 / FR-G.2 columns, matching required types, nullability, and defaults.
- `tune_trials.stage` is created at line 216 as `INTEGER NOT NULL DEFAULT 1`, and `additiveTrialColumns` repeats the same migration definition at lines 354-356 for prototype DB upgrades.
- Required indexes `idx_tune_trials_run_id` and `idx_tune_trials_ts` are created at lines 238-239 with `CREATE INDEX IF NOT EXISTS`.
- `AutotuneExitReason` lines 24-33 contains exactly the 9 normative values: `ok`, `interrupted`, `no_feasible`, `budget_exhausted_no_model_selected`, `budget_exhausted_with_partial_recommendation`, `pre_warm_integrity_failure`, `provider_conflict`, `config_error`, and `internal_error`.
- `AutotuneCommand.defaultDBPath` resolves to `~/.config/macprovider/autotune.sqlite` at `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift` lines 87-90, and `AutotuneDB.init(path:)` uses that default at line 86 while preserving `:memory:` for tests.
- The prototype reference on `origin/spike/provider-model-autotune` uses the expected idempotent additive-column loop for `kv_bits`, `max_context_cap`, `max_batch`, and `replicates_n`; Step 3 correctly extends that shape for SPEC v0.3 `stage`.

#### Category B: Transactional retention sweep (FR-G.1)

(no findings)

Verification notes:
- `applyRetentionInTransaction(retainRuns:)` rejects `retainRuns < 1` before `BEGIN` at lines 183-188.
- The transaction sequence is `BEGIN IMMEDIATE TRANSACTION`, stale-run selection ordered by `started_at_utc DESC, run_id DESC`, `DELETE FROM tune_trials`, `DELETE FROM tune_runs`, and `COMMIT` at lines 188-203.
- The rollback path at lines 204-206 preserves the original error while attempting `ROLLBACK`.
- The string-interpolated `LIMIT -1 OFFSET \(retainRuns)` at line 193 is fed only by the typed `Int` parameter after the `>= 1` guard; no untrusted string reaches interpolated SQL.
- `AutotuneDBTests.testRetentionSweepDeletesOldestRunsAndTrialsTransactionally` inserts 52 run/trial pairs, retains 50, proves the two oldest run IDs are gone from both tables, and checks for zero orphan trials.

#### Category C: C-interop correctness

(no findings)

Verification notes:
- `withStatement` lines 279-288 wraps every successful `sqlite3_prepare_v2` in `defer { sqlite3_finalize(statement) }`, covering normal return and throw paths from the statement body.
- `init(path:)` lines 95-111 closes a partially opened handle on open failure and calls `close()` before rethrowing migration failures.
- `deinit` lines 114-116 and `close()` lines 340-345 close the owned SQLite handle exactly once for normal object lifetime.
- Text binds use the local Swift SQLite idiom `SQLITE_TRANSIENT` defined at line 363 as `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`, so bound Swift strings are copied before their lifetimes can end.
- Integer, double, null, and error-message bridging are straightforward: `sqlite3_bind_int64`, `sqlite3_bind_double`, `sqlite3_bind_null`, and copied `sqlite3_errmsg` strings at lines 297-351.

#### Category D: Anti-regression

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed with 260 XCTest tests, 0 failures; Swift Testing reported 0 tests.
- `AutotuneDBTests` contributed 4 passing tests: fresh schema creation, prototype-stage migration, transactional retention, and invalid `exit_reason` rejection.
- `phase3-binary/Package.swift` did not add a third-party dependency; `SQLite3` is imported as the system SQLite module in `AutotuneDB.swift`.
- Grepping `phase3-binary/Sources` for `SQLite3` / `sqlite3_` found Step 3 is the first production SQLite consumer in this package, so there was no prior local SQLite wrapper idiom to preserve.
- The new file is additive and no existing source file calls `AutotuneDB` yet, matching the Step 3 no-runtime-wiring boundary.

#### Category E: Forward-compatibility

(no findings)

Verification notes:
- `AutotuneTrialRow` lines 42-60 exposes every FR-G.1 field Step 7 and Step 11 will need, including explicit `stage`, nullable metrics, serving knobs, and `replicatesN`.
- `AutotuneRunRow` lines 62-81 exposes every FR-G.2 field Step 9 and Step 10 will need, including nullable `recommendationJSON`, nullable `recipeHash`, `applied`, and `exitReason`.
- `insertTrial(_:)` and `insertRun(_:)` bind all struct fields into explicit column lists, reducing risk if future migrations append columns.
- The commit message directive correctly warns later runtime steps to call `insertRun` before retention and to set `tune_trials.stage` explicitly for every trial.

#### Category O: Anything else

(no findings)

Verification notes:
- `phase3-binary/implementation-notes.html` lines 1096-1122 accurately records the Step 3 design choices: system SQLite, default DB path, idempotent `stage` migration, application-layer enum enforcement, and transactional retention.
- The commit message follows the repo Lore trailer convention and records the third-party SQLite wrapper rejection plus test claims.
- The duplicate-column-ignore behavior at `AutotuneDB.swift` lines 233-236 and 271-276 is intentionally redundant on fresh DBs and required for prototype-upgrade compatibility.
- The audit remained read-only for implementation code; only this Round 4 report section was appended.

### Step 3 readiness verdict

READY TO PROCEED TO STEP 4.

---

## Round 5 audit (Codex on 994c7ee — Step 4 round 1)

**Audited:** commit 994c7ee on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 4, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 2 MAJOR / 2 MINOR / 1 QUESTION
**Step 4 readiness:** FIX REQUIRED

### Executive summary

FIX REQUIRED. Step 4 is additive and correctly introduces the intended foreground provider lifecycle primitive without wiring it into `AutotuneCommand.run()` yet. The broad shape matches SPEC-013: `start()` owns one `RunningProvider`, always assembles `serve --no-join`, `waitForReady()` separates readiness from later measurement timing, and `stop()` is SIGTERM-only with no SIGKILL, `Process.interrupt()`, or `Darwin.kill` escalation.

The blocking issues are in process/readiness edge paths. First, the `process.run()` failure cleanup path can hang because it calls `finishLogging()`, which drains pipe read ends when the subprocess never launched and the pipe write ends may still be open. Second, `waitForReady()` returns `.ready` immediately on HTTP 200 before running the post-request process-exit check, leaving the high-risk "200 then exited before return" race unhandled. These are Step 4 contract gaps, so Step 5 should wait for a fix pass.

`swift test --package-path phase3-binary` passed on 2026-06-18 with 266 XCTest tests, 1 skipped integration-gated test, and 0 failures; the Swift Testing runner passed with 0 tests. `git diff --check 994c7ee^ 994c7ee` produced no whitespace errors. No d-inference source was inspected.

### Findings

#### Category A: Single-provider invariant (load-bearing)

**A.1 (QUESTION) — `stop()` leaves a stuck process as `current` but reports no hard stop failure.**
- **Location:** `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift` lines 176-202
- **What:** If the grace window expires while the process is still alive, `stop()` returns without clearing `current`; the next `start()` will throw `alreadyRunning`. If the process is alive but no longer holding the port, no warning is emitted because the warning is port-only.
- **Why:** This preserves the no-overlap invariant, but Step 7 iteration will effectively halt on the next candidate unless it treats `alreadyRunning` after `stop()` as a stuck-provider failure.
- **Recommendation:** Keep SIGTERM-only behavior, but decide in the fix pass or Step 7 whether `stop()` should surface a status/result for "process still alive" so callers can record a clear trial/run failure instead of discovering it via the next `start()`.

Verification notes:
- `start()` checks and mutates `current` under `stateLock` and rejects a live existing process at lines 75-83.
- `clearCurrentIfSame(_:)` uses object identity under lock at lines 295-305, so concurrent `stop()` calls do not double-clear or double-close the same provider.
- `testStartRejectsSecondRunningProvider` proves a second sequential `start()` is rejected while the first stub provider is alive.

#### Category B: Process lifecycle correctness

**B.1 (MAJOR) — Spawn-failure cleanup can hang while draining never-launched pipes.**
- **Location:** `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift` lines 121-126 and 378-382
- **What:** On `process.run()` failure, the catch block calls `running.finishLogging()`. Because `process.isRunning` is false, `finishLogging()` calls `readDataToEndOfFile()` on stdout/stderr pipe read handles. For a process that never launched, the pipe write ends can still be open in the parent, so the read waits for EOF that may never arrive.
- **Why:** A missing, non-executable, or otherwise unspawnable provider binary can hang `start()` instead of throwing. That is a process-lifecycle contract gap and can block autotune before Step 7 has a chance to classify the candidate/run failure.
- **Recommendation:** Split cleanup modes. On spawn failure, clear readability handlers and close/sync the log handle without draining read ends, or explicitly close the pipe write handles before any `readDataToEndOfFile()` attempt. Add a regression test with an invalid provider path that proves `start()` returns/throws promptly.
- **Evidence:** A local Swift reproduction using a missing executable, a `Pipe`, and `readDataToEndOfFile()` after `run()` threw printed `run threw` and then timed out after 2 seconds.

Verification notes:
- Successful spawn uses `Process` directly because the runner needs lifetime control; the existing `runProcess` helpers in `SelfUpdate.swift` and `UninstallCommand.swift` are one-shot `run()` + `waitUntilExit()` wrappers and are not suitable for this owned-live-process case.
- Pipe readability handlers weakly reference `running`, avoiding a direct closure retain cycle.

#### Category C: Async HTTP polling correctness (FR-D.1 measurement isolation)

**C.1 (MAJOR) — `waitForReady()` skips the post-request exit check on HTTP 200.**
- **Location:** `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift` lines 148-153 and 162-168
- **What:** The loop checks `process.isRunning` before the HTTP request and after non-ready responses/errors, but the HTTP 200 path returns `.ready` immediately at line 152. If the provider exits after producing the 200 response but before `waitForReady()` returns, the method can report `.ready` for an already-dead process.
- **Why:** The prompt calls the process-exit race in `waitForReady()` one of the highest-risk surfaces. Step 7 will rely on `.ready` to start measurement; returning ready for an exited process can misclassify a startup/runtime failure as a later probe failure.
- **Recommendation:** After receiving HTTP 200, re-check `provider.process.isRunning` before returning `.ready`; if it has exited, call `clearCurrentIfSame(provider)` and return `.processExited(rc:stderrTail:)`. Add a stub test that serves one `/v1/models` 200 response and exits immediately.

Verification notes:
- `Task.sleep(nanoseconds:)` is used directly at line 170, so caller cancellation can propagate.
- Request timeout is set per HTTP attempt at line 146, preserving a bounded polling cadence separate from Step 7's later measurement window.

#### Category D: Stop/grace correctness (FR-E.1 launchd-safety)

(no findings)

Verification notes:
- `stop()` uses `process.terminate()` only; grep found no `Process.interrupt()`, `Darwin.kill`, `kill(`, or `SIGKILL` in `CandidateProviderRunner.swift`.
- The foreground runner does not call `launchctl`; SPEC-013 FR-E.1 launchd `bootout/bootstrap` remains a separate Step 5 responsibility.
- `isPortOpen(_:)` closes its socket descriptor with `defer { close(descriptor) }` at lines 318-323.

#### Category E: Argv assembly (FR-B.1 alignment with PR #105 + FR-E.2)

**E.1 (MINOR) — Runner invalid-knob tests cover only `kvBits`.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/CandidateProviderRunnerTests.swift` lines 38-49
- **What:** `testServeArgumentsRejectInvalidKnobs` asserts only `.invalidKvBits(5)`. It does not cover invalid port, invalid max context, or invalid max batch for the runner's own `serveArguments()` validation.
- **Why:** The implementation validates all four classes at lines 233-244, and existing serve-command tests cover related production knob validation, so this is not a runtime defect. It is still a Step 4 test gap because the audit prompt explicitly asks this runner test to cover each invalid input class.
- **Recommendation:** Extend the test to assert `.invalidPort`, `.invalidMaxContext`, and `.invalidMaxBatch` directly against `CandidateProviderRunner.serveArguments(...)`.

Verification notes:
- `serveArguments()` always includes `serve --no-join --model <model> --port <port>` and appends only non-nil optional knob flags.
- `model` is passed as an argv array element, not shell-interpolated, so shell injection is not introduced by model IDs.

#### Category F: Resource hygiene

(no findings beyond B.1)

Verification notes:
- Normal successful-start cleanup clears both readability handlers before log finalization at lines 378-380.
- `ProcessOutputTail` is lock-protected for append/snapshot, and stderr remainder is appended before the final snapshot on process-exit cleanup.
- The known resource-lifetime blocker is the spawn-failure pipe-drain path reported as B.1.

#### Category G: Anti-regression

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed with 266 XCTest tests, 1 skipped integration-gated test, and 0 failures.
- `git show --name-only --format='' 994c7ee` lists only `CandidateProviderRunner.swift`, `CandidateProviderRunnerTests.swift`, and `implementation-notes.html`.
- `git diff --check 994c7ee^ 994c7ee` produced no whitespace errors.

#### Category H: Forward-compatibility (Step 5, 6, 7, 10)

(no findings beyond A.1/C.1)

Verification notes:
- Step 5 external provider conflict detection is not implemented here and remains a separate pre-flight before invoking the runner.
- Step 6 pre-warm can wrap the runner without changing the runner's lifecycle surface.
- Step 7 gets the intended `start -> waitForReady -> stop` primitive, but should not consume Step 4 until B.1 and C.1 are fixed.
- Step 10 signal handling can call the synchronous `stop()` path, subject to the A.1 stuck-process status question.

#### Category I: Anything else

**I.1 (MINOR) — Log filenames can collide within the same second.**
- **Location:** `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift` lines 275-277
- **What:** Log filenames use safe model name, port, and `Int(Date().timeIntervalSince1970)`. Two starts for the same model and port within one second produce the same path and the later `Data().write(..., .atomic)` truncates the earlier log.
- **Why:** Normal autotune candidates are expected to take longer than one second, so this is low probability. It becomes more plausible around fast spawn failures or future tests that exercise repeated starts.
- **Recommendation:** Include a UUID, nanosecond timestamp, or monotonically increasing per-run counter in the log filename.

Verification notes:
- `safeModelName(_:)` conservatively maps non-filesystem-safe characters to `-`.
- The new `spec013-autotune-step4` implementation-notes section accurately describes the Step 4 design, SIGTERM-only stop policy, and skipped real-binary integration test.

### Step 4 readiness verdict

FIX REQUIRED.

---

## Round 6 audit (Codex on 4bcef89 — Step 4 round 2 closure verification)

**Audited:** commit 4bcef89 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 4, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 5 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 5 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 4 readiness:** READY TO PROCEED TO STEP 5

### Executive summary

READY TO PROCEED TO STEP 5. Commit 4bcef89 closes all five round-1 findings without weakening the unchanged Step 4 lifecycle surface. The audited Step 4 source, tests, and implementation notes are unchanged between 4bcef89 and current HEAD e043876; the only committed file after 4bcef89 is the round-2 prompt file.

`swift test --package-path phase3-binary` passed on 2026-06-18: 273 tests executed, 1 integration-gated test skipped, 0 failures. The new CandidateProviderRunner tests executed and passed, including the missing-binary start path, the immediate-exit-after-200 readiness path, the StopResult happy path, the three argv validation additions, and the same-second log filename collision test. No SIGKILL escalation, `Process.interrupt()`, `Darwin.kill`, or `kill(` call was introduced in the Step 4 runner.

### Round-1 finding closures

**B.1 (MAJOR) — CLOSED.** The spawn-failure catch path in `CandidateProviderRunner.start()` now calls `running.discardLogging(reason:)` instead of `finishLogging()`. `discardLogging` clears both stdout and stderr readability handlers, writes a `process spawn failed: ...` note, synchronizes and closes the log file, and does not call `readDataToEndOfFile()`. The regression test `testStartFailsPromptlyWithMissingBinary` uses a randomized `/nonexistent/...` binary path, calls `start()` synchronously, asserts a thrown error, and asserts elapsed time is under 1 second; the test passed in 0.007 seconds in the requested suite run.

**C.1 (MAJOR) — CLOSED.** The HTTP 200 branch in `waitForReady()` now checks `provider.process.isRunning` before `return .ready`; on false it calls `clearCurrentIfSame(provider)` and returns `.processExited(rc: Int(provider.process.terminationStatus), stderrTail: provider.stderrTail.snapshot())`, matching the pre-loop exit-path fields and invariant cleanup. `testWaitForReadyHandlesImmediateExitAfterFirstResponse` uses an executable Python stub that validates `serve --no-join`, binds the requested port, responds once with HTTP 200 and a `/v1/models` payload, closes the socket, and exits immediately. The test intentionally accepts `.ready` or `.processExited` but rejects `.timeout`, which is contract-meaningful for the round-1 regression class.

**A.1 (QUESTION) — CLOSED.** `stop(graceSeconds:)` now returns `StopResult` with `.stopped` and `.stuck(pid:)`, and the method is marked `@discardableResult`, so existing ignored-return callers still compile and passed the full test suite. `.stuck(pid:)` is returned only after the grace loop and only when `provider.process.isRunning` remains true; port-only-held cases still log the port warning but return `.stopped` if the process exited and `clearCurrentIfSame(provider)` succeeds. `testStopReturnsStoppedForNeverStartedRunner` covers the never-started happy path, and leaving deterministic stuck-path coverage to later integration is acceptable for this round.

**E.1 (MINOR) — CLOSED.** The fix-pass added `testServeArgumentsRejectInvalidPort`, `testServeArgumentsRejectInvalidMaxContext`, and `testServeArgumentsRejectInvalidMaxBatch`. The port test covers both 0 and 65_536 and asserts `.invalidPort(...)`; the max-context and max-batch tests pass zero values and assert `.invalidMaxContext(0)` and `.invalidMaxBatch(0)`. The original invalid kv-bits test remains in place.

**I.1 (MINOR) — CLOSED.** `logFileURL(model:port:in:)` now creates a fresh `UUID().uuidString.prefix(8)` inside each call and appends it to the second-resolution timestamp, so the suffix is not cached. `testLogFileURLsDoNotCollideWithinOneSecond` builds two URLs in immediate succession for the same model and port and asserts distinct last path components. The test accessor is production-visible but explicitly named `logFileURLForTesting`, and I do not see a Step 4 contract risk from that naming-only exposure.

### Round-2 new findings

#### Category Z-CLOSURE

(no findings)

#### Category R-REGRESSION-V04F1

(no findings)

Spot-checks:
- The single-provider invariant and lock discipline remain intact: `start()` still checks/mutates `current` under `stateLock`, `currentProviderIfAny()` remains lock-protected, and `clearCurrentIfSame(_:)` still clears only the same `RunningProvider` identity before finalizing logs.
- The `stop()` core logic remains SIGTERM-only: terminate, poll process/port until grace expiry, log a port-held warning, clear current only when the process exits, and now return `.stopped` or `.stuck(pid:)`.
- `serveArguments(...)` assembly remains unchanged except for added tests; it still emits `serve --no-join --model <model> --port <port>` plus optional knob flags after validation.
- `finishLogging()` remains the normal cleanup path and is unchanged in behavior; `discardLogging(reason:)` is a sibling used only for spawn-failure cleanup.

#### Category N-NEWGAPS-V04F1

(no findings)

Spot-checks:
- `discardLogging(reason:)` clears both readability handlers, writes the failure note, synchronizes and closes the log file, and has the `closed` guard.
- The post-200 process-exit check still has a tiny race between `isRunning` and returning `.ready`, but this is the practical residual race described in the prompt and is acceptable for Step 4.
- `.stuck(pid:)` reads `processIdentifier` only when `isRunning` is true at the end of the grace window, so the PID validity assumption is acceptable.
- The 8-character UUID suffix supplies enough entropy for the expected concurrent-start scale.
- The Python stub's `#!/usr/bin/env python3` dependency is acceptable for the macOS/Xcode-oriented test environment.

#### Category O-OTHER-V04F1

(no findings)

### Step 4 readiness verdict

READY TO PROCEED TO STEP 5.

---

## Round 7 audit (Codex on d40a6f7 — Step 5 round 1)

**Audited:** commit d40a6f7 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 5, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 0 MAJOR / 4 MINOR / 0 QUESTION
**Step 5 readiness:** READY TO PROCEED TO STEP 6

### Executive summary

READY TO PROCEED TO STEP 6. I found no CRITICAL or MAJOR contract violations in the Step 5 provider-conflict primitives. The launchd label byte-matches SPEC-003, SPEC-013, the plist template, install.sh, UninstallCommand, and SelfUpdate as `live.streamvc.macprovider`; bootout uses the service target form `gui/<uid>/live.streamvc.macprovider`, while bootstrap correctly uses domain target `gui/<uid>` plus plist path. Foreground detection uses argv-element matching rather than substring grep and excludes argv containing the exact `autotune` subcommand, so the self-refusal class is covered by implementation and tests.

The side-effect surface is closure-injected for the drainer and injectable at the detector snapshot boundaries. I found no real launchctl mutation, real signal delivery, real restart, or real socket dependency in the Step 5 unit tests; the only real launchctl call is behind the integration-gated test. No SIGKILL escalation, `Process.interrupt()`, or `kill(_, SIGKILL)` path exists in the Step 5 implementation; `SIGKILL` appears only in the v1-disabled warning text.

Verification: `swift test --package-path phase3-binary` passed on 2026-06-18 with 283 tests executed, 2 tests skipped, and 0 failures. The Step 4 anti-regression filter also passed: `swift test --package-path phase3-binary --filter CandidateProviderRunnerTests` executed 13 tests, skipped 1 integration-gated test, and had 0 failures.

### Findings

#### Category A: launchd detection correctness (FR-E.1)

(no findings)

Verification notes:
- `ProviderConflictDetector.launchdLabel` is `live.streamvc.macprovider` at `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift:11`.
- The same byte string appears in SPEC-003 at `specs/SPEC-003-open-onboarding.md:346`, `:426`, and `:870`; SPEC-013 at `specs/SPEC-013-cli-autotune.md:724`; the plist template at `phase3-binary/dist/launchd-plist-template.plist:7`; install.sh at `phase3-binary/dist/install.sh:749` and `:923`; UninstallCommand at `phase3-binary/Sources/macprovider-cli/UninstallCommand.swift:23`; and SelfUpdate at `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:207` and `:217`.
- `parseLaunchdManagedPID(from:)` tokenizes on space or tab, requires whole-field equality for the label, returns the first field as PID, and returns nil for `-`, matching the expected launchctl list shapes.
- `defaultLaunchctlList()` executes `/bin/launchctl list`, captures stdout only, waits for exit, and throws on non-zero status.

#### Category B: foreground detection correctness (FR-E.2 self-exclusion)

(no findings)

Verification notes:
- `isForegroundServe(argv:)` at `ProviderConflictDetector.swift:56` rejects any argv array containing the exact `autotune` element before scanning for a `macprovider-cli` executable basename followed immediately by exact `serve`.
- Whole-word correctness is preserved: `macprovider-cli-helper` does not pass the executable basename check, and `serve-helper` / `serve-foo` do not pass the exact subcommand check.
- `defaultProcessList()` uses `proc_listpids` plus `sysctl(CTL_KERN, KERN_PROCARGS2, pid)` and bounds-checks index movement while parsing argc, exec path, null padding, and argv strings.

#### Category C: Drain correctness (FR-E.1)

(no findings)

Verification notes:
- Launchd drain calls the injected launchctl runner with `["bootout", "gui/<uid>/live.streamvc.macprovider"]` at `ProviderConflictDetector.swift:217`, matching SPEC-013's service-target drain command at `specs/SPEC-013-cli-autotune.md:756`.
- Foreground drain sends exactly `SIGTERM` via the injected `signalSender` at `ProviderConflictDetector.swift:219`.
- Drain polling waits for port-free and, on foreground conflicts, process exit; if the foreground process remains after grace, the warning explicitly says SIGKILL is disabled in v1.

#### Category D: Restore correctness (FR-E.1)

(no findings)

Verification notes:
- Launchd restore calls `["bootstrap", "gui/<uid>", plistURL.path]` at `ProviderConflictDetector.swift:236`, matching the bootstrap domain-target + plist syntax in SPEC-013 and install.sh.
- The default plist path is `~/Library/LaunchAgents/live.streamvc.macprovider.plist` at `ProviderConflictDetector.swift:193`, byte-aligned with SPEC-003, SPEC-013, install.sh, UninstallCommand, and SelfUpdate.
- Foreground restore is opt-in through `restartForeground`; otherwise it returns `.skipped`.

#### Category E: DI surface completeness

(no findings)

Verification notes:
- `ProviderDrainer` injects all side effects named in the prompt: launchctl execution, signal sending, process-running probe, port probe, foreground restart, and warning writer.
- The detector injects the effectful snapshot boundaries: launchctl list output and process list output.
- The Step 5 unit tests use stubs for launchctl, signal, port, process-running, and foreground restart effects. The real launchctl list path is integration-gated behind `MACPROVIDER_INTEGRATION_TEST=1`.

#### Category F: Anti-regression on Step 4

(no findings)

Verification notes:
- `CandidateProviderRunner.stop(graceSeconds:)` now calls `MacProviderPortProbe.isOpen(provider.port)` at `CandidateProviderRunner.swift:222` and `:228`; no other runner behavior changed in the Step 5 diff.
- The deleted private `isPortOpen(_:)` body is byte-equivalent in behavior to `MacProviderPortProbe.isOpen(_:)` in `PortProbe.swift:4`.
- `PortProbe.swift` is in the same `macprovider_cli` target/module, so the runner needs no new module import.
- `swift test --package-path phase3-binary --filter CandidateProviderRunnerTests` passed with 13 tests executed, 1 skipped, 0 failures.

#### Category G: Test coverage

**G.1 (MINOR) — Inactive launchd PID parsing lacks a direct unit test.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift:39`; `phase3-binary/Tests/macprovider-cliTests/ProviderConflictDetectorTests.swift:7`
- **What:** The parser correctly returns `(found: true, pid: nil)` for launchctl rows whose PID field is `-`, but the test suite does not pin that inactive-service case.
- **Why:** Inactive loaded jobs are an expected launchctl list variant and Step 5's enum explicitly allows `launchdManaged(pid: nil)`. The implementation is straightforward and reviewed as correct, so this is a coverage gap, not a blocker.
- **Recommendation:** Add a detector test with `-\t-\tlive.streamvc.macprovider` and assert `.launchdManaged(pid: nil)`.

**G.2 (MINOR) — Helper-binary foreground false-positive coverage is incomplete.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift:61`; `phase3-binary/Tests/macprovider-cliTests/ProviderConflictDetectorTests.swift:54`
- **What:** `testServeSubstringDoesNotMatchForegroundServe` covers a subcommand-like `-serve-helper` argument, but it does not cover a helper executable such as `/path/macprovider-cli-helper serve`.
- **Why:** The implementation rejects helper executables via `lastPathComponent == "macprovider-cli"`, so runtime behavior is correct. The missing test leaves one of the prompt's named false-positive classes unpinned.
- **Recommendation:** Add a second argv fixture for `["/path/macprovider-cli-helper", "serve"]` and assert `.none`.

**G.3 (MINOR) — The SIGKILL-disabled warning path is not unit-tested.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift:224`; `phase3-binary/Tests/macprovider-cliTests/ProviderConflictDetectorTests.swift:95`
- **What:** Foreground drain tests verify `SIGTERM`, but no test stubs `processIsRunning` as true after grace and asserts the injected `warningWriter` receives the v1 no-SIGKILL warning.
- **Why:** The implementation contains the warning and never escalates, so this is not a discipline violation. The warning is operator-visible behavior for the stuck foreground path and should be regression-pinned.
- **Recommendation:** Add a foreground drain test with `portIsOpen: { _ in false }`, `processIsRunning: { _ in true }`, and an injected warning recorder.

#### Category H: Forward-compatibility

**H.1 (MINOR) — Launchd restore is not idempotent by itself.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift:231`
- **What:** `restore(.launchdManaged)` always calls `launchctl bootstrap gui/<uid> <plist>` and returns `.restored` only if launchctl succeeds. A second restore after the service has already been bootstrapped will likely throw from launchctl.
- **Why:** Step 10 owns lifecycle cleanup and can ensure restore is called once or can tolerate already-loaded launchctl failures. This is not a Step 5 blocker, but the primitive does not provide an idempotent "ensure restored" contract.
- **Recommendation:** When Step 10 wires restore, either call it exactly once per successful drain or handle the already-loaded launchctl status as a non-fatal restore outcome.

Verification notes:
- `ProviderConflict` gives Step 7 enough information to branch on launchd-managed versus foreground and include foreground PID/argv details where needed.
- `restore(.none)` returns `.skipped`, and foreground restore is safely gated by `restartForeground`.

#### Category I: Anything else

(no findings)

Verification notes:
- `MacProviderPortProbe` as a single-static-method enum is consistent with the local Swift namespace style.
- The implementation-notes `spec013-autotune-step5` section accurately describes launchd detection, argv matching, DI closures, bootout/bootstrap targets, SIGTERM-only foreground drain, and the Step 7/Step 10 wiring boundary.
- The strict clean-room boundary was preserved; no d-inference source was inspected.

### Step 5 readiness verdict

READY TO PROCEED TO STEP 6.

---

## Round 8 audit (Codex on 3adddbf — Step 5 round 2 closure verification)

**Audited:** commit 3adddbf on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 5, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 3 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED / 1 DEFERRED across the 4 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 5 readiness:** READY TO PROCEED TO STEP 6

### Executive summary

READY TO PROCEED TO STEP 6. Commit 3adddbf closes G.1, G.2, and G.3 with real behavior-pinning tests rather than tautological object construction. Each test exercises the exact Step 5 contract that Round 7 identified as under-covered: inactive launchd PID parsing, helper-binary foreground false-positive rejection, and the no-SIGKILL warning path when a foreground process remains alive after grace.

H.1 remains intentionally deferred, and the deferral is sound for Step 5. The implementation-notes entry explicitly records that `restore(.launchdManaged)` is not call-idempotent by itself and assigns the call-once lifecycle discipline to Step 10, which is the wiring layer that will know whether cleanup has already run. Anti-regression checks passed: `git diff d40a6f7 3adddbf -- phase3-binary/Sources/` is empty, and `swift test --package-path phase3-binary` executed 286 tests with 2 skipped and 0 failures.

### Round-1 finding closures

**G.1 (MINOR) — CLOSED.** `testParseLaunchdManagedInactivePIDReturnsNil` lives in `ProviderConflictDetectorTests` and feeds `"-\t-\tlive.streamvc.macprovider\n"` directly to `ProviderConflictDetector.parseLaunchdManagedPID(from:)`. It asserts both halves of the parser contract with `XCTAssertTrue(parsed.found)` and `XCTAssertNil(parsed.pid)`. This is meaningful coverage: if future parser changes stop treating `-` as a loaded-but-inactive launchd row, the test will fail.

**G.2 (MINOR) — CLOSED.** `testHelperBinaryDoesNotMatchForegroundServe` lives in `ProviderConflictDetectorTests`, constructs a detector with a process list containing `["/usr/local/bin/macprovider-cli-helper", "serve"]`, and asserts `try detector.detect()` returns `.none`. This is not tautological because it reaches the detector's argv scanner; changing `isForegroundServe(argv:)` from `lastPathComponent == "macprovider-cli"` to substring matching would make the helper binary look like a foreground serve process and fail this test.

**G.3 (MINOR) — CLOSED.** `testForegroundDrainEmitsNoSIGKILLWarningWhenProcessRemainsAfterGrace` lives in `ProviderDrainerTests` and uses the required DI surface: `signalSender` records SIGTERM, `processIsRunning: { _ in true }` keeps the process stuck, `portIsOpen: { _ in false }` makes the port-free path win, and `warningWriter` records the operator warning. It asserts `.drained`, one SIGTERM send, one warning, and warning text containing both `pid 7777` and `SIGKILL is disabled in v1`. This pins the visible no-SIGKILL policy without requiring real signals or sockets.

**H.1 (MINOR) — DEFERRED.** Commit 3adddbf does not change `restore(.launchdManaged)`, and that is appropriate for this Step 5 fix-pass. The new `implementation-notes.html` entry precisely states that a second `launchctl bootstrap` after successful restore can fail because the service is already loaded, then assigns the call-once discipline to Step 10's signal-handler / failure-cleanup wiring. Step 10 is the right owner because it decides lifecycle cleanup sequencing; Step 5 only provides the primitive.

### Round-2 new findings

#### Category Z-CLOSURE

(no findings)

Verification notes:
- G.1, G.2, and G.3 are closed by tests that would fail under the named regressions.
- H.1 is not over-closed or hidden; it is explicitly documented as a Step 10 forward-compat obligation.

#### Category R-REGRESSION-V05F1

(no findings)

Verification notes:
- `git diff d40a6f7 3adddbf -- phase3-binary/Sources/` is empty, confirming no production source change in the fix-pass.
- `swift test --package-path phase3-binary` passed on 2026-06-18: 286 tests executed, 2 tests skipped, 0 failures.

#### Category N-NEWGAPS-V05F1

(no findings)

Verification notes:
- Test placement is correct: the parser and helper-binary tests are in `ProviderConflictDetectorTests`; the warning-path test is in `ProviderDrainerTests`.
- The warning test uses all necessary injectors for this path: `signalSender`, `processIsRunning`, `portIsOpen`, and `warningWriter`.
- The new tests are behavior-sensitive rather than tautological: they exercise parser output, detector classification, signal/warning side effects, and drain result selection.

#### Category O-OTHER-V05F1

(no findings)

### Step 5 readiness verdict

READY TO PROCEED TO STEP 6.

---

## Round 9 audit (Codex on e7bfab5 — Step 6 round 1)

**Audited:** commit e7bfab5 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 6, round 1 of N
**Date:** 2026-06-18
**Total findings:** 1 CRITICAL / 1 MAJOR / 2 MINOR / 0 QUESTION
**Step 6 readiness:** FIX REQUIRED

### Executive summary

FIX REQUIRED. The Step 6 shape choice is internally consistent: this implementation intentionally treats `ProviderPreWarmer` as a disposable Shape B load/readiness probe, stops the provider before returning `.warmed`, and leaves Step 7 to start a fresh provider against the now-warm cache. That is not a G.2 design bug by itself; it is documented in `implementation-notes.html`, asserted by the new tests, and compatible with the BUILD prompt's Step 7 sequence of `pre-warm + start + wait-for-ready + fire`.

The blocker is FR-D.2 classification. The marker list covers the literal phrase `missing tokenizer.json`, but the actual Swift/HF dependency path can emit `Required configuration file missing: tokenizer.json`, which does not contain that marker because of the colon. Missing `tokenizer.json` is the SPEC's named repository-shape integrity example, so this can classify a named integrity failure as transient and let Step 7 advance to the next candidate.

Anti-regression passed. `swift test --package-path phase3-binary` passed on 2026-06-18 with 293 tests executed, 2 tests skipped, and 0 failures.

### Findings

#### Category A: FR-D.1 measurement isolation

(no findings)

Verification notes:
- `ProviderPreWarmer.prewarmAndProbe` records `started` before `runner.start`, waits for `waitForReady`, and returns `.warmed(cacheState:, loadDurationSec:)` only after readiness.
- `loadDurationSec` is only carried in `PreWarmResult`; Step 6 is not wired into `AutotuneCommand.run()` and nothing in the commit feeds it into gate TTFT.
- The production default for `now` is `Date.init`.

#### Category B: FR-D.2 transient vs integrity classification

**B.1 (CRITICAL) — Actual missing-tokenizer errors can miss the integrity marker and be classified transient.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift:138`; `phase3-binary/.build/checkouts/swift-transformers/Sources/Hub/Hub.swift:69`; `phase3-binary/.build/checkouts/swift-transformers/Sources/Hub/Hub.swift:260`; `phase3-binary/.build/checkouts/mlx-swift-examples/Libraries/MLXLMCommon/Tokenizer.swift:51`.
- **What:** Step 6 matches `"missing tokenizer.json"`. The dependency path for a local model directory with no `tokenizer.json` throws `configurationMissing("tokenizer.json")`, whose localized description is `Required configuration file missing: tokenizer.json`. The lowercased text `required configuration file missing: tokenizer.json` does not contain `missing tokenizer.json`.
- **Why:** SPEC-013 FR-D.2 explicitly names missing `tokenizer.json` as an integrity-class repository-shape failure. If the provider writes the dependency error to stderr, `failureClass(for:)` returns `.transient`, so Step 7 would advance instead of aborting with `exit_reason = 'pre_warm_integrity_failure'`.
- **Recommendation:** Add markers for the real dependency strings, at minimum `configuration file missing: tokenizer.json`, `missing: tokenizer.json`, `file not found: tokenizer.json`, and `missing required tokenizer files`. Add unit tests proving mixed-case and colon-bearing missing-tokenizer stderr classify as `.integrity`.

**B.2 (MAJOR) — Known malformed-weight loader strings are outside the integrity marker set.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift:138`; `phase3-binary/.build/checkouts/mlx-swift-examples/Libraries/MLXLMCommon/Load.swift:74`; `phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/io/safetensors.cpp:214`; `phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/io/safetensors.cpp:223`.
- **What:** MLX loads every `.safetensors` file through `loadArrays`; the vendored MLX safetensors reader throws strings such as `[load_safetensors] Invalid json header length ...` and `[load_safetensors] Invalid json metadata ...`. Public safetensors implementations also surface header/metadata corruption strings such as invalid header deserialization and incomplete metadata. None include Step 6's current hash/signature/checksum markers.
- **Why:** A malformed weights file can be a partial-download transient, but it can also be corrupted or tampered repository content. The current classifier has no way to distinguish it and defaults to `.transient`, which is the wrong bias for a plausible integrity signal under the asymmetric FR-D.2 risk model.
- **Recommendation:** Classify concrete malformed safetensors/load-header strings as integrity, or introduce a narrower `.integrity` marker set for corrupted local artifact text: `invalid json header`, `invalid json metadata`, `invalid header`, `incomplete metadata`, `file not fully covered`, and `invalid or corrupted`. Add regression coverage for at least one malformed-weight stderr sample.

**B.3 (MINOR) — Classification tests cover only one integrity marker.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift:95`; `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift:119`; `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift:143`.
- **What:** Tests cover network transient, lowercase `signature mismatch`, and timeout transient, but not missing tokenizer, mixed-case integrity text, malformed safetensors text, or short-marker false positives such as `no hash mismatch detected`.
- **Why:** The missing-tokenizer gap above would have been caught by a dependency-shaped test string. Case-insensitive behavior is intended but not locked.
- **Recommendation:** Add table-driven classification tests for every SPEC-named integrity example and one false-positive guard if the short `hash mismatch` marker remains.

#### Category C: HuggingFaceCacheChecker correctness

(no findings)

Verification notes:
- `repositoryDirectory(for:)` maps `mlx-community/Llama-3.2-1B-Instruct-4bit` to `models--mlx-community--Llama-3.2-1B-Instruct-4bit`, matching the HF cache reference layout.
- Hugging Face documents `snapshots/<commit>/` entries as symlinks to `../../blobs/{hash}` and also permits copied files when symlinks are unavailable; `containsAnyFile` accepts either regular files or symlinks.
- The partial-download false positive is not outcome-breaking because a broken snapshot still fails during provider load and reaches the FR-D.2 classifier.

#### Category D: Provider lifecycle wrapping

(no findings)

Verification notes:
- `defer { runner.stop(graceSeconds:) }` executes on `.warmed`, `.failed`, thrown `start`, and cancellation paths.
- Step 4's `stop()` returns `.stopped` when never started, so the throw-before-start path is safe.
- The wrapper preserves v1's no-SIGKILL rule by delegating only to `CandidateProviderRunner.stop`.

#### Category E: Test fixtures

**E.1 (MINOR) — `now` injection is not used to make load-duration assertions deterministic.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift:47`; `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift:63`; `phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift:91`.
- **What:** The happy/cold path tests use the production clock and assert only `loadDurationSec >= 0`.
- **Why:** The injection exists specifically to make timing stable; the current assertions would not catch a future change that records the end time before readiness or always returns zero.
- **Recommendation:** Add a tiny deterministic clock fixture and assert a known positive duration for at least one `.warmed` path.

#### Category F: Anti-regression

(no findings)

Verification notes:
- `git show e7bfab5 --stat` changes only `ProviderPreWarmer.swift`, `ProviderPreWarmerTests.swift`, and `implementation-notes.html`; production Step 1-5 files are not modified by the Step 6 commit.
- `swift test --package-path phase3-binary` passed: 293 tests executed, 2 tests skipped, 0 failures.

#### Category G: Forward-compatibility (Step 7, 10)

(no findings)

Verification notes:
- G.2 status: intended restart-with-warm-cache behavior, not a design bug in Step 6. `ProviderPreWarmer.swift:109` stops the provider before the caller receives `.warmed`; `ProviderPreWarmerTests.swift:64` and `:92` assert the port is closed; `implementation-notes.html:1327` says the wrapper always calls `stop`, and `:1332` calls this a disposable load/readiness phase.
- Step 7 must therefore start a new provider, wait for readiness, fire trial requests, and stop. The cold fetch is excluded because Step 6 has already warmed the HF cache; the second readiness wait is still outside gate-ttft-ms per the BUILD prompt's Step 7 sequence.
- `PreWarmResult` is sufficient for Step 7's branch shape: `.warmed`, `.failed(.transient, ...)`, and `.failed(.integrity, ...)`.

#### Category H: Anything else

(no findings)

Verification notes:
- NFR-4 is respected for Step 6: Shape B's only external egress is the runtime's HuggingFace online fallback during model load.
- The strict clean-room boundary was preserved; no d-inference source was inspected.

### Step 6 readiness verdict

FIX REQUIRED.

---

## Round 10 audit (Codex on 682abe8 — Step 6 round 2 closure verification)

**Audited:** commit 682abe8 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 6, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 4 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 4 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 1 MAJOR new / 0 MINOR new
**Step 6 readiness:** NARROW V2 REQUIRED

### Executive summary

Commit 682abe8 closes all 4 Round 9 findings. The missing-tokenizer classifier now matches the actual swift-transformers Hub error string, malformed safetensors header/metadata strings now classify as integrity, mixed-case matching is regression-tested, and the injected clock now has a deterministic 7-second duration assertion.

Anti-regression passed: `swift test --package-path phase3-binary` executed 297 tests, skipped 2 integration-gated tests, and reported 0 failures. However, the expanded 15-marker integrity list introduced one new precision gap: the unanchored `"incomplete metadata"` and `"invalid or corrupted"` markers are broad enough to classify plausible non-weight, retryable metadata/cache errors as integrity. Under the prompt's false-positive rule, this is a MAJOR new finding and Step 6 needs a narrow V2 before Step 7.

### Round-1 finding closures

**B.1 (CRITICAL) — CLOSED.** `ProviderPreWarmer` lowercases stderr and now includes `"configuration file missing: tokenizer.json"` plus `"missing: tokenizer.json"` and `"missing required tokenizer files"`, while keeping the original `"missing tokenizer.json"` fallback. The actual local dependency string is `Required configuration file missing: tokenizer.json` from `phase3-binary/.build/checkouts/swift-transformers/Sources/Hub/Hub.swift:69` and `:260-262`, and the new test `testPreWarmerClassifiesConfigurationFileMissingTokenizerAsIntegrity` feeds that exact string and asserts `.integrity`.

**B.2 (MAJOR) — CLOSED.** The marker list now includes `"invalid json header"` and `"invalid json metadata"`, which match the mlx-swift safetensors reader strings at `phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/io/safetensors.cpp:213-214` and `:221-223`. The new test `testPreWarmerClassifiesInvalidJsonHeaderAsIntegrity` uses the actual shape `"[load_safetensors] Invalid json header length 0"` and asserts `.integrity`. mlx-swift is MIT-licensed (`phase3-binary/.build/checkouts/mlx-swift/LICENSE`), so this check did not violate the d-inference clean-room boundary.

**B.3 (MINOR) — CLOSED.** `testPreWarmerClassifiesMixedCaseIntegrityCorrectly` feeds `"SIGNATURE Mismatch on Model Weights"` and asserts `.integrity`. Because production classification lowercases `stderrTail` before `contains` checks, this test locks the intended case-insensitive matcher behavior.

**E.1 (MINOR) — CLOSED.** `testPreWarmerLoadDurationReflectsInjectedClock` injects a `now` closure that returns `1_000_000` on the first call and `1_000_007` on the second call, then asserts `loadDurationSec == 7.0` with accuracy `0.001`. A regression that takes the end timestamp before readiness returns, or always returns zero, would fail this assertion.

### Round-2 new findings

#### Category Z-CLOSURE

(no findings)

#### Category R-REGRESSION-V06F1

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 297 tests executed, 2 skipped, 0 failures.
- The Step 6 happy-path, cold-cache, network-transient, signature-mismatch-integrity, timeout-transient, and four new audit-response tests all passed in `ProviderPreWarmerTests`.
- No Step 4 / Step 5 suite failures were observed in the full package test run.

#### Category N-NEWGAPS-V06F1

**N.1 (MAJOR) — Broad unanchored integrity markers can over-classify plausible non-weight metadata/cache errors.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift:130-133`; `phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift:189-192`.
- **What:** The classifier applies every marker as a case-insensitive substring to the full provider stderr tail. The new `"invalid json header"` and `"invalid json metadata"` markers are anchored enough to the mlx safetensors loader's actual strings. The new tokenizer markers are also specific. But `"incomplete metadata"` and `"invalid or corrupted"` are not anchored to safetensors, weights, tokenizer files, or repository-shape context.
- **Why:** A benign or retryable provider-exit line such as `Download failed: incomplete metadata in Hugging Face API response; retry later` would match `"incomplete metadata"`. A local cache-maintenance line such as `cache index invalid or corrupted; rebuild cache and retry` would match `"invalid or corrupted"`. Those lines are plausibly transient/local-state failures rather than repository tampering, but this code would return `.integrity` and over-abort the candidate. The asymmetric FR-D.2 model tolerates some transient-as-integrity risk, but the prompt explicitly treats a plausible benign matching line as a MAJOR precision gap.
- **Recommendation:** Narrow these markers to concrete model-artifact contexts, for example require safetensors/weights/load context (`"[load_safetensors] invalid json header"`, `"[load_safetensors] invalid json metadata"`, `"weights file is invalid or corrupted"`) or remove `"incomplete metadata"` unless paired with a safetensors-specific phrase. Add negative tests proving benign metadata/cache lines remain `.transient`.

#### Category O-OTHER-V06F1

(no findings)

### Step 6 readiness verdict

NARROW V2 REQUIRED.

---

## Round 11 audit (Codex on dcd7f63 — Step 6 round 3 closure verification)

**Audited:** commit dcd7f63 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 6, round 3 of N
**Date:** 2026-06-18
**Closure summary:** 1 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED for N.1
**Round-3 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 6 readiness:** READY TO PROCEED TO STEP 7

### Executive summary

Commit dcd7f63 closes Round 10 N.1. The two vague integrity markers, `"incomplete metadata"` and `"invalid or corrupted"`, are no longer in the production integrity list; the list is now 13 markers. The two new negative-lock tests feed the exact benign lines from Round 10 and assert `.transient`, so either broad marker would flip the matching test to `.integrity` and fail.

Anti-regression passed. `swift test --package-path phase3-binary` executed 299 tests, skipped 2 integration-gated tests, and reported 0 failures. The four Round 9 closure tests still pass under the narrower marker list, and the remaining 13 markers still cover SPEC-013 FR-D.2's named integrity examples.

### Round-2 finding closures

**N.1 (MAJOR) — CLOSED.** `ProviderPreWarmer.integrityMarkers` now omits `"incomplete metadata"` and `"invalid or corrupted"` while retaining the anchored safetensors loader markers `"invalid json header"` and `"invalid json metadata"` (`phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift:164-207`). The new tests `testPreWarmerClassifiesIncompleteMetadataDownloadErrorAsTransient` and `testPreWarmerClassifiesCacheRebuildHintAsTransient` feed `Download failed: incomplete metadata in Hugging Face API response; retry later` and `cache index invalid or corrupted; rebuild cache and retry`, respectively, and assert `.transient` (`phase3-binary/Tests/macprovider-cliTests/ProviderPreWarmerTests.swift:270-326`). Because classification is a lowercased substring match, reintroducing either removed marker would make the corresponding test return `.integrity` and fail.

### Round-3 new findings

#### Category Z-CLOSURE

(no findings)

Verification notes:
- The integrity list is 13 markers: 7 signature/hash/checksum markers, 4 missing-tokenizer markers, and 2 safetensors loader markers.
- SPEC-013 FR-D.2 coverage remains present: signature mismatch via `"signature mismatch"`; weight hash mismatch via `"hash mismatch"`; missing `tokenizer.json` via the four tokenizer markers; safetensors header/metadata corruption via `"invalid json header"` and `"invalid json metadata"`; tampering signals via the signature/hash/checksum class.
- The four Round 9 closure tests still pass in the full suite: `testPreWarmerClassifiesConfigurationFileMissingTokenizerAsIntegrity`, `testPreWarmerClassifiesInvalidJsonHeaderAsIntegrity`, `testPreWarmerClassifiesMixedCaseIntegrityCorrectly`, and `testPreWarmerLoadDurationReflectsInjectedClock`.

#### Category R-REGRESSION-V06F2

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 299 tests executed, 2 skipped, 0 failures.
- `ProviderPreWarmerTests` executed 13 tests, including the 4 Round 9 closure tests and the 2 Round 10 negative-lock tests, with 0 failures.
- No Step 1-5 suite failures were observed in the full package test run.

#### Category N-NEWGAPS-V06F2

(no findings)

Verification notes:
- Local spot-checks in `mlx-swift`, `mlx-swift-examples`, and `swift-transformers` found the active MLX provider load path in `LLMModelFactory._load` calls `loadWeights`, which enumerates `.safetensors` files and calls `MLX.loadArrays(url:)`; that path's concrete malformed safetensors strings are `[load_safetensors] Invalid json header ...` and `[load_safetensors] Invalid json metadata ...`, both still covered.
- A build-visible `swift-transformers` `WeightsError.invalidFile` string says `The weights file is invalid or corrupted.`, but `rg` found no call chain from the audited MLX provider load path to `Weights.from(fileURL:)`; it is therefore not a concrete Step 6 precision gap for this implementation.
- The removed strings now correctly classify the Round 10 benign HF API metadata and cache rebuild examples as transient.

#### Category O-OTHER-V06F2

(no findings)

### Step 6 readiness verdict

READY TO PROCEED TO STEP 7.

---

## Round 12 audit (Codex on 98d7079 — Step 7 round 1)

**Audited:** commit 98d7079 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 7, round 1 of N
**Date:** 2026-06-18
**Total findings:** 1 CRITICAL / 1 MAJOR / 4 MINOR / 0 QUESTION
**Step 7 readiness:** FIX REQUIRED

### Executive summary

Step 7 preserves the load-bearing biggest-fit iteration contract for the normal success path. `Stage1Iterator.run()` stores the constructor's `candidates` array unchanged, iterates `for candidate in candidates`, and returns immediately on the first feasible probe. The AC-17 unit test is meaningful: it supplies `["1b", "32b"]` with both candidates feasible and asserts only `1b` is pre-warmed, probed, and persisted.

The blocker is the all-infeasible failure-reason contract. `failureReasons.last` only surfaces the smallest candidate when the input order is largest-first. SPEC-013 also requires explicit operator order to be honored verbatim, including a manifestly small-first list, so the current code can surface the largest candidate's reason first in a valid AC-17-style override. That is a silent FR-A.4 / FR-H.4 violation and must be fixed before Step 8.

Full anti-regression passed. `swift test --package-path phase3-binary` executed 306 tests, skipped 2 integration-gated tests, and reported 0 failures.

### Findings

#### Category A: FR-A.1 / AC-17 operator-order contract

(no findings)

Verification notes:
- `Stage1Iterator.init` assigns `self.candidates = candidates`, preserving the caller-provided Swift array value (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:119-145` at 98d7079).
- `run()` iterates `for candidate in candidates` with no sort, filter, size parse, or re-rank helper in the file (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:147-218` at 98d7079).
- `testStage1IteratorHonorsOperatorOrderForACSeventeen` makes both `"1b"` and `"32b"` feasible, passes `["1b", "32b"]`, and asserts the selected model, prewarmer list, prober list, and DB rows are all only `"1b"` (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:128-151` at 98d7079). A size-descending internal sort would select/probe `"32b"` and fail this test.

#### Category B: FR-A.2 STOP-on-first-feasible

(no findings)

Verification notes:
- The `.feasible` branch returns `Stage1IteratorResult` immediately and includes the feasible row in `trials` (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:191-206` at 98d7079).
- `testStage1IteratorStopsOnFirstFeasible` uses `[model-a infeasible, model-b feasible, model-c feasible]` and asserts only `model-a` and `model-b` are probed/persisted (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:8-34` at 98d7079).

#### Category C: FR-A.3 four-condition feasibility gate

(no findings)

Verification notes:
- HTTP 2xx is required before accepting a replicate (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:365-370` at 98d7079).
- TTFT p95 uses sorted `ceil(n * 0.95) - 1`, rejects only when `p95 > gate`, so equality is feasible (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:402-408`, `505-509` at 98d7079).
- Stop-token leak detection scans the full generated text for `<|im_end|>`, `<|endoftext|>`, and `<|eot_id|>` (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:286-287`, `371-373` at 98d7079).
- Process exits before readiness and during per-request peeks are converted to infeasible results (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:343-356`, `377-391` at 98d7079).

#### Category D: SSE parsing correctness

**D.1 (MINOR) — SSE parser does not lock common non-happy streaming edge cases.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:449-503` at 98d7079; `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:153-197` at 98d7079.
- **What:** The parser handles the common OpenAI-compatible `data: {"choices":[{"delta":{"content":"..."}}]}` shape and also `choices[0].text`. It skips comments, blank lines, role-only deltas, malformed JSON, and `[DONE]` without crashing. The test suite only exercises the happy SSE payload through the stop-token and TTFT tests.
- **Why:** This is acceptable for v1 but leaves no regression lock for HTTP non-2xx, malformed `data:` JSON, comment/heartbeat lines, or completions-style `choices[0].text`. A future parser tightening could silently turn valid OpenAI-compatible streams into "no content."
- **Recommendation:** Add focused prober tests for HTTP 503 -> infeasible, malformed JSON/comment lines -> skipped gracefully, and `choices[0].text` -> content accepted.

#### Category E: FR-A.4 / FR-H.4 smallest-first error

**E.1 (CRITICAL) — `failureReasons.last` can surface the largest candidate first for a valid operator-supplied order.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:149`, `207-217` at 98d7079; `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:93-126` at 98d7079.
- **What:** All-infeasible surfacing uses `failureReasons.last`. That returns the smallest candidate only when iteration order is largest-first. SPEC-013 FR-A.1 explicitly says the operator may override order entirely and the implementation must honor even a manifestly wrong `"1B first, then 32B"` order. SPEC-013 FR-H.4 separately requires the error message to lead with the smallest failed candidate, not the last evaluated candidate.
- **Why:** With a valid operator override like `["1b", "32b"]` where both fail, `failureReasons.last` would lead with the `32b` reason. That is exactly the severity-definition example for a silent FR-A.4 / FR-H.4 violation: the largest candidate's reason is surfaced first. The existing test only uses `["32b", "14b", "1b"]`, so it passes by tautology and does not catch the AC-17-style override case.
- **Recommendation:** Track failure reasons by candidate identity and surface the smallest-by-size/model-order diagnostic independently from iteration order. If no reliable size metadata exists in Step 7, make the size-order source explicit by passing the default size ordering or parsed candidate metadata into the iterator. Add a regression test with `candidates: ["1b", "32b"]`, both infeasible, expecting the `1b` reason first while still preserving evaluation order.

#### Category F: FR-D.2 integrity-vs-transient cascade

**F.1 (MAJOR) — Integrity abort records no trial row, and the test locks that absence.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:160-166` at 98d7079; `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:60-91` at 98d7079.
- **What:** On `.failed(.integrity, reason)`, the iterator throws `preWarmIntegrityFailure` immediately before calling `makeTrialRow` or `autotuneDB.insertTrial`. The test then asserts `trialModels(at: dbURL) == []`.
- **Why:** The audit prompt's FR-D.2/FR-G.1 check expects the offending candidate's trial to be recorded before abort so reporting can preserve the candidate and reason. The current code loses the integrity failure from `tune_trials`; Step 10 may later write the `tune_runs` row, but Step 7's dormant primitive has no persisted per-candidate evidence for this security-relevant abort.
- **Recommendation:** Insert a Stage 1 `tune_trials` row for integrity pre-warm failures before throwing, with `fits = false`, `n_err = 1`, `kept = false`, and `notes = "pre-warm integrity: <reason>"` or an equivalent distinct prefix. Flip the test to assert that row exists and that the second candidate is still never pre-warmed/probed.

#### Category G: DI / Protocol design

**G.1 (MINOR) — Production pre-warmer conformance leaks a concrete runner downcast.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:27-43` at 98d7079.
- **What:** `ProviderPreWarmer: Stage1PreWarming` accepts `Stage1ProviderRunning` but immediately downcasts to `CandidateProviderRunner`, throwing `invalidInjectedRunner` otherwise.
- **Why:** Tests avoid this by injecting a fake `Stage1PreWarming`, and production passes a real `CandidateProviderRunner`, so this is not a functional blocker. It does make the protocol boundary weaker than it looks and can surprise any future test that combines the real prewarmer with a fake runner.
- **Recommendation:** Either keep the cast but document that the production adapter requires `CandidateProviderRunner`, or make `ProviderPreWarmer` generic/abstract over the runner methods it actually needs.

#### Category H: AutotuneDB persistence

**H.1 (MINOR) — Stage 1 feasible rows set `kept = true` despite the schema comment saying Stage 2 owns kept.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:191-196`, `247-265` at 98d7079; `specs/SPEC-013-cli-autotune.md:1057-1060`.
- **What:** `makeTrialRow` accepts `kept`, and the iterator passes `kept: probeResult.isFeasible`, so the first feasible Stage 1 row is persisted with `kept = true`.
- **Why:** The audit prompt's Category H expects the first feasible row to be kept, but SPEC-013 FR-G.1's schema comment says `kept` is "Stage 2 only; 0 in Stage 1." This is a spec/prompt tension, not a runtime correctness blocker for Step 7. It should be resolved before Step 9 reporting depends on `kept` semantics.
- **Recommendation:** Pick one interpretation before wiring recommendation reporting. If Stage 1 chosen-model rows should be discoverable via `kept`, update the normative schema comment. If `kept` is Stage 2-only, persist Stage 1 `kept = false` and derive the chosen model from `Stage1IteratorResult.selectedModel` / Step 10 run metadata.

Verification notes:
- Stage is hard-coded to `1`, `runID` is stable across rows, `kvBits` and `maxBatch` are `nil`, `maxContextCap` equals `targetContext`, and `replicatesN = stage1Replicates` (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:247-265` at 98d7079).
- `git show 98d7079 -- phase3-binary/Sources/macprovider-cli/AutotuneDB.swift` produced no diff; Step 7 does not modify the DB schema.

#### Category I: Anti-regression on Steps 1-6

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 306 tests executed, 2 skipped, 0 failures.
- `git diff --stat 0f76bcf 98d7079 -- phase3-binary/Sources/` shows only the new `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift` source file under `Sources`.
- Existing Step 4 and Step 6 production APIs are extended by protocol conformances in the new file; no existing source method signatures are changed by the Step 7 commit.

#### Category J: Forward-compatibility (Steps 8, 9, 10)

(no findings)

Verification notes:
- `Stage1IteratorResult` exposes `selectedModel`, `trials`, and `exitReason`, enough for Step 8 to receive the chosen model and Step 9 to use the returned trial metrics (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:62-66` at 98d7079).
- `Stage1Prober` starts a fresh runner and stops it in `defer`, preserving the Step 6 disposable pre-warm / fresh probe-provider lifecycle (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:324-341` at 98d7079).
- Step 10 still owns `AutotuneCommand.run()` wiring, `tune_runs`, signal handling, and final output; Step 7 remains dormant as intended.

#### Category K: Test fixtures and coverage

**K.1 (MINOR) — Stage 1 persistence fields are only partially asserted.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:8-151`, `334-362` at 98d7079.
- **What:** Iterator tests query persisted `model` and one transient `notes` value, but do not assert `stage = 1`, `run_id`, `fits`, `n_err`, `kept`, `replicates_n`, `target_context`, or metric fields.
- **Why:** The production `makeTrialRow` currently sets most of these correctly, but a future regression could write `stage = 0` or lose `replicates_n` without failing the Step 7 test suite. AC-16 is explicitly about `tune_trials.stage`.
- **Recommendation:** Add a row-reader helper for full `AutotuneTrialRow`-relevant columns and assert at least one infeasible row, one transient row, and one feasible row have the expected Stage 1 fields.

Verification notes:
- The seven required tests exist and exercise the named high-level contracts: stop-on-first-feasible, transient advancement, integrity abort, all-infeasible reason surfacing, AC-17 operator order, stop-token leak detection, and TTFT gate miss.
- Gaps remaining: HTTP non-2xx, malformed SSE JSON, zero replicates, and full persisted field assertions.

#### Category O: Anything else

(no findings)

Verification notes:
- The Step 7 implementation-notes section accurately describes the dormant iterator/prober, operator-order preservation, fresh probe provider, SSE TTFT measurement, Stage 1 persistence, and test coverage at a high level (`phase3-binary/implementation-notes.html` section `spec013-autotune-step7` at 98d7079).
- The per-row ISO8601 formatter allocation is a minor performance detail and not material for Stage 1 candidate counts.

### Step 7 readiness verdict

FIX REQUIRED.

---

## Round 13 audit (Codex on a9da9e5 — Step 7 round 2 closure verification)

**Audited:** commit a9da9e5 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 7, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 6 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 6 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 1 MINOR new
**Step 7 readiness:** READY TO PROCEED TO STEP 8

### Executive summary

Commit a9da9e5 closes all six Round 12 findings. The load-bearing E.1 fix no longer derives the all-infeasible surface from iteration order; it records failures by candidate identity and walks `candidatesBySize` smallest-first for the leading reason and `trials` list. The STOP-on-first-feasible path still returns immediately on the first feasible probe, and Stage 1 rows now consistently use `kept = false` while surfacing the selected model through `Stage1IteratorResult.selectedModel`.

Full anti-regression passed. `swift test --package-path phase3-binary` executed 310 tests, skipped 2 integration-gated tests, and reported 0 failures. Round 2 found one non-blocking API brittleness issue: future Step 10 wiring must pass explicit `candidatesBySize` for operator overrides, because the nil fallback assumes the default largest-first list. This is documented and test-covered for the explicit path, so it is a Step 10 handoff risk, not a Step 7 blocker.

### Round-1 finding closures

**E.1 (CRITICAL) — CLOSED.** `Stage1Iterator.init` now accepts `candidatesBySize: [String]?` and falls back to `Array(candidates.reversed())` only for the default largest-first convention (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:133-173`). `run()` stores failures in `failureReasonsByCandidate`, then computes `smallestFailed` by walking `candidatesBySize` and emits both the leading `"<candidate>: <reason>"` surface and the size-ordered `trials` list from that same order (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:182-289`). The default-list test now asserts `1b: 1b leaked stop token` and `["1b leaked stop token", "14b too slow", "32b too slow"]`; the new operator-override test passes `candidates: ["1b", "32b"]` plus `candidatesBySize: ["1b", "32b"]`, makes both fail, and asserts the `1b` reason leads (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:98-194`).

**F.1 (MAJOR) — CLOSED.** The `.failed(.integrity, reason)` branch now builds a `pre-warm integrity: <reason>` row, calls `autotuneDB.insertTrial(row)`, appends the row, and only then throws `preWarmIntegrityFailure` (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:198-218`). `testStage1IteratorAbortsOnIntegrity` asserts the offending model row exists, `trialModels(at:) == ["model-a"]`, while `prewarmer.models == ["model-a"]` and `prober.probedModels == []`, so the second candidate remains unvisited (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:60-96`).

**H.1 (MINOR) — CLOSED.** The probe row creation path always passes `kept: false`, including for feasible rows (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:244-255`). `makeTrialRow` still returns `Stage1IteratorResult(selectedModel: candidate, ...)` immediately on feasibility, so Step 9 can consume the chosen model without relying on Stage 1 `tune_trials.kept` (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:259-265`). `testStage1IteratorPersistsFullStage1FieldSet` asserts `row.kept == false` for a feasible Stage 1 row (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:320-358`).

**D.1 (MINOR) — CLOSED.** The fix-pass adds the two requested prober tests. `testStage1ProberClassifiesHTTPNon2xxAsInfeasible` serves `/v1/models` as ready, then returns HTTP 503 for the chat completion request and asserts an infeasible result containing `HTTP 503` (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:269-293`, `384-435`). `testStage1ProberAcceptsCompletionsStyleTextSSE` uses a fixture that sends `: keep-alive`, `data: not-valid-json`, a valid `choices[0].text` chunk, then `[DONE]`, and asserts feasibility (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:295-318`, `437-511`). The parser skips non-`data:` comment lines, skips malformed JSON through `try?`, and accepts both `delta.content` and `text` content shapes (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:521-575`).

**K.1 (MINOR) — CLOSED.** `assertSingleTrialRow` directly selects `ts_utc, run_id, stage, model, target_context, measured_prompt_tokens, max_tokens, agg_throughput_tps, ttft_p95_ms, fits, n_err, kept, notes, kv_bits, max_context_cap, max_batch, replicates_n` from SQLite and maps columns 0 through 16 into `AutotuneTrialRow` without an index shift (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:513-571`). The new test asserts `stage = 1`, `runID = "stage1-test-run"`, `fits = true`, `nErr = 0`, `kept = false`, `replicatesN = 3`, `maxContextCap = 4_000`, `kvBits = nil`, and `maxBatch = nil`, so regressions such as `stage = 0` or lost `replicates_n` would fail (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:326-358`).

**G.1 (MINOR) — CLOSED.** The `ProviderPreWarmer: Stage1PreWarming` extension is runtime-identical except for documentation. The new doc block explicitly states the production adapter requires a concrete `CandidateProviderRunner`, explains the `invalidInjectedRunner` fake-runner edge, and directs tests to inject fake `Stage1PreWarming` instead (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:27-40`).

### Round-2 new findings

#### Category Z-CLOSURE

(no findings)

Verification notes:
- All six Round 12 closures are implemented in the claimed commit and are covered by the new or updated tests named in the round-2 prompt.
- `phase3-binary/implementation-notes.html` has a Step 7 round-1 audit-response entry documenting E.1, F.1, H.1, D.1, K.1, G.1, and the 310-test anti-regression result (`phase3-binary/implementation-notes.html:1484-1540`).

#### Category R-REGRESSION-V07F1

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 310 tests executed, 2 skipped, 0 failures.
- `Stage1IteratorTests` executed 11 tests with 0 failures, including the 7 original Step 7 tests plus the 4 audit-response tests.
- The AC-17 guard remains meaningful: `testStage1IteratorHonorsOperatorOrderForACSeventeen` still passes `["1b", "32b"]`, makes both feasible, and asserts only `1b` is selected, pre-warmed, probed, and persisted (`phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:196-219`).
- No Step 1-6 suite failures were observed in the full package test run.

#### Category N-NEWGAPS-V07F1

**N.1 (MINOR) — `candidatesBySize` is a brittle handoff contract for future Step 10 wiring.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:133-173`, `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:271-284`, `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:119-149`.
- **What:** The E.1 closure is correct when callers pass the new explicit `candidatesBySize` parameter for operator overrides. However, the nil fallback assumes `candidates` is the default largest-first list and reverses it. If a future Step 10 caller passes an operator-supplied smallest-first list as `candidates` but omits `candidatesBySize`, all-infeasible diagnostics will lead with the largest failed candidate again. The explicit override test covers the correct usage, but the API does not make omission impossible.
- **Why:** This does not break Step 7 today because Stage 1 is still a dormant primitive and `AutotuneCommand.run()` has not wired `Stage1Iterator` yet. The comment at initialization documents the required Step 10 behavior, and `AutotuneCommand.defaultCandidates` already carries `sizeB` metadata for default candidates. The risk is future integration drift at the boundary between `AutotuneCommand.candidatePlan()` and `Stage1Iterator`.
- **Recommendation:** In Step 10, derive and pass explicit smallest-first `candidatesBySize` for every `Stage1Iterator` call, including `--candidate-models` overrides. Add a Step 10 integration test where `--candidate-models 1b,32b` makes both fail and asserts the all-infeasible surface still leads with `1b`. If size metadata is unavailable for arbitrary operator IDs, require the caller to preserve the operator's explicit size order or document the limitation in the Step 10 error surface.

#### Category O-OTHER-V07F1

(no findings)

Verification notes:
- A `candidatesBySize` entry not present in `candidates` is ignored by the dictionary lookup and walk, which is graceful.
- A `candidatesBySize` list missing a failed candidate omits that candidate from the size-ordered failure surface. This is part of the same API handoff risk as N.1 rather than a separate Step 7 defect.
- If integrity-row insertion itself throws, the caller sees the DB insertion failure instead of `preWarmIntegrityFailure`. That preserves the more immediate persistence failure and is acceptable for v1.

### Step 7 readiness verdict

READY TO PROCEED TO STEP 8.

---

## Round 14 audit (Codex on 118599e — Step 8 round 1)

**Audited:** commit 118599e on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 8, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 1 MAJOR / 1 MINOR / 0 QUESTION
**Step 8 readiness:** FIX REQUIRED

### Executive summary

The load-bearing Category A check passed: `Stage2HillClimb.isNewBest` is a faithful Swift port of PR #103 prototype `_is_new_best`. It rejects nil TPS, accepts the first feasible baseline, handles `best_tps <= 0`, uses strict `relGap > epsilon` for throughput wins, and only replaces inside the tie band when the new TTFT is present and strictly lower. The three isNewBest scenario tests use correct gaps: 12 vs 10 is a 20% throughput win, 10.1 vs 10 is a 1% tie-band TTFT win, and 10.05 vs 10 is a 0.5% tie-band non-replacement when TTFT is worse.

The main blocker is persistence semantics for `tune_trials.kept`. The implementation writes `kept = true` for every cell that becomes best at evaluation time, so a later winner leaves earlier rows marked kept. The Step 8 prompt's FR-G.1 interpretation requires only the final winning Stage 2 cell to have `kept = true` and all other cells to have `kept = false`; the tests currently lock the opposite behavior for throughput and TTFT replacement cases.

Anti-regression passed. `swift test --package-path phase3-binary` executed 317 tests, skipped 2 integration-gated tests, and reported 0 failures. Because the persisted `kept` field can mislead Step 9 reporting if it scans `tune_trials`, Step 8 is not ready to proceed as-is.

### Findings

#### Category A: isNewBest semantics port

(no findings)

Verification notes:
- Prototype reference: `origin/spike/provider-model-autotune:beta/autotune.py` lines containing `_is_new_best` implement `tps is None -> False`, `best is None -> True`, `best.get("tps") or 0.0`, `best_tps <= 0 -> tps > 0`, `rel_gap > TPS_TIE_EPSILON -> True`, and tie-band TTFT replacement only when `ttft is not None and (best_ttft is None or ttft < best_ttft)`.
- Swift matches branch-for-branch at `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:172-200`. The split `if let ttft, let bestTTFT { return ttft < bestTTFT }` plus `if ttft != nil { return true }` is equivalent to Python's `ttft is not None and (best_ttft is None or ttft < best_ttft)`.
- Equal TPS/equal TTFT and tie-band/equal TTFT both return false because the Swift branch uses strict `<`, matching the prototype.
- Tests at `phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:32-69` and `:161-179` exercise throughput-primary replacement, TTFT tie-break replacement, and epsilon non-replacement with correct relative gaps.

#### Category B: Strict-all-feasible per cell (FR-B.2)

(no findings)

Verification notes:
- `Stage2Prober.probe` normalizes replicate count to at least 1, collects TTFT/TPS only for passing requests, and returns `.infeasible` with nil aggregate metrics whenever `nErr > 0` (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:315-413`).
- The four FR-A.3 gate classes are covered in the prober path: HTTP 2xx check (`:354-358`), TTFT gate check (`:366-370`), stop-token leak check (`:359-365`), and provider exit before/during probing (`:329-344`, `:374-390`).
- `testStage2HillClimbRejectsCellWhenAnyReplicateInfeasible` configures an infeasible first cell with `stage2Replicates: 3` and asserts `fits == false`, nil TPS/TTFT aggregates, `replicatesN == 3`, and nil persisted throughput (`phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:72-95`).

#### Category C: Cartesian product determinism

(no findings)

Verification notes:
- The nested loops are deterministic: `kvBitsAxis` outer, `maxBatchAxis` middle, `maxContextAxis` inner (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:107-153`).
- The persistence/order test reads rows by `ORDER BY id ASC` and asserts `[nil, nil, 4, 4]` for kv bits and `[1, 2, 1, 2]` for max batch, matching that loop order (`phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:127-158`, `:230-237`).
- `phase3-binary/implementation-notes.html:1553-1557` documents the same axis order.

#### Category D: AutotuneDB persistence

**D.1 (MAJOR) - Stage 2 persists transient best rows as `kept = true`, not only the final winning cell.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:126-149`, `:232-249`; `phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:47-49`, `:67-69`.
- **What:** `isNewBest` is computed before each insert and passed directly to `makeTrialRow(kept:)`. If cell A is the first feasible baseline and cell B later becomes the winner, both rows are persisted with `kept = true`. The throughput and TTFT replacement tests explicitly assert `[true, true]`.
- **Why:** The Step 8 prompt interprets SPEC-013 FR-G.1 as requiring Stage 2's final winning cell row to get `kept = true` and all other rows to get `kept = false`. Multiple kept rows can silently mislead Step 9 if recommendation reporting reconstructs the winner from `tune_trials.kept` rather than `Stage2HillClimbResult.winningKnobs`.
- **Recommendation:** Persist one final winner marker only. The least invasive fix is to evaluate all cells, determine `best`, then insert rows with `kept = (row cell == final best)`; alternatively update the previously inserted incumbent row to `kept = false` whenever a later cell wins. Update the replacement tests to expect `[false, true]` and add a DB assertion that exactly one Stage 2 row in a run has `kept = true`.

Verification notes:
- Other required fields are populated correctly in code: `stage = 2`, stable `runID`, per-cell `kvBits`, per-cell `maxContextCap`, per-cell `maxBatch`, `replicatesN = stage2Replicates`, nil aggregate metrics on infeasible rows, and non-nil median/p95 metrics on feasible rows (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:232-249`).
- `testStage2HillClimbPersistsAllCellTrialsWithStageTwo` asserts row count, `stage`, `kvBits`, `maxBatch`, `maxContextCap`, `replicatesN`, and prober order (`phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:146-158`), but not runID, model, targetContext, measuredPromptTokens, maxTokens, fits, nErr, kept, notes, or aggregate metrics.

#### Category E: noFeasibleCell error

(no findings)

Verification notes:
- `Stage2HillClimbError.noFeasibleCell(reason:)` is distinct from Stage 1 errors and includes a descriptive `CustomStringConvertible` surface (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:18-26`).
- The all-infeasible path joins per-cell failure reasons and throws only after all cells are evaluated (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:139-159`).
- `testStage2HillClimbAllCellsInfeasibleThrowsNoFeasibleCell` asserts the specific error case, both failure reason fragments, and the Stage 2 description prefix (`phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:98-124`).
- Step 10 still owns mapping this error to `tune_runs.exit_reason`; no Step 8 code commits to a new enum value.

#### Category F: Provider lifecycle per cell

(no findings)

Verification notes:
- `Stage2HillClimb.run()` calls `runnerFactory()` inside the innermost cell loop (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:107-116`), so each cell receives a fresh runner instance.
- `Stage2Prober.probe` starts the provider with the cell's `kvBits`, `maxContext`, and `maxBatch`, then stops it in `defer` (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:318-327`).
- Because each probe call awaits completion before the next loop iteration, the prior provider's defer-stop runs before the next cell starts.

#### Category G: SSE/TTFT measurement reuse

(no findings)

Verification notes:
- Stage 2 duplicates rather than shares Stage 1's SSE helper code, but the core parser/measurement shape is aligned: same endpoint, streamed request body, first non-empty `delta.content` or `choices[0].text` as TTFT boundary, generated text accumulation, whitespace token approximation, and p95/median helpers (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:497-593`; `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:416-512`).
- The notable Stage 2 difference is intentional for strict-all-feasible per-cell semantics: TTFT over gate increments `nErr` immediately and causes the cell to become infeasible with nil aggregates (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:366-399`).

#### Category H: Anti-regression on Steps 1-7

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 317 tests executed, 2 skipped, 0 failures.
- `Stage2HillClimbTests` executed 7 tests with 0 failures.
- `git diff --stat 118599e^ 118599e` shows exactly 3 changed files: added `Stage2HillClimb.swift`, added `Stage2HillClimbTests.swift`, and modified `implementation-notes.html`. No existing Step 1-7 production sources were modified in the Step 8 commit.

#### Category I: Forward-compatibility (Steps 9, 10)

(no findings)

Verification notes:
- `Stage2HillClimbResult` exposes `selectedModel`, `winningKnobs`, `medianTPS`, `p95TTFTMS`, `replicates`, and `cellTrials`, which is enough for Step 9's recommendation surface if Step 9 consumes the result object directly (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:9-16`).
- Step 10 can wire Stage 1 to Stage 2 cleanly by passing `Stage1IteratorResult.selectedModel` into `Stage2HillClimb.selectedModel`; the Step 8 commit intentionally leaves CLI runtime wiring untouched.
- D.1 remains the Step 9/10 handoff risk if later reporting uses DB `kept` rows instead of the result object.

#### Category J: Test fixtures

**J.1 (MINOR) - Direct `isNewBest` edge-branch tests are incomplete.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:7-180`; `phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:172-200`.
- **What:** The seven tests cover baseline selection, throughput replacement, TTFT replacement, strict infeasible rejection, all-infeasible error reporting, persistence/order, and epsilon non-replacement. They do not directly test `bestTPS <= 0` or the tie-band branch where `bestTTFT == nil`.
- **Why:** The production hill-climb usually stores feasible `Double` metrics, so these edges are unlikely in normal flow. Still, they are explicit prototype branches, and a future refactor of the static helper could break them without failing Step 8 tests.
- **Recommendation:** Add direct static-helper tests for `bestTPS: 0` with positive/non-positive new TPS and tie-band `ttft != nil, bestTTFT: nil`. The `kv_bits = nil` winning case is already covered by the first-baseline and epsilon-hold tests.

Verification notes:
- Each named test exercises more than "did not throw": the assertions check winner knobs, metrics, persisted row count/fields, error payload, or cell order.
- `testStage2HillClimbPersistsAllCellTrialsWithStageTwo` should be expanded in the D.1 fix-pass to assert the full row set, especially exactly-one final `kept`.

#### Category K: Anything else

(no findings)

Verification notes:
- `phase3-binary/implementation-notes.html:1545-1577` accurately describes the dormant Step 8 scope, deterministic axis order, `WinningKnobs`, keep-best rule, strict infeasible behavior, and test coverage at a high level.
- Naming divergence is acceptable: Stage 1 iterates candidate models, while Stage 2 hill-climbs knobs within the chosen model.

### Step 8 readiness verdict

FIX REQUIRED.

---

## Round 15 audit (Codex on 022e8a3 — Step 8 round 2 closure verification)

**Audited:** commit 022e8a3 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 8, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 2 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 2 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 8 readiness:** READY TO PROCEED TO STEP 9

### Executive summary

Commit 022e8a3 closes both Round 14 findings. D.1 is closed by moving Stage 2 winner persistence to a post-loop marker update: all rows are inserted with `kept = false`, the final winner is tracked by row index, and `AutotuneDB.markStage2WinnerCell(runID:kvBits:maxBatch:maxContextCap:)` marks only the final winning knob cell in SQLite while the in-memory `cellTrials` row is updated to match. J.1 is closed by five direct `isNewBest` edge-branch tests covering `bestTPS <= 0` and the nil-TTFT tie-band branches.

The highest-risk new surface, `markStage2WinnerCell`, is acceptable. Its SQL handles `kv_bits` NULL with `IS NULL`, uses `kv_bits = ?` only for non-NULL values, binds all operator data through the existing SQLite helpers, and matches by `run_id`, `stage = 2`, `kv_bits`, `max_batch`, and `max_context_cap`. Full anti-regression passed: `swift test --package-path phase3-binary` executed 322 tests, skipped 2 integration-gated tests, and reported 0 failures.

### Round-1 finding closures

**D.1 (MAJOR) — CLOSED.** `Stage2HillClimb.run()` now records `bestRowIndex` when a feasible cell becomes the current best, inserts every trial row with `kept: false`, and only after the Cartesian product completes calls `autotuneDB.markStage2WinnerCell` with the final winner's knobs (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:102-184`). If every cell is infeasible, the `guard let best else` path throws `.noFeasibleCell` before the marker call, so no winner row is fabricated (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:165-179`).

`markStage2WinnerCell` uses a constant SQL-clause choice for `kv_bits`: nil emits `kv_bits IS NULL`; non-nil emits `kv_bits = ?` (`phase3-binary/Sources/macprovider-cli/AutotuneDB.swift:194-210`). Bind arithmetic is correct in both branches. The nil branch binds `run_id` at 1, skips `kv_bits`, binds `max_batch` at 2, and binds `max_context_cap` at 3. The non-nil branch binds `run_id` at 1, `kv_bits` at 2, `max_batch` at 3, and `max_context_cap` at 4 (`phase3-binary/Sources/macprovider-cli/AutotuneDB.swift:211-222`). The `UPDATE` predicate is limited to `run_id`, `stage = 2`, the appropriate `kv_bits` clause, `max_batch`, and `max_context_cap`, so it matches the intended Stage 2 winner row for the run; repeated calls set the same row's `kept` to 1 again. The persistence regression test asserts the four Stage 2 rows remain in deterministic order and exactly one row has `kept = true`, specifically `[false, true, false, false]` for the winning nil-`kv_bits`/`max_batch=2` cell (`phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:132-171`).

**J.1 (MINOR) — CLOSED.** The fix-pass adds the five requested direct helper tests. `testIsNewBestAcceptsPositiveTPSWhenBestTPSIsZero` asserts positive new TPS wins when `bestTPS` is zero; `testIsNewBestRejectsZeroTPSWhenBestTPSIsZero` asserts zero and negative new TPS do not win; `testIsNewBestWinsTieBandWhenBestTTFTIsNil` asserts a measurable new TTFT wins inside the TPS tie band against nil incumbent TTFT; `testIsNewBestHoldsWhenBothTTFTsAreNilInTieBand` asserts both-unmeasurable TTFT keeps the incumbent; and `testIsNewBestHoldsWhenNewTTFTIsNilInTieBand` asserts nil new TTFT does not displace a measurable incumbent TTFT (`phase3-binary/Tests/macprovider-cliTests/Stage2HillClimbTests.swift:195-248`). These tests target the explicit branches in `Stage2HillClimb.isNewBest` at `bestTPS <= 0` and `abs(relGap) <= tpsTieEpsilon` (`phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift:196-225`).

### Round-2 new findings

#### Category Z-CLOSURE

(no findings)

Verification notes:
- D.1 is not cosmetic: the DB insertion path no longer writes transient `kept = true`, and the post-loop `UPDATE` uses `kv_bits IS NULL` for nil rather than `kv_bits = NULL`.
- J.1 is covered by five non-tautological tests that assert the named true/false outcomes against the static helper.

#### Category R-REGRESSION-V08F1

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 322 tests executed, 2 skipped, 0 failures.
- `Stage2HillClimbTests` executed 12 tests with 0 failures, including the 5 new direct `isNewBest` edge tests.
- The Step 3 `AutotuneDB` change is additive: commit 022e8a3 adds `markStage2WinnerCell` without changing existing `insertTrial`, `insertRun`, retention, schema, or bind helper signatures (`git diff --name-only 022e8a3^ 022e8a3` shows the expected Step 8 files plus the audit report).
- `phase3-binary/implementation-notes.html` has the Step 8 round-1 audit-response entry documenting the D.1/J.1 closures and the claimed 322-test anti-regression result (`phase3-binary/implementation-notes.html:1578-1634`).

#### Category N-NEWGAPS-V08F1

(no findings)

Verification notes:
- SQL injection surface is closed: typed values are bound with the existing `withStatement`/`bind` helpers; the only interpolated SQL is the constant `kv_bits IS NULL` vs `kv_bits = ?` clause.
- In-memory consistency is preserved by mutating `trialRows[bestRowIndex].kept = true` after the DB marker update.
- The no-feasible-cell edge does not call `markStage2WinnerCell`; the method call is below the `guard let best else { throw ... }` block.
- The method is idempotent by SQL semantics: matching the same row and setting `kept = 1` again does not create extra rows or additional kept states.

#### Category O-OTHER-V08F1

(no findings)

### Step 8 readiness verdict

READY TO PROCEED TO STEP 9.

---

## Round 16 audit (Codex on 292b2f9 — Step 9 round 1)

**Audited:** commit 292b2f9 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 9, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 0 MAJOR / 4 MINOR / 1 QUESTION
**Step 9 readiness:** READY TO PROCEED TO STEP 10

### Executive summary

Step 9's highest-risk JCS path is acceptable for the SPEC-013 hash domain. `RFC8785JCS` sorts object keys by UTF-16 code units, preserves array order, emits no whitespace, renders hash-domain integers directly as decimal `Int`, preserves JSON `null`, leaves `/` unescaped in model IDs, and feeds UTF-8 canonical bytes directly into `CryptoKit.SHA256` with lowercase hex. The required independent reference-vector check matched the baked test literal: `printf '%s' '<A.7 JSON>' | shasum -a 256` returned `eb5f8f90c09c2bbcec0dca6f42c203c25a7a8d403a734c6a81379b14ad702f9d`.

The custom `ConfigApplier` design also satisfies the intended v1 operator-config shape: it validates existing YAML with Yams, rewrites only top-level owned keys, omits `kv_bits` when the unquantized cell wins, writes temp files adjacent to the destination, and commits with POSIX `rename`. I found no AC-9/AC-11/AC-12 blocker. The remaining issues are non-blocking: one documented concurrent-backup race, two test-strength gaps around schema/config preservation, one narrow launchd-hint assertion gap, and one nil-recommendation hash-policy question for Step 10's DB persistence.

Verification passed. `swift test --package-path phase3-binary` executed 344 tests, skipped 2 integration-gated tests, and reported 0 failures. Step 9 stays standalone: commit 292b2f9 adds only the three new Step 9 source files, two new test files, and implementation notes; it does not wire `AutotuneCommand.run()`.

### Findings

#### Category A: RFC 8785 JCS encoder correctness

(no findings)

Verification notes:
- Object keys are sorted by `lhs.utf16.lexicographicallyPrecedes(rhs.utf16)` (`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift:16-18`, `:44-46`), matching RFC 8785's UTF-16 code-unit ordering requirement.
- The encoder builds objects and arrays with only `{}`, `[]`, `:`, and `,` separators and no spaces/newlines/tabs (`RFC8785JCS.swift:22-26`).
- Hash-domain numbers are `case int(Int)` and render through `String(int)`, so `4`, `4000`, and `131072` do not route through `Double` or scientific notation (`RFC8785JCS.swift:29-30`).
- `kv_bits == nil` becomes the literal JSON token `null` in the hash input (`RecommendationEmitter.swift:103-108`; `RecommendationEmitterTests.swift:188-216`).
- `/` is not escaped because `escapeString` only special-cases quote, backslash, named control escapes, remaining controls, and U+FFFD (`RFC8785JCS.swift:48-75`). The A.7 model IDs therefore hash as unescaped HF paths.
- Array order is preserved by mapping array elements in source order (`RFC8785JCS.swift:25-26`).
- The independent reference-vector command returned `eb5f8f90c09c2bbcec0dca6f42c203c25a7a8d403a734c6a81379b14ad702f9d`, matching the literal `sha256:eb5f8f90c09c2bbcec0dca6f42c203c25a7a8d403a734c6a81379b14ad702f9d` asserted in `testRecipeHashMatchesReferenceVector` (`RecommendationEmitterTests.swift:134-142`). This is not tautological with the Swift encoder.

#### Category B: recipe_hash domain isolation

**B.1 (QUESTION) — nil-recommendation `recipe_hash` policy needs an explicit Step 10 decision before DB persistence.**
- **Location:** `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift:95-121`, `:261-277`; `specs/SPEC-013-cli-autotune.md:1124-1131`.
- **What:** When `recommendation == nil`, Step 9 still emits a non-empty recipe hash by hashing a degenerate JCS object with `"model": null` and `"knobs": null`. The JSON schema section requires a `recipe_hash` field, but the DB schema comment says `recipe_hash TEXT -- NULL if no recommendation`.
- **Why:** This does not break Step 9's standalone JSON surface, and the Step 9 prompt calls this branch ambiguous. Step 10, however, will persist `tune_runs.recipe_hash`; persisting the degenerate hash would disagree with the DB comment, while forcing NULL would make `EmittedRecommendation.recipeHash` too eager for the no-recommendation branch.
- **Recommendation:** In Step 10, choose and test the persistence contract explicitly. If DB rows should store NULL on no recommendation, keep the JSON field as Step 9 emits it only if the spec owner accepts that JSON/DB divergence; otherwise make the emitted recipe hash optional or encode `null` in JSON too.

Verification notes:
- The hash input includes exactly `binary_version`, `candidate_models`, `chip`, `knobs`, `model`, `ram_gb`, and `target_context` (`RecommendationEmitter.swift:100-121`).
- Excluded observation/run fields are not referenced by `recipeHashInput`: `run_id`, timestamps, `os_version`, replicate/gate/tie parameters, measured TPS/TTFT, alternates, infeasible, `db_path`, and `serve_command` stay out of the hash domain.
- `testRecipeHashIgnoresObservationFields` varies `runID`, `startedAt`, `endedAt`, `tpsMedian`, `ttftP95MS`, and `replicates` and asserts identical hashes (`RecommendationEmitterTests.swift:145-164`).
- RAM and binary-version sensitivity are covered by `testRecipeHashSensitiveToMachineRAM` and `testRecipeHashSensitiveToBinaryVersion` (`RecommendationEmitterTests.swift:166-186`).

#### Category C: SHA-256 + format wrapping

(no findings)

Verification notes:
- `RFC8785JCS.sha256Hex` hashes `Data(canonical.utf8)`, not a hex string or UTF-16 representation (`RFC8785JCS.swift:38-41`).
- Hex output uses `%02x`, and `RecommendationEmitter.recipeHash` adds the literal lowercase `sha256:` prefix (`RFC8785JCS.swift:41`; `RecommendationEmitter.swift:95-98`).
- `testJSONOutputRecipeHashFormat` asserts `^sha256:[0-9a-f]{64}$` and lowercasing (`RecommendationEmitterTests.swift:127-132`).

#### Category D: Terminal block (FR-F.1)

(no findings)

Verification notes:
- The emitted block includes model, target context, YAML-key knob names, measured median TPS/p95 TTFT/replicate count, alternates, serve command, run ID, and DB path (`RecommendationEmitter.swift:149-177`; `RecommendationEmitterTests.swift:6-23`).
- Step 9 returns strings and does not print to stderr/stdout; Step 10 owns destinations (`RecommendationEmitter.swift:57-85`).
- Nil `kv_bits` renders as `unset` and omits `--kv-bits` from both returned serve command and terminal block (`RecommendationEmitter.swift:154`, `:196-219`; `RecommendationEmitterTests.swift:25-41`).
- The nil-recommendation branch emits a clear `NO RECOMMENDATION` block, lists infeasibles in input order, and omits the serve command (`RecommendationEmitter.swift:129-146`; `RecommendationEmitterTests.swift:43-58`).

#### Category E: --json schema (FR-F.2)

**E.1 (MINOR) — JSON schema regression test spot-checks nested objects instead of asserting the full documented field/type set.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/RecommendationEmitterTests.swift:92-115`; implementation at `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift:241-402`.
- **What:** `testJSONOutputMatchesSpec013Schema` verifies top-level fields and the recommendation knob names, but only asserts that `machine`, `inputs`, `alternates`, `infeasible`, and `recipe_hash` are non-nil. It does not assert every documented nested key and type for `machine`, `inputs`, `infeasible[]`, recommendation measurements, or ISO timestamp shape.
- **Why:** Manual inspection shows the implementation currently encodes the required fields, so this is not a Step 9 schema bug. The test is weaker than AC-11's stated "every documented field is present with the documented type" regression bar and could miss a future nested-field removal.
- **Recommendation:** Expand the test to walk the decoded JSON and assert exact required keys plus primitive types for `machine`, `inputs`, `recommendation`, `recommendation.knobs`, `infeasible[]`, and the top-level timestamp strings.

Verification notes:
- The implementation encodes `spec_version`, `run_id`, `started_at`, `ended_at`, `machine`, `inputs`, nullable `recommendation`, `alternates`, `infeasible`, `recipe_hash`, and `db_path` (`RecommendationEmitter.swift:247-278`).
- JSON knob names are the YAML keys `kv_bits`, `max_concurrency_override`, and `max_context_override`, and nil `kv_bits` uses JSON `null` (`RecommendationEmitter.swift:374-389`).
- Alternates are the slice after the chosen model, empty when the chosen model is last, and empty when the chosen model is not found (`RecommendationEmitter.swift:180-194`; `RecommendationEmitterTests.swift:60-90`). The not-found behavior is intentionally undefined by the spec and harmless for Step 9.

#### Category F: kv_bits nil propagation (cross-cutting)

(no findings)

Verification notes:
- Terminal display uses `kv_bits: unset` (`RecommendationEmitter.swift:154`).
- Serve command construction omits `--kv-bits` when nil (`RecommendationEmitter.swift:196-219`).
- JSON output encodes `"kv_bits": null` (`RecommendationEmitter.swift:380-386`).
- JCS hash input encodes `"kv_bits":null` (`RecommendationEmitter.swift:103-108`; `RecommendationEmitterTests.swift:209-216`).
- Config apply omits the YAML `kv_bits:` line when nil (`ConfigApplier.swift:119-124`, `:143-155`, `:167-176`; `ConfigApplierTests.swift:73-89`).
- Apply summary uses `kv_bits=unset` (`ConfigApplier.swift:198-200`).

#### Category G: ConfigApplier backup counter (FR-F.3)

**G.1 (MINOR) — backup path selection has a TOCTOU overwrite window under concurrent applies.**
- **Location:** `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift:84-104`.
- **What:** `firstAvailableBackupPath` uses `fileExists` to select the first free `config.yaml.bak-<unix-ts>-<counter>`, then `atomicWrite` writes a temp file and calls POSIX `rename` to the selected destination. If another autotune process creates the same backup path between the existence check and `rename`, `rename` will replace that destination.
- **Why:** The single-process counter behavior is correct and tested, but FR-F.3 says backup writes must never overwrite existing files. The Step 9 audit prompt classifies this specific stat-then-create race as MINOR for v1, but it is still a real concurrent-apply limitation.
- **Recommendation:** Use an exclusive destination creation strategy for backups, such as `open(O_CREAT | O_EXCL)` followed by writing the backup bytes, or a macOS exclusive rename primitive where available, and retry the next counter on `EEXIST`.

Verification notes:
- Counter 0 and collision increment are tested (`ConfigApplierTests.swift:6-26`).
- Exhaustion is testable through `maxBackupCounter` and covered with counters 0...1 (`ConfigApplierTests.swift:28-42`).
- The implementation tries counters from 0 through 65,535 by default and throws `backupCollisionsExhausted` if all are occupied (`ConfigApplier.swift:30-37`, `:84-99`).

#### Category H: ConfigApplier atomic write (FR-F.3)

(no findings)

Verification notes:
- Temp files are constructed in the same directory as the destination (`ConfigApplier.swift:101-104`, `:203-206`).
- The final commit uses POSIX `rename`, not `FileManager.replaceItem` (`ConfigApplier.swift:101-112`).
- The atomic-write test spies temp names for both backup and config writes and asserts temp files are gone after successful renames (`ConfigApplierTests.swift:110-132`).

#### Category I: ConfigApplier non-owned key preservation (FR-F.3, AC-9)

**I.1 (MINOR) — AC-9 preservation tests do not prove byte-identical non-owned coverage or parser round-trip.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/ConfigApplierTests.swift:44-71`; `phase3-binary/Sources/MacProviderCore/Config.swift:239-241`.
- **What:** `testApplyPreservesNonOwnedKeysVerbatim` uses three `contains` assertions for selected non-owned snippets, and `testApplyMutatesOnlyFourOwnedKeys` compares a simple dictionary of keyed lines. There is no test that extracts every non-owned pre/post byte span and proves byte identity, and no test that the binary's `Config.swift` parser reads the post-apply owned values.
- **Why:** Manual implementation inspection is favorable: non-owned raw lines are appended unchanged, top-level owned keys are the only recognized rewrite targets, and nil `kv_bits` is omitted. Still, AC-9 explicitly calls for byte-identical non-owned keys and a parser round-trip; the shipped tests can miss ordering/comment drift outside the three snippets and can miss a future parser-key mismatch.
- **Recommendation:** Add a fixture with comments before/after non-owned keys, blank lines, and ordering sentinels; compare all non-owned lines byte-for-byte pre/post. Then parse the post-apply file through `Config.swift`'s loader and assert `model`, `kv_bits`, `max_context_override`, and `max_concurrency_override` resolve to the recommendation values.

Verification notes:
- The rewrite algorithm validates YAML with Yams, scans raw text line by line, rewrites only non-indented exact owned top-level keys, appends non-owned `rawLine` unchanged, inserts missing owned non-nil keys, and omits nil `kv_bits` (`ConfigApplier.swift:73-82`, `:115-185`).
- Existing tests cover selected non-owned snippets, the four changed owned keys, nil `kv_bits` omission, and idempotence (`ConfigApplierTests.swift:44-108`).
- Duplicate owned keys remain undefined; the last YAML value would normally win in a parser, while the rewriter sees each owned line. This is a SPEC-silent edge and not a Step 9 blocker for normal generated config.

#### Category J: Idempotency (FR-F.3, AC-9)

(no findings)

Verification notes:
- `testApplyIsIdempotent` compares the full post-apply config after two identical applies and excludes only the expected backup-path/counter difference (`ConfigApplierTests.swift:91-108`).
- The second backup contains the first post-apply config, and the first backup remains the original config (`ConfigApplierTests.swift:105-107`).

#### Category K: launchd restart hint (FR-F.3)

**K.1 (MINOR) — launchd hint test does not assert all required substrings.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/ConfigApplierTests.swift:134-139`; implementation at `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift:87-92`.
- **What:** `testLaunchdRestartHintIncludesBootoutAndBootstrap` asserts only `launchctl bootout` and `launchctl bootstrap`. The implementation currently also includes `~/Library/LaunchAgents/live.streamvc.macprovider.plist` and `live.streamvc.macprovider`, but the test would not catch a future regression that drops either path/service token.
- **Why:** FR-F.3 requires the hint to contain both commands, the plist path, and the service identifier. Step 10 will decide stderr routing, so Step 9 only needs the helper content to be locked.
- **Recommendation:** Extend the test to assert `~/Library/LaunchAgents/live.streamvc.macprovider.plist` and `live.streamvc.macprovider` in addition to bootout/bootstrap.

Verification notes:
- Step 9 only returns the hint string; it does not print, so stdout/stderr routing remains correctly deferred to Step 10 (`RecommendationEmitter.swift:87-92`).

#### Category L: Anti-regression on Steps 1-8

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 344 tests executed, 2 skipped, 0 failures.
- `git diff --name-status 292b2f9^ 292b2f9` shows exactly the Step 9 surface: three added source files, two added test files, and implementation-notes changes.
- `AutotuneCommand.run()`, Stage1Iterator, Stage2HillClimb, AutotuneDB, ProviderPreWarmer, and CandidateProviderRunner are not modified by commit 292b2f9.

#### Category M: Forward-compatibility (Step 10)

(no findings beyond B.1)

Verification notes:
- `RecommendationEmitter.build(_:)` is a pure value-returning seam that exposes terminal text, JSON, recipe hash, alternates, and serve command for Step 10 (`RecommendationEmitter.swift:57-85`; `EmittedRecommendation` at `:42-48`).
- `ConfigApplier.apply` is standalone and can be called by Step 10 only under `--apply` (`ConfigApplier.swift:40-65`).
- `EmittedRecommendation.recipeHash` is accessible for future `tune_runs.recipe_hash` persistence (`RecommendationEmitter.swift:42-48`, `:78-84`).
- With nil recommendation, `build(_:)` still returns terminal text and JSON with `"recommendation": null` (`RecommendationEmitter.swift:129-146`, `:269-273`; `RecommendationEmitterTests.swift:117-125`). Step 10 must not call `ConfigApplier.apply` in that branch.

#### Category N: Anything else

(no findings)

Verification notes:
- `phase3-binary/implementation-notes.html` documents Step 9's dormant scope, the JCS choices, the reference-vector hash, Yams validation plus custom top-level rewrite, backup/temp+rename behavior, and the 22 Step 9 tests (`phase3-binary/implementation-notes.html:1637-1683`).
- Naming is consistent with the Step 9 surface: `RecommendationEmitter`, `RFC8785JCS`, `ConfigApplier`, and `EmittedRecommendation`.
- The commit's two `Rejected:` decisions are reflected in implementation notes: JSONEncoder-only hashing is replaced by RFC8785 JCS, and Yams emission is rejected in favor of validation plus constrained raw-text rewriting.

### Step 9 readiness verdict

READY TO PROCEED TO STEP 10.

---

## Round 17 audit (Codex on d6c634c — Step 9 round 2 closure verification)

**Audited:** commit d6c634c on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 9, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 5 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 5 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 9 readiness:** READY TO PROCEED TO STEP 10

### Executive summary

Commit d6c634c closes all five Round 16 findings. The nil-recommendation hash policy is now explicit and internally consistent: `EmittedRecommendation.recipeHash` is optional, `RecommendationEmitter.recipeHash(_:)` returns nil before building the JCS hash when no recommendation exists, and `JSONRoot.encode(to:)` emits literal JSON null via `encodeNil(forKey: .recipeHash)`, not the string `"null"`. Existing recipe-hash tests remain on non-nil recommendation inputs and still cover the reference vector plus observation-field exclusion and sensitivity properties.

The new exclusive backup path is acceptable for Step 9. `writeBackupExclusively` preserves the prior `<config>.bak-<unix-ts>-<counter>` naming scheme while replacing stat-then-rename with `open(O_CREAT | O_EXCL | O_WRONLY, 0o644)`, retries on `EEXIST`, reports non-`EEXIST` open/write failures through `backupWriteFailed`, and writes through a manual loop that handles `EINTR` and partial writes. The `n == 0` case has no explicit break, but this fd is a regular file opened for blocking writes; for a positive remaining count, a repeated zero-byte write would be pathological rather than a practical v1 risk. I do not consider it a new Step 9 finding.

Verification passed. `swift test --package-path phase3-binary` executed 348 tests, skipped 2 integration-gated tests, and reported 0 failures.

### Round-1 finding closures

**B.1 (QUESTION) — CLOSED.** `EmittedRecommendation.recipeHash` is now `String?` (`RecommendationEmitter.swift:42-48`), and `RecommendationEmitter.recipeHash(_:)` returns nil before computing the hash when `inputs.recommendation == nil` (`RecommendationEmitter.swift:95-100`). `JSONRoot.recipeHash` is also optional, and the encoder's else branch calls `encodeNil(forKey: .recipeHash)` (`RecommendationEmitter.swift:244-284`), which produces literal `null` in the emitted JSON field. `testRecipeHashIsNilWhenRecommendationIsNil` asserts both `XCTAssertNil(emitted.recipeHash)` and `root["recipe_hash"] is NSNull` (`RecommendationEmitterTests.swift:164-173`). Existing hash properties still exercise non-nil recommendations: `testRecipeHashMatchesReferenceVector` compares the baked `sha256:` value, and the observation/sensitivity tests compare optional values produced from recommendation-bearing inputs (`RecommendationEmitterTests.swift:194-245`).

**E.1 (MINOR) — CLOSED.** `testJSONOutputMatchesSpec013Schema` now asserts primitive values/types for documented nested fields, exact key sets for `machine`, `inputs`, `recommendation`, `recommendation.knobs`, and `infeasible[0]`, ISO-8601 shape for both timestamps, and documented alternates/infeasible ordering/content (`RecommendationEmitterTests.swift:92-162`). This closes the prior nested-schema spot-check gap and intentionally catches undocumented additive fields through `Set(keys)` assertions.

**G.1 (MINOR) — CLOSED.** `writeBackupExclusively` constructs the same `config.yaml.bak-<unix-ts>-<counter>` candidate path, opens it with `O_CREAT | O_EXCL | O_WRONLY` and `0o644`, returns on successful write, retries only on `EEXIST`, and throws `ConfigApplierError.backupWriteFailed(destination:, errno:)` for other open/write failures (`ConfigApplier.swift:86-131`). `writeAll` uses `base.advanced(by: written)` and `data.count - written`, retries `EINTR`, and advances `written += n` for partial writes. `testApplyBackupUsesExclusiveCreateAgainstTOCTOURace` pre-creates counters 0 through 3, verifies the new backup lands at counter 4, and asserts all pre-existing backup contents remain unchanged (`ConfigApplierTests.swift:134-154`). The adjusted atomic-write test correctly expects one temp path because only the config write still uses temp+rename (`ConfigApplierTests.swift:111-132`).

**I.1 (MINOR) — CLOSED.** `ConfigApplierTests` now imports `MacProviderCore` (`ConfigApplierTests.swift:1-4`). `testApplyPreservesNonOwnedLinesByteIdentically` uses comments, blank lines, an inline comment, and a SPEC-013 marker, then compares filtered non-owned line arrays pre/post (`ConfigApplierTests.swift:156-185`). The helper removes only non-indented top-level owned lines for `model`, `kv_bits`, `max_context_override`, and `max_concurrency_override`; indented same-name lines remain in the preserved non-owned set (`ConfigApplierTests.swift:248-262`). `testApplyResultIsParseableByConfigLoader` loads the post-apply file through `ConfigLoader.load(cli:environment:)` and asserts the four runtime config values resolve to the recommendation values (`ConfigApplierTests.swift:187-199`).

**K.1 (MINOR) — CLOSED.** The renamed `testLaunchdRestartHintIncludesAllRequiredSubstrings` asserts `launchctl bootout`, `launchctl bootstrap`, `~/Library/LaunchAgents/live.streamvc.macprovider.plist`, and `gui/$UID/live.streamvc.macprovider` (`ConfigApplierTests.swift:202-209`). The implementation still contains those substrings in the returned hint (`RecommendationEmitter.swift:87-92`).

### Round-2 new findings

No new findings in Category Z-CLOSURE, R-REGRESSION-V09F1, N-NEWGAPS-V09F1, or O-OTHER-V09F1.

Notes:
- `writeAll` has correct pointer arithmetic for partial writes and `EINTR` retry. It does not special-case `n == 0`, but for this blocking regular-file backup fd the loop is acceptable as-is for v1.
- Optional recipe hash encoding uses `encodeNil`, so nil emits JSON null. The load-bearing Step 10 seam is the returned `EmittedRecommendation.recipeHash`; there is no static cache or alternate state path in Step 9.
- Concurrent backup attempts on the same timestamp/counter now resolve through `O_EXCL`: one process creates the counter path and another observes `EEXIST` and retries the next counter.
- The non-owned-line helper would preserve indented owned-key-named lines rather than filter them. That is appropriate for this top-level-only rewriter and not a real concern for SPEC-013's operator config shape.
- `phase3-binary/implementation-notes.html` includes the Round 1 audit-response entry documenting all five closures and the 348/2/0 anti-regression result (`implementation-notes.html:1684-1756`).

### Step 9 readiness verdict

READY TO PROCEED TO STEP 10.

---

## Round 18 audit (Codex on 79d48ca — Step 10 round 1)

**Audited:** commit 79d48ca on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 10, round 1 of N
**Date:** 2026-06-18
**Total findings:** 1 CRITICAL / 2 MAJOR / 1 MINOR / 0 QUESTION
**Step 10 readiness:** FIX REQUIRED

### Executive summary

Step 10's core row lifecycle is mostly in place. `AutotuneCommand.run()` inserts a provisional `tune_runs` row with `exit_reason = 'internal_error'` and `ended_at_utc = NULL`, then updates the same row on the normal, interrupted, no-feasible, budget-exhausted, pre-warm integrity, provider-conflict, and unexpected-error branches. The DispatchSource signal callbacks are flag-only, the raw `exit_reason` values match SPEC-013, Stage 2 partial budget exhaustion persists JSON plus recipe hash, and the full Swift suite passed with the expected 363 executed tests and 2 skipped integration-gated tests.

The blocker is the LOCKED Step 7 file check. `Stage1Iterator.swift` is not additive-only: Step 10 changes the nil `candidatesBySize` fallback from `Array(candidates.reversed())` to `candidates`, and updates an existing Stage1Iterator test to pass an explicit `candidatesBySize` value. That violates the stated Step 10 constraint that locked Stage 1 changes are limited to new defaulted init parameters and boundary poll points.

I also found two lifecycle gaps that should be fixed before Step 11 acceptance testing: cancellation is not re-polled after Stage 2 before recommendation emission / `--apply` / final `.ok`, and thrown `ProviderDrainer.drain(...)` failures are finalized as `internal_error` instead of the requested `provider_conflict`. The remaining issue is a resilience bug in `MachineFingerprinter.ramGB()`: sysctl failure returns `0`, not the documented minimum of `1`.

### Findings

#### Category A: Signal handler async-signal-safety

(no findings)

Verification notes:
- `AutotuneSignalSources.init(flag:)` creates SIGINT and SIGTERM `DispatchSourceSignal`s, and each `setEventHandler` body only calls `flag.set()` (`phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift:31-41`).
- The handlers do not print, write files, touch SQLite, allocate dates, or log.
- `signal(SIGINT, SIG_IGN)` and `signal(SIGTERM, SIG_IGN)` are installed after the event handlers are wired and before `resume()` (`AutotuneRuntimeSupport.swift:36-47`).
- `deinit` cancels both DispatchSourceSignal objects (`AutotuneRuntimeSupport.swift:50-53`).
- Synthetic interrupt coverage exists: `testInterruptionFlagCancelsLoopAtNextPoll` pre-sets the flag and asserts exit 130 before Stage 1, and `testInterruptedSetsTuneRunExitReason` asserts `exit_reason == "interrupted"` plus `endedAtUTC == nil` (`AutotuneCommandRunTests.swift:136-158`).

#### Category B: Cooperative interruption polling

**B.1 (MAJOR) - interruption can be ignored after Stage 2 and before `--apply` / final `.ok`.**
- **Location:** `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:381-416`.
- **What:** After `Stage2HillClimb.run(...)` returns, `run()` immediately builds/emits the recommendation, optionally calls `applyConfig(...)`, and finalizes `exitReason: .ok` without another `cancellationReason()` poll. A SIGINT/SIGTERM that arrives in this interval can still apply config and persist `ok`.
- **Why:** The prompt explicitly requires polling between major substeps, including before `--apply`. This is a known-classifiable interrupted exit, so finalizing it as `ok` is a lifecycle contract gap.
- **Recommendation:** Poll after Stage 2 returns and again immediately before `applyConfig(...)`; on `.interrupted`, update the run with `endedAtUTC: nil`, `exitReason: .interrupted`, no apply, and exit 130. Add a unit test that flips the injected flag after Stage 2 and before apply.

Verification notes:
- The shared `cancellationReason` closure distinguishes `.interrupted` from `.budgetExhausted` (`AutotuneCommand.swift:144-152`).
- Stage 1 polls at candidate boundaries and maps `.interrupted` to exit 130 / `endedAtUTC: nil` (`Stage1Iterator.swift:195-203`; `AutotuneCommand.swift:263-280`).
- Stage 2 polls at cell boundaries and maps `.interrupted` to exit 130 / `endedAtUTC: nil` (`Stage2HillClimb.swift:117-129`; `AutotuneCommand.swift:337-363`).

#### Category C: Wall-clock budget enforcement (FR-H.4 / AC-13)

(no findings)

Verification notes:
- `startedAt` is sampled before DB open and before machine fingerprinting, and `deadline = startedAt.addingTimeInterval(TimeInterval(maxDuration))` (`AutotuneCommand.swift:128-130`).
- The deadline check uses injected `dependencies.now() > deadline` (`AutotuneCommand.swift:144-152`).
- Pre-Stage-1 and mid-Stage-1 budget exhaustion emit a no-recommendation JSON surface and persist `budget_exhausted_no_model_selected` with nil recommendation/hash (`AutotuneCommand.swift:214-227`, `:267-280`).
- Mid-Stage-2 budget exhaustion after a feasible best calls `finalizePartial`, emits `partial: true`, persists JSON plus recipe hash, and exits non-zero (`Stage2HillClimb.swift:123-127`; `AutotuneCommand.swift:342-363`).
- If the Stage 2 budget trips before any feasible cell, Step 10 maps it to `no_feasible` through `Stage2HillClimbError.noFeasibleCell(reason: "budget exhausted before any Stage 2 cell completed")` (`Stage2HillClimb.swift:123-127`; `AutotuneCommand.swift:364-377`).

#### Category D: tune_runs row lifecycle (FR-G.2)

(no findings beyond B.1 and J.1)

Verification notes:
- The provisional insert uses `endedAtUTC: nil`, nil recommendation/hash, `applied: false`, and `exitReason: AutotuneExitReason.internalError.rawValue` (`AutotuneCommand.swift:180-200`).
- `AutotuneDB.updateRun(...)` is a real `UPDATE tune_runs SET ... WHERE run_id = ?`, not delete+insert (`AutotuneDB.swift:188-211`).
- Known Stage 1/2 classified exits call `updateRun(...)` with the expected enum values; unexpected thrown errors after the provisional insert are updated to `.internalError` (`AutotuneCommand.swift:210-420`).
- `interrupted` paths use `endedAt: nil`; non-interrupted classified paths use `dependencies.now()` for `endedAt` (`AutotuneCommand.swift:210-227`, `:263-377`, `:410-420`).
- `config_error` exists in the enum but Step 10 does not emit a row for parse-time or DB-open errors, which is consistent with the prompt's note that this value may be reserved/unreachable in v1 setup paths.

#### Category E: tune_runs.applied semantics

(no findings)

Verification notes:
- `applied` starts false and flips true only after `dependencies.applyConfig(...)` returns successfully (`AutotuneCommand.swift:139-141`, `:396-407`).
- Apply failure writes an error to stderr, leaves `applied = false`, and still finalizes `exitReason: .ok` because the recommendation remains valid (`AutotuneCommand.swift:404-416`).
- Tests cover successful apply invocation, `applied = 1`, and failed apply leaving `exitReason == "ok"` plus `applied == 0` (`AutotuneCommandRunTests.swift:160-190`).

#### Category F: exit_reason enum coverage

(no findings beyond J.1)

Verification notes:
- `AutotuneExitReason` contains the nine normative values with correct raw strings: `ok`, `interrupted`, `no_feasible`, `budget_exhausted_no_model_selected`, `budget_exhausted_with_partial_recommendation`, `pre_warm_integrity_failure`, `provider_conflict`, `config_error`, and `internal_error` (`AutotuneDB.swift:23-34`).
- `insertRun` validates raw exit reasons before binding (`AutotuneDB.swift:35-39`, `:148-176`).

#### Category G: candidatesBySize derivation (FR-H.4)

(no findings in `AutotuneCommand`; see M.1 for the LOCKED Stage 1 edit)

Verification notes:
- Default-list runs return `defaultCandidates` filtered to the plan and sorted ascending by `sizeB` (`AutotuneCommand.swift:457-466`).
- Operator override runs return nil (`AutotuneCommand.swift:457-461`).
- Tests cover sorted default order and nil under `--candidate-models` (`AutotuneCommandRunTests.swift:107-134`).

#### Category H: FR-H.4 size-ordered terminal output

(no findings)

Verification notes:
- The all-infeasible branch zips Stage 1's surfaced trial reasons with `Self.candidatesBySize(for: plan) ?? plan.candidates` and prints the first entry as `(<smallest>)` (`AutotuneCommand.swift:281-299`, `:520-528`).
- `testTerminalOutputForAllInfeasibleLeadsWithSmallestSize` asserts the 1B line precedes the 3B line and that the smallest label is printed (`AutotuneCommandRunTests.swift:202-224`).

#### Category I: --apply integration with ConfigApplier

(no findings)

Verification notes:
- Production dependencies expand the optional `--config` path or fall back to `AppConfig.defaultConfigPath`, then construct `ConfigApplier(configPath:)` with that URL (`AutotuneCommand.swift:838-845`).
- On success, `result.summary` is written to stdout; if `--apply` and not `--drain`, the launchd restart hint is written to stderr (`AutotuneCommand.swift:396-403`).
- On apply failure, the error goes to stderr, `applied` remains false, and finalization continues (`AutotuneCommand.swift:404-416`).

#### Category J: --drain integration with ProviderDrainer

**J.1 (MAJOR) - thrown drain failures finalize as `internal_error` instead of `provider_conflict`.**
- **Location:** `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:230-245`, `:417-420`; `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift:212-224`.
- **What:** The conflict+`--drain` branch handles a returned `.portStillOpen` as `provider_conflict`, but if `ProviderDrainer.drain(...)` throws - for example launchctl bootout failure or foreground SIGTERM failure - the error bypasses the conflict branch and lands in the generic catch, which updates the run to `internal_error`.
- **Why:** The audit prompt requires drain failure to stay classified as `provider_conflict`; it is still a conflict scenario and is known/classifiable.
- **Recommendation:** Wrap `drainConflict(...)` in `do/catch` inside the conflict branch, update the run with `exitReason: .providerConflict`, print a conflict/drain failure message to stderr, and exit non-zero. Add a test that injects a throwing `drainConflict` closure and asserts `provider_conflict`.

Verification notes:
- Successful drain continues to Stage 1 and is tested by `testDrainFlagInvokesProviderDrainerOnConflict` (`AutotuneCommandRunTests.swift:193-200`).
- `.portStillOpen` is handled as `provider_conflict` (`AutotuneCommand.swift:238-243`).

#### Category K: MachineFingerprinter (resilience)

**K.1 (MINOR) - RAM sysctl fallback returns `0` instead of the documented minimum `1`.**
- **Location:** `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift:56-73`.
- **What:** `ramGB()` returns `0` when `sysctlbyname("hw.memsize", ...)` fails or returns zero. The `max(1, ...)` clamp only applies to successful nonzero sysctl results.
- **Why:** This keeps `machine_ram_gb` non-null but can persist an impossible RAM tier and poison `recipe_hash` machine sensitivity for fallback runs. The prompt expected failure fallback to produce at least `1`.
- **Recommendation:** Return `1` on sysctl failure/zero, or make the sysctl reader injectable and test both success and failure paths.

Verification notes:
- Chip fallback is `"unknown"` and OS version uses `ProcessInfo.processInfo.operatingSystemVersionString` (`AutotuneRuntimeSupport.swift:57-63`).
- Binary version uses `CoordinatorClient.binaryVersion` (`AutotuneRuntimeSupport.swift:57-63`).
- I found no tests covering `MachineFingerprinter` fallback paths.

#### Category L: partial: Bool additive field

(no findings)

Verification notes:
- `RecommendationCore.partial` defaults to `false` (`RecommendationEmitter.swift:27-35`).
- The terminal warning is inserted only when `partial == true` (`RecommendationEmitter.swift:149-170`).
- JSON omits `partial` when false and encodes it only when true (`RecommendationEmitter.swift:359-378`).
- `recipeHashInput(_:)` does not include `partial`, so measurement quality stays out of the recipe identity (`RecommendationEmitter.swift:104-125`).
- `implementation-notes.html` documents `"partial": true` as a SPEC-013 v0.4 candidate addition (`phase3-binary/implementation-notes.html:113-121`).

#### Category M: LOCKED file additive-only check (Stage1Iterator + Stage2HillClimb)

**M.1 (CRITICAL) - Stage1Iterator locked-file diff is not additive-only.**
- **Location:** `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:166-178`; `phase3-binary/Tests/macprovider-cliTests/Stage1IteratorTests.swift:112-123`; diff command `git diff a9da9e5 -- phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`.
- **What:** Step 10 changes the existing nil fallback from `self.candidatesBySize = candidatesBySize ?? Array(candidates.reversed())` to `self.candidatesBySize = candidatesBySize ?? candidates`. It also edits the existing all-infeasible Stage 1 test to pass `candidatesBySize: ["1b", "14b", "32b"]` instead of leaving the old nil-default behavior under test.
- **Why:** The prompt's locked-file rule allows new defaulted init parameters and new boundary poll points only. Changing existing nil fallback semantics is a non-additive behavioral change in a Step 7 LOCKED file, and modifying an existing test to accept the new behavior violates the "only adds new cancellation tests" anti-regression check.
- **Recommendation:** Restore the locked nil fallback behavior and keep Step 10's default-list behavior in `AutotuneCommand` by always passing explicit `candidatesBySize` for default-list runs. If operator override needs input-order error surfaces, add that through the caller's explicit argument or a new additive API path without changing the locked nil default. Restore the pre-existing Stage1Iterator test expectation and add separate new tests for Step 10 behavior.

Verification notes:
- The same `git diff a9da9e5 -- Stage1Iterator.swift` also shows additive enum cases, a defaulted `cancellationReason` init parameter, and a candidate-boundary poll; those parts are consistent with Step 10.
- The required `git diff 022e8a3 -- phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift` check is additive for the requested surface: it adds Equatable conformance, new error cases, a defaulted `cancellationReason`, a cell-boundary poll, and `finalizePartial`; it does not remove or rename the locked run API.

#### Category N: Anti-regression on Steps 1-9

(no findings beyond M.1)

Verification notes:
- `swift test --package-path phase3-binary` passed: 363 tests executed, 2 skipped, 0 failures.
- Step 10 modified only one pre-existing test file under `phase3-binary/Tests/macprovider-cliTests`: `Stage1IteratorTests.swift`. That modification is not purely additive because it changes an existing all-infeasible test's setup (`git diff --name-status 79d48ca^ 79d48ca -- phase3-binary/Tests/macprovider-cliTests`).
- `git diff --check 79d48ca^ 79d48ca` reported no whitespace errors.

#### Category O: Forward-compatibility (Step 11)

(no findings)

Verification notes:
- `AutotuneRunDependencies` exposes injectable seams for time, run ID, interrupt flag, signal-source install, machine fingerprinting, DB creation, conflict detection/drain/restore, Stage 1, Stage 2, recommendation emission, config apply, and stdout/stderr (`AutotuneCommand.swift:772-789`).
- The new `AutotuneCommandRunTests` use those seams to exercise lifecycle paths without real providers (`AutotuneCommandRunTests.swift:249-324`).
- `tune_runs.recipe_hash` is populated from `EmittedRecommendation.recipeHash` on normal and partial recommendation paths (`AutotuneCommand.swift:342-363`, `:392-416`).

#### Category P: Anything else

(no findings)

Verification notes:
- `phase3-binary/implementation-notes.html` documents the Step 10 signal pattern, provisional row tripwire, budget/partial behavior, candidatesBySize derivation, apply semantics, and report-only v2 decision (`implementation-notes.html:90-139`).
- The commit message records the intended UPDATE finalization decision and the test commands.

### Step 10 readiness verdict

FIX REQUIRED.

---

## Round 19 audit (Codex on fdb07ff — Step 10 round 2 closure verification)

**Audited:** commit fdb07ff on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 10, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 4 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 4 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 10 readiness:** READY TO PROCEED TO STEP 11

### Executive summary

Commit fdb07ff closes all four Round 18 findings. The highest-risk M.1 LOCKED-file check is clean: `git diff a9da9e5 fdb07ff -- phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift` restores the nil fallback to `candidatesBySize ?? Array(candidates.reversed())`, and the remaining diff is additive-only for the Step 10 surface: new interruption/budget error cases, a defaulted cancellation callback, and a candidate-boundary poll. The Step 7 all-infeasible test again relies on nil `candidatesBySize` rather than passing it explicitly.

The B.1, J.1, and K.1 closures also match the requested behavior. The new cancellation gates are after the Stage 2 `do/catch` and before `applyConfig`, the drain failure catch is scoped to `drainConflict(...)` inside the conflict branch and finalizes as `provider_conflict`, and `MachineFingerprinter.ramGB()` now returns `1` on sysctl failure while preserving the success-path `max(1, ...)` clamp. I found no new precision gap in the fix-pass. `swift test --package-path phase3-binary` passed with 366 executed tests, 2 skipped, and 0 failures.

### Round-1 finding closures

**M.1 (CRITICAL) — CLOSED.** The LOCKED `Stage1Iterator` nil fallback is restored at `Stage1Iterator.swift:185` to `candidatesBySize ?? Array(candidates.reversed())`. The diff from the Step 7 lock point (`git diff a9da9e5 fdb07ff -- .../Stage1Iterator.swift`) contains only additive Step 10 changes: `.interrupted`, `.budgetExhaustedNoModelSelected`, equality/description support, a defaulted `cancellationReason` init parameter, and the candidate-boundary poll. The Step 7 all-infeasible test at `Stage1IteratorTests.swift:112-122` no longer passes `candidatesBySize` explicitly. `AutotuneCommand.candidatesBySize(for:)` now returns non-nil for both plan sources: default plans sort selected defaults by ascending `sizeB`, and explicit plans return `plan.candidates` in input order (`AutotuneCommand.swift:491-508`). The renamed test `testCandidatesBySizeReturnsInputOrderForOperatorOverride` asserts `["a", "b"]`.

**B.1 (MAJOR) — CLOSED.** `AutotuneCommand.run()` now polls `cancellationReason() == .interrupted` immediately after `dependencies.runStage2(...)` returns and after the Stage 2 error catch (`AutotuneCommand.swift:395-403`). It then polls a second time at the top of `if apply { ... }`, before calling `dependencies.applyConfig(...)` (`AutotuneCommand.swift:420-429`). Both paths update the run with `endedAt: nil`, `exitReason: .interrupted`, and throw `ExitCode(130)`. `testInterruptionAfterStage2CancelsBeforeApply` flips the flag after the injected `runStage2` returns and asserts exit 130, `applyCalls == 0`, `exit_reason == "interrupted"`, and nil `endedAtUTC`.

**J.1 (MAJOR) — CLOSED.** The conflict + `--drain` branch wraps only `dependencies.drainConflict(conflict, port, TimeInterval(drainGrace))` in a `do/catch` (`AutotuneCommand.swift:245-252`). On throw it samples `endedAt`, updates the run as `.providerConflict`, writes stderr containing `--drain failed`, and throws `ExitCode(1)`. The no-conflict path and the surrounding conflict branch are not swallowed by this catch, and `updateRun(...)` failures inside the catch still propagate rather than being reclassified. `testDrainConflictThrowFinalizesAsProviderConflict` injects a throwing `drainConflict` closure and asserts `provider_conflict` plus the stderr message.

**K.1 (MINOR) — CLOSED.** `MachineFingerprinter.ramGB()` now returns `1` when `sysctlbyname("hw.memsize", ...)` fails or returns zero (`AutotuneRuntimeSupport.swift:66-78`). The success path still clamps with `max(1, ...)`. `testMachineFingerprinterRAMNeverReturnsZero` samples the real fingerprinter and asserts `ramGB >= 1`, which is sufficient to lock the no-zero contract for this pass.

### Round-2 new findings

#### Category Z-CLOSURE

(no findings)

Verification notes:
- All four Round 18 findings are closed.
- The Stage1Iterator LOCKED-file diff is additive-only relative to `a9da9e5`.
- The Stage2HillClimb LOCKED-file diff is additive-only relative to `022e8a3`: Equatable conformance, new cancellation/budget error cases, defaulted cancellation callback, cell-boundary poll, and partial-finalization helper.

#### Category R-REGRESSION-V10F1

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: 366 tests executed, 2 skipped, 0 failures.
- The three new regression-lock tests passed: `testInterruptionAfterStage2CancelsBeforeApply`, `testDrainConflictThrowFinalizesAsProviderConflict`, and `testMachineFingerprinterRAMNeverReturnsZero`.
- The renamed operator-override test preserves the same run-level derivation path (`parse` -> `candidatePlan()` -> `candidatesBySize(for:)`) while asserting input-order output instead of nil.
- The reverted Step 7 all-infeasible test still exercises the nil fallback end-to-end.

#### Category N-NEWGAPS-V10F1

(no findings)

Verification notes:
- The post-Stage-2 cancellation poll is outside and after the Stage 2 catch block, so it does not interfere with the budget-exhausted partial recommendation path.
- The pre-apply cancellation poll is before `applyConfig(...)`, not inside its async work.
- The drain catch boundary is limited to `drainConflict(...)`; it does not catch the whole conflict branch.
- Explicit `--candidate-models a,b` now passes `["a", "b"]` as the explicit surface order rather than relying on the locked nil fallback.
- The MachineFingerprinter test is host-dependent but acceptable for v1 because it locks the public no-zero sample contract.

#### Category O-OTHER-V10F1

(no findings)

### Step 10 readiness verdict

READY TO PROCEED TO STEP 11.

---

## Round 20 audit (Codex on 254d651 — Step 11 round 1)

**Audited:** commit 254d651 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 11, round 1 of N
**Date:** 2026-06-18
**Total findings:** 0 CRITICAL / 2 MAJOR / 3 MINOR / 1 QUESTION
**Step 11 readiness:** FIX REQUIRED

### Executive summary

Step 11's broad AC-tagged unit coverage is present: I found 24 `testAC...` methods across the five new `AutotuneACTests` files, with named coverage for AC-1 through AC-19 and non-tautological assertions for the expected run rows, recommendation fields, parser failures, lifecycle rows, and output surfaces. The highest-risk anti-regression check is clean: `git diff fdb07ff..254d651 -- phase3-binary/Sources/` is empty, and `swift test --package-path phase3-binary` passed with 390 tests executed, 4 skipped, and 0 failures.

The build is not ready for post-build yet because two Step 11 contract/documentation gaps remain. The AC-6 tests are integration-gated but still inject `detectConflict` rather than spawning/detecting real provider processes, so they assert a proxy command reaction rather than the documented launchd/foreground detection path. The AC-17 test comment and in-line assertion document the accepted v1 alternates deviation, but the Step 11 implementation-notes section contradicts that by calling it a strict AC-17 failure and omits the v0.4 fix path required by the prompt.

I also found three lower-severity documentation/coverage-shape issues: the AC-8 test comments do not document the Shape A exclusion, the AC-7 real-subprocess/coordinator-pool placeholder is absent despite the prompt calling for it, and implementation-notes does not record the post-build checklist. These are not source-lock violations, but they should be cleaned up before locking Step 11.

### Findings

#### Category A: Per-AC coverage (AC-1 through AC-19)

**A.1 (MAJOR) - AC-6 tests assert an injected proxy conflict, not the documented integration contract.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_IntegrationTests.swift:6-39`; `specs/SPEC-013-cli-autotune.md:1404-1424`.
- **What:** `testAC6ProviderConflictPreFlightRefusesLaunchdByDefault` and `testAC6ProviderConflictPreFlightRefusesForegroundByDefault` are gated by `AUTOTUNE_INTEGRATION_TESTS=1`, but when enabled they still set `deps.detectConflict = { .launchdManaged(pid: 123) }` or `.foreground(...)`. They do not spawn a real `macprovider-cli serve`, do not exercise `launchctl list`, and do not exercise foreground argv detection.
- **Why:** AC-6 is specifically about refusing when a provider is already running on the configured port and covering both install paths. The Step 11 prompt also says both AC-6 tests should spawn real subprocesses. The current tests only prove that `AutotuneCommand.run()` maps an already-supplied conflict enum to `provider_conflict`, a proxy surface already covered elsewhere.
- **Recommendation:** Replace or supplement these gated AC-6 tests with real integration harnesses: launchd-managed detection via a test plist/`launchctl` flow where feasible, and foreground detection via a real spawned `macprovider-cli serve` process. Keep the injected tests as fast unit coverage only if useful, but do not count them as the AC-6 integration lock.

Verification notes:
- AC-1, AC-2, AC-3, AC-4, AC-5, AC-8, AC-9, AC-10, AC-11, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, and AC-19 have named AC methods with line-range comments and specific assertions.
- `rg -n "func testAC" phase3-binary/Tests/macprovider-cliTests/AutotuneACTests | wc -l` returns 24.
- AC-17 intentionally locks the v1 position-based alternates behavior at `AutotuneAC_Stage1Tests.swift:251-253`; see Category C.

#### Category B: Integration gating

(no findings)

Verification notes:
- `AutotuneAC_IntegrationTests.setUpWithError()` skips unless `ProcessInfo.processInfo.environment["AUTOTUNE_INTEGRATION_TESTS"] == "1"` (`AutotuneAC_IntegrationTests.swift:6-10`), so polarity is correct.
- The default full test run reported 4 skipped tests: 2 AC-6 tests plus the 2 pre-existing integration-gated tests.
- Env-var spelling is exactly `AUTOTUNE_INTEGRATION_TESTS`.

#### Category C: AC-17 v1 deviation documentation

**C.1 (MAJOR) - implementation-notes does not document the AC-17 accepted deviation consistently or name the v0.4 fix path.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_Stage1Tests.swift:219-253`; `phase3-binary/implementation-notes.html:251-256`.
- **What:** The AC-17 method comment and in-line assertion comment are comprehensive: they name FR-F.1's smaller-candidates rule, the v1 position-based slice, the 1B/32B behavior, and the v0.4 candidate fix. The Step 11 implementation-notes section does not match them. It says the AC run has "1 strict AC-17 failure" because 32B appears as an alternate, and it does not name the v0.4 size-parsed-ordering fix path.
- **Why:** The prompt makes implementation-notes one of the three required AC-17 documentation surfaces. A future reader would see the test passing while implementation-notes still describes the behavior as a strict failure, which defeats the purpose of locking a known v1 limitation.
- **Recommendation:** Update the `spec013-autotune-step11` implementation-notes entry to explicitly say Step 11 accepts and locks the v1 position-based alternates behavior for operator order, 32B appears as an alternate for chosen 1B, FR-F.1 requires `[]`, and SPEC-013 v0.4 should plumb size-parsed ordering into the emitter.

**C.2 (QUESTION) - Should AC-17 be tightened now instead of deferred to v0.4?**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_Stage1Tests.swift:251-253`; `specs/SPEC-013-cli-autotune.md:1571-1573`.
- **What:** The test intentionally asserts `alternates == [thirtyTwoB]`, while SPEC-013 requires no smaller candidates after choosing 1B, i.e. `[]`.
- **Why:** This is a documented v1 limitation in the test, but it is also the one AC-17 assertion that knowingly locks behavior outside the locked spec.
- **Recommendation:** Operator call: either keep the v1 deviation and fix only documentation now, or bump to a v0.4 fix-pass that adds a model-size extractor/order seam and changes AC-17 to assert `[]`.

Verification notes:
- `git diff fdb07ff..254d651 -- phase3-binary/Sources/` is empty, so Step 11 itself does not modify the locked source surface.
- The literal prompt check `git diff d6c634c..254d651 -- phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift` is non-empty because that range spans audited Step 10 partial-recommendation additions, not just Step 11. I did not classify that as a Step 11 source-lock violation; the Step 11 boundary and final locked-source boundary are empty.

#### Category D: AC-8 Shape A scope decision

**D.1 (MINOR) - AC-8 Shape A exclusion is documented in implementation-notes but not in the AC-8 method comments.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_Stage1Tests.swift:107-173`; `phase3-binary/implementation-notes.html:241-245`.
- **What:** implementation-notes states that Shape A is out of scope for v1 and that the tests exercise Shape B transient/integrity classifications. The two AC-8 method comments only say "Shape B transient" and "Integrity-class"; they do not document that Shape A is intentionally excluded.
- **Why:** Category D requires the Shape A exclusion to be documented in both implementation-notes and the AC-8 test comments, so the current test file leaves the scope decision less discoverable.
- **Recommendation:** Add one short method-level or shared test comment near the AC-8 tests explaining that Step 6 selected Shape B and Shape A remains out of scope for v1.

Verification notes:
- The Shape B transient test advances from candidate 1 to candidate 2, records the transient note, and exits `ok` (`AutotuneAC_Stage1Tests.swift:107-140`).
- The Shape B integrity test records only candidate 1 and exits `pre_warm_integrity_failure` (`AutotuneAC_Stage1Tests.swift:143-173`).

#### Category E: AC-7 unit vs integration

**E.1 (MINOR) - AC-7 real-subprocess/coordinator-pool integration placeholder is absent.**
- **Location:** `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_Stage1Tests.swift:86-104`; `phase3-binary/Tests/macprovider-cliTests/AutotuneACTests/AutotuneAC_IntegrationTests.swift:1-41`; `phase3-binary/implementation-notes.html:246-250`.
- **What:** Step 11 has `testAC7NoJoinIsSetOnEveryCandidate`, but it directly calls `CandidateProviderRunner.serveArguments(...)` for three model IDs. `AutotuneAC_IntegrationTests.swift` contains only the two AC-6 methods; there is no AC-7 skipped placeholder or real-subprocess/coordinator-pool test.
- **Why:** The prompt asks for a unit variant plus an integration placeholder for AC-7. The unit assertion is non-tautological for argv construction, but it does not record argv via a mock runner and it does not cover the coordinator-pool observation called out in SPEC-013 lines 1429-1432.
- **Recommendation:** Add a skipped AC-7 integration placeholder or update the prompt/implementation-notes to explicitly defer it. If kept in Step 11, prefer a harness that starts candidate serve processes with `--no-join` and verifies the coordinator pool remains unaffected.

#### Category F: Fixture reuse vs duplication

(no findings)

Verification notes:
- `AutotuneACTestFixture.dependencies()` uses the existing `AutotuneRunDependencies` seam: time/run ID, signal-source, DB creation, conflict detection/drain/restore, Stage 1/2 runners, recommendation emission, config apply, and stdout/stderr (`AutotuneAC_Stage1Tests.swift:336-392`).
- The fixture does not introduce a parallel command runner; it injects the same dependency structure used by `AutotuneCommandRunTests`.

#### Category G: Anti-regression on Steps 1-10

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: `Executed 390 tests, with 4 tests skipped and 0 failures`.
- `git diff fdb07ff..254d651 -- phase3-binary/Sources/` produced no output.
- `git diff 254d651^ 254d651 -- phase3-binary/Sources/` also produced no output.
- `git diff --name-status 254d651^ 254d651 -- phase3-binary/Tests/macprovider-cliTests` lists only the five new `AutotuneACTests` files; no Step 1-10 test file was modified.

#### Category H: Forward-compatibility (post-build checklist)

**H.1 (MINOR) - implementation-notes does not document the post-build checklist as the next operator action.**
- **Location:** `phase3-binary/implementation-notes.html:197-257`; commit message for `254d651`.
- **What:** The commit message lists the next actions: SPEC-003 install note, `beta/DECISION_CRITERIA.md` entry, PR #103 disposition, push branch, and open implementation PR. The Step 11 implementation-notes entry does not include that checklist.
- **Why:** Category H.2 requires implementation-notes to document the post-build checklist. Keeping it only in the commit message makes the next-action trail less durable for readers using implementation-notes as the build log.
- **Recommendation:** Add a short "After Step 11 locks" paragraph to the `spec013-autotune-step11` entry with the five post-build items.

#### Category I: Anything else

(no findings)

Verification notes:
- The five new files are organized by Stage 1, Stage 2, lifecycle, output, and integration concerns.
- There are duplicate AC numbers only where expected: AC-6 has launchd/foreground variants, AC-8 has transient/integrity variants, AC-13 has Stage 1/Stage 2 budget variants, AC-18 has valid/invalid variants, and AC-19 has max-only/max+min variants.

### Step 11 readiness verdict

FIX REQUIRED.

---

## Round 21 audit (Codex on e4f7bc3 — Step 11 round 2 closure verification)

**Audited:** commit e4f7bc3 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 11, round 2 of N
**Date:** 2026-06-18
**Closure summary:** 6 CLOSED / 0 PARTIAL / 0 NOT CLOSED / 0 OVER-CLOSED across the 6 round-1 findings
**Round-2 findings:** 0 CRITICAL anti-regression / 0 MAJOR new / 0 MINOR new
**Step 11 readiness:** READY TO PROCEED TO POST-BUILD

### Executive summary

Commit e4f7bc3 closes all six Round 20 findings without touching locked source. The fix-pass is limited to the Step 11 AC test files and `implementation-notes.html`; `git diff fdb07ff..e4f7bc3 -- phase3-binary/Sources/` produced no output.

The anti-regression run passed with the expected count: `swift test --package-path phase3-binary` executed 393 tests, with 7 skipped and 0 failures. The increase from 390/4 to 393/7 matches the three new always-skipping real-subprocess placeholders, and the env-enabled integration-class check confirmed the two AC-6 mapping tests pass while those three placeholders skip from their own `XCTSkip` messages.

### Round-1 finding closures

**A.1 (MAJOR) — CLOSED.** The two AC-6 tests are now named `testAC6ProviderConflictMappingLaunchdManaged` and `testAC6ProviderConflictMappingForeground`, and their method comments explicitly call them mapping tests rather than real launchd/foreground detection tests. The top-of-file comment records the audit-driven split between injected mapping coverage and deferred real-subprocess coverage. The three placeholders exist in `AutotuneAC_IntegrationTests.swift`: `testAC6RealSubprocessLaunchdDetection`, `testAC6RealSubprocessForegroundDetection`, and `testAC7RealSubprocessNoJoinPlusCoordinatorPoolUnaffected`. Each placeholder's method body unconditionally throws `XCTSkip` with an AC-specific v2-expansion reason and a pointer to existing unit coverage.

**C.1 (MAJOR) — CLOSED.** The previous implementation-notes text describing "1 strict AC-17 failure" is gone. The Step 11 notes now frame AC-17 as an accepted v1 limitation, name the concrete case (`--candidate-models 1b,32b` with 1B chosen gives v1 `alternates == [32B]` while the spec requires `[]`), and name the v0.4 fix path: plumb size-parsed ordering into recommendation inputs through `candidatesBySize` and extend the existing `parseSizeB` approach for arbitrary HF IDs. `testAC17OperatorOrderHonoredVerbatim` and its inline alternates assertion remain consistent with those notes.

**C.2 (QUESTION) — CLOSED.** The implementation-notes explicitly resolve the question as a v0.4 deferral: keep v1 BUILD scope tight because the deviation is observable only for non-default operator orders, not default-list runs. That is a clear operator decision rather than an unresolved audit question.

**D.1 (MINOR) — CLOSED.** Both AC-8 methods now document the Shape A exclusion. `testAC8PreWarmTransientFailureAdvancesToNextCandidate` names Step 6's Shape B selection and says the pull/subcommand Shape A variant is out of scope for v1; `testAC8PreWarmIntegrityFailureAbortsTheWholeRun` carries the same scope decision for the integrity abort branch.

**E.1 (MINOR) — CLOSED.** `testAC7RealSubprocessNoJoinPlusCoordinatorPoolUnaffected` exists in `AutotuneAC_IntegrationTests.swift`. It always skips once the integration class gate is enabled, names the AC-7 real-subprocess plus coordinator-pool observation as a v2 expansion, and points at `testAC7NoJoinIsSetOnEveryCandidate` in `AutotuneAC_Stage1Tests` as the existing unit-level argv-construction guard.

**H.1 (MINOR) — CLOSED.** The Step 11 implementation-notes entry now includes an "After Step 11 LOCKS — post-build checklist" section with all five required items: SPEC-003 install note, `beta/DECISION_CRITERIA.md` entry, PR #103 disposition, push `feat/cli-autotune-impl`, and open the implementation PR separate from SPEC PR #108.

### Round-2 new findings

#### Category Z-CLOSURE

(no findings)

Verification notes:
- All six Round 20 items are closed as described above.
- `git show e4f7bc3` changes only `AutotuneAC_IntegrationTests.swift`, `AutotuneAC_Stage1Tests.swift`, and `implementation-notes.html`.

#### Category R-REGRESSION-V11F1

(no findings)

Verification notes:
- `swift test --package-path phase3-binary` passed: `Executed 393 tests, with 7 tests skipped and 0 failures`.
- Default environment behavior is correct: the two AC-6 mapping tests still skip when `AUTOTUNE_INTEGRATION_TESTS` is unset because the whole `AutotuneACIntegrationTests` class is gated.
- `AUTOTUNE_INTEGRATION_TESTS=1 swift test --package-path phase3-binary --filter AutotuneACIntegrationTests` passed: the two mapping tests executed and passed, while the three placeholders skipped individually with their own v2-expansion messages.

#### Category N-NEWGAPS-V11F1

(no findings)

Verification notes:
- Placeholder skip messages name AC-6 or AC-7, state the v2 integration expansion reason, and point at existing unit coverage (`ProviderConflictDetectorTests` for AC-6; `AutotuneAC_Stage1Tests` for AC-7).
- The placeholder methods are not env-gated internally; when the class gate passes, each method reaches its own unconditional `XCTSkip`.
- `git diff fdb07ff..e4f7bc3 -- phase3-binary/Sources/` is empty.

#### Category O-OTHER-V11F1

(no findings)

### Step 11 readiness verdict

READY TO PROCEED TO POST-BUILD.

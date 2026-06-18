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

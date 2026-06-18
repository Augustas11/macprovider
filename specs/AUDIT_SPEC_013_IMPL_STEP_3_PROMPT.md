# Implementation audit prompt — SPEC-013 Step 3 (SQLite DB layer)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / contract / Swift-idiom review** of the Step 3 commit that
landed the `AutotuneDB` SQLite layer on branch
`feat/cli-autotune-impl`.

Step 3 carries:

| Commit | Step | Scope |
|---|---|---|
| d0029e9 | 3 | `AutotuneDB` Swift class + `AutotuneExitReason` enum + `AutotuneTrialRow`/`AutotuneRunRow` value types + migration + transactional retention + 4 unit tests |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (260 tests). Codex (the implementer) raised zero
Open Questions. Operator wants an independent adversarial pass
BEFORE Step 4 (provider lifecycle) begins, so any DB layer defect
is caught before later steps build on it.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~25-35 min
(Step 3 is the heaviest implementation step so far — full SQLite
schema + C-interop bridge + transactional retention + enum
enforcement + ALTER TABLE migration). This is a **read-only
review** — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
3 commit (d0029e9) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Steps 1 (02b038d) and 2
(ffb00fb) are LOCKED. Steps 4-11 have NOT landed yet — your scope
is exclusively the Step 3 commit and its anti-regression impact on
the existing `phase3-binary/`.

This is a **read-only review**. You MUST NOT edit any file,
commit, push, or modify the git state.

## Context

Step 3 of `specs/BUILD_SPEC_013_PROMPT.md` calls for the
`AutotuneDB` writer surface that later steps use to persist
trials, runs, and recipe hashes. Specifically:

- Open `~/.config/macprovider/autotune.sqlite` (default; operator
  override via `--db-path`).
- Create `tune_trials` per SPEC-013 v0.3 FR-G.1 with
  `stage INTEGER NOT NULL DEFAULT 1`.
- Migrate prototype DBs that lack the `stage` column via
  `ALTER TABLE tune_trials ADD COLUMN stage INTEGER NOT NULL
  DEFAULT 1` with duplicate-column-ignore (the prototype's
  pattern in `beta/autotune.py` on `spike/provider-model-autotune`).
- Create `tune_runs` per FR-G.2 with the normative `exit_reason`
  enum (9 values) enforced at the application layer.
- Implement transactional retention sweep per FR-G.1: single
  SQLite transaction covering both `tune_trials` and `tune_runs`
  deletes; runs AFTER the new `tune_runs` row is created; default
  N=50, operator-overridable via `--retain-runs`, enforced N>=1.

Step 3 is ADDITIVE. The DB is created/written but is NOT yet
called from `AutotuneCommand.run()` — wiring happens in Step 7
(Stage 1 iteration). This audit verifies the writer surface is
correct so Step 7 (and Step 9 recommendation surface, Step 10
failure modes) can consume it.

## Required reading (in this order)

1. The Step 3 commit via `git show d0029e9`. The commit message
   contains the testing claims and rejected alternative (third-
   party SQLite wrapper).

2. The Step 3 source under audit:
   - `phase3-binary/Sources/macprovider-cli/AutotuneDB.swift`
     (363 lines, NEW). This is the bulk of the audit's surface.
   - `phase3-binary/Tests/macprovider-cliTests/AutotuneDBTests.swift`
     (240 lines, NEW; 4 unit tests + helpers).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step3` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §5.7 — full
     `tune_trials` schema (FR-G.1) and `tune_runs` schema
     (FR-G.2), the `stage` column rule, the retention semantics,
     and the normative `exit_reason` enum (9 values, with
     `applied INTEGER`-vs-`exit_reason` coexistence rules
     called out).

4. The prototype reference for the migration shape:
   `git show origin/spike/provider-model-autotune:beta/autotune.py
   | sed -n '/_ADDITIVE_TUNE_COLUMNS/,/CREATE INDEX/p'`
   — verify the additive-column pattern Step 3 ports matches
   what the prototype actually does.

5. Local style guide:
   - `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`
     — the recent Step 1 + fix-pass code; idioms.
   - Any existing sqlite usage in the codebase: grep
     `phase3-binary/Sources/` for `SQLite3` or `sqlite3_` to see
     whether Step 3 is the FIRST sqlite consumer or whether
     prior code established a pattern. If prior code exists,
     verify Step 3 matches its idiom.

You do NOT need to re-read SPEC-001, SPEC-002, SPEC-003 — the
audit scope is the DB layer.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation of FR-G.1 / FR-G.2;
  data-loss bug; non-transactional retention sweep that can
  leave orphans; SQL injection vector; resource leak (statement
  not finalized, handle not closed); anti-regression broke an
  existing passing test.
- **MAJOR** — schema column mismatch with the SPEC; the
  `exit_reason` enum admits a value not in the SPEC's 9-value
  list, or rejects a value that IS in the list; migration test
  passes but the actual prototype DB schema would fail; test
  gap that lets a silent regression land.
- **MINOR** — quality issues, naming inconsistencies, doc gaps.
- **QUESTION** — design choice Step 3 made where the SPEC was
  silent (e.g. choice of `BEGIN IMMEDIATE` vs `BEGIN`).

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — `swift test --package-path phase3-binary`
   MUST report 260 tests, 0 failures.
3. Strict clean-room on d-inference.
4. Read-only.

Additionally for Step 3:

5. **SQL injection discipline.** Step 3's `applyRetentionInTransaction`
   uses string-interpolated SQL for the LIMIT/OFFSET. The
   interpolated value is an `Int` (Swift's type system prevents
   string injection), but verify there's no path where untrusted
   data reaches a string-interpolated SQL clause.

6. **Resource-leak discipline.** Every `sqlite3_prepare_v2` MUST
   be matched by `sqlite3_finalize`. Every `sqlite3_open_v2` MUST
   be matched by `sqlite3_close` on every exit path including
   error paths. Verify by reading.

7. **Transaction discipline.** The retention sweep claims to be a
   single transaction. Verify the SQL sequence is `BEGIN ... DELETE
   trials ... DELETE runs ... COMMIT` with `ROLLBACK` on any error,
   AND that no intermediate `COMMIT` or implicit commit (e.g. DDL
   inside) could break the atomicity.

## Audit categories — work through each

### Category A: SPEC-013 FR-G.1 / FR-G.2 schema coverage

A.1  `tune_trials` schema (FR-G.1): walk the `CREATE TABLE` SQL
     in `migrate()`. Compare column-by-column against
     SPEC-013 §5.7 FR-G.1 table:
     - `id INTEGER PRIMARY KEY AUTOINCREMENT`
     - `ts_utc TEXT NOT NULL`
     - `run_id TEXT NOT NULL`
     - `stage INTEGER NOT NULL DEFAULT 1` (the v0.2 addition)
     - `model TEXT NOT NULL`
     - `target_context INTEGER NOT NULL`
     - `measured_prompt_tokens INTEGER` (nullable)
     - `max_tokens INTEGER NOT NULL`
     - `agg_throughput_tps REAL` (nullable)
     - `ttft_p95_ms REAL` (nullable)
     - `fits INTEGER NOT NULL DEFAULT 0`
     - `n_err INTEGER NOT NULL DEFAULT 0`
     - `kept INTEGER NOT NULL DEFAULT 0`
     - `notes TEXT` (nullable)
     - `kv_bits INTEGER` (nullable)
     - `max_context_cap INTEGER` (nullable)
     - `max_batch INTEGER` (nullable)
     - `replicates_n INTEGER` (nullable; new in v0.2)
     Any column missing, wrong type, wrong nullability, or wrong
     default = MAJOR.

A.2  `tune_runs` schema (FR-G.2): walk `CREATE TABLE tune_runs`
     against SPEC-013 §5.7 FR-G.2:
     - `run_id TEXT PRIMARY KEY`
     - `started_at_utc TEXT NOT NULL`
     - `ended_at_utc TEXT` (nullable)
     - `spec_version TEXT NOT NULL`
     - `binary_version TEXT NOT NULL`
     - `machine_ram_gb INTEGER NOT NULL`
     - `machine_chip TEXT NOT NULL`
     - `machine_os_version TEXT NOT NULL`
     - `target_context INTEGER NOT NULL`
     - `candidate_models_json TEXT NOT NULL`
     - `stage1_replicates INTEGER NOT NULL`
     - `stage2_replicates INTEGER NOT NULL`
     - `gate_ttft_ms INTEGER NOT NULL`
     - `tps_tie_epsilon REAL NOT NULL`
     - `recommendation_json TEXT` (nullable)
     - `recipe_hash TEXT` (nullable)
     - `applied INTEGER NOT NULL DEFAULT 0`
     - `exit_reason TEXT NOT NULL`
     Any column missing, wrong type, wrong nullability, or wrong
     default = MAJOR.

A.3  Indexes: SPEC-013 says
     `idx_tune_trials_run_id` and `idx_tune_trials_ts`. Verify
     both are created (with `CREATE INDEX IF NOT EXISTS`).
     `tune_runs` has `run_id` as PRIMARY KEY, so no extra index.

A.4  `exit_reason` enum: SPEC-013 §5.7 FR-G.2 names 9 values:
     `ok`, `interrupted`, `no_feasible`,
     `budget_exhausted_no_model_selected`,
     `budget_exhausted_with_partial_recommendation`,
     `pre_warm_integrity_failure`, `provider_conflict`,
     `config_error`, `internal_error`.
     Walk `AutotuneExitReason` enum cases and raw values. Any
     mismatch (extra value, missing value, wrong snake_case
     spelling) = MAJOR.

A.5  Migration ALTER for prototype DB: SPEC-013 says
     `ALTER TABLE tune_trials ADD COLUMN stage INTEGER NOT NULL
     DEFAULT 1`. Verify the SQL string in
     `additiveTrialColumns[0]` is exactly that. The
     duplicate-column-ignore swallows already-applied migrations.
     The migration test
     `testPrototypeTrialSchemaMigrationAddsStageColumnWithDefault`
     uses a fixture with the prototype's pre-stage schema and
     verifies `stage` is added with NOT NULL + DEFAULT 1 + value
     `1` for existing rows. Good.

A.6  Default DB path: SPEC-013 says
     `~/.config/macprovider/autotune.sqlite`. The `init` default
     parameter uses `AutotuneCommand.defaultDBPath`. Verify it
     resolves to the documented path.

A.7  `:memory:` support: `init(path:)` short-circuits the
     directory-create for `:memory:`. Useful for tests. SPEC
     doesn't require it but doesn't forbid it. Acceptable.

### Category B: Transactional retention sweep (FR-G.1)

B.1  Sequence: read `applyRetentionInTransaction`. The order
     MUST be:
     1. validate `retainRuns >= 1`
     2. `BEGIN IMMEDIATE TRANSACTION`
     3. compute `staleRuns` (the run_ids beyond the keep set)
     4. `DELETE FROM tune_trials WHERE run_id IN (staleRuns)`
     5. `DELETE FROM tune_runs WHERE run_id IN (staleRuns)`
     6. `COMMIT`
     7. ROLLBACK on any error
     Order MUST delete `tune_trials` BEFORE `tune_runs` (or
     simultaneously) to avoid foreign-key-style orphans if FK
     constraints are added later. The current order (trials first,
     then runs) is correct.

B.2  Atomicity: `BEGIN IMMEDIATE TRANSACTION` acquires the write
     lock immediately, preventing other writers. `BEGIN` (no
     IMMEDIATE) would defer; for a single-writer process like
     autotune, IMMEDIATE is the safer choice. Acceptable.

B.3  The `staleRunsSQL` uses `LIMIT -1 OFFSET \(retainRuns)`.
     SQLite's `LIMIT -1` means "no upper bound." Combined with
     OFFSET, this returns all rows past position `retainRuns` in
     the ORDER BY. Verify the ORDER BY is `started_at_utc DESC,
     run_id DESC` (newest first), so OFFSET `retainRuns` skips the
     N most recent runs and selects the older ones for deletion.
     Correct.

B.4  ROLLBACK path: the catch uses `try? execute("ROLLBACK")`
     (swallowing rollback errors). This is correct — if rollback
     fails, the original error should still propagate to the
     caller. Acceptable.

B.5  N <= 0 enforcement: the `guard retainRuns >= 1` happens
     BEFORE the BEGIN. Good; no orphan transaction.

B.6  Behavior with N == total row count: e.g. 50 runs in DB,
     retainRuns=50. The OFFSET skips all 50 rows, returns
     empty set, both DELETEs are no-ops, COMMIT succeeds.
     Correct.

B.7  Behavior with N > total: OFFSET past the end returns empty.
     Same as B.6. Correct.

B.8  Test coverage: `testRetentionSweepDeletesOldestRunsAndTrialsTransactionally`
     inserts 52 rows + 52 trials, applies retention=50, verifies
     50 + 50 remain, the 2 OLDEST (run-000, run-001) are gone
     from BOTH tables, and a LEFT JOIN confirms no orphan trials.
     This is a strong test. Could be strengthened with a test
     that asserts intermediate state is invisible to a parallel
     reader (i.e. transaction isolation) but that requires a
     concurrent writer — acceptable to skip.

### Category C: C-interop correctness

C.1  Statement lifetime: `withStatement` wraps every
     `sqlite3_prepare_v2` with a `defer { sqlite3_finalize(...) }`.
     Verify by reading. Any exit path from `withStatement` (early
     return, throw, normal return) MUST finalize. Defer satisfies
     this.

C.2  Handle lifetime: `init` opens with `sqlite3_open_v2`. The
     `deinit` calls `close()`. Any throw path from `init` (e.g.
     migration failure) MUST close the handle before re-throwing.
     Read `init`: the migrate() catch calls `close()` before
     rethrow. Good.

C.3  Open-failure path: if `sqlite3_open_v2` returns non-OK, the
     code captures the error message BEFORE closing the handle.
     Read: `let message = db.map(Self.errorMessage) ?? "..."`
     followed by `sqlite3_close(db)`. If `db` was returned but
     non-OK status, the message extraction reads from a partially-
     opened handle, which sqlite3 documents as safe. Then close.
     Correct.

C.4  `SQLITE_TRANSIENT` constant: Swift's `SQLite3` module does
     NOT export the `SQLITE_TRANSIENT` constant (it's a `#define
     ((sqlite3_destructor_type)-1)` in C). Step 3 defines it
     locally as `let SQLITE_TRANSIENT = unsafeBitCast(-1, to:
     sqlite3_destructor_type.self)` at file scope. This is the
     standard Swift idiom for sqlite-from-Swift. Verify the
     unsafeBitCast target type matches.

C.5  `sqlite3_bind_text` with `SQLITE_TRANSIENT` — the binding
     copies the string. This is correct for strings whose
     lifetime might end before `sqlite3_step` runs. The cost is
     a copy per bind; for our writer surface (one row per call)
     this is negligible.

C.6  `bind(Int?, at:, in:)` uses `sqlite3_bind_int64`. Swift
     `Int` on Apple Silicon is 64-bit, so this is correct.

C.7  Error message extraction: `sqlite3_errmsg(handle)` returns
     a C string owned by sqlite. Step 3's `errorMessage` uses
     `String(cString: $0)` which copies. Correct.

C.8  Concurrent access: `SQLITE_OPEN_FULLMUTEX` is set in the
     open flags. This makes the handle thread-safe (serialized
     mode). For a single-writer process this is correct.

C.9  Any path where a prepared statement could be leaked? Walk
     `withStatement` — the defer covers the success and throw
     paths from `body`. What about the prepare-failure path?
     Reading: `guard sqlite3_prepare_v2(...) == SQLITE_OK, let
     statement else { throw currentError() }`. The prepare-fail
     path throws without binding a statement (the guard's `let
     statement` only succeeds when both conditions hold). On
     fail, `statement` (the OpaquePointer?) may have been set
     by sqlite3 — sqlite documents that on prepare failure,
     statement is set to NULL. So nothing to finalize. Correct.

### Category D: Anti-regression

D.1  `swift test --package-path phase3-binary` — verify 260
     tests pass, 0 failures.

D.2  Does the new `import SQLite3` in `AutotuneDB.swift` pull
     in a new top-level dependency? `SQLite3` is the system
     module for `/usr/lib/libsqlite3.dylib`. macOS ships this;
     no Package.swift change needed. Verify by reading
     `phase3-binary/Package.swift` — is there a system library
     declaration needed for `import SQLite3` to resolve? On
     Apple platforms it usually does without a system library
     target.

D.3  Build time impact: SQLite is small. Compile time should not
     regress noticeably.

D.4  Does adding `AutotuneDB` to the module affect any other
     compile unit? It shouldn't — no other file imports it yet.

### Category E: Forward-compatibility

E.1  Step 7 (Stage 1 iteration) will call `insertTrial(_:)` for
     each candidate. Verify the `AutotuneTrialRow` value type
     has all fields Step 7 will need. Walk SPEC-013 §5.7 FR-G.1
     against the struct.

E.2  Step 9 (recommendation surface) will call `insertRun(_:)`
     and emit `recipe_hash`. Verify the `AutotuneRunRow` struct
     has `recipeHash: String?` (nullable for no-feasible runs).
     Correct.

E.3  Step 9's FR-F.2 `--apply` sets `applied = true`. Verify
     `AutotuneRunRow.applied: Bool` exists. Correct.

E.4  Step 10 (failure modes) needs the enum to cover all 9
     `exit_reason` values. Verified in A.4.

E.5  Future Step 11 ACs that probe DB state (AC-3 all-infeasible,
     AC-13 budget exhausted, AC-16 stage row counts): can the
     test fixtures construct rows freely? The two `make*`
     helpers in `AutotuneDBTests.swift` provide a base; Step 11
     test files can copy/extend the pattern. Acceptable.

### Category O: Anything else

Examples that DO belong here:
- The `additiveTrialColumns` array includes `("stage", "INTEGER
  NOT NULL DEFAULT 1")` even though the v0.3 CREATE TABLE
  already has the column. The duplicate-column-ignore swallows
  the duplicate ALTER on a fresh DB. Acceptable, but is the
  CREATE TABLE redundant with the ALTER if a fresh DB always
  has the column from CREATE? Answer: yes, but the ALTER is
  needed for upgrade-from-prototype path. The dual-write is
  correct.
- The Step 3 implementation-notes section accurately documents
  the design choice (system SQLite, application-layer enum,
  transactional retention).
- The commit message uses the local "Confidence / Scope-risk /
  Directive / Tested / Not-tested" trailer convention.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 4 audit (Codex on d0029e9 — Step 3 round 1)

**Audited:** commit d0029e9 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 3, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 3 readiness:** [READY TO PROCEED TO STEP 4 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-E + O. Same finding format as prior audit
rounds in this file.
```

## Out of scope for this audit

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1 + 2 (LOCKED)
- Auditing Steps 4-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK

## Done criteria

You are done when:

- The new `## Round 4 audit ...` section is appended to
  `/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`
- Earlier sections (rounds 1, 2, 3) are unchanged
- Every category A-E + O has a section
- Every finding has severity, location, what / why /
  recommendation
- The verdict line states READY TO PROCEED TO STEP 4 or
  FIX REQUIRED
- `swift test --package-path phase3-binary` was run and the
  result is reported in the executive summary

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 25-35 min.
- If verdict is READY TO PROCEED TO STEP 4: Claude commits the
  audit prompt + report and immediately fires codex on Step 4
  (provider lifecycle).
- If verdict is FIX REQUIRED: Claude rolls a fix-pass + the next
  round prompt. Loop until 0 CRITICAL / 0 MAJOR.

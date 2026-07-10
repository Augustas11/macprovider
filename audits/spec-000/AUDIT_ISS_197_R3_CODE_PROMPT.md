You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), CODE lane, ROUND 3.

R2 returned 2 MEDIUM + 1 LOW. R3 fixes:

1. (R2 MEDIUM #1) `--check` mutated schema via `OpenStore`. R3 added
   `requestlog.OpenStoreReadOnly` (sets `PRAGMA query_only=ON`, skips
   `migrate()`/`ensureColumns()`). `migrate-indexes --check` now routes
   through this read-only store. `--format` validation is hoisted
   BEFORE config-load + store-open. New tests:
   - `TestMigrateIndexesCheckIsReadOnly` — pre-seeds a legacy
     request_log (only id/ts_utc/request_id/model), runs `--check
     --format json`, asserts aggregate=`legacy`, asserts schema is
     STILL legacy after the command (external_request_id / account_id
     columns absent).
   - `TestMigrateIndexesCheckRejectsBogusFormatBeforeOpen` — passes
     `--format bogus`, asserts rc=2 and the legacy schema is
     unchanged (proving validation happens before OpenStore).

2. (R2 MEDIUM #2) Production reconciliation MUST fail closed on
   `unindexed`. R3 sharpened the SPEC scope: the operational binding
   applies to **out-of-process reconciliation tooling** (SPEC-005 v0.3+
   closing-the-books surface) — NOT to coordinator's in-process
   `RecoverLedger` / admin reconcile / hot-path AttemptN, which use
   SQLite `IS` clustering and are correct (just unindexed-slow) under
   state `unindexed`. The daemon-startup `unindexed` rollout window is
   by design and must serve traffic. SPEC-005 v0.3.2 cross-links the
   per-key state contract. The in-process recovery paths are
   intentionally NOT changed.

3. (R2 LOW: registry drift) R3 consolidated `migrationKeyDefs` to be
   the single source of truth for both `MigrationState` and
   `MigrateIndexes` — DDL + index name live on the registry; both
   functions iterate it.

4. SPEC §11 v1.5.1 now states: `migrationKeyDefs` MUST be non-empty;
   append-only; consumers MUST match by `key` and tolerate additional
   entries.

5. `sanitizeRequestLogText` strengthened to reject invalid UTF-8 and
   strip C1 codepoints (addresses R2 security MEDIUM #1 — see also
   the SECURITY lane prompt).

## Verify

- Does `OpenStoreReadOnly` actually prevent schema mutation? Are there
  any DDL/DML paths reachable via `MigrationState` that would still
  fire under `PRAGMA query_only=ON`? Verify `PRAGMA table_info` and
  `SELECT name FROM sqlite_master` work in this mode (they should —
  both are reads).
- Does the new dispatch order (`--format` validation before OpenStore)
  actually prevent the mutation? Look for any pre-validation path
  that could open the store anyway.
- Is `migrationKeyDefs` truly the single source of truth now? Are
  there any remaining places in the codebase that hardcode index
  names (`idx_request_log_external_request_id`,
  `idx_request_log_account_external_request_id`) that should reference
  the registry instead?
- Does the LOW about empty `migrationKeyDefs` need a runtime guard, or
  is the SPEC text + Go's compile-time slice-literal sufficient?
- Are there any test gaps — places where R3 added a normative MUST
  but no test pins it?
- Full coordinator test suite `go test ./...` — still green?

## Severity rubric

- **CRITICAL**: regression vs v1.5.0; OR sanitizer still has a bypass;
  OR `--check` still mutates schema.
- **HIGH**: an R2 finding not actually fixed in R3.
- **MEDIUM**: new code diverges from SPEC; test coverage misses a MUST.
- **LOW / NIT**: wording, defensive checks.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

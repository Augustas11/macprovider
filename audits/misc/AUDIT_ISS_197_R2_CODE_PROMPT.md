You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), CODE lane, ROUND 2.

R1 returned 1 HIGH (raw C1 bytes bypass `sanitizeExternalRequestID` because
the rune-based loop decoded `0x80-0x9f` to `utf8.RuneError`) plus a LOW
on the workflow narrative. R2 fixes:

1. `phase4-coordinator/internal/buyer/server.go`: extracted
   `sanitizeOpaqueHeader` shared by `sanitizeExternalRequestID` and
   `sanitizeAccountID`. New shape: trim → cap 128 → `utf8.ValidString` →
   byte-by-byte reject `<0x20`, `0x7f`, `0x80-0x9f`.
2. `phase4-coordinator/internal/buyer/server_test.go`:
   `TestRequestLogExternalRequestIDRejectsMalformedHeader` extended with
   `c1_low` (0x80), `c1_csi` (0x9b), `c1_high` (0x9f),
   `invalid_utf8_lead`, `invalid_utf8_alone`.
3. New `phase4-coordinator/internal/requestlog/store.go::MigrationState`
   returning per-key + aggregate state.
4. New CLI: `coordinator migrate-indexes --check --format json` in
   `phase4-coordinator/cmd/coordinator/migrate_indexes.go`.
5. New test `TestMigrationStateReportsPerKeyStatesAndAggregate` exercises
   `legacy`, `unindexed`, `indexed` states.

## Verify

- The byte-level sanitizer correctly rejects raw 0x80-0x9f AND invalid
  UTF-8. Does the implementation match the SPEC text? Are there any
  remaining bypasses (e.g. percent-encoded payloads that decode later)?
- `MigrationState` and `MigrateIndexes` share `migrationKeyDefs` — are
  they consistent? Could the index name in `migrationKeyDefs` drift from
  the DDL in `MigrateIndexes`?
- `--check --format json` is read-only — does any error path mutate
  state? Does it handle `--format` values other than `text|json`?
- Is the aggregate min-wise rule (`legacy if any, indexed iff all,
  unindexed otherwise`) correctly implemented? Look for off-by-one /
  early-exit bugs.
- Are there any new test gaps — places where the SPEC says a MUST but
  no test pins the contract? Particularly the production-tooling
  fail-closed behavior under state `unindexed`.
- Did the new `MigrationState` introduce any concurrent-access concern
  given the request-log store's `SetMaxOpenConns(1)` cap? (It's
  read-only so should not contend with INSERT writes, but verify.)
- Full coordinator test suite — `go test ./...` — still passes? (I ran
  this once; please re-verify if you touch anything.)

## Severity rubric

- **CRITICAL**: code lands a regression vs v1.5.0 / v1.4.2 or a real
  bypass in the sanitizer remains.
- **HIGH**: an R1 finding was not actually fixed, OR the new code has
  a money-path-adjacent gap.
- **MEDIUM**: the new state-machine implementation diverges from the
  SPEC text, OR test coverage misses a documented MUST.
- **LOW / NIT**: wording, naming, defensive checks.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

Return a structured findings list with severity, file:line, evidence,
and recommended fix.

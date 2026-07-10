# Audit prompt — ISS-196 R1 CODE lane

## What's under review

`fix/iss-196-account-scoped-pk` against `origin/main` (HEAD `ad76194`).
Changes the gateway's `usage_events` table PRIMARY KEY from
`(request_id)` — a global unique constraint — to
`(account_id, request_id)` — composite, per-account uniqueness.

This is the fix for [issue #196](https://github.com/Augustas11/macprovider/issues/196):
a buyer controlling two accounts could supply the same buyer-controlled
`X-Request-ID` and collide on the global PK after the streaming
response had already flushed bytes to the buyer, escaping settlement.

## Files in scope

- `phase5-gateway/internal/storage/sqlite/migrate.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/usage_events_pk_test.go` (new)
- `phase5-gateway/internal/router/server_test.go`

## Audit lens — CODE correctness

You are a senior Go reviewer paid to find bugs that ship. Limit findings to the diff
plus the migration runtime path. Apply this severity bar:

- **CRITICAL** — provable wrong behavior under normal operation, or a
  data-loss / data-corruption pattern in the migration.
- **HIGH** — a correctness bug that would fire under specific real-world
  inputs (race, panic-on-nil, wrong column count, broken sql query,
  silent ignore of a return value that's load-bearing).
- **MEDIUM** — pattern that *could* break under refactor or atypical
  driver behavior; missing test for a non-obvious branch.
- **LOW / IGNORE** — style, naming, comment polish, alternative idioms
  with no behavior delta. Do not file.

## Concrete things to look for

1. **Migration atomicity.** The `ensureUsageEventsCompositePK` rebuild
   runs `CREATE`, `INSERT ... SELECT`, `DROP`, `ALTER ... RENAME`,
   then four `CREATE INDEX/TRIGGER` inside a single transaction. Are
   any of those DDL statements implicit-commit on the modernc SQLite
   driver? Will a failure in step 3 (DROP) actually roll back? Does
   `PRAGMA foreign_keys = OFF` inside a transaction work as
   expected?
2. **Column-order assumption.** The `INSERT INTO usage_events_new
   SELECT ... FROM usage_events` selects 10 named columns explicitly
   — is the column list complete vs the legacy schema? Are CHECK
   constraints preserved?
3. **PK-shape detection.** `ensureUsageEventsCompositePK` reads
   `PRAGMA table_info` and inspects `pk > 0`. Confirm SQLite reports
   pk=1 for a single-column PK and pk=1, pk=2 for a composite. What
   about a future amendment that adds a third PK column?
4. **`EnsureUsageEvent` payload-verify.** The lookup query changed
   from `WHERE request_id = ?` to `WHERE account_id = ? AND
   request_id = ?`. Does this work for every call site? Are there
   any callers that don't have `event.AccountID` populated?
5. **`INSERT OR IGNORE` semantics under composite PK.** Same
   `(account_id, request_id)` retry must no-op (same-account
   idempotency); different `(account_id, request_id)` must insert a
   new row. The new test asserts both. Are there race scenarios the
   tests miss (e.g., two goroutines retrying the same
   `(account, request)` concurrently)?
6. **Idempotency of the migration.** Running `Migrate()` twice on a
   freshly-built composite-PK DB must be a no-op. Running it on a
   half-migrated DB (e.g., process killed mid-rebuild) — what
   happens? Is `usage_events_new` left over?
7. **`Migrate()` ordering.** `ensureUsageEventsCompositePK` runs
   AFTER `schemaSQL`. On a new install, schemaSQL creates the table
   with the composite PK directly, so the upgrade function detects
   it and returns. On an old install, schemaSQL is a no-op (CREATE
   IF NOT EXISTS), then the upgrade runs. Both paths converge.
   Confirm there's no DB state where this ordering produces a
   broken result.
8. **Test coverage.** Three new tests in `usage_events_pk_test.go`
   plus one updated test in `server_test.go`. Are any code paths in
   the new function untested? Specifically the
   `len(pkCols) != 1 || pkCols[0].name != "request_id"` defensive
   bail.

## Output format

Return findings as a JSON-friendly markdown block with this shape:

```
SEVERITY: <CRITICAL|HIGH|MEDIUM>
TITLE: <short>
FILE: <path>:<line>
DETAIL: <why this is wrong, concrete trigger if needed>
SUGGESTED FIX: <one-line>
```

If 0 findings, output exactly: `0 CRITICAL / 0 HIGH / 0 MEDIUM`.

## R2 update — what changed since R1

- Rebased onto current main (ad76194 includes #193 — drops the R1 stale-base false positives).
- Added `usageEventsAuxiliaryDDL` shared constant — Migrate() and ensureUsageEventsCompositePK() both execute it; sqlite_master entries byte-equal.
- Added `maxKnownSchemaVersion = 2` + `checkSchemaVersionGate` — Open refuses if DB has a higher version (rollback safety).
- Added `accountID` param to `ExplorerSessionDetail` + ambiguity detection.
- Filed #210 (demo_usage_events) and #211 (coord request_log) as out-of-scope follow-ups.

Re-audit the diff vs ad76194 against the same severity bar.

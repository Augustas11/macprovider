# SPEC-017 Step 1 IMPL CODE Audit — Round 1

Audit target: `impl/spec-017-step-1` (`HEAD` against `origin/main`) from the CODE lens.

Locked contract: SPEC-017 v0.1.8 plus `BUILD_SPEC_017_IMPL_PROMPT.md` Step 1.

## A. Migration SQL Correctness — BLOCKED

The table shapes mostly match the locked schema: `IF NOT EXISTS` is used, `TIMESTAMPTZ` and `NUMERIC(18,2)` are present where required, health bootstrap seeds all seven components, and the v0.1.7 `blocked_from_partner_projection` stub exists. Blocking issue is grant hygiene, covered in B because it is role SQL.

## B. Role Grants SQL Correctness — BLOCKED

### HIGH B1 — Grant migration documents `PUBLIC` revocation but never revokes from `PUBLIC`

File: `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:13`

Evidence:

```sql
-- Defense-in-depth: REVOKE ALL FROM PUBLIC before any GRANT so
-- default permissive privileges on PUBLIC do not leak past the
-- role boundary (BUILD §B.3).
REVOKE ALL ON SCHEMA public FROM stats_reader;
```

The migration repeats the same pattern for `stats_rollup` and `provider_portal`, but those statements revoke from the runtime roles, not from `PUBLIC`. The Step 1 audit prompt makes `REVOKE ALL ... FROM PUBLIC` before grants a HIGH requirement because default privileges must not leak around the runtime-role inventory.

Minimal fix: before runtime-role grants, explicitly revoke `PUBLIC` on the schema, all Step 1 tables, and Step 1 sequences, e.g. `REVOKE ALL ON SCHEMA public FROM PUBLIC`, `REVOKE ALL ON TABLE ... FROM PUBLIC`, and `REVOKE ALL ON SEQUENCE stats_late_events_id_seq, provider_visibility_audit_id_seq, partner_keys_id_seq FROM PUBLIC`; then keep explicit role grants.

## C. Migration Runner Code — BLOCKED

### CRITICAL C1 — Version tracking is race-prone; concurrent runners can both decide the same migration is unapplied

File: `phase4-coordinator/internal/stats/migrations/migrations.go:103`

Evidence:

```go
applied, err := loadApplied(ctx, db)
...
for _, m := range migrations {
    if _, ok := applied[m.Version]; ok {
        continue
    }
    if err := applyOne(ctx, db, m); err != nil {
```

`Apply` creates the version table, reads all applied versions into memory, then runs each missing migration without any advisory lock or serializable re-check. Two coordinator/migration processes can both observe version N as missing, execute the same DDL/role block concurrently, and then race on `INSERT INTO schema_migrations_spec017`. The prompt classifies race-prone version tracking as CRITICAL for Step 1 because this is the migration surface future Postgres steps inherit.

Minimal fix: serialize the whole migration run with a Postgres advisory lock, such as `pg_advisory_lock(hashtext('spec017_migrations'))`, held on one connection for the duration of `Apply`; or run each version claim under a transaction that locks the migrations table and re-checks the row before executing the body. Add an integration test that starts two concurrent `Apply` calls against the same Postgres and requires both to return success with one recorded row per version.

### HIGH C2 — Coordinator boot applies migrations through the `stats_rollup` runtime pool by default

File: `phase4-coordinator/cmd/coordinator/main.go:157`

Evidence:

```go
statsPools, err = stats.Open(context.Background(), statsCfg)
...
if os.Getenv("STATS_SKIP_MIGRATIONS_AT_BOOT") != "1" {
    if err := statsmigrations.Apply(context.Background(), statsPools.Rollup); err != nil {
```

The migration package itself says callers must use a role with `CREATE / GRANT / REVOKE` privileges and that runtime roles are not migration-capable (`phase4-coordinator/internal/stats/migrations/migrations.go:97`). Running migrations with `stats_rollup` either fails on normal locked grants or pressures operators to over-privilege the rollup role. That is a bad first Postgres pattern for Step 2 to inherit.

Minimal fix: remove boot-time migrations from the runtime coordinator path, or add a separate migration/admin DSN used only by an explicit migration command or pre-listener bootstrap before runtime pools open. Do not use `stats_rollup`, `stats_reader`, or `provider_portal` for migration DDL/grants.

## D. main.go Integration — BLOCKED

### HIGH D1 — Startup smoke only pings; it does not prove DSNs map to the required roles or fail deny-list queries

File: `phase4-coordinator/internal/stats/stats.go:273`

Evidence:

```go
func smoke(ctx context.Context, p *Pools) error {
    ...
    for _, item := range pools {
        if err := item.db.PingContext(timeout); err != nil {
            return fmt.Errorf("smoke %s: %w", item.name, err)
        }
    }
    return nil
}
```

BUILD Step 1 requires startup smoke that each active pool can connect with its role and fails to query a deny-list table. A plain `PingContext` accepts a miswired DSN such as all three pools pointing at `stats_rollup` or a superuser. The `Pools` struct holds independent `*sql.DB` objects, but startup does not verify the role boundary that those pools are supposed to enforce.

Minimal fix: during smoke, assert `SELECT current_user` equals the expected role for each pool and run role-specific deny probes that must return SQLSTATE `42501` rather than success or relation-missing. At minimum, cover `stats_reader` denied on `ledger_request_credits`, `provider_portal` denied on a `stats_*` table, and `stats_rollup` denied on `partner_keys` / `provider_visibility_audit`. Add a real-Postgres integration test that exercises `stats.Open`, not just direct `sql.Open` calls.

## E. depguard / Lint Config + Makefile/CI — PASS WITH LOCAL GAP

The depguard and forbidigo config exists in `phase4-coordinator/.golangci.yml`, `make lint-coordinator` runs it, and CI has an unconditional `coordinator-lint` job. The AC-16 fixture is a valid tagged Go file and `lint_test.go` asserts `depguard` plus the forbidden import name.

Local verification gap: `golangci-lint` is not installed in this environment, so I could not execute `make lint-coordinator` locally. CI installs `golangci-lint@v1.62.2`.

## F. Tests (AC-9, AC-10, AC-16, AC-19, AC-20) — PASS WITH LOCAL GAP

The integration tests use testcontainers-go and cover AC-9, AC-10 commit/rollback, AC-19, AC-20, container cleanup via `t.Cleanup`, and grant deny checks. CI runs `make test-coordinator-integration` on every PR.

Local verification gap: `go test -tags=integration -run TestMigrationsIdempotent -timeout 5m ./internal/stats/...` could not run here because Docker is unavailable and testcontainers panicked with `rootless Docker not found`.

## G. Dependency Hygiene — PASS

Production code adds one Postgres driver, `github.com/lib/pq`. `pgx` appears only transitively through testcontainers in `go.sum`, not as a direct production driver. testcontainers imports are isolated to `//go:build integration` tests, so default `go test ./...` does not require Docker.

## Verification Performed

- `make test-coordinator` — PASS
- `make vet-coordinator` — PASS
- `cd phase4-coordinator && go test ./internal/stats/...` — PASS
- `cd phase4-coordinator && go vet ./internal/stats/...` — PASS
- `make lint-coordinator` — NOT RUN: `golangci-lint` not installed locally
- `cd phase4-coordinator && go test -tags=integration -run TestMigrationsIdempotent -timeout 5m ./internal/stats/...` — NOT RUN: Docker unavailable (`rootless Docker not found`)

## Final Verdict

Counts:

- CRITICAL: 1
- HIGH: 3
- MEDIUM: 0
- LOW: 0
- INFO: 0

Verdict: NOT READY TO LOCK.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM.

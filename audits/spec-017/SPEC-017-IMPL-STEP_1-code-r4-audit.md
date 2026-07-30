# SPEC-017 Step 1 IMPL CODE Audit — Round 4

Audit target: `impl/spec-017-step-1` (`HEAD` at `00c5301`, diff against `origin/main`) from the CODE lens.

Locked contract: SPEC-017 v0.1.8 plus `BUILD_SPEC_017_IMPL_PROMPT.md` Step 1.

Round-3 closure check: the previous HIGH lint/CI install blocker is closed. The Makefile hint, CI install command, and lint-test skip messages now use the valid v2 module path:

```text
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2
```

Local verification confirmed that path resolves and the installed binary is `golangci-lint` v2.12.2.

## A. Migration SQL Correctness — PASS

The Step 1 SQL uses `CREATE TABLE IF NOT EXISTS` for every table and `CREATE INDEX IF NOT EXISTS` for Step 1 indexes. Required locked shapes match: `TIMESTAMPTZ` is used for timestamp fields, USD totals use `NUMERIC(18,2)`, audit / partner / late-event / rewards ids are `BIGSERIAL`, and `provider_id` plus `pseudonym` are `TEXT`.

`stats_components_health` uses `component` as `PRIMARY KEY`, constrains the seven locked component values, and `002_bootstrap_health_and_rewards.up.sql` seeds all seven rows. Leaderboard rank indexes exist for `rank_earnings`, `rank_tokens`, and `rank_jobs`; timeseries tables use `bucket_start` as the primary key. The named BIGSERIAL sequences (`stats_late_events_id_seq`, `provider_visibility_audit_id_seq`, `partner_keys_id_seq`) exist through explicit table names and match grant targets. `provider_visibility.blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT FALSE` is present.

## B. Role Grants SQL Correctness — PASS

Grant migrations run after table creation. `004_grants.up.sql` revokes from `PUBLIC` on schema, tables, sequences, and functions before granting runtime roles, and `003_roles.up.sql` revokes default privileges for future tables/sequences from the runtime roles. `stats_reader` grants are enumerated and limited to the request-path tables plus implementation-authored `stats_rewards_populated`; no `stats_late_events`, `provider_rewards_ledger`, or audit-table grant is present. `stats_rollup` has the locked stats write surface plus `provider_visibility` / `provider_rewards_ledger` reads and `stats_late_events_id_seq`; it is explicitly denied `partner_keys` and `provider_visibility_audit`. `provider_portal` has only the visibility/audit insert-update surface and the audit sequence grant.

`partner_keys_writer` is intentionally not created in v0.1, matching the BUILD prompt resolution for `last_used_at_updates_enabled = false`.

## C. Migration Runner Code — PASS

Migrations are embedded with `//go:embed`, loaded in version order, and applied through `migrations.Apply`. The runner creates `schema_migrations_spec017` if missing, serializes the whole run with a Postgres advisory lock on one connection, and applies each migration body plus version insert in one transaction. Coordinator runtime boot does not call `Apply` through a runtime-role pool.

Default tests cover embedded migration loading and schema-shape checks. Integration tests cover second-run idempotency and concurrent `Apply` calls against real Postgres, but could not be run locally because Docker is unavailable.

## D. main.go Integration — PASS

When `stats.enabled = false`, `cmd/coordinator/main.go` skips `stats.Open`; Step 1 still does not mount `/v1/stats/*`, so the disabled path remains the existing mux fallback. When enabled, `stats.Open` requires independent DSNs for `stats_reader`, `stats_rollup`, and `provider_portal`, opens separate `*sql.DB` instances, applies explicit pool tuning, and runs per-pool smoke checks before listener startup. `main.go` defers `statsPools.Close()`.

Startup smoke asserts `current_user` for each role, catches duplicate Postgres users across pools, checks each role's positive grant, and requires permission-denied on a deny-list query. `partner_keys_writer_dsn` is only consulted when `stats.partner_keys.last_used_at_updates_enabled = true`. `partner_keys_admin_dsn` is plumbed as config only and is not opened at coordinator startup.

## E. depguard / Lint Config + Makefile/CI — PASS

`.golangci.yml` uses the golangci-lint v2 schema, enables `depguard` and `forbidigo`, and defines the two SPEC-017 import boundaries. The rollup rule now also forbids `internal/auth`, matching the round-3 architecture fix. `forbidigo` is scoped to `internal/stats/*` and bans `os.Exit`, `log.Fatal`, and `log.Fatalf`.

`make lint-coordinator` runs `golangci-lint run --config=.golangci.yml ./...`. CI installs `golangci-lint` from the valid v2 module path, runs the lint target on every PR, then runs the fixture assertion tests. The tagged fixtures are valid Go files: one imports forbidden `internal/billing`, and one calls `os.Exit(1)`. The tests assert the named lint output contains `depguard` / `forbidigo` and the fixture evidence.

## F. Tests (AC-9, AC-10, AC-16, AC-19, AC-20) — PASS WITH LOCAL GAP

AC-16 runs in the default package test lane when `golangci-lint` is installed and is explicitly re-run in CI after installing the pinned binary.

The integration suite is build-tagged with `integration`, uses testcontainers-go to start real Postgres, and registers `t.Cleanup` container termination. Code-read confirms coverage for:

- AC-9: `stats_reader` denied on `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`, and `provider_tokens`, asserting permission denied and rejecting relation-missing errors.
- AC-10: provider-portal commit and rollback subcases, including `mode = 'exact'`, `blocked_from_partner_projection = FALSE`, and audit row count.
- AC-19: no-row `provider_visibility` left join defaults to `mode = 'bucketed'` and `blocked = FALSE`.
- AC-20: SQL assertion rejects `actor_kind = 'operator' AND new_mode = 'exact'`.
- Migration idempotency, concurrent migration application, provider-portal deny on stats tables, and stats-rollup deny on partner/audit tables.

Local gap: Docker is not available in this environment, so the real-Postgres integration command failed before test execution with `rootless Docker not found`. The CI `coordinator-stats-integration` job is unconditional and runs `make test-coordinator-integration` on `ubuntu-latest`, where Docker is available.

## G. Dependency Hygiene — PASS

Production code adds a single Postgres driver, `github.com/lib/pq`, registered in `cmd/coordinator/main.go`. `pgx` appears only transitively in `go.sum` through testcontainers. `testcontainers-go` imports are isolated to `//go:build integration` tests, so default `go test ./...` does not require Docker. `go vet` passes on the touched stats/coordinator surface.

## Verification Performed

- `make test-coordinator` — PASS
- `make vet-coordinator` — PASS
- `cd phase4-coordinator && go test ./internal/stats/...` — PASS
- `cd phase4-coordinator && go test -count=1 ./internal/stats/...` — PASS
- `cd phase4-coordinator && go test -count=1 ./internal/config -run 'Stats|Config|Validate|Load'` — PASS
- `cd phase4-coordinator && go vet ./internal/stats/... ./cmd/coordinator` — PASS
- `cd phase4-coordinator && go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2` — PASS
- `cd phase4-coordinator && go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2 config verify --config=.golangci.yml` — PASS
- `cd phase4-coordinator && go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2 run --config=.golangci.yml ./...` — PASS, `0 issues`
- `make lint-coordinator` — PASS, `0 issues`
- `cd phase4-coordinator && go test -count=1 -run 'TestAC16ForbiddenImportFails|TestForbidigoOSExitRule' ./internal/stats/` — PASS
- `cd phase4-coordinator && go test -tags=integration -run 'TestAC9|TestAC10|TestAC19|TestAC20|TestMigrationsIdempotent|TestMigrationsConcurrent|TestProviderPortalCannotReadStats|TestStatsRollupCannotTouchPartnerKeys' -timeout 5m ./internal/stats/...` — NOT RUN to completion locally: Docker unavailable (`rootless Docker not found`)

## Final Verdict

Counts:

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0
- INFO: 0

Verdict: READY TO LOCK.

`READY TO LOCK` because the CODE lane is at 0 CRITICAL + 0 HIGH + 0 MEDIUM.

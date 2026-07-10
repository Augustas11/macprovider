# SPEC-017 Step 1 IMPL CODE Audit — Round 2

Audit target: `impl/spec-017-step-1` (`HEAD` at `0b3e87b`, diff against `origin/main`) from the CODE lens.

Locked contract: SPEC-017 v0.1.8 plus `BUILD_SPEC_017_IMPL_PROMPT.md` Step 1.

Round-1 closure check: the previously flagged `PUBLIC` revoke, migration concurrency, boot-time migration role, and startup smoke gaps are closed in this diff.

## A. Migration SQL Correctness — PASS

The Step 1 tables are created with `IF NOT EXISTS`; required timestamp, money, text, and BIGSERIAL shapes match the locked schema; `stats_components_health` has `component` as primary key and all seven bootstrap rows; leaderboard rank indexes and timeseries primary-key indexes exist; `provider_visibility.blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT FALSE` is present.

## B. Role Grants SQL Correctness — PASS

Grant ordering is correct: role creation precedes grants, and grants follow table creation. `004_grants.up.sql` now revokes from `PUBLIC` before role grants, grants the enumerated request-path and rollup surfaces including the implementation-authored `stats_rewards_populated` lookup table, and does not grant `partner_keys` or `provider_visibility_audit` to `stats_rollup`. `003_roles.up.sql` intentionally omits `partner_keys_writer` for v0.1.

## C. Migration Runner Code — PASS

Migrations are embedded with `//go:embed`, each migration body and its version row are committed in one transaction, `schema_migrations_spec017` is created if missing, and the whole `Apply` call is serialized with a Postgres advisory lock. The runner is no longer used from coordinator boot through a runtime pool.

## D. main.go Integration — PASS

When `stats.enabled = false`, `main.go` does not call `stats.Open` and does not mount `/v1/stats/*`. When enabled, `stats.Open` requires the three runtime DSNs, opens independent `*sql.DB` instances, tunes pool sizes/lifetimes, runs role/deny-list smoke before listener startup, and `main.go` defers `statsPools.Close()`. The CLI admin DSN is plumbed but not opened at coordinator startup; the writer DSN is only required when `last_used_at_updates_enabled = true`.

## E. depguard / Lint Config + Makefile/CI — BLOCKED

### HIGH E1 — Pinned `golangci-lint@v1.62.2` does not accept the committed config and the lint target cannot pass on clean Step 1 code

File: `phase4-coordinator/.golangci.yml:28`

Evidence:

```yaml
linters:
  default: none
  enable:
    - depguard
    - forbidigo
```

File: `phase4-coordinator/.golangci.yml:66`

Evidence:

```yaml
forbidigo:
  forbid:
    - pattern: 'os\.Exit'
      msg: "SPEC-017 §7.3 — internal/stats/* must not call os.Exit; propagate errors to cmd/coordinator/main.go"
```

Verification evidence:

```text
$ cd phase4-coordinator && go run github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2 config verify --config=.golangci.yml
jsonschema: "linters" ... additionalProperties 'default' not allowed
jsonschema: "linters-settings.forbidigo.forbid.0" ... expected string, but got object
jsonschema: "linters-settings.forbidigo" ... additionalProperties 'exclude_godoc_examples' not allowed
```

`golangci-lint run --config=.golangci.yml ./internal/stats/...` also fails on clean source before any fixture is involved, producing forbidigo diagnostics against ordinary identifiers such as `package stats`, `bool`, `string`, and `sql.DB`. That means `make lint-coordinator` and the CI `coordinator-lint` job do not prove the AC-16 depguard boundary; they fail because the config shape is wrong for the pinned linter version.

Why: AC-16 requires a compilable fixture to trip depguard/forbidigo by name. A lint config that is rejected or misparsed by the pinned linter is equivalent to the rule not firing on the named import; the CI job cannot distinguish real import-boundary regressions from config failure.

Minimal fix: rewrite `.golangci.yml` to the `golangci-lint@v1.62.2` schema, e.g. use `linters.disable-all: true` instead of `linters.default: none`, and express forbidigo rules in the v1-supported format. Then run:

```text
cd phase4-coordinator && go run github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2 config verify --config=.golangci.yml
make lint-coordinator
cd phase4-coordinator && go test -count=1 -run 'TestAC16ForbiddenImportFails|TestForbidigoOSExitRule' ./internal/stats/
```

## F. Tests (AC-9, AC-10, AC-16, AC-19, AC-20) — PASS WITH LOCAL GAP

The integration tests are build-tagged with `integration`, use testcontainers-go, terminate containers with `t.Cleanup`, and cover AC-9, AC-10 commit/rollback, AC-19, AC-20, migration idempotency, and concurrent migration application. CI runs `make test-coordinator-integration` on every PR. AC-16 test intent is present but blocked by E1 until the pinned lint config is fixed.

Local gap: Docker is not running in this environment, so the integration suite could not start Postgres and panicked with `rootless Docker not found`.

## G. Dependency Hygiene — PASS

Production code adds a single direct Postgres driver, `github.com/lib/pq`. `pgx` appears only as a transitive testcontainers dependency. testcontainers imports are isolated to `//go:build integration` tests, so default `go test ./...` does not require Docker.

## Verification Performed

- `make test-coordinator` — PASS
- `make vet-coordinator` — PASS
- `make lint-coordinator` — NOT RUN locally to completion: `golangci-lint` binary not installed
- `cd phase4-coordinator && go run github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2 config verify --config=.golangci.yml` — FAIL, config rejected
- `cd phase4-coordinator && go run github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2 run --config=.golangci.yml ./internal/stats/...` — FAIL, forbidigo misfires on clean source due config schema mismatch
- `cd phase4-coordinator && go test -tags=integration -run 'TestAC9|TestAC10|TestAC19|TestAC20|TestMigrationsIdempotent|TestMigrationsConcurrent|TestProviderPortalCannotReadStats|TestStatsRollupCannotTouchPartnerKeys' -timeout 5m ./internal/stats/...` — NOT RUN to completion: Docker unavailable (`rootless Docker not found`)

## Final Verdict

Counts:

- CRITICAL: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 0
- INFO: 0

Verdict: NOT READY TO LOCK.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM.

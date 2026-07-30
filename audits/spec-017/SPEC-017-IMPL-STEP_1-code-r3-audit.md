# SPEC-017 Step 1 IMPL CODE Audit — Round 3

Audit target: `impl/spec-017-step-1` (`HEAD` at `21d3c2a`, diff against `origin/main`) from the CODE lens.

Locked contract: SPEC-017 v0.1.8 plus `BUILD_SPEC_017_IMPL_PROMPT.md` Step 1.

Round-2 closure check: the previous lint-config blocker is partially closed. The committed `.golangci.yml` verifies and runs cleanly under the correct `golangci-lint` v2.12.2 binary, and the AC-16 fixture tests pass when that binary is present. The remaining blocker is the committed CI/local install command for that pinned binary.

Codex cross-check: `omc ask codex` artifact `.omc/artifacts/ask/codex-code-audit-cross-check-for-spec-017-step-1-pr-impl-spec-017--2026-06-26T07-27-49-760Z.md` independently confirmed the same HIGH finding and minimal fix.

## A. Migration SQL Correctness — PASS

The Step 1 tables are created with `IF NOT EXISTS`; required timestamp, money, text, and BIGSERIAL shapes match the locked schema; `stats_components_health` has `component` as primary key and all seven bootstrap rows; leaderboard rank indexes and timeseries primary-key indexes exist; `provider_visibility.blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT FALSE` is present.

## B. Role Grants SQL Correctness — PASS

Grant ordering remains correct: role creation precedes grants, and grants follow table creation. `004_grants.up.sql` revokes from `PUBLIC` before role grants, grants the enumerated request-path and rollup surfaces including the implementation-authored `stats_rewards_populated` lookup table, and does not grant `partner_keys` or `provider_visibility_audit` to `stats_rollup`. `003_roles.up.sql` intentionally omits `partner_keys_writer` for v0.1.

## C. Migration Runner Code — PASS

Migrations are embedded with `//go:embed`, each migration body and its version row are committed in one transaction, `schema_migrations_spec017` is created if missing, and the whole `Apply` call is serialized with a Postgres advisory lock. Coordinator boot does not apply migrations through a runtime-role pool.

## D. main.go Integration — PASS

When `stats.enabled = false`, `main.go` does not call `stats.Open` and does not mount `/v1/stats/*`. When enabled, `stats.Open` requires the three runtime DSNs, opens independent `*sql.DB` instances, tunes pool sizes/lifetimes, runs role/deny-list smoke before listener startup, and `main.go` defers `statsPools.Close()`. The CLI admin DSN is plumbed but not opened at coordinator startup; the writer DSN is only required when `last_used_at_updates_enabled = true`.

## E. depguard / Lint Config + Makefile/CI — BLOCKED

### HIGH E1 — CI installs the pinned golangci-lint binary from an invalid module path, so the AC-16 job fails before lint or fixture assertions run

File: `Makefile:29`

Evidence:

```make
echo "golangci-lint not found; install: go install github.com/golangci/golangci-lint/cmd/golangci-lint/v2/cmd/golangci-lint@v2.12.2"; \
```

File: `.github/workflows/ci.yml:153`

Evidence:

```yaml
go install github.com/golangci/golangci-lint/cmd/golangci-lint/v2/cmd/golangci-lint@v2.12.2
```

Verification evidence:

```text
$ cd phase4-coordinator && go install github.com/golangci/golangci-lint/cmd/golangci-lint/v2/cmd/golangci-lint@v2.12.2
go: github.com/golangci/golangci-lint/cmd/golangci-lint/v2/cmd/golangci-lint@v2.12.2: invalid version: unknown revision cmd/golangci-lint/v2/cmd/golangci-lint/v2.12.2
```

The correct v2 module path resolves:

```text
$ cd phase4-coordinator && go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2 version
golangci-lint has version 2.12.2 ...
```

Why: E.3 requires the new lint target to run on every PR, and AC-16 requires CI to prove the depguard/forbidigo boundary with named diagnostics. On a clean GitHub runner, the `coordinator-lint` job reaches this invalid `go install` command before `make lint-coordinator` and before `TestAC16ForbiddenImportFails|TestForbidigoOSExitRule`; the job fails for tool-install plumbing, not for the named lint rule. That leaves the Step 1 import-boundary gate unproven in CI.

Minimal fix: replace every install hint/command with the valid v2 path:

```text
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2
```

At minimum, update `.github/workflows/ci.yml:153`, `Makefile:29`, and the skip messages in `phase4-coordinator/internal/stats/lint_test.go:36` and `phase4-coordinator/internal/stats/lint_test.go:82`.

## F. Tests (AC-9, AC-10, AC-16, AC-19, AC-20) — PASS WITH LOCAL GAP

The integration tests remain build-tagged with `integration`, use testcontainers-go, terminate containers with `t.Cleanup`, and cover AC-9, AC-10 commit/rollback, AC-19, AC-20, migration idempotency, and concurrent migration application. CI declares an unconditional `coordinator-stats-integration` job. AC-16 fixture assertions pass locally when the correct `golangci-lint` v2.12.2 binary is available, but CI execution is blocked by E1 until the install path is fixed.

Local gap: Docker is not running in this environment, so the integration suite could not start Postgres and panicked with `rootless Docker not found`.

## G. Dependency Hygiene — PASS

Production code adds a single direct Postgres driver, `github.com/lib/pq`. `pgx` appears only as a transitive testcontainers dependency. testcontainers imports are isolated to `//go:build integration` tests, so default `go test ./...` does not require Docker.

## Verification Performed

- `make test-coordinator` — PASS
- `make vet-coordinator` — PASS
- `make lint-coordinator` — PASS locally because `golangci-lint` v2.12.2 is already on PATH
- `cd phase4-coordinator && go install github.com/golangci/golangci-lint/cmd/golangci-lint/v2/cmd/golangci-lint@v2.12.2` — FAIL, invalid module path
- `cd phase4-coordinator && go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2 config verify --config=.golangci.yml` — PASS
- `cd phase4-coordinator && go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2 run --config=.golangci.yml ./...` — PASS, `0 issues`
- `cd phase4-coordinator && go test -count=1 -run 'TestAC16ForbiddenImportFails|TestForbidigoOSExitRule' ./internal/stats/` — PASS with `golangci-lint` v2.12.2 on PATH
- `cd phase4-coordinator && go test -tags=integration -run 'TestAC9|TestAC10|TestAC19|TestAC20|TestMigrationsIdempotent|TestMigrationsConcurrent|TestProviderPortalCannotReadStats|TestStatsRollupCannotTouchPartnerKeys' -timeout 5m ./internal/stats/...` — NOT RUN to completion: Docker unavailable (`rootless Docker not found`)
- `omc ask codex --print ...` — PASS, advisor confirmed HIGH E1

## Final Verdict

Counts:

- CRITICAL: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 0
- INFO: 0

Verdict: NOT READY TO LOCK.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM.

# SPEC-017 IMPL Step 1 architecture audit — round 4

Audit target: `impl/spec-017-step-1` Step 1 implementation diff (`origin/main...HEAD`, HEAD `00c5301`, PR Augustas11/macprovider#173).

Prior-round status: the round-3 architecture finding is closed. The rollup depguard rule now denies `internal/auth` in `phase4-coordinator/.golangci.yml:66-67`, preserving the Step 2 import boundary unless a future SPEC-bumped allowlist names a narrower helper.

Validation evidence:
- `go test ./internal/stats/...` passed.
- `golangci-lint run --config=.golangci.yml ./...` passed with `0 issues`.
- `go test -count=1 -run 'TestAC16ForbiddenImportFails|TestForbidigoOSExitRule' ./internal/stats/` passed.
- `make test-coordinator-integration` could not run locally because testcontainers panicked before starting Postgres: `rootless Docker not found`. The PR workflow still runs `make test-coordinator-integration` in the unconditional `coordinator-stats-integration` job.

## A. Schema correctness — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

The migrations still encode the locked §9.1 / §6.1 / §6.5 / §5.4.1 schema shape. `001_stats_tables.up.sql` creates the required overview, split timeseries, four leaderboard tables, `stats_components_health`, `stats_late_events`, `provider_visibility`, `provider_visibility_audit`, `partner_keys`, `provider_rewards_ledger`, and the chosen `stats_rewards_populated` storage. It omits `stats_rollup_state`, the removed leaderboard `earnings_work_bucket` / `earnings_rewards_bucket` columns, `stats_components_health.status`, and `partner_keys.rate_limit_burst`. `002_bootstrap_health_and_rewards.up.sql` pre-seeds all seven health components and all four rewards-populated windows with sentinel rows.

## B. Postgres role inventory — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

The grant inventory remains aligned with locked §7.2. `stats_reader` gets the request-path SELECT set plus `stats_rewards_populated`; `stats_rollup` gets SELECT/INSERT/UPDATE/DELETE on the rollup-owned writer set plus `stats_rewards_populated`, SELECT on `provider_visibility` and `provider_rewards_ledger`, and sequence use only for `stats_late_events_id_seq`; `provider_portal` gets visibility writes, audit INSERT, and `provider_visibility_audit_id_seq` use. There are no TRUNCATE / ALTER / DROP grants and no unconditional `partner_keys_writer` role. The IMPL-authored OLTP source grants are limited to the BUILD-pinned SPEC-005 v0.3 typical source set plus SPEC-002 `provider_tokens`.

## C. DB-connection mechanics — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

`internal/stats.Open` opens one `*sql.DB` per active runtime role, requires the three runtime DSNs only when `stats.enabled = true`, gates `partner_keys_writer` on `stats.partner_keys.last_used_at_updates_enabled`, and smoke-tests role identity plus positive/deny probes. `cmd/coordinator/main.go` no longer runs migrations through a runtime pool, does not instantiate `partner_keys_admin_dsn`, and keeps `/v1/stats/*` unregistered when stats are disabled.

## D. Package layout + import-graph lint — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

The pinned package layout is present: flat `internal/stats`, `internal/stats/store`, `internal/stats/rollup`, and `internal/stats/migrations`. The depguard config enforces request-path and rollup boundaries, including the round-3 `internal/auth` denial for rollup, and forbidigo bans `os.Exit`, `log.Fatal`, and `log.Fatalf` under `internal/stats/*`. The AC-16 fixture is a compilable build-tagged import of `internal/billing` and the targeted test asserts the `depguard` diagnostic by name.

## E. Test coverage — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

Step 1 tests cover the required architecture-owned ACs: AC-9 permission-denied checks against the SPEC-005 / SPEC-002 OLTP stubs, AC-10 commit and rollback provider-visibility paths with `blocked_from_partner_projection = FALSE`, AC-16 named lint fixtures, AC-19 left-join no-row default tuple, and AC-20 zero operator-exact audit rows. The integration suite could not be executed on this local host due to missing Docker, but CI wires it as an every-PR job rather than an optional local-only suite.

## F. Cross-step seams to Step 2/3/4 — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

Step 1 declares the later-step config seams (`stats.enabled`, rollup backfill/partial-history/retention, optional partner-key last-used updates, CORS max age/allowlist, trusted proxies, and the separate partner-key admin DSN) without landing concrete handlers, rollup tick SQL, partner-key CLI commands, nginx config, or unexpected production dependencies beyond the allowed Postgres driver, testcontainers-go, and lint tooling path.

```text
Verdict: READY TO LOCK
CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO: 0
```

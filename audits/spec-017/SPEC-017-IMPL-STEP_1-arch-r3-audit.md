# SPEC-017 IMPL Step 1 architecture audit — round 3

Audit target: `impl/spec-017-step-1` Step 1 implementation diff (`origin/main...HEAD`, HEAD `21d3c2a`).

Prior-round status: the round-1 DB startup/smoke and AC-16 CI findings are closed. The round-2 golangci-lint v1/v2 syntax blocker is closed; the current CI path pins and runs golangci-lint `v2.12.2`.

Validation evidence:
- `go test ./internal/stats/...` passed.
- `golangci-lint run --config=.golangci.yml ./...` passed under golangci-lint `2.12.2`.
- `go test -count=1 -run 'TestAC16ForbiddenImportFails|TestForbidigoOSExitRule' ./internal/stats/` passed.
- `make test-coordinator-integration` could not run locally because testcontainers panicked before starting Postgres: `rootless Docker not found`. The workflow still runs this suite on PR via `.github/workflows/ci.yml`.

## A. Schema correctness — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

The Step 1 migrations encode the locked §9.1 tables without the removed leaderboard earnings-bucket columns, without `stats_components_health.status`, and without `partner_keys.rate_limit_burst`. `provider_visibility` includes the `blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT FALSE` stub, `provider_visibility_audit` uses `BIGSERIAL id`, and `stats_rewards_populated` provides the pinned rewards-populated storage seam. The bootstrap migration pre-seeds all seven `stats_components_health` rows with sentinel timestamps.

## B. Postgres role inventory — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

The role inventory matches the locked §7.2 shape: `stats_reader` receives request-path SELECT grants plus explicit denies, `stats_rollup` receives DML grants without TRUNCATE/ALTER/DROP and cannot read `partner_keys` or `provider_visibility_audit`, and `provider_portal` is limited to visibility writes plus audit insertion and sequence use. `partner_keys_writer` is intentionally not created by default.

## C. DB-connection mechanics — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

The implementation opens one runtime pool per active role when `stats.enabled = true`, treats `partner_keys_writer_dsn` as conditional on `stats.partner_keys.last_used_at_updates_enabled`, and fail-closes on missing required DSNs or smoke-test failures. The Step 1 main path does not open the separate partner-key admin DSN and does not register `/v1/stats/*` while stats are disabled.

## D. Package layout + import-graph lint — 0 CRITICAL / 0 HIGH / 1 MEDIUM

### **[MEDIUM] Rollup depguard omits the internal/auth boundary**

**Where:** `phase4-coordinator/.golangci.yml:57`

**Evidence:**

```yaml
stats-rollup:
  list-mode: lax
  files:
    - "**/internal/stats/rollup/**/*.go"
  deny:
    - pkg: github.com/augstar/macprovider-coordinator/internal/explorer
    - pkg: github.com/augstar/macprovider-coordinator/internal/ws
    - pkg: github.com/augstar/macprovider-coordinator/internal/stats
    - pkg: github.com/augstar/macprovider-coordinator/internal/stats/store
```

**Why it matters:** BUILD §2 Step 1 pins the stats import graph before Step 2 lands: rollup may import only the read-only billing/session/pool source side and must not import `internal/auth` beyond a named Bearer-parser allowlist. Step 1 does not define an allowlist symbol, so omitting `internal/auth` from the rollup deny list lets two conforming Step 2 sessions make different architecture choices.

**Fix:** Add `github.com/augstar/macprovider-coordinator/internal/auth` to the `stats-rollup` depguard deny list now. If a later step truly needs a narrow Bearer parser helper, introduce that explicit allowlist in the same lint boundary change.

## E. Test coverage — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

AC-9, AC-10, AC-19, and AC-20 are covered by the stats integration suite, including the permission-denied OLTP probe, commit and rollback provider-visibility paths, the no-row default tuple, and the no operator-exact audit assertion. AC-16 now uses compilable lint fixtures and asserts the depguard diagnostic by name.

## F. Cross-step seams — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings.

Step 1 adds the config seams needed by later stats steps without committing HTTP handlers, rollup tick queries, partner-key CLI commands, nginx config, or unexpected direct dependencies beyond the allowed Postgres driver, testcontainers-go, and lint tooling path.

```
Verdict: NEEDS FIX
CRITICAL: 0
HIGH: 0
MEDIUM: 1
LOW: 0
INFO: 0
```

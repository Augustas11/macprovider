# SPEC-017 IMPL Step 1 architecture audit — round 1

Audit target: `impl/spec-017-step-1` Step 1 implementation diff (`origin/main...HEAD`).

## A. Schema correctness — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings. The Step 1 migrations create the locked SPEC-017 tables, omit the removed leaderboard bucket columns and `partner_keys.rate_limit_burst`, split `stats_components_health` into the seven locked components, omit a stored health `status`, include `provider_visibility.blocked_from_partner_projection`, use `BIGSERIAL` audit/key ids, create `provider_rewards_ledger`, and pin rewards-populated storage as `stats_rewards_populated`.

## B. Postgres role inventory — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings in the SQL grant inventory itself. The static migration grants match the locked §7.2 shape: `stats_reader` is read-only on the request-path set, `stats_rollup` gets DELETE+INSERT-compatible writer grants without TRUNCATE/ALTER/DROP, `provider_portal` gets only visibility/audit writes, and `partner_keys_writer` is skipped by default.

## C. DB-connection mechanics — 0 CRITICAL / 2 HIGH / 0 MEDIUM

### **[HIGH] Coordinator boot runs migrations through the `stats_rollup` runtime pool**

**Where:** `phase4-coordinator/cmd/coordinator/main.go:149`

**Evidence:**

```go
// Apply migrations using the rollup pool — it has CREATE
// privileges in development and test environments; in
// production the operator applies migrations out-of-band
// before coordinator boot (and SPEC-017 §F.2 SECURITY
// invariant: migrations MUST NOT run as a runtime role).
// Production deployments set
// STATS_SKIP_MIGRATIONS_AT_BOOT=1 to skip; default behavior
// for non-production keeps the bootstrap path frictionless.
if os.Getenv("STATS_SKIP_MIGRATIONS_AT_BOOT") != "1" {
    if err := statsmigrations.Apply(context.Background(), statsPools.Rollup); err != nil {
```

**Why it matters:** BUILD Step 1 separates schema/role migration from runtime role pools, and locked §7.2 gives `stats_rollup` only the rollup table DML/read grants, not `CREATE ROLE`, table creation, GRANT, or REVOKE authority. The current default boot path can only work if `stats_rollup` is privilege-widened beyond the locked inventory, or if every enabled deployment remembers an extra skip env var.

**Fix:** Remove boot-time migration execution from `cmd/coordinator/main.go`. Keep `statsmigrations.Apply` as an operator/test helper invoked with an admin/migration DSN outside the runtime role inventory, and make coordinator startup only open/smoke the three active runtime pools.

### **[HIGH] Startup smoke does not verify the configured DSNs are the locked roles**

**Where:** `phase4-coordinator/internal/stats/stats.go:273`

**Evidence:**

```go
func smoke(ctx context.Context, p *Pools) error {
    timeout, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()
    pools := []struct {
        name string
        db   *sql.DB
    }{
        {"stats_reader", p.Reader},
        {"stats_rollup", p.Rollup},
        {"provider_portal", p.ProviderPortal},
    }
    ...
    for _, item := range pools {
        if err := item.db.PingContext(timeout); err != nil {
            return fmt.Errorf("smoke %s: %w", item.name, err)
        }
    }
    return nil
}
```

**Why it matters:** BUILD §2 Step 1 requires per-role DSNs and fail-closed role smoke. `PingContext` proves only that a TCP/login path works; it does not catch `stats_reader_dsn` accidentally pointing at `stats_rollup`, all three DSNs pointing at the same superuser, or a role widened beyond §7.2. That leaves the Step 2/3 isolation seam dependent on operator convention instead of code.

**Fix:** Extend `smoke` to run role-specific SQL: assert `current_user` equals the expected role for each pool, assert the three required roles are distinct, and include one positive and one deny-list query per role. For example, `stats_reader` should SELECT an allowed stats table and fail permission-denied on `ledger_request_credits`; `provider_portal` should fail on `stats_overview_current`; `stats_rollup` should fail on `partner_keys`.

## D. Package layout + import-graph lint — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No architecture findings in the package layout or lint rule definitions. The diff establishes the pinned flat `internal/stats`, `internal/stats/store`, `internal/stats/rollup`, and `internal/stats/migrations` layout, and the depguard/forbidigo config encodes the Step 1 import and process-exit boundaries.

## E. Test coverage — 0 CRITICAL / 1 HIGH / 0 MEDIUM

### **[HIGH] AC-16 fixture assertion is not actually enforced in CI**

**Where:** `.github/workflows/ci.yml:31` and `.github/workflows/ci.yml:151`

**Evidence:**

```yaml
- name: make vet-coordinator
  run: make vet-coordinator

- name: make test-coordinator
  run: make test-coordinator
...
- name: Install golangci-lint
  run: |
    go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2
    echo "$(go env GOPATH)/bin" >> $GITHUB_PATH
- name: make lint-coordinator
  run: make lint-coordinator
```

and the assertion test skips when that binary is absent:

```go
bin, err := exec.LookPath("golangci-lint")
if err != nil {
    t.Skip("golangci-lint not on PATH; install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2")
}
```

**Why it matters:** BUILD §E.3/§D.4 requires the AC-16 fixture to be asserted by name, not merely that normal lint runs. In CI, `make test-coordinator` runs before golangci-lint is installed and therefore skips `TestAC16ForbiddenImportFails`; the later lint job installs golangci-lint but does not run the tagged fixture assertion. A broken fixture or missing diagnostic name can pass every PR.

**Fix:** In the `coordinator-lint` job, after installing golangci-lint, run the targeted test that enables the fixture assertion, for example `cd phase4-coordinator && go test ./internal/stats -run 'TestAC16ForbiddenImportFails|TestForbidigoOSExitRule'`. Alternatively add a Make target for the AC-16 fixture tests and call it from the lint job.

## F. Cross-step seams to Step 2/3/4 — 0 CRITICAL / 0 HIGH / 0 MEDIUM

No additional architecture findings. The Step 1 diff declares the config fields Steps 2/3 need, does not add concrete HTTP handlers, rollup tick queries, nginx config, or partner-key CLI commands, and introduces only the expected direct dependencies (`lib/pq`, `testcontainers-go`, `testcontainers-go/modules/postgres`) for this step.

## Verdict

```text
Verdict: NEEDS FIX
CRITICAL: 0
HIGH: 3
MEDIUM: 0
LOW: 0
INFO: 0
```

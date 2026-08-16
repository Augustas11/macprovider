# AUDIT_SPEC_017_IMPL_STEP_1 — Code lane

Operator-paste prompt to audit the **Step 1 IMPL code** under PR
`impl/spec-017-step-1`, from the CODE lens.

Audit target is the Step 1 implementation diff (Go source, SQL
migrations, depguard config, Makefile/CI changes, Step 1 tests).
SPEC-017 v0.1.8 is LOCKED.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_1-code-rM-audit.md` (fresh per round).

---

```
=== BEGIN PROMPT ===

You are auditing the Step 1 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` from the CODE lens — bugs, incorrect SQL,
race conditions, resource leaks, error-handling gaps, test
adequacy, idiomatic Go, dependency hygiene.

Output: specs/SPEC-017-IMPL-STEP_1-code-rM-audit.md (round M;
fresh file per round).

Severity model:
- CRITICAL — a bug that ships Step 1 in a broken state OR a Step
  1 contract violation the rollup/handler will inherit (e.g. wrong
  column type so values silently truncate, missing UNIQUE
  constraint causing duplicate rows under concurrent rollup ticks,
  migration that is not idempotent so partial-rerun bricks
  startup).
- HIGH — a real bug with a workaround (e.g. forgotten ORDER BY in
  a fixture seed, missing defer Close on a sql.DB, a depguard
  rule that doesn't actually fire on the named import).
- MEDIUM — style / clarity / minor correctness issue that two
  conforming sessions would resolve the same way once pointed at.
- LOW — polish.
- INFO — observations.

## Critical constraints

1. Step 1 introduces Postgres into a previously SQLite-only
   codebase. The migration runner, driver choice, and pool
   configuration are first-of-kind for the coordinator. Any code
   pattern that the next Postgres-touching code (Step 2 rollup)
   would have to undo is HIGH or CRITICAL.
2. Locked SPEC §7.2.5: one *sql.DB per active runtime role. No
   shared pools. The CODE lens MUST verify (a) the pool struct
   really holds independent *sql.DB instances, (b) startup smoke
   actually runs per pool, and (c) Close runs on each pool at
   shutdown.
3. Migrations MUST be idempotent — Step 1 IS the migration
   surface and Steps 2/3/4 will run on top of it. Non-idempotent
   migrations are CRITICAL.
4. depguard rules are AC-16 — the test fixture MUST actually
   trigger the rule and the test MUST assert the rule name
   appears in the lint output. A non-compilable fixture path
   that fails as a compiler error (not a lint diagnostic) is
   CRITICAL.
5. Tests for AC-9 / AC-10 / AC-19 / AC-20 — these MUST hit a
   real Postgres (testcontainers-go is the chosen vehicle).
   Tests that mock the role boundary defeat the purpose; that
   would be CRITICAL.

## Required reading

1. `specs/BUILD_SPEC_017_IMPL_PROMPT.md` §2 Step 1 — the
   normative scope.
2. `specs/SPEC-017-network-stats-api.md` v0.1.8 §5.4.1, §6.1,
   §6.5, §7.2, §9.1, §9.1a.
3. The Step 1 diff at branch `impl/spec-017-step-1`.
4. `phase4-coordinator/go.mod` — to verify the Postgres driver
   added matches the BUILD prompt's "lib/pq or pgx; pick one
   consistent with the rest of the project" rule.
5. `phase4-coordinator/cmd/coordinator/main.go` — the
   integration point for per-role pools.
6. `.github/workflows/ci.yml` — to verify the depguard /
   integration / AC-20 SQL CI jobs were added.

## Code audit categories

### A. Migration SQL correctness
A.1  Every `CREATE TABLE` is `IF NOT EXISTS` so re-running the
     migration on an already-migrated DB does not panic. Missing
     is CRITICAL.
A.2  Every column type matches the locked SPEC §9.1 / §5.4.1
     /§6.1 / §6.5 verbatim. Specifically: `TIMESTAMPTZ` (not
     `TIMESTAMP`); `NUMERIC(18,2)` for $ totals; `BIGSERIAL` for
     audit / partner_keys id; `TEXT` for `provider_id` and
     `pseudonym`. Any drift is CRITICAL.
A.3  `stats_components_health` PRIMARY KEY is `component`; UNIQUE
     constraint on `component`. The 7 enum values are pre-seeded.
     Missing PK or bootstrap is HIGH.
A.4  Indexes on `stats_leaderboard_*` for the sort axes
     (`rank_earnings`, `rank_tokens`, `rank_jobs`) and on the
     timeseries tables for `bucket_start`. Missing is MEDIUM
     unless Step 2/3's query plans would still hit the SLA on a
     seq scan (the rollup-tick cadence is on the order of
     seconds, so a missing index manifests in production, not
     CI).
A.5  Sequences explicitly named (e.g.
     `provider_visibility_audit_id_seq`,
     `partner_keys_id_seq`, `stats_late_events_id_seq`) so the
     `USAGE, SELECT ON SEQUENCE ...` grant clause has a real
     target. Missing is CRITICAL — the grant would fail at
     migration time.
A.6  `provider_visibility.blocked_from_partner_projection
     BOOLEAN NOT NULL DEFAULT FALSE` (v0.1.7 stub) — present.

### B. Role grants SQL correctness
B.1  Grants run AFTER the table CREATE statements (same
     migration or follow-on). If a role is granted before the
     table exists, that is CRITICAL.
B.2  Every `GRANT SELECT ON TABLE ... TO stats_reader` matches
     the §7.2.1 enumeration. Surplus grants are CRITICAL.
B.3  `REVOKE ALL ON ... FROM PUBLIC` runs first so default
     privileges don't leak. Missing is HIGH.
B.4  Default privileges on future tables in the same schema MUST
     NOT silently grant to runtime roles (`ALTER DEFAULT
     PRIVILEGES`). If absent, a new table added by Step 2 could
     auto-grant to `stats_reader` — that is a SECURITY-adjacent
     CODE finding (HIGH).
B.5  `partner_keys_writer` role NOT created when
     `last_used_at_updates_enabled = false`. Unconditional
     creation is HIGH per BUILD §2 Step 1 resolution.

### C. Migration runner code
C.1  The runner is idempotent — running it twice produces zero
     diff. Test for this is required.
C.2  The runner runs each migration in a transaction so a
     failed migration does not leave the DB in an intermediate
     state. Missing wrap-in-tx is CRITICAL.
C.3  Migration version tracking table (e.g. `schema_migrations`)
     is created if missing and updated atomically with the
     migration body. Race-prone version tracking is CRITICAL.
C.4  Migrations are embedded into the binary (e.g.
     `//go:embed`) so a deployed binary does not depend on a
     filesystem path for SQL files. External path dependency is
     HIGH (deploy-fragility).

### D. main.go integration
D.1  When `stats.enabled = false` (default), no Postgres pool
     opens, no smoke fires, no `/v1/stats/*` route registers.
     Verify by code-read. Failure is CRITICAL.
D.2  When `stats.enabled = true`, each required runtime DSN
     produces an independent *sql.DB; on missing DSN OR on
     failed smoke, the process exits non-zero BEFORE any HTTP
     listener binds. Permissive fallback is CRITICAL.
D.3  Each opened pool has a deferred Close in startup so SIGTERM
     drains cleanly. Missing Close is HIGH.
D.4  Pool tuning (max open conns, max idle, conn max lifetime)
     is at least set explicitly to non-default values matching
     a coordinator instance running at coordinator.malibu.tech
     load. Pool defaults are pgx/lib/pq's defaults, which are
     typically not safe for production. Unset is MEDIUM (no
     SLA target in Step 1).
D.5  `partner_keys_writer_dsn` ONLY consulted when
     `stats.partner_keys.last_used_at_updates_enabled = true`.
     Required-by-default is HIGH.
D.6  CLI operator DSN (`coordinator.partner_keys_admin_dsn`) —
     if present in config, Step 1 MUST NOT open a pool for it
     at coordinator startup. Step 4.A invokes it at CLI
     subcommand time. Opening at startup is HIGH (couples
     coordinator boot to a DSN it does not need).

### E. depguard / lint config + Makefile/CI
E.1  `.golangci.yml` (or equivalent) configures depguard with
     the two boundaries (request-path vs rollup carve-out) AND
     forbids `os.Exit`/`log.Fatal` under `internal/stats/*`.
E.2  Makefile target `lint-coordinator` (or equivalent) runs
     `golangci-lint run` with the new config.
E.3  CI job runs the new lint target on every PR.
E.4  AC-16 fixture file under `internal/stats/...` IS a valid
     Go file (compiles) but imports a forbidden package; test
     asserts the lint output names the depguard rule (e.g.
     contains the string "depguard" or the rule's `desc`).

### F. Tests (AC-9, AC-10, AC-16, AC-19, AC-20)
F.1  AC-9 — uses testcontainers-go to spin a real Postgres,
     applies the migrations, applies the grants, opens a
     connection as `stats_reader`, runs
     `SELECT 1 FROM ledger_request_credits LIMIT 1` (and at
     least one of the other SPEC-005 ledger tables), asserts
     the error code from the driver is "permission denied"
     (NOT "relation does not exist").
F.2  AC-10 — both subcases (commit + rollback). Asserts both
     `mode = 'exact', blocked_from_partner_projection = FALSE`
     and the audit row count.
F.3  AC-16 — fixture compiles; test asserts named lint
     diagnostic.
F.4  AC-19 — SQL fixture proves left-join default tuple.
F.5  AC-20 — runs in CI on every PR (not gated behind a build
     tag).
F.6  Test cleanup — each test that spins testcontainers MUST
     terminate the container at end-of-test. A leaked container
     is HIGH (CI flake).

### G. Dependency hygiene
G.1  Postgres driver added (lib/pq vs pgx) — pick one and
     justify in the PR description. Two drivers added is HIGH.
G.2  testcontainers-go added under a build tag so default
     `go test ./...` does not require Docker.
G.3  No surprise transitive — the diff's `go.sum` delta is
     reviewable; surprise modules are HIGH.
G.4  `go vet ./...` still passes. `make vet-coordinator` passes.

## Output format

Same as the ARCH lane:
- Per-category heading + one-line verdict.
- Per-finding: severity, file:line, evidence snippet, why,
  minimal fix.
- Final verdict block with counts.

`READY TO LOCK` iff 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```

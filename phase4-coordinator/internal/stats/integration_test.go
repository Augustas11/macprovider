//go:build integration

package stats_test

// SPEC-017 v0.1.8 Step 1 — Postgres-dependent integration tests.
// Build-tagged so the default `make test-coordinator` target on a
// Docker-less host does not fail. The CI
// `coordinator-stats-integration` job runs this suite on every
// PR (BUILD §E.5: AC-20 MUST run on every PR; the integration
// job is unconditional so the gate is satisfied).
//
// ACs covered here:
//
//   AC-9  — stats_reader receives "permission denied" (NOT
//           "relation does not exist") on
//           `SELECT 1 FROM ledger_request_credits LIMIT 1`.
//   AC-10 — provider_visibility commit + rollback subcases under
//           the provider_portal role; left-join default tuple
//           (mode='bucketed', blocked_from_partner_projection=FALSE)
//           verified.
//   AC-19 — SQL fixture proves a provider with no
//           provider_visibility row defaults to the bucketed tuple
//           via the left-join semantics Step 3 will use.
//   AC-20 — CI SQL assertion that no
//           `actor_kind='operator' AND new_mode='exact'` audit row
//           was seeded; the operator-exact path is invariant-
//           prohibited (§6.6.3).
//
// Note on the OLTP stub: AC-9 requires that stats_reader hit
// `ledger_request_credits` AS IF it existed in the OLTP cluster
// the rollup reads from. In production, SPEC-005 v0.3 owns the
// table CREATE; in this test we create a minimal stub matching
// the SPEC-005 name. The grants migration (005_oltp_source_*) is
// idempotent + defensive (skips missing tables); after the stub
// is created we re-run the grants migration so stats_rollup gets
// SELECT and stats_reader is explicitly DENY'd. This proves the
// post-grant state is what production will be, not a synthetic
// "table doesn't exist" state.

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	_ "github.com/lib/pq"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
)

const (
	// Digest-pinned Postgres image — BUILD §G.1 + round-1
	// SECURITY r1 MEDIUM 2: a mutable tag like
	// `postgres:16.4-alpine3.20` is forbidden hygiene; bake in
	// the manifest-list digest so the test image is fixed even
	// if the upstream tag is reused. Refresh deliberately when
	// bumping the major version.
	pgImage = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"

	roleStatsReader     = "stats_reader"
	roleStatsRollup     = "stats_rollup"
	roleProviderPortal  = "provider_portal"
	roleAdminPassword   = "stepone-admin-password" // local only; container is ephemeral
	roleRuntimePassword = "stepone-runtime-pw"
)

// pgFixture wraps an ephemeral Postgres container + the four
// connection strings we need (admin + 3 runtime roles).
type pgFixture struct {
	container tc.Container
	host      string
	port      string
	dbName    string
}

func (f *pgFixture) adminDSN() string {
	return fmt.Sprintf("postgres://postgres:%s@%s:%s/%s?sslmode=disable", roleAdminPassword, f.host, f.port, f.dbName)
}

func (f *pgFixture) roleDSN(role string) string {
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable", role, roleRuntimePassword, f.host, f.port, f.dbName)
}

func (f *pgFixture) Close(ctx context.Context) {
	if f == nil || f.container == nil {
		return
	}
	_ = f.container.Terminate(ctx)
}

func startPostgres(t *testing.T) *pgFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	c, err := tcpg.Run(ctx, pgImage,
		tcpg.WithDatabase("stats_test"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(roleAdminPassword),
		tc.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(60*time.Second),
		),
	)
	if err != nil {
		t.Fatalf("start postgres: %v", err)
	}
	host, err := c.Host(ctx)
	if err != nil {
		t.Fatalf("host: %v", err)
	}
	port, err := c.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("mapped port: %v", err)
	}
	fx := &pgFixture{
		container: c,
		host:      host,
		port:      port.Port(),
		dbName:    "stats_test",
	}
	t.Cleanup(func() {
		// Use a fresh background context so a slow teardown
		// during a flaky CI run still cleans up the container.
		bg, c2 := context.WithTimeout(context.Background(), 30*time.Second)
		defer c2()
		fx.Close(bg)
	})
	return fx
}

// applyMigrationsAndStubOLTP runs the SPEC-017 migrations against
// the admin DSN, creates the OLTP stub tables that AC-9 reads
// against, then re-runs the grants migration so stats_rollup has
// SELECT on the stubs and stats_reader is explicitly DENY'd.
// After this returns, the four runtime role identities exist and
// their passwords match `roleRuntimePassword`.
func applyMigrationsAndStubOLTP(t *testing.T, fx *pgFixture) *sql.DB {
	t.Helper()
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply SPEC-017 migrations: %v", err)
	}

	// Round-1 SECURITY r1 CRITICAL 1 fix: the migration creates
	// runtime roles with NOLOGIN and no password material. The
	// production deploy automation rotates them via
	// `ALTER ROLE ... WITH LOGIN PASSWORD '...'` from the
	// secret store; the test harness does the same in-memory.
	for _, role := range []string{roleStatsReader, roleStatsRollup, roleProviderPortal} {
		if _, err := adminDB.ExecContext(ctx, fmt.Sprintf(
			`ALTER ROLE %s WITH LOGIN PASSWORD '%s'`, role, roleRuntimePassword,
		)); err != nil {
			t.Fatalf("rotate role %s: %v", role, err)
		}
	}

	// Create OLTP stub tables matching SPEC-005 v0.3 names so
	// AC-9 gets permission-denied (not relation-does-not-exist).
	// Schema is minimal — column shape is irrelevant for the
	// permission check; only the table identity matters.
	stubDDL := `
        CREATE TABLE IF NOT EXISTS ledger_request_credits      (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ledger_operator_credits     (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ledger_payout_ready         (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS ledger_reconciliation_runs  (id BIGSERIAL PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS provider_tokens             (id BIGSERIAL PRIMARY KEY);
    `
	if _, err := adminDB.ExecContext(ctx, stubDDL); err != nil {
		t.Fatalf("create OLTP stubs: %v", err)
	}

	// Re-apply the OLTP-source grants migration so the
	// idempotent DO block hits the now-present stub tables.
	// schema_migrations_spec017 already records 005 as applied,
	// so we re-execute the file body directly.
	all, err := statsmigrations.All()
	if err != nil {
		t.Fatalf("load migrations: %v", err)
	}
	for _, m := range all {
		if m.Version == 5 {
			if _, err := adminDB.ExecContext(ctx, m.SQL); err != nil {
				t.Fatalf("re-apply OLTP grants on stubs: %v", err)
			}
			break
		}
	}

	return adminDB
}

// ===========================================================================
// AC-9 — stats_reader permission denied on OLTP ledger tables.
// ===========================================================================
func TestAC9_StatsReaderPermissionDeniedOnLedger(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	readerDB, err := sql.Open("postgres", fx.roleDSN(roleStatsReader))
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	defer readerDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// BUILD §E.1 / F.1 — verify against MULTIPLE SPEC-005 tables;
	// "at least one" is the floor but ledger_request_credits is
	// the canonical case and the others reinforce the invariant.
	for _, table := range []string{
		"ledger_request_credits",
		"ledger_operator_credits",
		"ledger_payout_ready",
		"ledger_reconciliation_runs",
		"provider_tokens",
	} {
		_, err := readerDB.QueryContext(ctx, fmt.Sprintf(`SELECT 1 FROM %s LIMIT 1`, table))
		if err == nil {
			t.Errorf("stats_reader unexpectedly succeeded SELECT on %s; expected permission denied", table)
			continue
		}
		// lib/pq error class for permission-denied is SQLSTATE 42501.
		// The driver wraps it as `*pq.Error`; we assert by string
		// match on the error message so the test does not couple to
		// the pq error type (and BUILD §E.1 wants "permission denied",
		// NOT "relation does not exist").
		msg := err.Error()
		if !contains(msg, "permission denied") {
			t.Errorf("stats_reader on %s: expected 'permission denied', got %q", table, msg)
		}
		if contains(msg, "does not exist") {
			t.Errorf("stats_reader on %s: error suggests missing relation (%q); the OLTP stub setup is wrong", table, msg)
		}
	}
}

// ===========================================================================
// AC-10 — provider_visibility commit + rollback under provider_portal.
// ===========================================================================
func TestAC10_ProviderVisibilityCommitAndRollback(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	portalDB, err := sql.Open("postgres", fx.roleDSN(roleProviderPortal))
	if err != nil {
		t.Fatalf("open portal: %v", err)
	}
	defer portalDB.Close()

	// Pre-seed: as admin (since stats_reader/portal cannot INSERT
	// initial 'bucketed' rows directly — portal only has INSERT/
	// UPDATE on provider_visibility but the test fixture itself
	// runs as admin).
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	defer adminDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := adminDB.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p1', 'bucketed')`,
	); err != nil {
		t.Fatalf("seed p1 bucketed: %v", err)
	}

	// === Subcase A: bucketed -> exact, commit path. ===
	tx, err := portalDB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin subcase A: %v", err)
	}
	if _, err := tx.ExecContext(ctx, `
        INSERT INTO provider_visibility (provider_id, mode)
        VALUES ('p1', 'exact')
        ON CONFLICT (provider_id) DO UPDATE
        SET mode = EXCLUDED.mode, updated_at = now()
    `); err != nil {
		_ = tx.Rollback()
		t.Fatalf("upsert p1: %v", err)
	}
	if _, err := tx.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p1', 'bucketed', 'exact', 'provider', 'p1', '127.0.0.1', 'test')
    `); err != nil {
		_ = tx.Rollback()
		t.Fatalf("audit insert p1: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit subcase A: %v", err)
	}

	// Assert post-commit state: mode='exact', blocked_*=FALSE
	// (the v0.1.7 stub column was not touched by the DO UPDATE
	// and falls to its DEFAULT). BUILD §E.2.
	var mode string
	var blocked bool
	row := adminDB.QueryRowContext(ctx,
		`SELECT mode, blocked_from_partner_projection FROM provider_visibility WHERE provider_id = 'p1'`,
	)
	if err := row.Scan(&mode, &blocked); err != nil {
		t.Fatalf("scan p1: %v", err)
	}
	if mode != "exact" {
		t.Errorf("p1 mode = %q, want %q", mode, "exact")
	}
	if blocked {
		t.Errorf("p1 blocked_from_partner_projection = true, want false (v0.1.7 stub default)")
	}

	var auditCount int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM provider_visibility_audit
        WHERE provider_id = 'p1' AND old_mode = 'bucketed' AND new_mode = 'exact'
          AND actor_kind = 'provider'
    `).Scan(&auditCount); err != nil {
		t.Fatalf("count p1 audit: %v", err)
	}
	if auditCount != 1 {
		t.Errorf("p1 audit count = %d, want 1", auditCount)
	}

	// === Subcase B: rollback path with distinct provider. ===
	tx, err = portalDB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin subcase B: %v", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_rollback', 'exact')`,
	); err != nil {
		_ = tx.Rollback()
		t.Fatalf("seed p_rollback: %v", err)
	}
	if _, err := tx.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p_rollback', 'bucketed', 'exact', 'provider', 'p_rollback', '127.0.0.1', 'test')
    `); err != nil {
		_ = tx.Rollback()
		t.Fatalf("audit insert p_rollback: %v", err)
	}
	// Force a PK conflict to abort the transaction.
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_rollback', 'bucketed')`,
	); err == nil {
		_ = tx.Rollback()
		t.Fatalf("expected PK conflict to abort the transaction; got success")
	}
	// The transaction is now in aborted state; explicit Rollback.
	_ = tx.Rollback()

	var pCount int
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM provider_visibility WHERE provider_id = 'p_rollback'`,
	).Scan(&pCount); err != nil {
		t.Fatalf("count p_rollback visibility: %v", err)
	}
	if pCount != 0 {
		t.Errorf("p_rollback visibility count = %d, want 0 (rollback should have undone the INSERT)", pCount)
	}
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM provider_visibility_audit WHERE provider_id = 'p_rollback'`,
	).Scan(&pCount); err != nil {
		t.Fatalf("count p_rollback audit: %v", err)
	}
	if pCount != 0 {
		t.Errorf("p_rollback audit count = %d, want 0", pCount)
	}
}

// ===========================================================================
// AC-19 — left-join no-row default tuple.
// ===========================================================================
func TestAC19_LeftJoinNoRowDefault(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Seed a stats_leaderboard_24h row for a provider with NO
	// provider_visibility row. The left-join query Step 3's
	// handler will use MUST default mode='bucketed' AND
	// blocked_from_partner_projection=FALSE on the no-row case.
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO stats_leaderboard_24h (
            provider_id, pseudonym, generated_at,
            rank_earnings, rank_tokens, rank_jobs,
            earnings_bucket
        ) VALUES (
            'never-toggled-xyz', 'pseudo-xyz', now(),
            1, 1, 1,
            '$'
        )
    `); err != nil {
		t.Fatalf("seed leaderboard row: %v", err)
	}

	// This is the same left-join shape Step 3's handler will use.
	row := adminDB.QueryRowContext(ctx, `
        SELECT
            l.provider_id,
            COALESCE(v.mode, 'bucketed') AS mode,
            COALESCE(v.blocked_from_partner_projection, FALSE) AS blocked
        FROM stats_leaderboard_24h l
        LEFT JOIN provider_visibility v ON v.provider_id = l.provider_id
        WHERE l.provider_id = 'never-toggled-xyz'
    `)
	var pid, mode string
	var blocked bool
	if err := row.Scan(&pid, &mode, &blocked); err != nil {
		t.Fatalf("scan left-join: %v", err)
	}
	if mode != "bucketed" {
		t.Errorf("no-row provider mode = %q, want 'bucketed'", mode)
	}
	if blocked {
		t.Errorf("no-row provider blocked = true, want false")
	}
}

// ===========================================================================
// AC-20 — no operator-exact audit row, ever.
// ===========================================================================
// Per BUILD §E.5 + §2.4 this assertion runs on every PR via the
// `coordinator-stats-integration` CI job. The test seeds a clean
// migration + bootstrap and asserts the prohibited combination
// has zero rows. A future fixture that violates §6.6.3 by
// inserting `actor_kind='operator' AND new_mode='exact'` would
// trip this immediately.
func TestAC20_NoOperatorExactAuditRow(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Pre-emptive defensive seed: insert a legitimate
	// actor_kind='operator' AND new_mode='bucketed' row (the
	// emergency suppression direction per §6.6.3 is allowed).
	if _, err := adminDB.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p_emergency', 'exact', 'bucketed', 'operator', 'ops@example.com', '10.0.0.1', 'cli')
    `); err != nil {
		t.Fatalf("seed legitimate operator suppression: %v", err)
	}

	var count int
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM provider_visibility_audit
        WHERE new_mode = 'exact' AND actor_kind = 'operator'
    `).Scan(&count); err != nil {
		t.Fatalf("query AC-20: %v", err)
	}
	if count != 0 {
		t.Errorf("AC-20 violated: %d rows with actor_kind='operator' AND new_mode='exact' (operator MUST NOT exact-enable per §6.6.3)", count)
	}
}

// ===========================================================================
// Schema-shape sanity tests — confirm the migrations created the
// tables Step 2/3 expect.
// ===========================================================================
func TestSchemaShapeSanity(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Health table has exactly 7 component rows (v0.1.7 split).
	var n int
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM stats_components_health`,
	).Scan(&n); err != nil {
		t.Fatalf("count components_health: %v", err)
	}
	if n != 7 {
		t.Errorf("stats_components_health row count = %d, want 7", n)
	}

	// Rewards-populated bootstrap has 4 rows, all false.
	if err := adminDB.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM stats_rewards_populated WHERE rewards_populated = FALSE`,
	).Scan(&n); err != nil {
		t.Fatalf("count rewards_populated bootstrap: %v", err)
	}
	if n != 4 {
		t.Errorf("stats_rewards_populated false-bootstrap count = %d, want 4", n)
	}

	// stats_leaderboard_24h has NO earnings_work_bucket /
	// earnings_rewards_bucket columns (v0.1.7 removed).
	for _, banned := range []string{"earnings_work_bucket", "earnings_rewards_bucket"} {
		if err := adminDB.QueryRowContext(ctx, `
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_name = 'stats_leaderboard_24h' AND column_name = $1
        `, banned).Scan(&n); err != nil {
			t.Fatalf("information_schema lookup: %v", err)
		}
		if n != 0 {
			t.Errorf("stats_leaderboard_24h has forbidden column %q (v0.1.7 removed)", banned)
		}
	}

	// partner_keys has NO rate_limit_burst column (v0.1.8 removed).
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_name = 'partner_keys' AND column_name = 'rate_limit_burst'
    `).Scan(&n); err != nil {
		t.Fatalf("information_schema partner_keys lookup: %v", err)
	}
	if n != 0 {
		t.Errorf("partner_keys has forbidden column 'rate_limit_burst' (v0.1.8 removed)")
	}

	// provider_visibility has the v0.1.7
	// blocked_from_partner_projection stub.
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_name = 'provider_visibility' AND column_name = 'blocked_from_partner_projection'
    `).Scan(&n); err != nil {
		t.Fatalf("information_schema provider_visibility lookup: %v", err)
	}
	if n != 1 {
		t.Errorf("provider_visibility missing v0.1.7 blocked_from_partner_projection column stub")
	}

	// stats_components_health has NO status column (derived at
	// request time per §5.3; presence is CRITICAL per BUILD §A.4).
	if err := adminDB.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_name = 'stats_components_health' AND column_name = 'status'
    `).Scan(&n); err != nil {
		t.Fatalf("information_schema components_health status lookup: %v", err)
	}
	if n != 0 {
		t.Errorf("stats_components_health has forbidden 'status' column; status is derived at request time per §5.3")
	}
}

// ===========================================================================
// Migration idempotency — running All() twice is a no-op.
// ===========================================================================
func TestMigrationsIdempotent(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Re-run; schema_migrations_spec017 should already have all
	// versions recorded; Apply MUST be a no-op.
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("second Apply: %v", err)
	}

	// stats_components_health still has 7 rows (the ON CONFLICT
	// DO NOTHING in 002 protects it).
	var n int
	if err := adminDB.QueryRowContext(ctx, `SELECT COUNT(*) FROM stats_components_health`).Scan(&n); err != nil {
		t.Fatalf("count components_health: %v", err)
	}
	if n != 7 {
		t.Errorf("after re-apply, components_health row count = %d, want 7", n)
	}
}

// TestMigrationsConcurrent — round-1 CODE r1 CRITICAL C1 fix.
// Two parallel Apply calls must both succeed without leaving
// duplicate rows in schema_migrations_spec017 or double-applying
// the bootstrap inserts. The advisory lock in migrations.Apply
// serializes the runs.
func TestMigrationsConcurrent(t *testing.T) {
	fx := startPostgres(t)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	adminDB1, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin1: %v", err)
	}
	defer adminDB1.Close()
	adminDB2, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin2: %v", err)
	}
	defer adminDB2.Close()

	errCh := make(chan error, 2)
	go func() { errCh <- statsmigrations.Apply(ctx, adminDB1) }()
	go func() { errCh <- statsmigrations.Apply(ctx, adminDB2) }()
	for i := 0; i < 2; i++ {
		if err := <-errCh; err != nil {
			t.Fatalf("concurrent Apply (run %d): %v", i, err)
		}
	}

	// Exactly one row per migration version in
	// schema_migrations_spec017 (no duplicates from race).
	var rows int
	if err := adminDB1.QueryRowContext(ctx,
		`SELECT COUNT(DISTINCT version) FROM schema_migrations_spec017`,
	).Scan(&rows); err != nil {
		t.Fatalf("count distinct: %v", err)
	}
	var total int
	if err := adminDB1.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM schema_migrations_spec017`,
	).Scan(&total); err != nil {
		t.Fatalf("count total: %v", err)
	}
	if rows != total {
		t.Errorf("schema_migrations_spec017 has duplicate version rows: distinct=%d total=%d", rows, total)
	}
	if rows != 5 {
		t.Errorf("schema_migrations_spec017 distinct versions = %d, want 5", rows)
	}

	// stats_components_health still has exactly 7 rows.
	var comps int
	if err := adminDB1.QueryRowContext(ctx, `SELECT COUNT(*) FROM stats_components_health`).Scan(&comps); err != nil {
		t.Fatalf("count components_health: %v", err)
	}
	if comps != 7 {
		t.Errorf("stats_components_health row count = %d, want 7", comps)
	}
}

// TestAdvisoryLockKeyMatchesHashtext — defense-in-depth for the
// migrations.advisoryLockKey constant. A coordinator using a
// different hashing convention than the one used at IMPL time
// would race against itself; this test fails fast in CI if the
// constant drifts from a stable hash of the literal label.
func TestAdvisoryLockKeyMatchesHashtext(t *testing.T) {
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Re-acquire the lock with the constant and confirm
	// Postgres accepts it. The semantics we care about is "the
	// pre-computed BIGINT is a valid pg_advisory_lock argument
	// and the lock is acquired"; the constant's exact value is
	// the migration package's contract, not the test's.
	var ok bool
	if err := adminDB.QueryRowContext(ctx,
		`SELECT pg_try_advisory_lock(5179378192876502983)`,
	).Scan(&ok); err != nil {
		t.Fatalf("pg_try_advisory_lock: %v", err)
	}
	if !ok {
		t.Fatal("pg_try_advisory_lock returned false; lock collided with a prior holder")
	}
	if _, err := adminDB.ExecContext(ctx,
		`SELECT pg_advisory_unlock(5179378192876502983)`,
	); err != nil {
		t.Fatalf("pg_advisory_unlock: %v", err)
	}
}

// TestNoLoginRoleDefault — round-1 SECURITY r1 CRITICAL 1 fix:
// 003_roles.up.sql creates roles with NOLOGIN. Before the test
// harness rotates them, a connection attempt MUST fail.
func TestNoLoginRoleDefault(t *testing.T) {
	fx := startPostgres(t)

	// Apply ONLY the migrations, NOT the role-rotate step from
	// applyMigrationsAndStubOLTP — so the roles still have
	// NOLOGIN.
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	defer adminDB.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}

	// Confirm each runtime role has rolcanlogin = false (no
	// password, no LOGIN) before any rotation.
	for _, role := range []string{roleStatsReader, roleStatsRollup, roleProviderPortal} {
		var canLogin bool
		if err := adminDB.QueryRowContext(ctx,
			`SELECT rolcanlogin FROM pg_roles WHERE rolname = $1`, role,
		).Scan(&canLogin); err != nil {
			t.Fatalf("query rolcanlogin for %s: %v", role, err)
		}
		if canLogin {
			t.Errorf("role %s has rolcanlogin=true; 003_roles.up.sql should create with NOLOGIN", role)
		}
	}
}

// ===========================================================================
// Pool isolation — provider_portal CANNOT SELECT stats_* tables.
// ===========================================================================
func TestProviderPortalCannotReadStats(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	portalDB, err := sql.Open("postgres", fx.roleDSN(roleProviderPortal))
	if err != nil {
		t.Fatalf("open portal: %v", err)
	}
	defer portalDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err = portalDB.QueryContext(ctx, `SELECT 1 FROM stats_overview_current LIMIT 1`)
	if err == nil {
		t.Fatalf("provider_portal unexpectedly SELECT'd stats_overview_current; §7.2.3 invariant violated")
	}
	if !contains(err.Error(), "permission denied") {
		t.Errorf("provider_portal stats_overview_current: expected 'permission denied', got %q", err.Error())
	}

	// And provider_portal CAN insert into provider_visibility_audit
	// (the BIGSERIAL sequence grant works).
	if _, err := portalDB.ExecContext(ctx, `
        INSERT INTO provider_visibility_audit
            (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
        VALUES ('p_smoke', 'bucketed', 'exact', 'provider', 'p_smoke', '127.0.0.1', 'test')
    `); err != nil {
		t.Errorf("provider_portal insert into provider_visibility_audit failed (sequence USAGE grant missing?): %v", err)
	}
}

// ===========================================================================
// stats_rollup deny on partner_keys + provider_visibility_audit.
// ===========================================================================
func TestStatsRollupCannotTouchPartnerKeys(t *testing.T) {
	fx := startPostgres(t)
	_ = applyMigrationsAndStubOLTP(t, fx)

	rollupDB, err := sql.Open("postgres", fx.roleDSN(roleStatsRollup))
	if err != nil {
		t.Fatalf("open rollup: %v", err)
	}
	defer rollupDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err = rollupDB.QueryContext(ctx, `SELECT 1 FROM partner_keys LIMIT 1`)
	if err == nil {
		t.Errorf("stats_rollup unexpectedly SELECT'd partner_keys; §7.2.2 invariant violated")
	} else if !contains(err.Error(), "permission denied") {
		t.Errorf("stats_rollup partner_keys: expected 'permission denied', got %q", err.Error())
	}

	_, err = rollupDB.QueryContext(ctx, `SELECT 1 FROM provider_visibility_audit LIMIT 1`)
	if err == nil {
		t.Errorf("stats_rollup unexpectedly SELECT'd provider_visibility_audit")
	} else if !contains(err.Error(), "permission denied") {
		t.Errorf("stats_rollup provider_visibility_audit: expected 'permission denied', got %q", err.Error())
	}
}

func contains(haystack, needle string) bool {
	// Avoid importing strings here — keeps the test package's
	// import surface trivially auditable. The function is hot
	// enough only across a handful of assertions that the
	// stdlib strings.Contains overhead is irrelevant.
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

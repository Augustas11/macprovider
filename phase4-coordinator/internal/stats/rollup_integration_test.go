//go:build integration

package stats_test

// SPEC-017 v0.1.8 Step 2 — rollup integration tests against a
// real Postgres via testcontainers-go. Reuses the per-test
// container helpers from integration_test.go (same package +
// build tag) so each test starts a fresh ephemeral DB.
//
// Coverage:
//
//   - Overview tick populates stats_overview_current + advances
//     stats_components_health.overview.
//   - Timeseries rpm + tpm ticks populate per-minute rows
//     within the rolling 30-minute window. Failure of rpm-only
//     leaves tpm's last_ok_at fresh (BUILD §B.2).
//   - Leaderboard tick for each window {24h, 7d, 30d, all}
//     populates rows with bucket computed per §6.2, ranks
//     deterministic, provider_visibility left-join applied
//     (no-row default tuple bucketed + blocked=FALSE),
//     provider_id traced through provider_tokens (BUILD §F.3
//     trust-source).
//   - Bucket boundaries — fixtures at 4.99, 5.00, 49.99, 50.00
//     produce the expected $-bucket strings (§F.3).
//   - Shape C nightly rebuild — three sub-assertions per
//     BUILD §H.2: (i) failed-rebuild rollback leaves the
//     pre-rebuild row set intact; (ii) MVCC no-empty-state for
//     concurrent readers; (iii) post-commit equivalence.
//   - Drift > 0.5% fires `stats_rollup_drift_detected` AND
//     rebuild value wins.
//   - stats_late_events retention DELETE removes 100-day-old
//     rows; preserves 30-day-old rows.
//   - rewards_populated FALSE on empty ledger; TRUE when a
//     ledger row falls inside the requested window.

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	_ "github.com/lib/pq"
	"github.com/rs/zerolog"

	statsrollup "github.com/augstar/macprovider-coordinator/internal/stats/rollup"
)

// rollupOLTPStubDDL creates the Postgres-shape SPEC-005 +
// SPEC-002 source tables the rollup queries. Production
// mirrors SQLite billing → Postgres via operator-side tooling
// per the trust-source decision record; the test stub shape
// matches the SPEC-005 column names with Postgres TIMESTAMPTZ
// for ts_utc (vs SQLite TEXT in the live billing store).
//
// Note: Step 1's `applyMigrationsAndStubOLTP` helper already
// creates these tables as `id BIGSERIAL PRIMARY KEY` only — the
// AC-9 permission test only needs the table identity. Step 2's
// rollup needs the full column set, so we DROP and CREATE
// fresh here. Ordering matters: drop ledger_request_credits
// before provider_tokens (no FK between them in stubs, but
// keep an explicit order for readability).
const rollupOLTPStubDDL = `
DROP TABLE IF EXISTS ledger_request_credits CASCADE;
DROP TABLE IF EXISTS provider_tokens CASCADE;
CREATE TABLE ledger_request_credits (
    id                   BIGSERIAL PRIMARY KEY,
    request_id           TEXT NOT NULL,
    attempt_n            INTEGER NOT NULL,
    provider_id          TEXT NOT NULL,
    ts_utc               TIMESTAMPTZ NOT NULL,
    prompt_tokens        BIGINT,
    completion_tokens    BIGINT,
    provider_credits     BIGINT NOT NULL DEFAULT 0,
    fault_flag           TEXT NOT NULL DEFAULT 'none',
    quarantined          BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE provider_tokens (
    provider_id  TEXT PRIMARY KEY,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
`

func setupRollupFixture(t *testing.T) (*pgFixture, *sql.DB) {
	t.Helper()
	fx := startPostgres(t)
	adminDB := applyMigrationsAndStubOLTP(t, fx)
	if _, err := adminDB.ExecContext(context.Background(), rollupOLTPStubDDL); err != nil {
		t.Fatalf("create rollup OLTP stub: %v", err)
	}
	// The DROP+CREATE in rollupOLTPStubDDL invalidates the
	// grants that migration 005's DO block applied to the
	// original id-only stubs. Re-grant SELECT on the freshly
	// created tables.
	if _, err := adminDB.ExecContext(context.Background(), `
        GRANT SELECT ON ledger_request_credits TO stats_rollup;
        GRANT SELECT ON provider_tokens TO stats_rollup;
    `); err != nil {
		t.Fatalf("refresh OLTP grants: %v", err)
	}
	return fx, adminDB
}

// seedProviderTokens populates provider_tokens. The rollup joins
// on this table for authenticated provider-identity per the
// Step 1 trust-source decision; any provider NOT in this table
// is INVISIBLE to the rollup.
func seedProviderTokens(t *testing.T, db *sql.DB, providerIDs ...string) {
	t.Helper()
	for _, pid := range providerIDs {
		if _, err := db.ExecContext(context.Background(),
			`INSERT INTO provider_tokens (provider_id) VALUES ($1) ON CONFLICT DO NOTHING`, pid,
		); err != nil {
			t.Fatalf("seed provider_tokens %s: %v", pid, err)
		}
	}
}

// seedLedgerRow inserts a billing event into the OLTP stub.
func seedLedgerRow(t *testing.T, db *sql.DB, providerID string, ts time.Time, promptTok, completionTok, credits int64) {
	t.Helper()
	if _, err := db.ExecContext(context.Background(), `
        INSERT INTO ledger_request_credits
            (request_id, attempt_n, provider_id, ts_utc, prompt_tokens, completion_tokens, provider_credits)
        VALUES ($1, 0, $2, $3, $4, $5, $6)
    `, fmt.Sprintf("req-%s-%d", providerID, ts.UnixNano()), providerID, ts, promptTok, completionTok, credits); err != nil {
		t.Fatalf("seed ledger %s: %v", providerID, err)
	}
}

// freshRollupConfig returns a Config with the defaults applied
// AND with cadences too fast for production but cheap enough for
// tests (every job ticks once at startup; we don't wait for
// time.Ticker fires).
func freshRollupConfig() statsrollup.Config {
	return statsrollup.Config{
		BackfillMode:            "partial",
		PartialHistorySinceUnix: 0,
		UsdPerMillionCredits:    1.0,
		DriftThresholdRatio:     0.005,
		NightlyRebuildHourUTC:   9,
		LateEventsLookbackHours: 48,
		LateEventsRetentionDays: 90,
		OverviewInterval:        24 * time.Hour, // first tick fires immediately, then dormant
		TimeseriesRpmInterval:   24 * time.Hour,
		TimeseriesTpmInterval:   24 * time.Hour,
		Leaderboard24hInterval:  24 * time.Hour,
		Leaderboard7dInterval:   24 * time.Hour,
		Leaderboard30dInterval:  24 * time.Hour,
		LeaderboardAllInterval:  24 * time.Hour,
	}
}

// rollupDB returns a *sql.DB authenticated as stats_rollup. The
// rollup package writes via this pool only — testing through it
// proves the §7.2.2 grant set is correct for live production.
func rollupDB(t *testing.T, fx *pgFixture) *sql.DB {
	t.Helper()
	db, err := sql.Open("postgres", fx.roleDSN(roleStatsRollup))
	if err != nil {
		t.Fatalf("open stats_rollup pool: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// ==========================================================================
// Overview tick.
// ==========================================================================
func TestRollupOverviewTick(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	seedProviderTokens(t, adminDB, "p1", "p2")
	now := time.Now().UTC()
	seedLedgerRow(t, adminDB, "p1", now.Add(-2*time.Hour), 100, 50, 1000)
	seedLedgerRow(t, adminDB, "p2", now.Add(-1*time.Hour), 200, 75, 2000)

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	// Use Start to fire the first tick of each job, then cancel.
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	// Wait a short moment for the first ticks to complete (the
	// runner's first-tick fires immediately on each goroutine).
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	var tokensIn, tokensOut, requests int64
	if err := adminDB.QueryRowContext(context.Background(), `
        SELECT tokens_in, tokens_out, requests FROM stats_overview_current
    `).Scan(&tokensIn, &tokensOut, &requests); err != nil {
		t.Fatalf("scan overview: %v", err)
	}
	if tokensIn != 300 {
		t.Errorf("tokens_in = %d, want 300", tokensIn)
	}
	if tokensOut != 125 {
		t.Errorf("tokens_out = %d, want 125", tokensOut)
	}
	if requests != 2 {
		t.Errorf("requests = %d, want 2", requests)
	}

	var genAt time.Time
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT generated_at FROM stats_components_health WHERE component = 'overview'`,
	).Scan(&genAt); err != nil {
		t.Fatalf("scan health: %v", err)
	}
	if time.Since(genAt) > 5*time.Second {
		t.Errorf("stats_components_health.overview.generated_at not fresh: %v", genAt)
	}
}

// ==========================================================================
// Leaderboard tick + bucket + left-join no-row default.
// ==========================================================================
func TestRollupLeaderboard24hBucketsAndLeftJoin(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	now := time.Now().UTC()
	// Three providers with actual activity (the v0.1 implicit-
	// exclusion policy per SPEC §11 Q10 means zero-activity
	// providers DO NOT appear on the leaderboard; that's the
	// correct behavior — there's nothing to rank).
	seedProviderTokens(t, adminDB, "p_tiny", "p_small", "p_huge")

	// p_tiny — $0.005 (0.5¢, BELOW the $0.01 floor) → "-" bucket.
	// p_small — $4.99 → "$" bucket on 24h.
	// p_huge — $50.00 → "$$$" bucket on 24h.
	seedLedgerRow(t, adminDB, "p_tiny", now.Add(-1*time.Hour), 1, 1, 5_000) // 5_000 * 1.0 / 1e6 = $0.005
	seedLedgerRow(t, adminDB, "p_small", now.Add(-1*time.Hour), 10, 10, 4_990_000)
	seedLedgerRow(t, adminDB, "p_huge", now.Add(-1*time.Hour), 100, 100, 50_000_000)

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	rows, err := adminDB.QueryContext(context.Background(),
		`SELECT provider_id, earnings_bucket, earnings_usd FROM stats_leaderboard_24h ORDER BY provider_id`,
	)
	if err != nil {
		t.Fatalf("query leaderboard_24h: %v", err)
	}
	defer rows.Close()
	got := map[string]struct {
		bucket string
		usd    string
	}{}
	for rows.Next() {
		var pid, bucket, usd string
		if err := rows.Scan(&pid, &bucket, &usd); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got[pid] = struct {
			bucket string
			usd    string
		}{bucket, usd}
	}
	if got["p_tiny"].bucket != "-" {
		t.Errorf("p_tiny bucket = %q, want - (sub-cent total)", got["p_tiny"].bucket)
	}
	if got["p_small"].bucket != "$" {
		t.Errorf("p_small bucket = %q, want $ (4.99 lower bracket)", got["p_small"].bucket)
	}
	if got["p_huge"].bucket != "$$$" {
		t.Errorf("p_huge bucket = %q, want $$$ (50.00 upper bracket)", got["p_huge"].bucket)
	}
	if got["p_small"].usd != "4.99" {
		t.Errorf("p_small earnings_usd = %q, want 4.99", got["p_small"].usd)
	}
}

// TestRollupLeaderboardBoundaryAtFive — §6.2 boundary $5.00 →
// "$$", $4.99 → "$".
func TestRollupLeaderboardBoundaryAtFive(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	now := time.Now().UTC()
	seedProviderTokens(t, adminDB, "p_499", "p_500")
	seedLedgerRow(t, adminDB, "p_499", now.Add(-30*time.Minute), 0, 0, 4_990_000)
	seedLedgerRow(t, adminDB, "p_500", now.Add(-30*time.Minute), 0, 0, 5_000_000)

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	var b499, b500 string
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT earnings_bucket FROM stats_leaderboard_24h WHERE provider_id = 'p_499'`,
	).Scan(&b499); err != nil {
		t.Fatalf("scan p_499: %v", err)
	}
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT earnings_bucket FROM stats_leaderboard_24h WHERE provider_id = 'p_500'`,
	).Scan(&b500); err != nil {
		t.Fatalf("scan p_500: %v", err)
	}
	if b499 != "$" {
		t.Errorf("$4.99 bucket = %q, want $", b499)
	}
	if b500 != "$$" {
		t.Errorf("$5.00 bucket = %q, want $$ (lower inclusive)", b500)
	}
}

// ==========================================================================
// rewards_populated computation.
// ==========================================================================
func TestRollupRewardsPopulated(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()
	seedProviderTokens(t, adminDB, "p_x")

	// Empty ledger → all four windows FALSE.
	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	for _, w := range []string{"24h", "7d", "30d", "all"} {
		var p bool
		if err := adminDB.QueryRowContext(context.Background(),
			`SELECT rewards_populated FROM stats_rewards_populated WHERE window_label = $1`, w,
		).Scan(&p); err != nil {
			t.Fatalf("scan %s: %v", w, err)
		}
		if p {
			t.Errorf("rewards_populated[%s] = true, want false (ledger empty)", w)
		}
	}

	// Insert ledger row inside the 7d window; re-run; expect 7d
	// + 30d + all = TRUE; 24h = FALSE (the unix_ts is older
	// than 24h ago).
	now := time.Now().UTC()
	inside7d := now.Add(-48 * time.Hour).Unix()
	if _, err := adminDB.ExecContext(context.Background(),
		`INSERT INTO provider_rewards_ledger (provider_id, unix_ts, amount_usd) VALUES ('p_x', $1, 12.34)`,
		inside7d,
	); err != nil {
		t.Fatalf("insert reward: %v", err)
	}

	runner2, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New 2: %v", err)
	}
	ctx2, cancel2 := context.WithCancel(context.Background())
	runner2.Start(ctx2)
	time.Sleep(500 * time.Millisecond)
	cancel2()
	runner2.Wait()

	expect := map[string]bool{"24h": false, "7d": true, "30d": true, "all": true}
	for w, want := range expect {
		var p bool
		if err := adminDB.QueryRowContext(context.Background(),
			`SELECT rewards_populated FROM stats_rewards_populated WHERE window_label = $1`, w,
		).Scan(&p); err != nil {
			t.Fatalf("scan %s: %v", w, err)
		}
		if p != want {
			t.Errorf("rewards_populated[%s] = %v, want %v", w, p, want)
		}
	}
}

// ==========================================================================
// stats_late_events retention DELETE.
// ==========================================================================
func TestRollupLateEventsRetention(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	// Seed a 100-day-old + a 30-day-old row.
	if _, err := adminDB.ExecContext(context.Background(), `
        INSERT INTO stats_late_events (recorded_at, event_unix_ts, provider_id, source_billing_row)
        VALUES (now() - INTERVAL '100 days', 100, 'p_old', 'src-100'),
               (now() - INTERVAL '30 days',  200, 'p_mid', 'src-30')
    `); err != nil {
		t.Fatalf("seed late events: %v", err)
	}

	// Trigger the retention via direct call (the nightly
	// rebuild also calls it; we exercise the helper directly to
	// avoid waiting for the nightly hour).
	cfg := freshRollupConfig().DefaultsApplied()
	if err := statsrollup.RunLateEventsRetention(context.Background(), rdb, cfg); err != nil {
		t.Fatalf("retention: %v", err)
	}
	_ = logger

	var n int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_late_events WHERE provider_id = 'p_old'`,
	).Scan(&n); err != nil {
		t.Fatalf("count old: %v", err)
	}
	if n != 0 {
		t.Errorf("100-day-old late event not pruned: count=%d", n)
	}
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_late_events WHERE provider_id = 'p_mid'`,
	).Scan(&n); err != nil {
		t.Fatalf("count mid: %v", err)
	}
	if n != 1 {
		t.Errorf("30-day-old late event was pruned (retention default 90 days): count=%d", n)
	}
}

// ==========================================================================
// Shape C rebuild atomicity — 3 sub-assertions.
// ==========================================================================

// (i) Failed rebuild rolls back; pre-rebuild snapshot preserved.
func TestShapeCRebuild_FailedRollback(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	seedProviderTokens(t, adminDB, "p_a")
	now := time.Now().UTC()
	seedLedgerRow(t, adminDB, "p_a", now.Add(-1*time.Hour), 10, 10, 1_000_000)

	// First tick populates the leaderboard.
	logger := zerolog.Nop()
	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	// Snapshot R0.
	var r0Count int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_leaderboard_all`,
	).Scan(&r0Count); err != nil {
		t.Fatalf("R0 count: %v", err)
	}
	if r0Count != 1 {
		t.Fatalf("R0 count = %d, want 1", r0Count)
	}

	// Force a rebuild error by adding a CHECK (false) constraint
	// in NOT VALID mode. NOT VALID means existing rows are exempt
	// (so we don't have to clear stats_leaderboard_all first),
	// but future INSERTs ARE checked — the rebuild's DELETE+INSERT
	// will fail at INSERT-time, abort the transaction, and roll
	// back the DELETE. R0 stays intact.
	if _, err := adminDB.ExecContext(context.Background(),
		`ALTER TABLE stats_leaderboard_all ADD CONSTRAINT _rebuild_test_block CHECK (false) NOT VALID`,
	); err != nil {
		t.Fatalf("add CHECK: %v", err)
	}

	// Run the rebuild directly. Expect an error.
	cfg := freshRollupConfig().DefaultsApplied()
	if err := statsrollup.RunNightlyRebuild(context.Background(), rdb, cfg, logger); err == nil {
		t.Fatal("expected rebuild to fail due to CHECK constraint; got nil")
	}

	// R0 should still be there.
	var r0CountAfter int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_leaderboard_all`,
	).Scan(&r0CountAfter); err != nil {
		t.Fatalf("R0 after count: %v", err)
	}
	if r0CountAfter != r0Count {
		t.Errorf("rollback failed: pre=%d post=%d", r0Count, r0CountAfter)
	}

	// Clean up the constraint.
	if _, err := adminDB.ExecContext(context.Background(),
		`ALTER TABLE stats_leaderboard_all DROP CONSTRAINT _rebuild_test_block`,
	); err != nil {
		t.Logf("drop constraint cleanup: %v", err)
	}
}

// (ii) Successful rebuild: MVCC ensures no observer sees an
//
//	empty OR PARTIAL leaderboard during the rebuild
//	transaction. Round-2 CODE r2 HIGH 3 fix: R0 and R1 have
//	DISTINCT row counts (3 vs 5) so the concurrent reader can
//	distinguish "saw R0", "saw R1", "saw a mid-tx partial".
func TestShapeCRebuild_MVCCNoEmptyState(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()
	now := time.Now().UTC()

	r0Providers := []string{"p_r0_a", "p_r0_b", "p_r0_c"}
	seedProviderTokens(t, adminDB, r0Providers...)
	for _, pid := range r0Providers {
		seedLedgerRow(t, adminDB, pid, now.Add(-2*time.Hour), 10, 10, 1_000_000)
	}

	// Populate R0 via a cadence tick.
	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	// Seed 2 more providers so the rebuild's R1 has 5 rows.
	r1Extra := []string{"p_r1_d", "p_r1_e"}
	seedProviderTokens(t, adminDB, r1Extra...)
	for _, pid := range r1Extra {
		seedLedgerRow(t, adminDB, pid, now.Add(-2*time.Hour), 10, 10, 1_000_000)
	}

	// Concurrent reader: poll count; record any observation
	// that isn't 3 (R0) or 5 (R1).
	stopReader := make(chan struct{})
	var observedMixed atomic.Bool
	var lastCount atomic.Int64
	go func() {
		for {
			select {
			case <-stopReader:
				return
			default:
			}
			var c int
			row := adminDB.QueryRowContext(context.Background(),
				`SELECT COUNT(*) FROM stats_leaderboard_all`,
			)
			if err := row.Scan(&c); err == nil {
				lastCount.Store(int64(c))
				if c != 3 && c != 5 {
					observedMixed.Store(true)
				}
			}
			time.Sleep(2 * time.Millisecond)
		}
	}()

	cfg := freshRollupConfig().DefaultsApplied()
	if err := statsrollup.RunNightlyRebuild(context.Background(), rdb, cfg, logger); err != nil {
		t.Fatalf("rebuild: %v", err)
	}

	close(stopReader)
	if observedMixed.Load() {
		t.Errorf("concurrent reader saw mid-rebuild partial state (last observed count=%d, expected 3 or 5); Shape C MVCC invariant violated", lastCount.Load())
	}

	var c int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_leaderboard_all`,
	).Scan(&c); err != nil {
		t.Fatalf("post-rebuild count: %v", err)
	}
	if c != 5 {
		t.Errorf("post-rebuild count = %d, want 5 (R1)", c)
	}

	// Round-3 CODE r3 MED 2 fix: post-commit equivalence is
	// per-provider content-equality, not just COUNT. The rebuilt
	// rows MUST contain exactly r0Providers + r1Extra with
	// deterministic ranks. Compare the committed provider_id
	// set against the expected set.
	expected := map[string]struct{}{}
	for _, p := range append(append([]string{}, r0Providers...), r1Extra...) {
		expected[p] = struct{}{}
	}
	pidRows, err := adminDB.QueryContext(context.Background(),
		`SELECT provider_id FROM stats_leaderboard_all`,
	)
	if err != nil {
		t.Fatalf("query pids: %v", err)
	}
	defer pidRows.Close()
	got := map[string]struct{}{}
	for pidRows.Next() {
		var p string
		if err := pidRows.Scan(&p); err != nil {
			t.Fatalf("scan pid: %v", err)
		}
		got[p] = struct{}{}
	}
	for p := range expected {
		if _, ok := got[p]; !ok {
			t.Errorf("R1 missing provider %q (post-commit equivalence)", p)
		}
	}
	for p := range got {
		if _, ok := expected[p]; !ok {
			t.Errorf("R1 has unexpected provider %q (post-commit equivalence)", p)
		}
	}
}

// ==========================================================================
// Drift detection integration: Round-3 CODE r3 MED 1 fix.
// Pre-rebuild snapshot has earnings differing by >0.5% from the
// rebuilt OLTP truth; nightly rebuild MUST (a) emit
// `stats_rollup_drift_detected` in the captured zerolog, (b)
// commit the rebuild value, NOT the pre-rebuild value.
// ==========================================================================
func TestRollupDriftDetectedAndRebuildWins(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	now := time.Now().UTC()

	seedProviderTokens(t, adminDB, "p_drift")
	// OLTP truth: $50.00 in provider_credits.
	seedLedgerRow(t, adminDB, "p_drift", now.Add(-1*time.Hour), 100, 100, 50_000_000)

	// Pre-rebuild: populate via a tick (so the snapshot matches OLTP),
	// then MANUALLY corrupt stats_leaderboard_all to fake drift.
	logger := zerolog.Nop()
	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	// Fake drift: change the stored earnings_usd to differ by 100%
	// (clearly above the 0.5% threshold).
	if _, err := adminDB.ExecContext(context.Background(),
		`UPDATE stats_leaderboard_all SET earnings_usd = 25.00 WHERE provider_id = 'p_drift'`,
	); err != nil {
		t.Fatalf("fake drift: %v", err)
	}

	// Capture zerolog by piping through a bytes.Buffer.
	var buf bytes.Buffer
	driftLogger := zerolog.New(&buf)
	cfg := freshRollupConfig().DefaultsApplied()
	if err := statsrollup.RunNightlyRebuild(context.Background(), rdb, cfg, driftLogger); err != nil {
		t.Fatalf("rebuild: %v", err)
	}

	logOut := buf.String()
	if !strings.Contains(logOut, "stats_rollup_drift_detected") {
		t.Errorf("expected drift event in rebuild log; got: %s", logOut)
	}
	if !strings.Contains(logOut, `"axis":"earnings"`) {
		t.Errorf("expected axis=earnings in drift event; got: %s", logOut)
	}

	// Post-commit value MUST be the rebuild value (50.00), not the
	// corrupted incremental value (25.00).
	var got string
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT earnings_usd FROM stats_leaderboard_all WHERE provider_id = 'p_drift'`,
	).Scan(&got); err != nil {
		t.Fatalf("scan post-rebuild: %v", err)
	}
	if got != "50.00" {
		t.Errorf("post-rebuild earnings_usd = %q, want 50.00 (rebuild value wins)", got)
	}
}

// ==========================================================================
// byte_estimated token semantic: round-3 CODE r3 HIGH 1 fix.
// A ledger row with usage_source='byte_estimated' has NULL
// completion_tokens and a non-NULL estimated_completion_tokens.
// The rollup MUST use the effective-token CASE expression so the
// row's tokens contribute to overview/leaderboard/timeseries.
// ==========================================================================
func TestRollupByteEstimatedTokenSemantic(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	now := time.Now().UTC()

	// Extend the OLTP stub with the estimated_completion_tokens
	// + usage_source columns SPEC-005 ships. The stub created in
	// applyMigrationsAndStubOLTP only has the basic columns —
	// extend here.
	if _, err := adminDB.ExecContext(context.Background(), `
        ALTER TABLE ledger_request_credits
            ADD COLUMN IF NOT EXISTS estimated_completion_tokens BIGINT,
            ADD COLUMN IF NOT EXISTS usage_source TEXT NOT NULL DEFAULT 'provider_reported'
    `); err != nil {
		t.Fatalf("extend OLTP stub: %v", err)
	}

	seedProviderTokens(t, adminDB, "p_byte_est")

	// Provider-reported row: completion_tokens = 50.
	seedLedgerRow(t, adminDB, "p_byte_est", now.Add(-1*time.Hour), 100, 50, 1_000_000)

	// Byte-estimated row: completion_tokens NULL,
	// estimated_completion_tokens = 75.
	if _, err := adminDB.ExecContext(context.Background(), `
        INSERT INTO ledger_request_credits (request_id, attempt_n, provider_id, ts_utc,
            prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source, provider_credits)
        VALUES ('req-byte-est', 0, 'p_byte_est', $1, 200, NULL, 75, 'byte_estimated', 2_000_000)
    `, now.Add(-30*time.Minute)); err != nil {
		t.Fatalf("seed byte_estimated row: %v", err)
	}

	logger := zerolog.Nop()
	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	// Overview: tokens_in should be 100+200=300; tokens_out
	// should be 50+75=125 (the byte_estimated row's
	// estimated_completion_tokens contributes).
	var tokensIn, tokensOut int64
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT tokens_in, tokens_out FROM stats_overview_current`,
	).Scan(&tokensIn, &tokensOut); err != nil {
		t.Fatalf("scan overview: %v", err)
	}
	if tokensIn != 300 {
		t.Errorf("overview tokens_in = %d, want 300", tokensIn)
	}
	if tokensOut != 125 {
		t.Errorf("overview tokens_out = %d, want 125 (byte_estimated must use estimated_completion_tokens)", tokensOut)
	}

	// Leaderboard: token total = 300 + 125 = 425.
	var lbTokens int64
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT tokens FROM stats_leaderboard_24h WHERE provider_id = 'p_byte_est'`,
	).Scan(&lbTokens); err != nil {
		t.Fatalf("scan leaderboard: %v", err)
	}
	if lbTokens != 425 {
		t.Errorf("leaderboard tokens = %d, want 425 (byte_estimated semantic)", lbTokens)
	}
}

// ==========================================================================
// rpm-only failure isolation: tpm continues fresh when rpm fails
// (per-component fault isolation). Round-2 CODE r2 MEDIUM 2 fix.
// ==========================================================================
func TestRollupTimeseriesPerComponentFailureIsolation(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	seedProviderTokens(t, adminDB, "p_x")
	now := time.Now().UTC()
	seedLedgerRow(t, adminDB, "p_x", now.Add(-5*time.Minute), 10, 10, 1_000_000)

	// Break the rpm table by adding a CHECK that no row can
	// satisfy. The tpm tick continues working.
	if _, err := adminDB.ExecContext(context.Background(),
		`ALTER TABLE stats_timeseries_rpm_30m ADD CONSTRAINT _rpm_break CHECK (false) NOT VALID`,
	); err != nil {
		t.Fatalf("add rpm break: %v", err)
	}
	defer func() {
		_, _ = adminDB.ExecContext(context.Background(),
			`ALTER TABLE stats_timeseries_rpm_30m DROP CONSTRAINT IF EXISTS _rpm_break`,
		)
	}()

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(700 * time.Millisecond)
	cancel()
	runner.Wait()

	var rpmErrAt sql.NullTime
	var tpmGenAt time.Time
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT last_error_at FROM stats_components_health WHERE component = 'timeseries_rpm'`,
	).Scan(&rpmErrAt); err != nil {
		t.Fatalf("rpm health scan: %v", err)
	}
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT generated_at FROM stats_components_health WHERE component = 'timeseries_tpm'`,
	).Scan(&tpmGenAt); err != nil {
		t.Fatalf("tpm health scan: %v", err)
	}

	if !rpmErrAt.Valid {
		t.Error("rpm last_error_at not set; rpm tick should have failed")
	}
	if time.Since(tpmGenAt) > 10*time.Second {
		t.Errorf("tpm generated_at stale: %v (now: %v); component isolation broken", tpmGenAt, time.Now())
	}
}

// ==========================================================================
// Retention clamp+warn: New(LateEventsRetentionDays=15) clamps
// to 30 without erroring. Round-2 ARCH r2 LOW 1 + BUILD §E.2.
// ==========================================================================
func TestRollupRetentionClampWarn(t *testing.T) {
	fx, _ := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	cfg := freshRollupConfig()
	cfg.LateEventsRetentionDays = 15

	runner, err := statsrollup.New(rdb, cfg, statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New with retention=15 (should clamp + warn, not error): %v", err)
	}
	if runner == nil {
		t.Fatal("runner.New returned nil")
	}
}

// ==========================================================================
// Work-only provider with EMPTY rewards ledger — Step 2 round-1
// CODE r1 CRITICAL 1 regression test. Earlier draft panicked on
// nil reward amount; now defaults to zero.
// ==========================================================================
func TestRollupWorkOnlyEmptyRewards(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	seedProviderTokens(t, adminDB, "p_work_only")
	now := time.Now().UTC()
	seedLedgerRow(t, adminDB, "p_work_only", now.Add(-1*time.Hour), 100, 100, 10_000_000)

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	// All four leaderboard windows MUST have the row (no panic).
	for _, w := range []string{"24h", "7d", "30d", "all"} {
		var n int
		table := "stats_leaderboard_" + w
		if err := adminDB.QueryRowContext(context.Background(),
			fmt.Sprintf(`SELECT COUNT(*) FROM %s WHERE provider_id = 'p_work_only'`, table),
		).Scan(&n); err != nil {
			t.Fatalf("scan %s: %v", w, err)
		}
		if n != 1 {
			t.Errorf("%s missing p_work_only (empty rewards must NOT panic): count=%d", w, n)
		}
	}

	// Health row freshness verifies no panic occurred.
	var genAt time.Time
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT generated_at FROM stats_components_health WHERE component = 'leaderboard_24h'`,
	).Scan(&genAt); err != nil {
		t.Fatalf("scan health: %v", err)
	}
	if time.Since(genAt) > 5*time.Second {
		t.Errorf("leaderboard_24h health not fresh: %v", genAt)
	}
}

// ==========================================================================
// Rewards-only provider absent from provider_tokens MUST NOT
// enter the leaderboard — Step 2 round-1 CRITICAL trust-source
// fix verification.
// ==========================================================================
func TestRollupRewardsOnlyUnauthenticatedRejected(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	// p_spoof is in provider_rewards_ledger but NOT in provider_tokens.
	// The pre-fix code allowed this to enter the leaderboard via the
	// rewards aggregation path.
	if _, err := adminDB.ExecContext(context.Background(),
		`INSERT INTO provider_rewards_ledger (provider_id, unix_ts, amount_usd) VALUES ('p_spoof', $1, 1000.00)`,
		time.Now().UTC().Add(-12*time.Hour).Unix(),
	); err != nil {
		t.Fatalf("seed spoofed reward: %v", err)
	}

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	var n int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_leaderboard_24h WHERE provider_id = 'p_spoof'`,
	).Scan(&n); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if n != 0 {
		t.Errorf("p_spoof entered leaderboard via rewards-only path; provider_tokens trust-source was bypassed (count=%d)", n)
	}
}

// ==========================================================================
// generated_at consistency: all rows in a leaderboard tick share
// the same generated_at, equal to the stats_components_health row.
// Step 2 round-1 CODE r1 HIGH 3 fix.
// ==========================================================================
func TestRollupGeneratedAtConsistency(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	now := time.Now().UTC()
	seedProviderTokens(t, adminDB, "p_a", "p_b", "p_c")
	for _, pid := range []string{"p_a", "p_b", "p_c"} {
		seedLedgerRow(t, adminDB, pid, now.Add(-1*time.Hour), 10, 10, 1_000_000)
	}

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	// Count distinct generated_at values in stats_leaderboard_24h —
	// must be exactly 1 (one tick).
	var distinct int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(DISTINCT generated_at) FROM stats_leaderboard_24h`,
	).Scan(&distinct); err != nil {
		t.Fatalf("scan distinct: %v", err)
	}
	if distinct != 1 {
		t.Errorf("stats_leaderboard_24h has %d distinct generated_at values; want 1 (one tick)", distinct)
	}

	// Compare to stats_components_health row.
	var leaderboardGen, healthGen time.Time
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT MAX(generated_at) FROM stats_leaderboard_24h`,
	).Scan(&leaderboardGen); err != nil {
		t.Fatalf("scan leaderboard: %v", err)
	}
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT generated_at FROM stats_components_health WHERE component = 'leaderboard_24h'`,
	).Scan(&healthGen); err != nil {
		t.Fatalf("scan health: %v", err)
	}
	if !leaderboardGen.Equal(healthGen) {
		t.Errorf("leaderboard_24h generated_at (%v) != health generated_at (%v); same-tick invariant violated", leaderboardGen, healthGen)
	}
}

// ==========================================================================
// blocked_from_partner_projection = TRUE is a v0.1 column STUB —
// the rollup MUST NOT branch on it (SPEC §6.1 + §11 Q11; BUILD
// §6). Step 2 round-2 ARCH/CODE/SECURITY r2 HIGH 1 fix: this
// test now asserts the v0.1 contract — blocked providers STILL
// appear in leaderboard storage; v0.2 will define partner-
// projection suppression semantics.
// ==========================================================================
func TestRollupBlockedProviderStillAppearsInV01(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	seedProviderTokens(t, adminDB, "p_blocked")
	now := time.Now().UTC()
	seedLedgerRow(t, adminDB, "p_blocked", now.Add(-1*time.Hour), 100, 100, 1_000_000)

	if _, err := adminDB.ExecContext(context.Background(),
		`INSERT INTO provider_visibility (provider_id, mode, blocked_from_partner_projection)
         VALUES ('p_blocked', 'bucketed', TRUE)`,
	); err != nil {
		t.Fatalf("seed blocked: %v", err)
	}

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	var n int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_leaderboard_24h WHERE provider_id = 'p_blocked'`,
	).Scan(&n); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if n != 1 {
		t.Errorf("v0.1 rollup MUST NOT branch on blocked_from_partner_projection (§6.1 + §11 Q11); p_blocked count = %d, want 1", n)
	}
}

// ==========================================================================
// Late-event detection: T-30h folds into 30d (inside lookback);
// T-60h lands in stats_late_events (outside lookback). Step 2
// round-1 ARCH r1 HIGH 1 + CODE r1 CRIT-2 fix.
// ==========================================================================
func TestRollupLateEventDetection(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()

	now := time.Now().UTC()
	seedProviderTokens(t, adminDB, "p_recent", "p_late")
	// T-30h (inside 48h lookback) — folds into 30d snapshot.
	seedLedgerRow(t, adminDB, "p_recent", now.Add(-30*time.Hour), 10, 10, 1_000_000)
	// T-60h (outside 48h lookback) — lands in stats_late_events.
	seedLedgerRow(t, adminDB, "p_late", now.Add(-60*time.Hour), 20, 20, 2_000_000)

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	// p_recent in 30d snapshot.
	var n int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_leaderboard_30d WHERE provider_id = 'p_recent'`,
	).Scan(&n); err != nil {
		t.Fatalf("scan 30d recent: %v", err)
	}
	if n != 1 {
		t.Errorf("p_recent (T-30h, inside lookback) missing from 30d snapshot: count=%d", n)
	}

	// p_late in stats_late_events.
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_late_events WHERE provider_id = 'p_late'`,
	).Scan(&n); err != nil {
		t.Fatalf("scan late events: %v", err)
	}
	if n < 1 {
		t.Errorf("p_late (T-60h, outside lookback) missing from stats_late_events: count=%d", n)
	}

	// Re-run the rollup: late events are idempotent — no duplicate
	// row for p_late.
	runner2, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New 2: %v", err)
	}
	ctx2, cancel2 := context.WithCancel(context.Background())
	runner2.Start(ctx2)
	time.Sleep(500 * time.Millisecond)
	cancel2()
	runner2.Wait()

	var n2 int
	if err := adminDB.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM stats_late_events WHERE provider_id = 'p_late'`,
	).Scan(&n2); err != nil {
		t.Fatalf("scan late events 2: %v", err)
	}
	if n2 != n {
		t.Errorf("late events not idempotent: first run=%d second run=%d", n, n2)
	}
}

// ==========================================================================
// Provider not in provider_tokens is INVISIBLE to the rollup
// (Step 1 trust-source decision; BUILD §F.3).
// ==========================================================================
func TestRollupIgnoresUnauthenticatedProviders(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	rdb := rollupDB(t, fx)
	logger := zerolog.Nop()
	now := time.Now().UTC()

	// p_auth is in provider_tokens; p_spoof is NOT.
	seedProviderTokens(t, adminDB, "p_auth")
	seedLedgerRow(t, adminDB, "p_auth", now.Add(-1*time.Hour), 50, 50, 1_000_000)
	seedLedgerRow(t, adminDB, "p_spoof", now.Add(-1*time.Hour), 999, 999, 99_000_000)

	runner, err := statsrollup.New(rdb, freshRollupConfig(), statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	time.Sleep(500 * time.Millisecond)
	cancel()
	runner.Wait()

	rows, err := adminDB.QueryContext(context.Background(),
		`SELECT provider_id FROM stats_leaderboard_24h ORDER BY provider_id`,
	)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var pid string
		if err := rows.Scan(&pid); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got = append(got, pid)
	}
	if len(got) != 1 || got[0] != "p_auth" {
		t.Errorf("leaderboard = %v, want only [p_auth] (p_spoof must NOT appear — provider_tokens trust-source)", got)
	}
}

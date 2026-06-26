package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"time"

	"github.com/rs/zerolog"
)

// runNightlyRebuild performs the §9.4 full rebuild of
// `stats_leaderboard_30d` AND `stats_leaderboard_all`. Per
// SPEC §9.4 v0.1.8, the rebuild uses Shape C (DELETE+INSERT in
// one PostgreSQL transaction). Concurrent `stats_reader`
// SELECTs see either the pre-DELETE snapshot or the post-INSERT
// snapshot — never a partial mix — by virtue of PostgreSQL MVCC.
//
// Drift detection runs DURING the rebuild: the rollup compares
// each rebuilt provider's (earnings, tokens, jobs) against the
// pre-rebuild incremental snapshot. >cfg.DriftThresholdRatio
// (default 0.005 = 0.5%) on any axis emits a structured
// `stats_rollup_drift_detected` log event.
//
// The 90-day retention DELETE on `stats_late_events` runs AFTER
// the rebuild commits (BUILD §C.3 + §9.3): it is a separate,
// idempotent step that can be retried independently of the
// rebuild atomicity.
func runNightlyRebuild(ctx context.Context, db *sql.DB, cfg Config, logger zerolog.Logger) error {
	for _, window := range []string{"30d", "all"} {
		if err := rebuildWindow(ctx, db, cfg, window, logger); err != nil {
			return fmt.Errorf("nightly rebuild %s: %w", window, err)
		}
	}
	if err := runLateEventsRetention(ctx, db, cfg); err != nil {
		// Retention failure does NOT roll back the rebuild
		// (BUILD §C.3 pin: separate idempotent step). Log and
		// continue.
		logger.Warn().Err(err).Msg("stats_late_events retention DELETE failed; will retry next nightly tick")
	}
	return nil
}

// rebuildWindow runs the §9.4 Shape C rebuild for one window
// AND drift-checks the rebuild against the pre-rebuild
// incremental snapshot.
func rebuildWindow(ctx context.Context, db *sql.DB, cfg Config, window string, logger zerolog.Logger) error {
	now := time.Now().UTC()
	table := leaderboardTableForWindow(window)
	if table == "" {
		return fmt.Errorf("rollup: rebuild unknown window %q", window)
	}

	pre, err := snapshotLeaderboard(ctx, db, table)
	if err != nil {
		return fmt.Errorf("snapshot pre: %w", err)
	}

	rebuilt, err := computeLeaderboardRows(ctx, db, cfg, window, now)
	if err != nil {
		return fmt.Errorf("compute: %w", err)
	}

	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	if _, err := tx.ExecContext(ctx, fmt.Sprintf(`DELETE FROM %s`, table)); err != nil {
		return fmt.Errorf("delete: %w", err)
	}
	for _, r := range rebuilt {
		if err := insertLeaderboardRow(ctx, tx, table, r); err != nil {
			return fmt.Errorf("insert %s: %w", r.ProviderID, err)
		}
	}

	if err := healthOK(ctx, tx, componentForWindow(window), now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	committed = true

	emitDriftEvents(window, pre, rebuilt, cfg.DriftThresholdRatio, logger)
	return nil
}

// snapshotLeaderboard reads the existing rows from a leaderboard
// table into an in-memory map for drift comparison.
func snapshotLeaderboard(ctx context.Context, db *sql.DB, table string) (map[string]preRebuildRow, error) {
	q := fmt.Sprintf(`
        SELECT provider_id, earnings_usd, tokens, jobs
          FROM %s
    `, table)
	rows, err := db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]preRebuildRow)
	for rows.Next() {
		var pid, amt string
		var tokens, jobs int64
		if err := rows.Scan(&pid, &amt, &tokens, &jobs); err != nil {
			return nil, err
		}
		r := preRebuildRow{Tokens: tokens, Jobs: jobs}
		r.Earnings, _ = new(big.Rat).SetString(amt)
		if r.Earnings == nil {
			r.Earnings = new(big.Rat)
		}
		out[pid] = r
	}
	return out, rows.Err()
}

type preRebuildRow struct {
	Earnings *big.Rat
	Tokens   int64
	Jobs     int64
}

// emitDriftEvents compares the pre-rebuild snapshot against the
// rebuilt rows axis-by-axis. Per SPEC §9.4 v0.1, >0.5% drift on
// any axis fires a `stats_rollup_drift_detected` structured log
// event. The rebuild value already wins (it overwrote the
// pre-rebuild rows in the same transaction); this loop only
// surfaces the divergence to the operator alerting pipeline.
func emitDriftEvents(window string, pre map[string]preRebuildRow, rebuilt []leaderboardRow, threshold float64, logger zerolog.Logger) {
	if threshold <= 0 {
		threshold = 0.005
	}
	for _, r := range rebuilt {
		prev, ok := pre[r.ProviderID]
		if !ok {
			// New provider since last rebuild — no drift base.
			continue
		}
		emitDriftIfExceeds(window, "earnings", r.ProviderID, ratToFloat(prev.Earnings), ratToFloat(r.EarningsTotalUSD), threshold, logger)
		emitDriftIfExceeds(window, "tokens", r.ProviderID, float64(prev.Tokens), float64(r.Tokens), threshold, logger)
		emitDriftIfExceeds(window, "jobs", r.ProviderID, float64(prev.Jobs), float64(r.Jobs), threshold, logger)
	}
}

func emitDriftIfExceeds(window, axis, pid string, prev, current, threshold float64, logger zerolog.Logger) {
	denom := current
	if denom == 0 {
		denom = prev
	}
	if denom == 0 {
		return
	}
	delta := current - prev
	if delta < 0 {
		delta = -delta
	}
	ratio := delta / denom
	if ratio <= threshold {
		return
	}
	logger.Warn().
		Str("event", "stats_rollup_drift_detected").
		Str("window", window).
		Str("axis", axis).
		Str("provider_id_sample", pid).
		Float64("delta_ratio", ratio).
		Float64("rebuild_value", current).
		Float64("incremental_value", prev).
		Float64("threshold", threshold).
		Msg("rollup drift exceeds threshold; rebuild value wins")
}

func ratToFloat(r *big.Rat) float64 {
	if r == nil {
		return 0
	}
	f, _ := r.Float64()
	return f
}

// runLateEventsRetention deletes stats_late_events rows older
// than the operator-configured retention window. Runs AFTER the
// nightly rebuild transaction commits (separate idempotent step
// per BUILD §C.3 + §9.3). A retention failure does NOT roll back
// the rebuild.
func runLateEventsRetention(ctx context.Context, db *sql.DB, cfg Config) error {
	q := `DELETE FROM stats_late_events WHERE recorded_at < now() - ($1::text || ' days')::interval`
	_, err := db.ExecContext(ctx, q, fmt.Sprintf("%d", cfg.LateEventsRetentionDays))
	if err != nil {
		return fmt.Errorf("late_events retention: %w", err)
	}
	return nil
}

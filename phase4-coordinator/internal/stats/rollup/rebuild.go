package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"math/big"
	"time"

	"github.com/rs/zerolog"
)

// runNightlyRebuild performs the §9.4 v0.1.8 Shape C full
// rebuild of `stats_leaderboard_30d` AND `stats_leaderboard_all`
// in a SINGLE PostgreSQL transaction (round-1 ARCH r1 CRIT-2
// fix). Per SPEC §9.4, the rebuild MUST execute atomically so
// no observer sees a half-rebuilt state — that invariant
// extends across BOTH tables: a failure mid-rebuild MUST leave
// BOTH at their pre-rebuild snapshots.
//
// Drift detection runs PER WINDOW DURING the rebuild: each
// rebuilt provider's (earnings, tokens, jobs) is compared
// against the pre-rebuild incremental snapshot.
// >cfg.DriftThresholdRatio (default 0.005 = 0.5%) on any axis
// emits a structured `stats_rollup_drift_detected` log event.
//
// The 90-day retention DELETE on `stats_late_events` runs
// AFTER the rebuild commits (BUILD §C.3 + §9.3): separate
// idempotent step that can be retried independently of the
// rebuild atomicity.
func runNightlyRebuild(ctx context.Context, db *sql.DB, cfg Config, logger zerolog.Logger) error {
	now := time.Now().UTC()
	windows := []string{"30d", "all"}

	pre := make(map[string]map[string]preRebuildRow, len(windows))
	rebuilt := make(map[string][]leaderboardRow, len(windows))

	// Compute all rebuilt row sets BEFORE opening the
	// transaction (heavy work outside the tx so the lock window
	// is minimal).
	for _, w := range windows {
		preSnap, err := snapshotLeaderboard(ctx, db, leaderboardTableForWindow(w))
		if err != nil {
			return fmt.Errorf("nightly rebuild %s snapshot: %w", w, err)
		}
		pre[w] = preSnap
		rows, err := computeLeaderboardRows(ctx, db, cfg, w, now)
		if err != nil {
			return fmt.Errorf("nightly rebuild %s compute: %w", w, err)
		}
		rebuilt[w] = rows
	}

	tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return fmt.Errorf("nightly rebuild begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	for _, w := range windows {
		table := leaderboardTableForWindow(w)
		if table == "" {
			return fmt.Errorf("rollup: nightly rebuild unknown window %q", w)
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf(`DELETE FROM %s`, table)); err != nil {
			return fmt.Errorf("nightly rebuild %s delete: %w", w, err)
		}
		for _, r := range rebuilt[w] {
			if err := insertLeaderboardRow(ctx, tx, table, r, now); err != nil {
				return fmt.Errorf("nightly rebuild %s insert %s: %w", w, r.ProviderID, err)
			}
		}
		if err := healthOK(ctx, tx, componentForWindow(w), now); err != nil {
			return fmt.Errorf("nightly rebuild %s health: %w", w, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("nightly rebuild commit: %w", err)
	}
	committed = true

	// Drift detection (post-commit log emission only — the
	// rebuild value already won by virtue of overwriting the
	// pre-rebuild rows in the same transaction).
	for _, w := range windows {
		emitDriftEvents(w, pre[w], rebuilt[w], cfg.DriftThresholdRatio, logger)
	}

	// §9.3 90-day retention DELETE — separate idempotent step;
	// failure does NOT roll back the rebuild.
	if err := runLateEventsRetention(ctx, db, cfg); err != nil {
		logger.Warn().Err(err).Msg("stats_late_events retention DELETE failed; will retry next nightly tick")
	}
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
// rebuilt rows axis-by-axis over the UNION of provider IDs. A
// >threshold delta on any axis fires `stats_rollup_drift_detected`.
// The rebuild value has already won (committed in the same
// transaction); this log surfaces the divergence to the operator
// alerting pipeline.
//
// Round-5 ARCH r5 HIGH 2 fix: prior draft iterated only the
// rebuilt set, so providers that the incremental snapshot
// contained but the full recompute correctly DROPPED were
// silently deleted without drift events firing. That is exactly
// the stale-extra-row class §9.4 wants operators to know about.
// We now iterate `pre ∪ rebuilt`, treating missing-from-rebuilt
// as zero (drop-out) and missing-from-pre as zero (new
// provider).
func emitDriftEvents(window string, pre map[string]preRebuildRow, rebuilt []leaderboardRow, threshold float64, logger zerolog.Logger) {
	if threshold <= 0 {
		threshold = 0.005
	}
	rebuiltByPID := make(map[string]leaderboardRow, len(rebuilt))
	for _, r := range rebuilt {
		rebuiltByPID[r.ProviderID] = r
	}
	pids := make(map[string]struct{}, len(pre)+len(rebuilt))
	for pid := range pre {
		pids[pid] = struct{}{}
	}
	for pid := range rebuiltByPID {
		pids[pid] = struct{}{}
	}
	for pid := range pids {
		prev, hasPrev := pre[pid]
		curr, hasCurr := rebuiltByPID[pid]

		var prevEarn float64
		var prevTokens, prevJobs int64
		if hasPrev {
			prevEarn = ratToFloat(prev.Earnings)
			prevTokens = prev.Tokens
			prevJobs = prev.Jobs
		}

		var currEarn float64
		var currTokens, currJobs int64
		if hasCurr {
			currEarn = ratToFloat(curr.EarningsTotalUSD)
			currTokens = curr.Tokens
			currJobs = curr.Jobs
		}

		emitDriftIfExceeds(window, "earnings", pid, prevEarn, currEarn, threshold, logger)
		emitDriftIfExceeds(window, "tokens", pid, float64(prevTokens), float64(currTokens), threshold, logger)
		emitDriftIfExceeds(window, "jobs", pid, float64(prevJobs), float64(currJobs), threshold, logger)
	}
}

// emitDriftIfExceeds implements the pinned SPEC §9.4 v0.1 drift
// formula: `(rebuild - incremental) / max(rebuild, 1) > threshold`.
//
// Round-2 CODE r2 MEDIUM 1 fix: the earlier draft used a
// `current ?: prev` denominator which overstated drift for
// sub-unit rebuild values (e.g. $0.50 rebuild vs $0.49
// incremental shows 2% drift). The pinned `max(rebuild, 1)`
// denominator suppresses noise on sub-unit values — at the
// dollar magnitudes the leaderboard tracks, sub-cent rounding
// is below threshold.
//
// `rebuild` is the post-recompute value; `incremental` is the
// pre-rebuild snapshot. The function uses ABSOLUTE delta so a
// negative rebuild-vs-incremental delta (incremental had MORE)
// also fires.
func emitDriftIfExceeds(window, axis, pid string, incremental, rebuild, threshold float64, logger zerolog.Logger) {
	denom := rebuild
	if denom < 1 {
		denom = 1
	}
	delta := rebuild - incremental
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
		Float64("rebuild_value", rebuild).
		Float64("incremental_value", incremental).
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
// nightly rebuild transaction commits per §9.3.
func runLateEventsRetention(ctx context.Context, db *sql.DB, cfg Config) error {
	q := `DELETE FROM stats_late_events WHERE recorded_at < now() - ($1::text || ' days')::interval`
	_, err := db.ExecContext(ctx, q, fmt.Sprintf("%d", cfg.LateEventsRetentionDays))
	if err != nil {
		return fmt.Errorf("late_events retention: %w", err)
	}
	return nil
}

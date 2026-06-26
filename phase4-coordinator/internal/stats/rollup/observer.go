package rollup

import (
	"context"
	"database/sql"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/metrics"
)

// ObserveRollupLagOnce performs a single pass over the §9.5
// components, reading generated_at from stats_components_health
// and setting the stats_rollup_lag_seconds gauge for each.
//
// The production coordinator wraps this in a 15s ticker (see
// cmd/coordinator/main.go observeRollupLag); Step 4.C
// integration tests call it directly to drive the gauge through
// the real reader-DB SQL path rather than synthesizing a
// `m.RollupLagSeconds.WithLabelValues(...).Set(...)` call.
//
// `db` MUST be the stats_reader pool (read-only) — the only
// table read here is stats_components_health, which the reader
// role has SELECT on.
//
// Round-3 ARCH r3 MEDIUM 1 / CODE r3 MEDIUM 2 fix.
func ObserveRollupLagOnce(ctx context.Context, db *sql.DB, m *metrics.Metrics) {
	if m == nil || db == nil {
		return
	}
	components := []string{
		"overview",
		"timeseries_rpm",
		"timeseries_tpm",
		"leaderboard_24h",
		"leaderboard_7d",
		"leaderboard_30d",
		"leaderboard_all",
	}
	const q = `SELECT generated_at FROM stats_components_health WHERE component = $1`
	now := time.Now().UTC()
	for _, c := range components {
		var ts time.Time
		row := db.QueryRowContext(ctx, q, c)
		if err := row.Scan(&ts); err != nil {
			// Missing row / read error → record zero rather than
			// skipping; absence of an update is itself a signal a
			// downstream dashboard may want to alert on.
			m.RollupLagSeconds.WithLabelValues(c).Set(0)
			continue
		}
		lag := now.Sub(ts).Seconds()
		if lag < 0 {
			lag = 0
		}
		m.RollupLagSeconds.WithLabelValues(c).Set(lag)
	}
}

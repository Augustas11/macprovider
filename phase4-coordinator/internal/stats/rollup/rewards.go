package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// runRewardsPopulatedTick computes the `rewards_populated`
// boolean per window per SPEC §9.1a + §5.2 and persists it to
// `stats_rewards_populated`. Each row keyed by window_label (the
// column was renamed in Step 1 to avoid the Postgres reserved
// keyword `window`).
//
// The handler in Step 3 MUST NOT compute this synchronously
// from `provider_rewards_ledger` (the request-path role does
// not have SELECT on the ledger). The rollup pre-computes; the
// handler reads from `stats_rewards_populated`.
//
// EXISTS is the cheap probe — we only need a boolean. Using
// COUNT(*) here would force a full scan on busy ledgers.
func runRewardsPopulatedTick(ctx context.Context, db *sql.DB, cfg Config) error {
	now := time.Now().UTC()
	for _, window := range []string{"24h", "7d", "30d", "all"} {
		populated, err := rewardsPopulatedForWindow(ctx, db, window, now, cfg.PartialHistorySinceUnix)
		if err != nil {
			return fmt.Errorf("rewards_populated %s: %w", window, err)
		}
		if _, err := db.ExecContext(ctx, `
            INSERT INTO stats_rewards_populated (window_label, rewards_populated, generated_at)
            VALUES ($1, $2, $3)
            ON CONFLICT (window_label) DO UPDATE SET
                rewards_populated = EXCLUDED.rewards_populated,
                generated_at = EXCLUDED.generated_at
        `, window, populated, now); err != nil {
			return fmt.Errorf("rewards_populated %s upsert: %w", window, err)
		}
	}
	return nil
}

func rewardsPopulatedForWindow(ctx context.Context, db *sql.DB, window string, now time.Time, partialHistorySinceUnix int64) (bool, error) {
	since := windowStart(window, now, partialHistorySinceUnix)
	end := now.Unix()
	var exists bool
	err := db.QueryRowContext(ctx, `
        SELECT EXISTS (
            SELECT 1
              FROM provider_rewards_ledger
             WHERE unix_ts >= $1 AND unix_ts < $2
             LIMIT 1
        )
    `, since, end).Scan(&exists)
	return exists, err
}

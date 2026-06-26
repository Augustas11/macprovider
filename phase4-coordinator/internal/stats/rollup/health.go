package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// component is one of the seven SPEC §9.1 v0.1.7 enum values.
// Each per-table rollup job owns exactly one component row in
// `stats_components_health`.
type component string

const (
	componentOverview        component = "overview"
	componentTimeseriesRpm   component = "timeseries_rpm"
	componentTimeseriesTpm   component = "timeseries_tpm"
	componentLeaderboard24h  component = "leaderboard_24h"
	componentLeaderboard7d   component = "leaderboard_7d"
	componentLeaderboard30d  component = "leaderboard_30d"
	componentLeaderboardAll  component = "leaderboard_all"
)

// healthOK marks the component as having a fresh successful
// tick. `generated_at` AND `last_ok_at` advance to the same
// timestamp; the `last_error_*` columns are NOT cleared so the
// most recent failure stays visible until a new failure
// overwrites it. This matches BUILD §2 Step 2 "preserve
// previous values" pin.
func healthOK(ctx context.Context, db sqlExecer, c component, at time.Time) error {
	const q = `
        UPDATE stats_components_health
           SET generated_at = $1,
               last_ok_at   = $1
         WHERE component = $2
    `
	_, err := db.ExecContext(ctx, q, at, string(c))
	if err != nil {
		return fmt.Errorf("rollup: healthOK component=%s: %w", c, err)
	}
	return nil
}

// healthFail records a tick failure WITHOUT advancing
// `generated_at` or `last_ok_at` — those stay at the last
// successful tick's value (or the bootstrap sentinel from
// migration 002 if no tick has ever succeeded). Step 3 derives
// `status` from the freshness of `generated_at` per SPEC §5.3,
// so leaving it unchanged is correct.
func healthFail(ctx context.Context, db sqlExecer, c component, at time.Time, errMsg string) error {
	// Truncate very long error messages so a perpetually-failing
	// tick doesn't bloat the row. 4 KiB is plenty for a Postgres
	// error chain.
	const maxMsgLen = 4096
	if len(errMsg) > maxMsgLen {
		errMsg = errMsg[:maxMsgLen]
	}
	const q = `
        UPDATE stats_components_health
           SET last_error_at      = $1,
               last_error_message = $2
         WHERE component = $3
    `
	_, err := db.ExecContext(ctx, q, at, errMsg, string(c))
	if err != nil {
		return fmt.Errorf("rollup: healthFail component=%s: %w", c, err)
	}
	return nil
}

// sqlExecer is the minimal surface helpers below need. *sql.DB,
// *sql.Tx, and *sql.Conn all satisfy it. Avoids leaking the
// concrete pool type into the helper signatures.
type sqlExecer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

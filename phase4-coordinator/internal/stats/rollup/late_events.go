package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// detectLateEvents records billing-row corrections older than
// the §9.3 lookback boundary into `stats_late_events`. v0.1 IMPL
// runs this AFTER each 30d/all rollup tick (BUILD §C.3 + §9.3:
// 30d/all windows MUST scan a lookback and record older events).
//
// Selection: any OLTP row joining authenticated `provider_tokens`
// AND `ts_utc < (now - LateEventsLookbackHours)` is a candidate.
// Dedup: `NOT EXISTS` on `source_billing_row` so re-running on
// every tick is idempotent (no UNIQUE constraint on
// `stats_late_events` per SPEC §9.1; we enforce uniqueness at
// INSERT-time via the anti-join). Per BUILD §D.3, the helper
// supplies `event_unix_ts`, `provider_id`, `delta_tokens`, and
// `source_billing_row` — `delta_usd` is NULL because the row's
// per-event USD requires the per-snapshot credits→USD conversion
// factor which is not the v0.1 IMPL's responsibility here.
//
// v0.1 simplification documented in this file's earlier draft:
// the SPEC §9.3 INCREMENTAL MERGE optimization is deferred.
// `detectLateEvents` exists now (round-1 ARCH r1 HIGH 1 + CODE
// r1 CRIT-2 fix) so the late-event TABLE is populated for
// operator forensics and the nightly rebuild's reconciliation
// data path, but the incremental-merge optimization itself
// (avoiding the full recompute) remains a v0.2 candidate.
func detectLateEvents(ctx context.Context, db *sql.DB, cfg Config, window string, now time.Time) error {
	cutoff := lateEventBoundary(now, cfg.LateEventsLookbackHours)
	winStart := windowStart(window, now, cfg.PartialHistorySinceUnix)

	// Lookback-old work-side rows.
	const workQ = `
        INSERT INTO stats_late_events (event_unix_ts, provider_id, delta_tokens, source_billing_row)
        SELECT EXTRACT(EPOCH FROM lrc.ts_utc)::BIGINT AS evt_ts,
               lrc.provider_id,
               (COALESCE(lrc.prompt_tokens, 0) + COALESCE(lrc.completion_tokens, 0))::BIGINT,
               'lrc:' || lrc.id::TEXT AS src
          FROM ledger_request_credits lrc
          JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id
         WHERE EXTRACT(EPOCH FROM lrc.ts_utc) < $1
           AND ($2 = 0 OR EXTRACT(EPOCH FROM lrc.ts_utc) >= $2)
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
           AND NOT EXISTS (
               SELECT 1 FROM stats_late_events sle
                WHERE sle.source_billing_row = 'lrc:' || lrc.id::TEXT
           )
    `
	if _, err := db.ExecContext(ctx, workQ, cutoff, winStart); err != nil {
		return fmt.Errorf("late events work: %w", err)
	}

	// Lookback-old rewards-side rows.
	const rewardsQ = `
        INSERT INTO stats_late_events (event_unix_ts, provider_id, delta_usd, source_billing_row)
        SELECT prl.unix_ts,
               prl.provider_id,
               prl.amount_usd,
               'prl:' || prl.id::TEXT AS src
          FROM provider_rewards_ledger prl
          JOIN provider_tokens pt ON pt.provider_id = prl.provider_id
         WHERE prl.unix_ts < $1
           AND ($2 = 0 OR prl.unix_ts >= $2)
           AND NOT EXISTS (
               SELECT 1 FROM stats_late_events sle
                WHERE sle.source_billing_row = 'prl:' || prl.id::TEXT
           )
    `
	if _, err := db.ExecContext(ctx, rewardsQ, cutoff, winStart); err != nil {
		return fmt.Errorf("late events rewards: %w", err)
	}

	return nil
}

// recordLateEvent INSERTs a single row into `stats_late_events`.
// Kept as a helper for any operator-tool or future v0.2
// incremental path that needs to record a synthetic late event
// outside the OLTP-scan path above.
func recordLateEvent(ctx context.Context, db sqlExecer, providerID string, eventUnixTs int64, deltaUSD, deltaTokens sql.NullInt64, sourceRow string) error {
	const q = `
        INSERT INTO stats_late_events (
            event_unix_ts, provider_id,
            delta_usd, delta_tokens, source_billing_row
        ) VALUES ($1, $2, $3, $4, $5)
    `
	_, err := db.ExecContext(ctx, q,
		eventUnixTs, providerID,
		nullDecimal(deltaUSD), deltaTokens,
		sourceRow,
	)
	if err != nil {
		return fmt.Errorf("late_event insert: %w", err)
	}
	return nil
}

func nullDecimal(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return v.Int64
}

// lateEventBoundary returns the cutoff unix-second below which
// an OLTP row is considered "late" for the rollup (older than
// `now - lookback`).
func lateEventBoundary(now time.Time, lookbackHours int) int64 {
	return now.Add(-time.Duration(lookbackHours) * time.Hour).Unix()
}

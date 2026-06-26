package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// IMPL-authored v0.1 simplification (surface for SPEC v0.2):
//
// SPEC §9.3 describes an incremental-merge optimization for the
// 30d and all leaderboard ticks: scan an
// `last_processed_at - 48h` to `now` lookback, merge corrections
// into the existing snapshot, record older-than-lookback events
// in `stats_late_events`. v0.1 IMPL takes a simpler path:
//
//   - 24h, 7d, 30d, all ticks all do a full per-cadence
//     recompute (DELETE + INSERT, see leaderboard.go).
//   - The nightly Shape C rebuild (rebuild.go) recomputes from
//     scratch every UTC night, reconciling any per-tick drift.
//   - `stats_late_events` exists in schema (Step 1) and has the
//     §7.2.2 INSERT grant, but v0.1 ticks do NOT proactively
//     INSERT into it — the incremental detection isn't wired.
//     `recordLateEvent` below is reachable from a future v0.2
//     IMPL of the incremental path.
//
// Justification: at Pearl's current scale (327 providers, ~$52
// top earnings), full recompute at the §9.2 cadence is cheap;
// the SPEC's incremental optimization earns its complexity only
// at substantially larger scale. SPEC v0.2 candidate flag: when
// per-provider count or window size exceeds the operator's
// pre-set tick budget, switch to incremental merge using the
// `recordLateEvent` + `lateEventBoundary` helpers below.

// recordLateEvent INSERTs a row into `stats_late_events` for a
// billing-row correction that arrived outside the
// `LateEventsLookbackHours` lookback window for the 30d or all
// rollup. Helper kept here so a future v0.2 incremental tick
// can call it without reshaping the package.
//
// The §7.2.2 grants give stats_rollup INSERT on
// `stats_late_events` plus USAGE,SELECT on
// `stats_late_events_id_seq`. No partition or special handling
// is needed.
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

// nullDecimal converts sql.NullInt64 to a NUMERIC-safe form. The
// `delta_usd` column is NUMERIC(18,2); passing nil is the lib/pq
// pattern for SQL NULL. Implemented inline to avoid pulling in
// a NullDecimal type the rest of the package doesn't need.
func nullDecimal(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return v.Int64
}

// lateEventBoundary returns the cutoff unix-second below which
// an OLTP row is considered "late" for the given window's
// rollup (i.e. older than `now - lookback`). The 30d / all ticks
// use this to decide whether to fold the row into the snapshot
// or record it for the nightly rebuild.
func lateEventBoundary(now time.Time, lookbackHours int) int64 {
	return now.Add(-time.Duration(lookbackHours) * time.Hour).Unix()
}

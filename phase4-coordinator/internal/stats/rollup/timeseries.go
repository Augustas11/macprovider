package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// runTimeseriesRpmTick rewrites the rolling-30-minute window of
// `stats_timeseries_rpm_30m`. SPEC §9.2: per-minute request
// counts over the last 30 minutes; each tick rewrites the full
// window so missing minutes appear by their absence (the Step 3
// handler projects them as JSON null per §5.1).
//
// The tick runs DELETE+INSERT inside a single transaction so
// concurrent `stats_reader` selects see either the pre-tick
// state or the post-tick state, never a partial mix.
func runTimeseriesRpmTick(ctx context.Context, db *sql.DB, cfg Config) error {
	now := time.Now().UTC()
	// `bucketEnd` is the upper-exclusive minute boundary for
	// the per-minute aggregation; `now` (un-truncated) is the
	// timestamp the health row records so freshness assertions
	// don't lag by up to 60s.
	bucketEnd := now.Truncate(time.Minute)
	windowStart := bucketEnd.Add(-30 * time.Minute)

	type rpmRow struct {
		bucket time.Time
		count  int64
	}

	rows := make([]rpmRow, 0, 30)
	const q = `
        SELECT date_trunc('minute', lrc.ts_utc) AS bucket,
               COUNT(DISTINCT lrc.request_id)::BIGINT AS count
          FROM ledger_request_credits lrc
          JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id
         WHERE lrc.ts_utc >= $1 AND lrc.ts_utc < $2
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
         GROUP BY bucket
         ORDER BY bucket
    `
	cursor, err := db.QueryContext(ctx, q, windowStart, bucketEnd)
	if err != nil {
		return fmt.Errorf("rpm select: %w", err)
	}
	for cursor.Next() {
		var r rpmRow
		if err := cursor.Scan(&r.bucket, &r.count); err != nil {
			cursor.Close()
			return fmt.Errorf("rpm scan: %w", err)
		}
		rows = append(rows, r)
	}
	cursor.Close()
	if err := cursor.Err(); err != nil {
		return fmt.Errorf("rpm rows.Err: %w", err)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("rpm begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	if _, err := tx.ExecContext(ctx,
		`DELETE FROM stats_timeseries_rpm_30m WHERE bucket_start < $1 OR bucket_start >= $2`,
		windowStart, bucketEnd,
	); err != nil {
		return fmt.Errorf("rpm prune-old: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM stats_timeseries_rpm_30m WHERE bucket_start >= $1 AND bucket_start < $2`,
		windowStart, bucketEnd,
	); err != nil {
		return fmt.Errorf("rpm clear-window: %w", err)
	}
	for _, r := range rows {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO stats_timeseries_rpm_30m (bucket_start, requests) VALUES ($1, $2)`,
			r.bucket, r.count,
		); err != nil {
			return fmt.Errorf("rpm insert: %w", err)
		}
	}
	if err := healthOK(ctx, tx, componentTimeseriesRpm, now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("rpm commit: %w", err)
	}
	committed = true
	return nil
}

// runTimeseriesTpmTick rewrites `stats_timeseries_tpm_30m`. Same
// shape as RPM but two counters (input_tokens, output_tokens)
// per minute bucket. Splits failures per-axis per BUILD §B.2:
// rpm and tpm are independent components in
// stats_components_health.
func runTimeseriesTpmTick(ctx context.Context, db *sql.DB, cfg Config) error {
	now := time.Now().UTC()
	bucketEnd := now.Truncate(time.Minute)
	windowStart := bucketEnd.Add(-30 * time.Minute)

	type tpmRow struct {
		bucket time.Time
		inTok  int64
		outTok int64
	}
	rows := make([]tpmRow, 0, 30)
	const q = `
        SELECT date_trunc('minute', lrc.ts_utc) AS bucket,
               COALESCE(SUM(lrc.prompt_tokens), 0)::BIGINT     AS in_tok,
               COALESCE(SUM(lrc.completion_tokens), 0)::BIGINT AS out_tok
          FROM ledger_request_credits lrc
          JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id
         WHERE lrc.ts_utc >= $1 AND lrc.ts_utc < $2
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
         GROUP BY bucket
         ORDER BY bucket
    `
	cursor, err := db.QueryContext(ctx, q, windowStart, bucketEnd)
	if err != nil {
		return fmt.Errorf("tpm select: %w", err)
	}
	for cursor.Next() {
		var r tpmRow
		if err := cursor.Scan(&r.bucket, &r.inTok, &r.outTok); err != nil {
			cursor.Close()
			return fmt.Errorf("tpm scan: %w", err)
		}
		rows = append(rows, r)
	}
	cursor.Close()
	if err := cursor.Err(); err != nil {
		return fmt.Errorf("tpm rows.Err: %w", err)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("tpm begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	if _, err := tx.ExecContext(ctx,
		`DELETE FROM stats_timeseries_tpm_30m WHERE bucket_start < $1 OR bucket_start >= $2`,
		windowStart, bucketEnd,
	); err != nil {
		return fmt.Errorf("tpm prune-old: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM stats_timeseries_tpm_30m WHERE bucket_start >= $1 AND bucket_start < $2`,
		windowStart, bucketEnd,
	); err != nil {
		return fmt.Errorf("tpm clear-window: %w", err)
	}
	for _, r := range rows {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO stats_timeseries_tpm_30m (bucket_start, input_tokens, output_tokens) VALUES ($1, $2, $3)`,
			r.bucket, r.inTok, r.outTok,
		); err != nil {
			return fmt.Errorf("tpm insert: %w", err)
		}
	}
	if err := healthOK(ctx, tx, componentTimeseriesTpm, now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("tpm commit: %w", err)
	}
	committed = true
	return nil
}

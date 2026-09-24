package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

const dailySeriesDays = 90

type dailyBucket struct {
	Day      time.Time
	Requests int64
	InTok    int64
	OutTok   int64
}

// completeDayWindow is the half-open UTC range [start, end) of complete
// days to publish. end is today's UTC midnight, so the open day is omitted.
// When sinceUnix is set, start moves forward to the first midnight that is
// entirely inside the rollup history.
func completeDayWindow(now time.Time, sinceUnix int64) (time.Time, time.Time) {
	now = now.UTC()
	end := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	start := end.AddDate(0, 0, -dailySeriesDays)
	if sinceUnix > 0 {
		since := time.Unix(sinceUnix, 0).UTC()
		first := time.Date(since.Year(), since.Month(), since.Day(), 0, 0, 0, 0, time.UTC)
		if since.After(first) {
			first = first.AddDate(0, 0, 1)
		}
		if first.After(start) {
			start = first
		}
	}
	if !start.Before(end) {
		return end, end
	}
	return start, end
}

func queryDailySeries(ctx context.Context, db *sql.DB, sinceUnix int64, now time.Time) ([]dailyBucket, error) {
	start, end := completeDayWindow(now, sinceUnix)
	if !start.Before(end) {
		return nil, nil
	}
	q := `
        SELECT (lrc.ts_utc AT TIME ZONE 'UTC')::date AS day,
               COUNT(DISTINCT lrc.request_id)::BIGINT,
               COALESCE(SUM(` + effectivePromptTokensSQL("lrc") + `), 0)::BIGINT,
               COALESCE(SUM(` + effectiveCompletionTokensSQL("lrc") + `), 0)::BIGINT
          FROM ledger_request_credits lrc
          JOIN ` + authenticatedProvidersRelation + ` pt ON pt.provider_id = lrc.provider_id
         WHERE lrc.ts_utc >= $1 AND lrc.ts_utc < $2
           AND ($3 = 0 OR EXTRACT(EPOCH FROM lrc.ts_utc) >= $3)
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
         GROUP BY day
         ORDER BY day
    `
	cursor, err := db.QueryContext(ctx, q, start, end, sinceUnix)
	if err != nil {
		return nil, fmt.Errorf("daily select: %w", err)
	}
	defer cursor.Close()
	byDay := map[string]dailyBucket{}
	for cursor.Next() {
		var row dailyBucket
		if err := cursor.Scan(&row.Day, &row.Requests, &row.InTok, &row.OutTok); err != nil {
			return nil, fmt.Errorf("daily scan: %w", err)
		}
		byDay[row.Day.UTC().Format("2006-01-02")] = row
	}
	if err := cursor.Err(); err != nil {
		return nil, fmt.Errorf("daily rows: %w", err)
	}

	out := make([]dailyBucket, 0, dailySeriesDays)
	for day := start; day.Before(end); day = day.AddDate(0, 0, 1) {
		key := day.Format("2006-01-02")
		if row, ok := byDay[key]; ok {
			row.Day = day
			out = append(out, row)
			continue
		}
		out = append(out, dailyBucket{Day: day})
	}
	return out, nil
}

func writeDailySeries(ctx context.Context, tx *sql.Tx, rows []dailyBucket) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM stats_timeseries_daily`); err != nil {
		return fmt.Errorf("daily clear: %w", err)
	}
	for _, row := range rows {
		if _, err := tx.ExecContext(ctx, `
            INSERT INTO stats_timeseries_daily (day_start, requests, input_tokens, output_tokens)
            VALUES ($1::date, $2, $3, $4)
        `, row.Day.UTC().Format("2006-01-02"), row.Requests, row.InTok, row.OutTok); err != nil {
			return fmt.Errorf("daily insert: %w", err)
		}
	}
	return nil
}

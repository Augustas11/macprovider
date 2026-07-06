package prewarm

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Summary is the provider-visible last-hour idle-prewarm projection.
type Summary struct {
	EventsLast1h        map[string]int64 `json:"events_last_1h"`
	SkipsByReasonLast1h map[string]int64 `json:"skips_by_reason_last_1h"`
}

// Reader exposes provider-bound idle-prewarm summaries to non-stats handlers.
type Reader struct {
	db *sql.DB
}

func NewReader(db *sql.DB) *Reader {
	return &Reader{db: db}
}

func (r *Reader) ProviderIdlePrewarm(ctx context.Context, providerID string) (Summary, error) {
	out := Summary{
		EventsLast1h:        map[string]int64{},
		SkipsByReasonLast1h: map[string]int64{},
	}
	if r == nil || r.db == nil {
		return out, nil
	}
	cutoff := time.Now().UTC().Add(-time.Hour)
	const eventsQ = `
        SELECT event, COUNT(*)
          FROM stats_idle_prewarm_events
         WHERE provider_id = $1
           AND recorded_at >= $2
         GROUP BY event
    `
	rows, err := r.db.QueryContext(ctx, eventsQ, providerID, cutoff)
	if err != nil {
		return out, fmt.Errorf("provider idle prewarm events select: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var event string
		var count int64
		if err := rows.Scan(&event, &count); err != nil {
			return out, err
		}
		out.EventsLast1h[event] = count
	}
	if err := rows.Err(); err != nil {
		return out, err
	}

	const skipsQ = `
        SELECT reason, COUNT(*)
          FROM stats_idle_prewarm_events
         WHERE provider_id = $1
           AND event = 'idle_prewarm_skipped'
           AND reason IS NOT NULL
           AND recorded_at >= $2
         GROUP BY reason
    `
	rows, err = r.db.QueryContext(ctx, skipsQ, providerID, cutoff)
	if err != nil {
		return out, fmt.Errorf("provider idle prewarm skips select: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var reason string
		var count int64
		if err := rows.Scan(&reason, &count); err != nil {
			return out, err
		}
		out.SkipsByReasonLast1h[reason] = count
	}
	return out, rows.Err()
}

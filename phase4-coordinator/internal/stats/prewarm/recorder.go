package prewarm

import (
	"context"
	"database/sql"
	"fmt"
)

// Recorder writes authenticated provider idle-prewarm telemetry into the
// SPEC-017 stats store. It is intentionally narrow so the WebSocket package
// does not need a general stats-rollup database dependency.
type Recorder struct {
	db *sql.DB
}

func NewRecorder(db *sql.DB) *Recorder {
	return &Recorder{db: db}
}

func (r *Recorder) RecordIdlePrewarmEvent(ctx context.Context, providerID, event, reason string) error {
	if r == nil || r.db == nil {
		return nil
	}
	if reason == "" {
		_, err := r.db.ExecContext(ctx, `
            INSERT INTO stats_idle_prewarm_events (provider_id, event, reason)
            VALUES ($1, $2, NULL)
        `, providerID, event)
		if err != nil {
			return fmt.Errorf("record idle prewarm event: %w", err)
		}
		return nil
	}
	_, err := r.db.ExecContext(ctx, `
        INSERT INTO stats_idle_prewarm_events (provider_id, event, reason)
        VALUES ($1, $2, $3)
    `, providerID, event, reason)
	if err != nil {
		return fmt.Errorf("record idle prewarm event: %w", err)
	}
	return nil
}

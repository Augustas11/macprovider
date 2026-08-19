package rollup

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

func runRoutabilityTick(ctx context.Context, db *sql.DB, snap SnapshotProvider) error {
	now := time.Now().UTC()
	live := RoutabilitySnapshot{At: now}
	if rp, ok := snap.(RoutabilitySnapshotProvider); ok {
		live = rp.RoutabilitySnapshot()
		if live.At.IsZero() {
			live.At = now
		}
	}

	summaryJSON, err := json.Marshal(live.Summary)
	if err != nil {
		return fmt.Errorf("routability summary marshal: %w", err)
	}
	modelsJSON, err := json.Marshal(live.Models)
	if err != nil {
		return fmt.Errorf("routability models marshal: %w", err)
	}
	providersJSON, err := json.Marshal(live.Providers)
	if err != nil {
		return fmt.Errorf("routability providers marshal: %w", err)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("routability begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	const upsert = `
        INSERT INTO stats_routability_current (
            singleton, generated_at, summary, models, providers
        ) VALUES (
            TRUE, $1, $2::jsonb, $3::jsonb, $4::jsonb
        )
        ON CONFLICT (singleton) DO UPDATE SET
            generated_at = EXCLUDED.generated_at,
            summary = EXCLUDED.summary,
            models = EXCLUDED.models,
            providers = EXCLUDED.providers
    `
	if _, err := tx.ExecContext(ctx, upsert, live.At.UTC(), string(summaryJSON), string(modelsJSON), string(providersJSON)); err != nil {
		return fmt.Errorf("routability upsert: %w", err)
	}
	if err := healthOK(ctx, tx, componentRoutability, live.At.UTC()); err != nil {
		return fmt.Errorf("routability health: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("routability commit: %w", err)
	}
	committed = true
	return nil
}

package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// IntakeRow is the singleton `stats_intake_current` row (SPEC-017 v0.2.1
// §5.2b, §9.1): the exact `unmatched_models` and `fleet_ram` JSON objects
// the endpoint serves.
type IntakeRow struct {
	GeneratedAt         time.Time
	UnmatchedModelsJSON []byte
	FleetRAMJSON        []byte
}

// Intake reads the singleton intake read model; nil when no rollup tick has
// written it yet.
func (s *Store) Intake(ctx context.Context) (*IntakeRow, error) {
	const q = `
        SELECT generated_at, unmatched_models, fleet_ram
          FROM stats_intake_current
         WHERE singleton = TRUE
         LIMIT 1
    `
	var r IntakeRow
	if err := s.db.QueryRowContext(ctx, q).Scan(&r.GeneratedAt, &r.UnmatchedModelsJSON, &r.FleetRAMJSON); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("intake select: %w", err)
	}
	return &r, nil
}

package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

type RoutabilityRow struct {
	GeneratedAt   time.Time
	SummaryJSON   []byte
	ModelsJSON    []byte
	ProvidersJSON []byte
}

func (s *Store) Routability(ctx context.Context) (*RoutabilityRow, error) {
	const q = `
        SELECT generated_at, summary, models, providers
          FROM stats_routability_current
         WHERE singleton = TRUE
         LIMIT 1
    `
	var r RoutabilityRow
	if err := s.db.QueryRowContext(ctx, q).Scan(
		&r.GeneratedAt, &r.SummaryJSON, &r.ModelsJSON, &r.ProvidersJSON,
	); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("routability select: %w", err)
	}
	return &r, nil
}

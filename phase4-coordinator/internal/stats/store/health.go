package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// ComponentHealth mirrors the per-component row of
// `stats_components_health`. The handler derives the JSON
// `status` field per §5.3 from `GeneratedAt` against §9.5
// thresholds; the table has NO `status` column.
type ComponentHealth struct {
	Component        string
	GeneratedAt      time.Time
	LastOkAt         time.Time
	LastErrorAt      sql.NullTime
	LastErrorMessage sql.NullString
}

// ComponentGeneratedAt returns the `generated_at` for one
// `stats_components_health` row. The handler uses this for the
// per-window leaderboard `generated_at` when the leaderboard
// table is empty (round-2 ARCH H1 / CODE H3 fix).
func (s *Store) ComponentGeneratedAt(ctx context.Context, component string) (time.Time, error) {
	const q = `
        SELECT generated_at
          FROM stats_components_health
         WHERE component = $1
         LIMIT 1
    `
	var gen time.Time
	if err := s.db.QueryRowContext(ctx, q, component).Scan(&gen); err != nil {
		if err == sql.ErrNoRows {
			return time.Time{}, nil
		}
		return time.Time{}, fmt.Errorf("component_generated_at: %w", err)
	}
	return gen, nil
}

func (s *Store) ComponentsHealth(ctx context.Context) ([]ComponentHealth, error) {
	const q = `
        SELECT component, generated_at, last_ok_at, last_error_at, last_error_message
          FROM stats_components_health
         ORDER BY component
    `
	rows, err := s.db.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("components_health select: %w", err)
	}
	defer rows.Close()
	var out []ComponentHealth
	for rows.Next() {
		var c ComponentHealth
		if err := rows.Scan(&c.Component, &c.GeneratedAt, &c.LastOkAt, &c.LastErrorAt, &c.LastErrorMessage); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

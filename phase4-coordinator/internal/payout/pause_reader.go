package payout

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// PauseReader provides read-only access to the persistent
// registration_paused flag. The §3.3 handler instantiates one
// at startup and shares it across handler requests; writes go
// through the §6.4.1 admin endpoints (Step 3) and the
// runtime_flags table.
type PauseReader struct {
	db *sql.DB
}

// NewPauseReader returns a PauseReader bound to the shared
// *sql.DB handle. It does not pre-warm the value; each call
// hits the DB so the §6.4.1 pause endpoint's flip is
// immediately observable.
func NewPauseReader(db *sql.DB) (*PauseReader, error) {
	if db == nil {
		return nil, fmt.Errorf("payout.NewPauseReader: db is required")
	}
	return &PauseReader{db: db}, nil
}

// IsRegistrationPaused returns true iff
// runtime_flags.value = 1 for name='registration_paused'.
// A missing row is treated as an error (callers MUST surface
// 500 and the startup-time sentinel-asymmetry detector will
// HALT on next boot).
func (p *PauseReader) IsRegistrationPaused(ctx context.Context) (bool, error) {
	var v int
	err := p.db.QueryRowContext(ctx,
		`SELECT value FROM runtime_flags WHERE name='registration_paused'`,
	).Scan(&v)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, fmt.Errorf("registration_paused flag missing (SPEC §4.8a invariant)")
		}
		return false, err
	}
	return v == 1, nil
}

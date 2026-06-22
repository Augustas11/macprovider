package ws

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

var errCanarySanctionStoreClosed = errors.New("canary sanction store is closed")

type CanarySanctionStore interface {
	LoadCanarySanctions(ctx context.Context) ([]pool.CanarySanctionSnapshot, error)
	UpsertCanarySanction(ctx context.Context, sanction pool.CanarySanctionSnapshot) error
	DeleteCanarySanction(ctx context.Context, providerID string) error
}

type SQLiteCanarySanctionStore struct {
	db *sql.DB
}

func NewSQLiteCanarySanctionStore(db *sql.DB) (*SQLiteCanarySanctionStore, error) {
	if db == nil {
		return nil, errCanarySanctionStoreClosed
	}
	s := &SQLiteCanarySanctionStore{db: db}
	if err := s.migrate(context.Background()); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *SQLiteCanarySanctionStore) migrate(ctx context.Context) error {
	if s == nil || s.db == nil {
		return errCanarySanctionStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS provider_canary_sanctions (
    provider_id          TEXT    PRIMARY KEY,
    fail_count           INTEGER NOT NULL,
    last_checked_at_utc  TEXT    NULL,
    last_failed_at_utc   TEXT    NULL,
    updated_at_utc       TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_provider_canary_sanctions_updated_at
    ON provider_canary_sanctions(updated_at_utc);
`)
	return err
}

func (s *SQLiteCanarySanctionStore) LoadCanarySanctions(ctx context.Context) ([]pool.CanarySanctionSnapshot, error) {
	if s == nil || s.db == nil {
		return nil, errCanarySanctionStoreClosed
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT provider_id, fail_count, last_checked_at_utc, last_failed_at_utc
FROM provider_canary_sanctions`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []pool.CanarySanctionSnapshot
	for rows.Next() {
		var providerID string
		var failCount int
		var checkedRaw, failedRaw sql.NullString
		if err := rows.Scan(&providerID, &failCount, &checkedRaw, &failedRaw); err != nil {
			return nil, err
		}
		checkedAt, err := parseOptionalTime(checkedRaw)
		if err != nil {
			return nil, fmt.Errorf("parse canary last_checked_at for %s: %w", providerID, err)
		}
		failedAt, err := parseOptionalTime(failedRaw)
		if err != nil {
			return nil, fmt.Errorf("parse canary last_failed_at for %s: %w", providerID, err)
		}
		out = append(out, pool.CanarySanctionSnapshot{
			ProviderID:    providerID,
			FailCount:     failCount,
			LastCheckedAt: checkedAt,
			LastFailedAt:  failedAt,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *SQLiteCanarySanctionStore) UpsertCanarySanction(ctx context.Context, sanction pool.CanarySanctionSnapshot) error {
	if s == nil || s.db == nil {
		return errCanarySanctionStoreClosed
	}
	if sanction.ProviderID == "" || sanction.FailCount <= 0 {
		return fmt.Errorf("invalid canary sanction snapshot")
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO provider_canary_sanctions (
    provider_id,
    fail_count,
    last_checked_at_utc,
    last_failed_at_utc,
    updated_at_utc
) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(provider_id) DO UPDATE SET
    fail_count = excluded.fail_count,
    last_checked_at_utc = excluded.last_checked_at_utc,
    last_failed_at_utc = excluded.last_failed_at_utc,
    updated_at_utc = excluded.updated_at_utc`,
		sanction.ProviderID,
		sanction.FailCount,
		formatOptionalTime(sanction.LastCheckedAt),
		formatOptionalTime(sanction.LastFailedAt),
		time.Now().UTC().Format(time.RFC3339Nano),
	)
	return err
}

func (s *SQLiteCanarySanctionStore) DeleteCanarySanction(ctx context.Context, providerID string) error {
	if s == nil || s.db == nil {
		return errCanarySanctionStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM provider_canary_sanctions WHERE provider_id = ?`, providerID)
	return err
}

func parseOptionalTime(raw sql.NullString) (*time.Time, error) {
	if !raw.Valid || raw.String == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339Nano, raw.String)
	if err != nil {
		return nil, err
	}
	t = t.UTC()
	return &t, nil
}

func formatOptionalTime(t *time.Time) any {
	if t == nil || t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}

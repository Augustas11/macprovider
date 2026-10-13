package sqlite

import (
	"context"
	"fmt"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// ensureQuotaReservationFundingSource adds the SPEC-050 funding source to
// quota reservations (existing rows are paid-quota rows) and the
// allowance_active_days table, and stamps v19 in the same transaction so an
// older gateway refuses the database (maxKnownSchemaVersion).
func (s *Store) ensureQuotaReservationFundingSource(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(quota_reservations)`)
	if err != nil {
		return err
	}
	found := false
	for rows.Next() {
		var cid, notNull, pk int
		var name, typ string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "funding_source" {
			found = true
		}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if !found {
		if _, err := tx.ExecContext(ctx, `ALTER TABLE quota_reservations ADD COLUMN funding_source TEXT NOT NULL DEFAULT 'quota' CHECK (funding_source IN ('quota', 'allowance'))`); err != nil {
			return fmt.Errorf("add quota_reservations.funding_source: %w", err)
		}
	}
	if _, err := tx.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS allowance_active_days (
		account_id TEXT NOT NULL,
		day TEXT NOT NULL,
		created_at TEXT NOT NULL,
		PRIMARY KEY (account_id, day)
	)`); err != nil {
		return fmt.Errorf("create allowance_active_days: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(19, ?)`, encodeTime(time.Now().UTC())); err != nil {
		return fmt.Errorf("stamp schema v19: %w", err)
	}
	return tx.Commit()
}

func normalizeFundingSource(source string) (string, error) {
	switch source {
	case "", storage.FundingSourceQuota:
		return storage.FundingSourceQuota, nil
	case storage.FundingSourceAllowance:
		return storage.FundingSourceAllowance, nil
	}
	return "", fmt.Errorf("unknown funding source %q", source)
}

// MarkReservationFundingSource sets the SPEC-050 funding of an active
// reservation after the coordinator answered: "allowance" takes it off the
// paid daily quota; "quota" puts an allowance-only reservation the
// coordinator did not fund back on it.
func (s *Store) MarkReservationFundingSource(ctx context.Context, accountID, requestID, source string) error {
	source, err := normalizeFundingSource(source)
	if err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE quota_reservations SET funding_source = ?
		WHERE account_id = ? AND request_id = ? AND status = 'active'`, source, accountID, requestID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return storage.ErrReservationNotFound
	}
	return nil
}

// NoteAllowanceDay records whether the coordinator reported an allowance
// for the account on the UTC day, so the gateway can forward a
// paid-quota-exhausted request as allowance-only across restarts and
// instances. Rows older than a week are pruned on write.
func (s *Store) NoteAllowanceDay(ctx context.Context, accountID, day string, active bool, now time.Time) error {
	if !active {
		_, err := s.db.ExecContext(ctx, `DELETE FROM allowance_active_days WHERE account_id = ? AND day = ?`, accountID, day)
		return err
	}
	res, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO allowance_active_days(account_id, day, created_at) VALUES(?, ?, ?)`,
		accountID, day, encodeTime(now.UTC()))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		_, err = s.db.ExecContext(ctx, `DELETE FROM allowance_active_days WHERE day < ?`, now.UTC().AddDate(0, 0, -7).Format("2006-01-02"))
	}
	return err
}

// AllowanceDayActive reports whether the coordinator reported an allowance
// for the account on the UTC day.
func (s *Store) AllowanceDayActive(ctx context.Context, accountID, day string) (bool, error) {
	var n int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM allowance_active_days WHERE account_id = ? AND day = ?`, accountID, day).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

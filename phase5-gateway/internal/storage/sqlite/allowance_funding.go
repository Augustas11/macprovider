package sqlite

import (
	"context"
	"fmt"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// ensureQuotaReservationFundingSource adds the SPEC-050 funding source to
// quota reservations. Existing rows are paid-quota rows.
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
	if found {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, `ALTER TABLE quota_reservations ADD COLUMN funding_source TEXT NOT NULL DEFAULT 'quota' CHECK (funding_source IN ('quota', 'allowance'))`); err != nil {
		return fmt.Errorf("add quota_reservations.funding_source: %w", err)
	}
	return nil
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

// MarkReservationAllowanceFunded moves an active paid-quota reservation to
// the SPEC-050 allowance after the coordinator funded the request from the
// account's allowance, so neither its hold nor its usage counts against the
// paid daily quota.
func (s *Store) MarkReservationAllowanceFunded(ctx context.Context, accountID, requestID string) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE quota_reservations SET funding_source = 'allowance'
		WHERE account_id = ? AND request_id = ? AND status = 'active'`, accountID, requestID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return storage.ErrReservationNotFound
	}
	return nil
}

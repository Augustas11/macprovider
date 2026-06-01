package billing

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

func (s *Store) ClaimPayoutReady(ctx context.Context, payoutID int64, expectedGrossCredits int64, payoutExternalID, payoutCurrency string) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer func() { _ = tx.Rollback() }()
	var windowStart, windowEnd string
	var grossCredits int64
	err = tx.QueryRowContext(ctx, `
SELECT window_start_utc, window_end_utc, gross_credits
  FROM ledger_payout_ready
 WHERE id = ?`, payoutID).Scan(&windowStart, &windowEnd, &grossCredits)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	res, err := tx.ExecContext(ctx, `
UPDATE ledger_payout_ready
   SET status = 'consumed',
       payout_external_id = ?,
       payout_currency = ?
 WHERE id = ?
   AND status = 'ready'
   AND gross_credits = ?`,
		nullString(payoutExternalID),
		nullString(payoutCurrency),
		payoutID,
		expectedGrossCredits,
	)
	if err != nil {
		return false, err
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	claimed := affected == 1
	status := "complete"
	var errText any
	if !claimed {
		status = "failed"
		errText = fmt.Sprintf("payout %d is not ready or amount changed", payoutID)
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.ExecContext(ctx, `
INSERT INTO ledger_reconciliation_runs (
    run_type, from_utc, to_utc, request_log_rows_scanned,
    missing_credit_rows_created, orphan_credit_rows_quarantined,
    buyer_equivalent_credits, provider_gross_credits,
    reconciliation_delta_credits, started_at_utc, finished_at_utc, status,
    error, created_at_utc
) VALUES ('spec_007_claim', ?, ?, 0, 0, 0, ?, ?, 0, ?, ?, ?, ?, ?)`,
		windowStart,
		windowEnd,
		grossCredits,
		grossCredits,
		now,
		now,
		status,
		errText,
		now,
	); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return claimed, nil
}

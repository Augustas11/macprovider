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
	var windowStart, windowEnd, payoutStatus string
	var sourceCreditCount, grossCredits, providerCredits, operatorCredits, minPayoutCredits int64
	err = tx.QueryRowContext(ctx, `
SELECT window_start_utc, window_end_utc, source_credit_count, gross_credits,
       provider_credits, operator_credits, min_payout_credits, status
  FROM ledger_payout_ready
 WHERE id = ?`, payoutID).Scan(
		&windowStart,
		&windowEnd,
		&sourceCreditCount,
		&grossCredits,
		&providerCredits,
		&operatorCredits,
		&minPayoutCredits,
		&payoutStatus,
	)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	recordClaimAudit := func(status string, errText any) error {
		_, err := tx.ExecContext(ctx, `
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
		)
		return err
	}
	if payoutStatus == "ready" {
		var sourceCount int64
		if err := tx.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM ledger_request_credits
 WHERE settlement_id = ?`, payoutID).Scan(&sourceCount); err != nil {
			return false, err
		}
		var payableCount, payableGross, payableProvider, payableOperator int64
		if err := tx.QueryRowContext(ctx, `
SELECT COUNT(*),
       COALESCE(SUM(lrc.gross_credits), 0),
       COALESCE(SUM(lrc.provider_credits), 0),
       COALESCE(SUM(lrc.gross_credits - lrc.provider_credits), 0)
  FROM ledger_request_credits lrc
  JOIN spec022_payable_request_credits payable ON payable.id = lrc.id
 WHERE lrc.settlement_id = ?`, payoutID).Scan(&payableCount, &payableGross, &payableProvider, &payableOperator); err != nil {
			return false, err
		}
		sourceSetValid := sourceCount > 0 && sourceCount == payableCount
		payoutMatchesSources := sourceCreditCount == payableCount &&
			grossCredits == payableGross &&
			providerCredits == payableProvider &&
			operatorCredits == payableOperator
		if !sourceSetValid || !payoutMatchesSources {
			if payableCount != sourceCount {
				if _, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET settled = 0,
       settlement_id = NULL,
       updated_at_utc = ?
 WHERE settlement_id = ?
   AND NOT EXISTS (
       SELECT 1
         FROM spec022_payable_request_credits payable
        WHERE payable.id = ledger_request_credits.id
   )`, now, payoutID); err != nil {
					return false, err
				}
			}
			if payableCount > 0 && payableProvider >= minPayoutCredits {
				if _, err := tx.ExecContext(ctx, `
UPDATE ledger_payout_ready
   SET source_credit_count = ?,
       gross_credits = ?,
       provider_credits = ?,
       operator_credits = ?
 WHERE id = ?
   AND status = 'ready'`,
					payableCount,
					payableGross,
					payableProvider,
					payableOperator,
					payoutID,
				); err != nil {
					return false, err
				}
			} else {
				if _, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET settled = 0,
       settlement_id = NULL,
       updated_at_utc = ?
 WHERE settlement_id = ?`, now, payoutID); err != nil {
					return false, err
				}
				if _, err := tx.ExecContext(ctx, `DELETE FROM ledger_payout_ready WHERE id = ? AND status = 'ready'`, payoutID); err != nil {
					return false, err
				}
			}
			if err := recordClaimAudit("failed", fmt.Sprintf("payout %d source credits were recomputed after SPEC-022 revalidation", payoutID)); err != nil {
				return false, err
			}
			if err := tx.Commit(); err != nil {
				return false, err
			}
			return false, nil
		}
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
	if err := recordClaimAudit(status, errText); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return claimed, nil
}

package billing

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

func (s *Store) RunSettlement(ctx context.Context, cfg SettlementConfig, windowStart, windowEnd time.Time) error {
	s.SetSettlementConfig(cfg)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'conflicting_settlement_id'),
       updated_at_utc = ?
 WHERE ts_utc < ?
   AND settled = 0
   AND settlement_id IS NOT NULL
   AND quarantined = 0`,
		now,
		windowEnd.UTC().Format(time.RFC3339Nano),
	); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'operator_split_mismatch'),
       updated_at_utc = ?
 WHERE ts_utc < ?
   AND settled = 0
   AND settlement_id IS NULL
   AND quarantined = 0
   AND (
       (
           SELECT COUNT(*)
             FROM ledger_operator_credits
            WHERE request_credit_id = ledger_request_credits.id
       ) != 1
       OR (
           SELECT COALESCE(SUM(operator_credits), 0)
             FROM ledger_operator_credits
            WHERE request_credit_id = ledger_request_credits.id
       ) + provider_credits != gross_credits
   )`,
		now,
		windowEnd.UTC().Format(time.RFC3339Nano),
	); err != nil {
		return err
	}
	rows, err := tx.QueryContext(ctx, `
SELECT provider_id, COUNT(*), SUM(gross_credits), SUM(provider_credits), SUM(gross_credits - provider_credits)
  FROM ledger_request_credits
 WHERE ts_utc < ? AND settled = 0 AND settlement_id IS NULL AND quarantined = 0
 GROUP BY provider_id
HAVING SUM(provider_credits) >= ?`,
		windowEnd.UTC().Format(time.RFC3339Nano),
		cfg.MinPayoutCredits,
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var providerID string
		var count, gross, providerCredits, operatorCredits int64
		if err := rows.Scan(&providerID, &count, &gross, &providerCredits, &operatorCredits); err != nil {
			return err
		}
		key := providerID + "|" + windowStart.UTC().Format(time.RFC3339Nano) + "|" + windowEnd.UTC().Format(time.RFC3339Nano)
		res, err := tx.ExecContext(ctx, `
INSERT INTO ledger_payout_ready (
    provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
    gross_credits, provider_credits, operator_credits, min_payout_credits,
    payout_currency, payout_external_id, status, idempotency_key, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 'ready', ?, ?)
ON CONFLICT(idempotency_key) DO UPDATE SET
    source_credit_count = source_credit_count + excluded.source_credit_count,
    gross_credits = gross_credits + excluded.gross_credits,
    provider_credits = provider_credits + excluded.provider_credits,
    operator_credits = operator_credits + excluded.operator_credits
WHERE ledger_payout_ready.status = 'ready'`,
			providerID,
			windowStart.UTC().Format(time.RFC3339Nano),
			windowEnd.UTC().Format(time.RFC3339Nano),
			cfg.CadenceDays,
			count,
			gross,
			providerCredits,
			operatorCredits,
			cfg.MinPayoutCredits,
			key,
			now,
		)
		if err != nil {
			return err
		}
		var settlementID int64
		var payoutStatus string
		err = tx.QueryRowContext(ctx, `SELECT id, status FROM ledger_payout_ready WHERE idempotency_key = ?`, key).Scan(&settlementID, &payoutStatus)
		if err != nil {
			return err
		}
		if payoutStatus != "ready" {
			continue
		}
		if affected, _ := res.RowsAffected(); affected == 0 {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET settled = 1, settlement_id = ?, updated_at_utc = ?
 WHERE provider_id = ? AND ts_utc < ? AND settled = 0 AND settlement_id IS NULL AND quarantined = 0`,
			settlementID,
			now,
			providerID,
			windowEnd.UTC().Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) StartWeeklySettlement(ctx context.Context, cfg SettlementConfig) {
	s.SetSettlementConfig(cfg)
	go func() {
		for {
			next := NextMondayUTC(time.Now().UTC())
			timer := time.NewTimer(time.Until(next))
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
				cfg := s.SettlementConfig(cfg)
				if !cfg.JobEnabled {
					continue
				}
				end := next
				start := end.AddDate(0, 0, -cfg.CadenceDays)
				_ = s.RunSettlement(ctx, cfg, start, end)
			}
		}
	}()
}

func NextMondayUTC(t time.Time) time.Time {
	t = t.UTC()
	day := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
	days := (int(time.Monday) - int(day.Weekday()) + 7) % 7
	if days == 0 && !t.Before(day) {
		days = 7
	}
	return day.AddDate(0, 0, days)
}

func nullIntFromRow(row *sql.Row) (int64, error) {
	var n sql.NullInt64
	if err := row.Scan(&n); err != nil {
		return 0, err
	}
	if !n.Valid {
		return 0, nil
	}
	return n.Int64, nil
}

func idempotencyKey(providerID string, start, end time.Time) string {
	return fmt.Sprintf("%s|%s|%s", providerID, start.UTC().Format(time.RFC3339Nano), end.UTC().Format(time.RFC3339Nano))
}

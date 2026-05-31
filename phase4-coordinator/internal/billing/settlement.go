package billing

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

func (s *Store) RunSettlement(ctx context.Context, cfg SettlementConfig, windowStart, windowEnd time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(ctx, `
SELECT provider_id, COUNT(*), SUM(gross_credits), SUM(provider_credits), SUM(gross_credits - provider_credits)
  FROM ledger_request_credits
 WHERE ts_utc >= ? AND ts_utc < ? AND settled = 0 AND quarantined = 0
 GROUP BY provider_id
HAVING SUM(provider_credits) >= ?`,
		windowStart.UTC().Format(time.RFC3339Nano),
		windowEnd.UTC().Format(time.RFC3339Nano),
		cfg.MinPayoutCredits,
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	now := time.Now().UTC().Format(time.RFC3339Nano)
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
ON CONFLICT(idempotency_key) DO NOTHING`,
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
		settlementID, _ := res.LastInsertId()
		if settlementID == 0 {
			err = tx.QueryRowContext(ctx, `SELECT id FROM ledger_payout_ready WHERE idempotency_key = ?`, key).Scan(&settlementID)
			if err != nil {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET settled = 1, settlement_id = ?, updated_at_utc = ?
 WHERE provider_id = ? AND ts_utc >= ? AND ts_utc < ? AND settled = 0 AND quarantined = 0`,
			settlementID,
			now,
			providerID,
			windowStart.UTC().Format(time.RFC3339Nano),
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
	if !cfg.JobEnabled {
		return
	}
	go func() {
		for {
			next := NextMondayUTC(time.Now().UTC())
			timer := time.NewTimer(time.Until(next))
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
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

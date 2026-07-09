package billing

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

func (s *Store) RunSettlement(ctx context.Context, cfg SettlementConfig, windowStart, windowEnd time.Time) error {
	s.SetSettlementConfig(cfg)
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	now := sqliteTimeText(time.Now().UTC())
	snapshotAtUTC := now
	defer func() {
		_, _ = conn.ExecContext(context.Background(), `DROP TABLE IF EXISTS temp.settlement_eligible_request_credits`)
	}()
	if _, err := conn.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'conflicting_settlement_id'),
       updated_at_utc = ?
 WHERE `+sqliteTimeBefore("ts_utc")+`
   AND settled = 0
   AND settlement_id IS NOT NULL
   AND quarantined = 0`,
		now,
		sqliteTimeText(windowEnd),
	); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'operator_split_mismatch'),
       updated_at_utc = ?
 WHERE `+sqliteTimeBefore("ts_utc")+`
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
		sqliteTimeText(windowEnd),
	); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `
CREATE TEMP TABLE IF NOT EXISTS settlement_eligible_request_credits (
    id INTEGER PRIMARY KEY,
    provider_id TEXT NOT NULL
);
DELETE FROM settlement_eligible_request_credits;`); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `
INSERT INTO settlement_eligible_request_credits (id, provider_id)
SELECT lrc.id, lrc.provider_id
  FROM ledger_request_credits lrc
 WHERE `+sqliteTimeBefore("lrc.ts_utc")+`
   AND lrc.settled = 0
   AND lrc.settlement_id IS NULL
   AND (
       lrc.quarantined = 0
       OR EXISTS (
           SELECT 1
             FROM ledger_quarantine_resolutions lqr
            WHERE lqr.request_credit_id = lrc.id
              AND lqr.id = (
                  SELECT latest.id
                    FROM ledger_quarantine_resolutions latest
                   WHERE latest.request_credit_id = lrc.id
                   ORDER BY latest.created_at_utc DESC, latest.id DESC
                   LIMIT 1
              )
              AND lqr.resolution_kind = 'force_credit'
              AND lqr.force_credit_matures_at_utc IS NOT NULL
              AND lqr.force_credit_matures_at_utc <= ?
       )
   )
   AND (
       COALESCE(lrc.settlement_policy_mode, 'legacy') IN ('legacy', 'observe')
       OR (
           lrc.settlement_policy_mode = 'enforce'
           AND lrc.settlement_account_scope_hash IS NOT NULL
           AND lrc.settlement_policy_version IS NOT NULL
           AND EXISTS (
               SELECT 1
                 FROM settlement_route_snapshots srs
                 JOIN settlement_receipt_verdicts srv
                   ON srv.account_scope_hash = lrc.settlement_account_scope_hash
                  AND srv.request_id = srs.request_id
                  AND srv.attempt_n = srs.attempt_n
                  AND srv.provider_id = srs.provider_id
                  AND srv.route_snapshot_digest = srs.route_snapshot_digest
                 JOIN settlement_attempt_outputs sao
                   ON sao.account_scope = srs.account_scope
                  AND sao.request_id = srs.request_id
                  AND sao.attempt_n = srs.attempt_n
                  AND sao.provider_id = srs.provider_id
                WHERE srs.request_id = lrc.request_id
                  AND srs.attempt_n = lrc.attempt_n
                  AND srs.provider_id = lrc.provider_id
                  AND srs.route_snapshot_mode = 'enforce'
                  AND srs.route_snapshot_policy_version = lrc.settlement_policy_version
                  AND srv.route_snapshot_mode = 'enforce'
                  AND srv.route_snapshot_policy_version = lrc.settlement_policy_version
                  AND srv.closed = 1
                  AND srv.settlement_outcome = 'verified'
                  AND sao.overlapping_or_duplicate = 0
           )
       )
   )
   AND NOT EXISTS (
       SELECT 1
         FROM ledger_payout_ready lpr
         JOIN ledger_quarantine_resolutions lqr
           ON lqr.request_credit_id = lrc.id
        WHERE lpr.provider_id = lrc.provider_id
          AND lpr.window_start_utc = ?
          AND lpr.window_end_utc = ?
          AND lqr.id = (
              SELECT latest.id
                FROM ledger_quarantine_resolutions latest
               WHERE latest.request_credit_id = lrc.id
               ORDER BY latest.created_at_utc DESC, latest.id DESC
               LIMIT 1
          )
          AND lqr.resolution_kind = 'force_credit'
          AND lqr.force_credit_matures_at_utc IS NOT NULL
          AND lqr.force_credit_matures_at_utc > lpr.created_at_utc
   )`,
		sqliteTimeText(windowEnd),
		snapshotAtUTC,
		sqliteTimeText(windowStart),
		sqliteTimeText(windowEnd),
	); err != nil {
		return err
	}
	rows, err := conn.QueryContext(ctx, `
SELECT lrc.provider_id, COUNT(*), SUM(lrc.gross_credits), SUM(lrc.provider_credits), SUM(lrc.gross_credits - lrc.provider_credits)
  FROM ledger_request_credits lrc
  JOIN settlement_eligible_request_credits eligible ON eligible.id = lrc.id
 GROUP BY lrc.provider_id
HAVING SUM(provider_credits) >= ?`,
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
		key := providerID + "|" + sqliteTimeText(windowStart) + "|" + sqliteTimeText(windowEnd)
		res, err := conn.ExecContext(ctx, `
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
			sqliteTimeText(windowStart),
			sqliteTimeText(windowEnd),
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
		err = conn.QueryRowContext(ctx, `SELECT id, status FROM ledger_payout_ready WHERE idempotency_key = ?`, key).Scan(&settlementID, &payoutStatus)
		if err != nil {
			return err
		}
		if payoutStatus != "ready" {
			continue
		}
		if affected, _ := res.RowsAffected(); affected == 0 {
			continue
		}
		if _, err := conn.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET settled = 1, settlement_id = ?, updated_at_utc = ?
 WHERE provider_id = ?
   AND id IN (SELECT id FROM settlement_eligible_request_credits WHERE provider_id = ?)`,
			settlementID,
			now,
			providerID,
			providerID,
		); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	return nil
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
	return fmt.Sprintf("%s|%s|%s", providerID, sqliteTimeText(start), sqliteTimeText(end))
}

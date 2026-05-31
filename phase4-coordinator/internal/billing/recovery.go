package billing

import (
	"context"
	"database/sql"
	"time"
)

type RecoverInput struct {
	ScanFrom time.Time
	ScanTo   time.Time
	Source   string
}

func (s *Store) RecoverLedger(ctx context.Context, in RecoverInput) error {
	if in.Source == "" {
		in.Source = "startup_scan"
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: false})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	started := time.Now().UTC()
	rows, err := tx.QueryContext(ctx, `
SELECT rl.id, rl.ts_utc, rl.request_id, rl.model, rl.provider_assigned_id,
       rl.prompt_tokens, rl.completion_tokens, rl.status, rl.stream, rl.error_code,
       COALESCE((
         SELECT COUNT(*) - 1 FROM request_log prior
          WHERE prior.request_id = rl.request_id AND prior.id <= rl.id
       ), 0) AS attempt_n
  FROM request_log rl
 WHERE rl.ts_utc >= ? AND rl.ts_utc < ?
   AND rl.provider_assigned_id IS NOT NULL
   AND rl.status != 503
 ORDER BY rl.ts_utc, rl.id`,
		in.ScanFrom.UTC().Format(time.RFC3339Nano),
		in.ScanTo.UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	scanned, created, quarantined := int64(0), int64(0), int64(0)
	buyerEquivalent, providerGross := int64(0), int64(0)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for rows.Next() {
		var rlID int64
		var tsText, requestID, model, assignedID string
		var errorCode sql.NullString
		var prompt, completion sql.NullInt64
		var status, stream, attemptN int
		if err := rows.Scan(&rlID, &tsText, &requestID, &model, &assignedID, &prompt, &completion, &status, &stream, &errorCode, &attemptN); err != nil {
			return err
		}
		scanned++
		ts, err := time.Parse(time.RFC3339Nano, tsText)
		if err != nil {
			ts = time.Now().UTC()
		}
		var providerID string
		err = tx.QueryRowContext(ctx, `
SELECT provider_id FROM ledger_provider_identity_snapshots
 WHERE request_id = ? AND attempt_n = ? AND provider_assigned_id = ?
 ORDER BY id DESC LIMIT 1`, requestID, attemptN, assignedID).Scan(&providerID)
		if err != nil {
			quarantined++
			continue
		}
		var exists int
		if err := tx.QueryRowContext(ctx, `
SELECT 1 FROM ledger_request_credits
 WHERE request_id = ? AND attempt_n = ? AND provider_id = ?
 LIMIT 1`, requestID, attemptN, providerID).Scan(&exists); err == nil {
			continue
		}
		snapshotID, rewards, multiplier, share, err := s.snapshotAt(ctx, ts)
		if err != nil {
			quarantined++
			continue
		}
		var pp, cp *int64
		if prompt.Valid {
			v := prompt.Int64
			pp = &v
		}
		if completion.Valid {
			v := completion.Int64
			cp = &v
		}
		input := HotPathInput{
			RequestID:          requestID,
			AttemptN:           attemptN,
			ProviderAssignedID: assignedID,
			ProviderID:         providerID,
			Model:              model,
			Status:             status,
			Stream:             stream == 1,
			TSUtc:              ts,
			PromptTokens:       pp,
			CompletionTokens:   cp,
			ErrorCode:          errorCode.String,
			FaultFlag:          FaultNone,
			ConfigSnapshotID:   snapshotID,
			RateEntry:          RateFor(rewards.RateCard, model),
			MultiplierPPM:      multiplier,
			ProviderShareBps:   share,
		}
		result := ComputeCredits(pp, cp, nil, usageFor(errorCode.String, nil), FaultNone, input.RateEntry, multiplier, share)
		id, err := insertRequestCreditTx(ctx, tx, input, result, in.Source, now, false, "")
		if err != nil {
			return err
		}
		if err := insertOperatorCreditTx(ctx, tx, id, input, result, now); err != nil {
			return err
		}
		created++
		buyerEquivalent += result.GrossCredits
		providerGross += result.GrossCredits
	}
	if err := rows.Err(); err != nil {
		return err
	}
	finished := time.Now().UTC()
	_, err = tx.ExecContext(ctx, `
INSERT INTO ledger_reconciliation_runs (
    run_type, from_utc, to_utc, request_log_rows_scanned,
    missing_credit_rows_created, orphan_credit_rows_quarantined,
    buyer_equivalent_credits, provider_gross_credits,
    reconciliation_delta_credits, started_at_utc, finished_at_utc, status,
    error, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'complete', NULL, ?)`,
		in.Source,
		in.ScanFrom.UTC().Format(time.RFC3339Nano),
		in.ScanTo.UTC().Format(time.RFC3339Nano),
		scanned,
		created,
		quarantined,
		buyerEquivalent,
		providerGross,
		providerGross-buyerEquivalent,
		started.Format(time.RFC3339Nano),
		finished.Format(time.RFC3339Nano),
		started.Format(time.RFC3339Nano),
	)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) StartStartupScan(ctx context.Context, cfg SettlementConfig, now time.Time) error {
	to := now.UTC().Add(-time.Duration(cfg.RecoveryGraceSeconds) * time.Second)
	from := to.Add(-time.Duration(cfg.StartupReconcileWindowHours) * time.Hour)
	return s.RecoverLedger(ctx, RecoverInput{ScanFrom: from, ScanTo: to, Source: "startup_scan"})
}

func (s *Store) StartNightlyReconcile(ctx context.Context, cfg SettlementConfig) {
	if !cfg.JobEnabled {
		return
	}
	go func() {
		for {
			now := time.Now().UTC()
			next := time.Date(now.Year(), now.Month(), now.Day()+1, 0, 0, 0, 0, time.UTC)
			timer := time.NewTimer(time.Until(next))
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
				to := time.Now().UTC().Add(-time.Duration(cfg.RecoveryGraceSeconds) * time.Second)
				from := to.AddDate(0, 0, -cfg.NightlyReconcileWindowDays)
				_ = s.RecoverLedger(ctx, RecoverInput{ScanFrom: from, ScanTo: to, Source: "nightly_reconcile"})
			}
		}
	}()
}

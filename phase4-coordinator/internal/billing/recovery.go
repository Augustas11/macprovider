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
	now := time.Now().UTC().Format(time.RFC3339Nano)
	orphanRes, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'missing_request_log'),
       updated_at_utc = ?
 WHERE quarantined = 0
   AND NOT EXISTS (
       SELECT 1 FROM request_log rl
        WHERE rl.request_id = ledger_request_credits.request_id
   )`, now)
	if err != nil {
		return err
	}
	orphanRows, _ := orphanRes.RowsAffected()
	rows, err := tx.QueryContext(ctx, `
SELECT rl.id, rl.ts_utc, rl.request_id, rl.model, rl.provider_assigned_id,
       rl.prompt_tokens, rl.completion_tokens, rl.status, rl.stream, rl.error_code,
       rl.retried,
       COALESCE((
         SELECT COUNT(*) - 1 FROM request_log prior
          WHERE prior.request_id = rl.request_id AND prior.id <= rl.id
       ), 0) AS attempt_n,
       COALESCE((
         SELECT COUNT(*) FROM request_log same
          WHERE same.request_id = rl.request_id
       ), 0) AS same_request_count
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
	scanned, created, quarantined := int64(0), int64(0), orphanRows
	buyerEquivalent, providerGross := int64(0), int64(0)
	for rows.Next() {
		var rlID int64
		var tsText, requestID, model, assignedID string
		var errorCode sql.NullString
		var prompt, completion sql.NullInt64
		var status, stream, retried, attemptN, sameRequestCount int
		if err := rows.Scan(&rlID, &tsText, &requestID, &model, &assignedID, &prompt, &completion, &status, &stream, &errorCode, &retried, &attemptN, &sameRequestCount); err != nil {
			return err
		}
		scanned++
		ts, err := time.Parse(time.RFC3339Nano, tsText)
		if err != nil {
			ts = time.Now().UTC()
		}
		if attemptN > 1 || (attemptN == 1 && retried == 0) || sameRequestCount > 2 {
			if err := insertQuarantineTx(ctx, tx, requestID, attemptN, unresolvedProviderID(assignedID), assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), errorCode.String, in.Source, "ambiguous_attempt_n", now); err != nil {
				return err
			}
			quarantined++
			continue
		}
		var providerID string
		err = tx.QueryRowContext(ctx, `
SELECT provider_id FROM ledger_provider_identity_snapshots
 WHERE request_id = ? AND attempt_n = ? AND provider_assigned_id = ?
	 ORDER BY id DESC LIMIT 1`, requestID, attemptN, assignedID).Scan(&providerID)
		if err != nil {
			if err := insertQuarantineTx(ctx, tx, requestID, attemptN, unresolvedProviderID(assignedID), assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), errorCode.String, in.Source, "missing_provider_identity", now); err != nil {
				return err
			}
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
			if err := insertQuarantineTx(ctx, tx, requestID, attemptN, providerID, assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), errorCode.String, in.Source, "missing_config_snapshot", now); err != nil {
				return err
			}
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
	s.SetSettlementConfig(cfg)
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
				cfg := s.SettlementConfig(cfg)
				to := time.Now().UTC().Add(-time.Duration(cfg.RecoveryGraceSeconds) * time.Second)
				from := to.AddDate(0, 0, -cfg.NightlyReconcileWindowDays)
				_ = s.RecoverLedger(ctx, RecoverInput{ScanFrom: from, ScanTo: to, Source: "nightly_reconcile"})
			}
		}
	}()
}

func insertQuarantineTx(ctx context.Context, tx *sql.Tx, requestID string, attemptN int, providerID, assignedID string, ts time.Time, model string, status int, stream bool, promptTokens, completionTokens *int64, errorCode, source, reason, now string) error {
	usage := usageFor(errorCode, nil)
	fault := FaultNone
	if usage == UsageNullError {
		fault = FaultNullUsageError
	}
	_, err := tx.ExecContext(ctx, `
INSERT OR IGNORE INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, prompt_tokens, completion_tokens, estimated_completion_tokens,
    usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc, quarantined, quarantine_reason
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, 0, 0, 0, 0, 0, 0, ?, ?, ?, 1, ?)`,
		requestID,
		attemptN,
		providerID,
		nullString(assignedID),
		ts.UTC().Format(time.RFC3339Nano),
		model,
		status,
		boolInt(stream),
		nullInt64(promptTokens),
		nullInt64(completionTokens),
		usage,
		fault,
		source,
		now,
		reason,
	)
	return err
}

func unresolvedProviderID(assignedID string) string {
	if assignedID == "" {
		return "__unresolved__"
	}
	return "__unresolved__:" + assignedID
}

func ppFromNull(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
}

func cpFromNull(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
}

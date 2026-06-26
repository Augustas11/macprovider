package billing

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

type RecoverInput struct {
	ScanFrom time.Time
	ScanTo   time.Time
	Source   string
}

func (s *Store) RecoverLedger(ctx context.Context, in RecoverInput) (retErr error) {
	if in.Source == "" {
		in.Source = "startup_scan"
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: false})
	if err != nil {
		return err
	}
	started := time.Now().UTC()
	defer func() {
		if retErr == nil {
			return
		}
		finished := time.Now().UTC()
		_, _ = s.db.ExecContext(context.Background(), `
INSERT INTO ledger_reconciliation_runs (
    run_type, from_utc, to_utc, request_log_rows_scanned,
    missing_credit_rows_created, orphan_credit_rows_quarantined,
    buyer_equivalent_credits, provider_gross_credits,
    reconciliation_delta_credits, started_at_utc, finished_at_utc, status,
    error, created_at_utc
) VALUES (?, ?, ?, 0, 0, 0, 0, 0, 0, ?, ?, 'failed', ?, ?)`,
			in.Source,
			in.ScanFrom.UTC().Format(time.RFC3339Nano),
			in.ScanTo.UTC().Format(time.RFC3339Nano),
			started.Format(time.RFC3339Nano),
			finished.Format(time.RFC3339Nano),
			retErr.Error(),
			started.Format(time.RFC3339Nano),
		)
	}()
	defer func() { _ = tx.Rollback() }()
	now := time.Now().UTC().Format(time.RFC3339Nano)
	orphanRes, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'missing_request_log'),
       updated_at_utc = ?
 WHERE quarantined = 0
    AND ts_utc >= ?
    AND ts_utc < ?
	AND NOT EXISTS (
       SELECT 1
         FROM request_log rl
         JOIN ledger_provider_identity_snapshots lpis
           ON lpis.request_id = rl.request_id
          AND lpis.provider_assigned_id = rl.provider_assigned_id
          AND lpis.attempt_n = ledger_request_credits.attempt_n
          AND lpis.provider_id = ledger_request_credits.provider_id
        WHERE rl.request_id = ledger_request_credits.request_id
          AND COALESCE((
              SELECT COUNT(*) - 1 FROM request_log prior
               WHERE prior.request_id = rl.request_id AND prior.id <= rl.id
          ), 0) = ledger_request_credits.attempt_n
   )`, now, in.ScanFrom.UTC().Format(time.RFC3339Nano), in.ScanTo.UTC().Format(time.RFC3339Nano))
	if err != nil {
		return err
	}
	orphanRows, _ := orphanRes.RowsAffected()
	rows, err := tx.QueryContext(ctx, `
SELECT rl.id, rl.ts_utc, rl.request_id, rl.model, rl.provider_assigned_id,
       rl.prompt_tokens, rl.completion_tokens, rl.estimated_completion_tokens,
       rl.status, rl.stream, rl.error_code,
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
		var prompt, completion, estimated sql.NullInt64
		var status, stream, retried, attemptN, sameRequestCount int
		if err := rows.Scan(&rlID, &tsText, &requestID, &model, &assignedID, &prompt, &completion, &estimated, &status, &stream, &errorCode, &retried, &attemptN, &sameRequestCount); err != nil {
			return err
		}
		scanned++
		ts, err := time.Parse(time.RFC3339Nano, tsText)
		if err != nil {
			ts = time.Now().UTC()
		}
		if invalidRecoveryToken(prompt) || invalidRecoveryEstimate(estimated) || invalidRecoveryCompletion(completion, estimated) {
			affected, err := quarantineExistingLedgerForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID, "invalid_usage_tokens", now)
			if err != nil {
				return err
			}
			if affected == 0 {
				exists, err := ledgerRowExistsForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID)
				if err != nil {
					return err
				}
				if !exists {
					if err := insertQuarantineTx(ctx, tx, requestID, attemptN, unresolvedProviderID(assignedID), assignedID, ts, model, status, stream == 1, nil, nil, errorCode.String, in.Source, "invalid_usage_tokens", now); err != nil {
						return err
					}
					quarantined++
				}
			}
			quarantined += affected
			continue
		}
		ambiguousAttempt := attemptN > 1 || (attemptN == 1 && retried == 0) || sameRequestCount > 2
		var providerID string
		err = tx.QueryRowContext(ctx, `
SELECT provider_id FROM ledger_provider_identity_snapshots
 WHERE request_id = ? AND attempt_n = ? AND provider_assigned_id = ?
	 ORDER BY id DESC LIMIT 1`, requestID, attemptN, assignedID).Scan(&providerID)
		if err != nil {
			reason := "missing_provider_identity"
			if ambiguousAttempt {
				reason = "ambiguous_attempt_n"
			}
			if err := insertQuarantineTx(ctx, tx, requestID, attemptN, unresolvedProviderID(assignedID), assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), errorCode.String, in.Source, reason, now); err != nil {
				return err
			}
			quarantined++
			continue
		}
		// Use the tx-bound queryer — at MaxOpenConns(1), calling
		// s.snapshotAt (which uses s.db) here would deadlock waiting for a
		// second connection that cannot be obtained while this tx pins the
		// only one. Issue #21 / ARCH-3.
		snapshotID, rewards, multiplier, share, err := snapshotAtTx(ctx, tx, ts)
		if err != nil {
			affected, quarantineErr := quarantineExistingLedgerForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID, "missing_config_snapshot", now)
			if quarantineErr != nil {
				return quarantineErr
			}
			if affected == 0 {
				exists, existsErr := ledgerRowExistsForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID)
				if existsErr != nil {
					return existsErr
				}
				if !exists {
					if err := insertQuarantineTx(ctx, tx, requestID, attemptN, providerID, assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), errorCode.String, in.Source, "missing_config_snapshot", now); err != nil {
						return err
					}
					quarantined++
				}
			}
			quarantined += affected
			continue
		}
		var pp, cp *int64
		var ep *int64
		if prompt.Valid {
			v := prompt.Int64
			pp = &v
		}
		if completion.Valid {
			v := completion.Int64
			cp = &v
		}
		if estimated.Valid {
			v := estimated.Int64
			ep = &v
		}
		input := HotPathInput{
			RequestID:           requestID,
			AttemptN:            attemptN,
			ProviderAssignedID:  assignedID,
			ProviderID:          providerID,
			Model:               model,
			Status:              status,
			Stream:              stream == 1,
			TSUtc:               ts,
			PromptTokens:        pp,
			CompletionTokens:    cp,
			EstimatedCompTokens: ep,
			ErrorCode:           errorCode.String,
			FaultFlag:           FaultNone,
			ConfigSnapshotID:    snapshotID,
			RateEntry:           RateFor(rewards.RateCard, model),
			MultiplierPPM:       multiplier,
			ProviderShareBps:    share,
		}
		result := ComputeCredits(pp, cp, ep, usageFor(errorCode.String, ep), FaultNone, input.RateEntry, multiplier, share)
		if attemptN > 1 {
			affected, err := quarantineExistingLedgerForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID, "ambiguous_attempt_n", now)
			if err != nil {
				return err
			}
			if affected == 0 {
				exists, err := ledgerRowExistsForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID)
				if err != nil {
					return err
				}
				if !exists {
					if err := insertQuarantineTx(ctx, tx, requestID, attemptN, providerID, assignedID, ts, model, status, stream == 1, pp, cp, errorCode.String, in.Source, "ambiguous_attempt_n", now); err != nil {
						return err
					}
					quarantined++
				}
			}
			quarantined += affected
			continue
		}
		actualGross, expectedGross, exists, mismatch, err := reconcileExistingCreditTx(ctx, tx, input, result, now)
		if err != nil {
			return err
		}
		if exists {
			buyerEquivalent += expectedGross
			providerGross += actualGross
			if mismatch {
				quarantined++
			}
			continue
		}
		if ambiguousAttempt {
			if err := insertQuarantineTx(ctx, tx, requestID, attemptN, providerID, assignedID, ts, model, status, stream == 1, pp, cp, errorCode.String, in.Source, "ambiguous_attempt_n", now); err != nil {
				return err
			}
			quarantined++
			continue
		}
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
				if !cfg.JobEnabled {
					continue
				}
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

func reconcileExistingCreditTx(ctx context.Context, tx *sql.Tx, input HotPathInput, expected BilledRow, now string) (int64, int64, bool, bool, error) {
	var id, gross, providerCredits, promptRate, completionRate, multiplier, share int64
	var usageSource, faultFlag string
	var estimated sql.NullInt64
	var quarantined, settled int
	var settlementID sql.NullInt64
	err := tx.QueryRowContext(ctx, `
SELECT id, gross_credits, provider_credits, usage_source, estimated_completion_tokens,
       prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm,
       provider_share_bps, fault_flag, quarantined, settled, settlement_id
  FROM ledger_request_credits
 WHERE request_id = ? AND attempt_n = ? AND provider_id = ?
 LIMIT 1`, input.RequestID, input.AttemptN, input.ProviderID).Scan(&id, &gross, &providerCredits, &usageSource, &estimated, &promptRate, &completionRate, &multiplier, &share, &faultFlag, &quarantined, &settled, &settlementID)
	if err == sql.ErrNoRows {
		return 0, 0, false, false, nil
	}
	if err != nil {
		return 0, 0, false, false, err
	}
	if quarantined == 1 {
		return 0, 0, true, false, nil
	}
	recomputed := expected
	allowByteEstimated := usageSource == UsageByteEstimated && input.CompletionTokens == nil && estimated.Valid
	if allowByteEstimated {
		recomputed = ComputeCredits(input.PromptTokens, input.CompletionTokens, intPtrFromNull(estimated), usageSource, faultFlag, input.RateEntry, input.MultiplierPPM, input.ProviderShareBps)
	} else {
		recomputed = expected
	}
	var operatorCredits sql.NullInt64
	var operatorRows int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(operator_credits), 0), COUNT(*) FROM ledger_operator_credits WHERE request_credit_id = ?`, id).Scan(&operatorCredits, &operatorRows); err != nil {
		return 0, 0, true, false, err
	}
	contractMismatch := promptRate != input.RateEntry.PromptCreditsPerMtok ||
		completionRate != input.RateEntry.CompletionCreditsPerMtok ||
		multiplier != input.MultiplierPPM ||
		share != input.ProviderShareBps
	if allowByteEstimated {
		contractMismatch = contractMismatch || usageSource != UsageByteEstimated || invalidBillableTokenCount(estimated.Int64)
	} else {
		contractMismatch = contractMismatch || usageSource != expected.UsageSource || faultFlag != expected.FaultFlag
	}
	mismatch := recomputed.GrossCredits != gross ||
		recomputed.ProviderCredits != providerCredits ||
		recomputed.FaultFlag != faultFlag ||
		contractMismatch ||
		operatorRows != 1 ||
		providerCredits+operatorCredits.Int64 != gross
	if mismatch {
		if settled == 1 || settlementID.Valid {
			return gross, recomputed.GrossCredits, true, false, fmt.Errorf("ledger mismatch on settled credit request_id=%s attempt_n=%d provider_id=%s", input.RequestID, input.AttemptN, input.ProviderID)
		}
		if _, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'reconciliation_mismatch'),
       updated_at_utc = ?
 WHERE id = ?`, now, id); err != nil {
			return 0, 0, true, false, err
		}
	}
	return gross, recomputed.GrossCredits, true, mismatch, nil
}

func ledgerRowExistsForRequestAttemptTx(ctx context.Context, tx *sql.Tx, requestID string, attemptN int, assignedID string) (bool, error) {
	var exists int
	err := tx.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1
      FROM ledger_request_credits
     WHERE request_id = ?
       AND attempt_n = ?
       AND (
           provider_assigned_id = ?
           OR provider_id IN (
               SELECT provider_id
                 FROM ledger_provider_identity_snapshots
                WHERE request_id = ?
                  AND attempt_n = ?
                  AND provider_assigned_id = ?
           )
       )
)`, requestID, attemptN, assignedID, requestID, attemptN, assignedID).Scan(&exists)
	if err != nil {
		return false, err
	}
	return exists == 1, nil
}

func quarantineExistingLedgerForRequestAttemptTx(ctx context.Context, tx *sql.Tx, requestID string, attemptN int, assignedID, reason, now string) (int64, error) {
	res, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, ?),
       updated_at_utc = ?
 WHERE request_id = ?
   AND attempt_n = ?
   AND quarantined = 0
   AND (
       provider_assigned_id = ?
       OR provider_id IN (
           SELECT provider_id
             FROM ledger_provider_identity_snapshots
            WHERE request_id = ?
              AND attempt_n = ?
              AND provider_assigned_id = ?
       )
   )`, reason, now, requestID, attemptN, assignedID, requestID, attemptN, assignedID)
	if err != nil {
		return 0, err
	}
	affected, _ := res.RowsAffected()
	return affected, nil
}

func invalidRecoveryToken(v sql.NullInt64) bool {
	return v.Valid && invalidBillableTokenCount(v.Int64)
}

func invalidRecoveryEstimate(v sql.NullInt64) bool {
	return v.Valid && invalidBillableTokenCount(v.Int64)
}

func invalidRecoveryCompletion(completion, estimated sql.NullInt64) bool {
	if !completion.Valid {
		return false
	}
	if completion.Int64 < 0 {
		return true
	}
	if completion.Int64 <= maxBillableTokens {
		return false
	}
	return !estimated.Valid || invalidRecoveryEstimate(estimated)
}

func intPtrFromNull(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
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

package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
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
	// SPEC-002 v1.5.0 / issue #211 money-path defense-in-depth: the
	// orphan-detection subquery and the `prior` / `same` counts below
	// scope by (account_id, request_id) using SQLite `IS` semantics
	// so all three reconciliation sites (hotpath.go, this file,
	// endpoints.go admin reconcile) compute the same attempt ordinal.
	// Note that rl.request_id is coordinator-internal (server-minted
	// UUID v4); the buyer-supplied collision class lives on
	// external_request_id and is addressed by the composite
	// (account_id, external_request_id) reconciliation key. This
	// scoping is defense-in-depth: should the same internal
	// request_id ever recur across accounts (UUID collision,
	// retry-loop bug, future schema change), each account's
	// attempts are derived within its own scope rather than
	// misclassified as cross-account retries. NULL-account_id
	// legacy rows cluster with NULL-account_id rows only —
	// backwards-compatible with pre-v1.5.0 single-account behavior.
	orphanRes, err := tx.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = COALESCE(quarantine_reason, 'missing_request_log'),
       updated_at_utc = ?
 WHERE quarantined = 0
    AND `+sqliteTimeRange("ts_utc")+`
	AND NOT EXISTS (
       SELECT 1
         FROM request_log rl
         JOIN ledger_provider_identity_snapshots lpis
           ON lpis.request_id = rl.request_id
          AND lpis.provider_assigned_id = rl.provider_assigned_id
          AND lpis.attempt_n = ledger_request_credits.attempt_n
          AND lpis.provider_id = ledger_request_credits.provider_id
        WHERE rl.request_id = ledger_request_credits.request_id
          -- SPEC-002 v1.5.2 / SPEC-005 v0.3.3 (issue #168): prefer
          -- the persisted monotonic rl.attempt_n exact match when
          -- non-NULL; fall back to the v0.3.1 id-ASC derivation for
          -- legacy NULL rows during the rollout window. Both paths
          -- compute identical ordinals.
          AND COALESCE(rl.attempt_n, (
              SELECT COUNT(*) - 1 FROM request_log prior
               WHERE prior.account_id IS rl.account_id
                 AND prior.request_id = rl.request_id
                 AND prior.id <= rl.id
          ), 0) = ledger_request_credits.attempt_n
   )`, now, sqliteTimeText(in.ScanFrom), sqliteTimeText(in.ScanTo))
	if err != nil {
		return err
	}
	orphanRows, _ := orphanRes.RowsAffected()
	rows, err := tx.QueryContext(ctx, `
SELECT rl.id, rl.ts_utc, rl.request_id, rl.account_id, rl.model, rl.provider_assigned_id,
       rl.prompt_tokens, rl.cached_prompt_tokens, rl.completion_tokens, rl.estimated_completion_tokens,
       rl.status, rl.stream, rl.error_code, rl.cache_quarantine_reason,
       rl.retried,
       -- SPEC-002 v1.5.2 / SPEC-005 v0.3.3 (issue #168): prefer
       -- persisted rl.attempt_n when non-NULL; fall back to the
       -- v0.3.1 id-ASC derivation for legacy NULL rows during the
       -- rollout window. Both paths compute identical ordinals.
       COALESCE(rl.attempt_n, (
         SELECT COUNT(*) - 1 FROM request_log prior
          WHERE prior.account_id IS rl.account_id
            AND prior.request_id = rl.request_id
            AND prior.id <= rl.id
       ), 0) AS attempt_n
  FROM request_log rl
 WHERE `+sqliteTimeRange("rl.ts_utc")+`
   AND rl.provider_assigned_id IS NOT NULL
   AND rl.status != 503
 ORDER BY rl.ts_utc, rl.id`,
		sqliteTimeText(in.ScanFrom),
		sqliteTimeText(in.ScanTo),
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
		var accountID, errorCode, cacheQuarantineReason sql.NullString
		var prompt, cached, completion, estimated sql.NullInt64
		var status, stream, retried, attemptN int
		if err := rows.Scan(&rlID, &tsText, &requestID, &accountID, &model, &assignedID, &prompt, &cached, &completion, &estimated, &status, &stream, &errorCode, &cacheQuarantineReason, &retried, &attemptN); err != nil {
			return err
		}
		scanned++
		ts, err := time.Parse(time.RFC3339Nano, tsText)
		if err != nil {
			ts = time.Now().UTC()
		}
		invalidReason := ""
		if invalidRecoveryToken(prompt) || invalidRecoveryEstimate(estimated) || invalidRecoveryCompletion(completion, estimated) {
			invalidReason = "invalid_usage_tokens"
		} else if invalidRecoveryCached(prompt, cached) {
			invalidReason = "invalid_cached_prompt_tokens"
		}
		if invalidReason != "" {
			affected, err := quarantineExistingLedgerForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID, invalidReason, now)
			if err != nil {
				return err
			}
			if affected == 0 {
				exists, err := ledgerRowExistsForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID)
				if err != nil {
					return err
				}
				if !exists {
					if err := insertQuarantineTx(ctx, tx, requestID, attemptN, unresolvedProviderID(assignedID), assignedID, ts, model, status, stream == 1, nil, nil, nil, errorCode.String, in.Source, invalidReason, now); err != nil {
						return err
					}
					quarantined++
				}
			}
			quarantined += affected
			continue
		}
		// SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168) quarantine
		// rule: with persisted monotonic attempt_n (or its byte-
		// identical id-ASC fallback for legacy NULL rows), row 3+
		// receives a stable distinct ordinal and is credited normally.
		// The v0.3.1 "attemptN > 1 || sameRequestCount > 2" trigger is
		// removed. The only remaining quarantine class is
		// attempt_n == 1 with retried == 0 — legitimate-retry-
		// without-explicit-marker that cannot be safely
		// distinguished from a buggy duplicate INSERT.
		ambiguousAttempt := attemptN == 1 && retried == 0
		var providerID string
		var identityConfigSnapshotID, providerReportedPrompt sql.NullInt64
		err = tx.QueryRowContext(ctx, `
	SELECT provider_id, config_snapshot_id, provider_reported_prompt_tokens FROM ledger_provider_identity_snapshots
	 WHERE request_id = ? AND attempt_n = ? AND provider_assigned_id = ?
		 ORDER BY id DESC LIMIT 1`, requestID, attemptN, assignedID).Scan(&providerID, &identityConfigSnapshotID, &providerReportedPrompt)
		if err != nil {
			reason := "missing_provider_identity"
			if ambiguousAttempt {
				reason = "ambiguous_attempt_n"
			}
			if err := insertQuarantineTx(ctx, tx, requestID, attemptN, unresolvedProviderID(assignedID), assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), intPtrFromNull(estimated), errorCode.String, in.Source, reason, now); err != nil {
				return err
			}
			quarantined++
			continue
		}
		if cacheQuarantineReason.Valid && cacheQuarantineReason.String != "" {
			affected, err := quarantineExistingLedgerForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID, cacheQuarantineReason.String, now)
			if err != nil {
				return err
			}
			if affected == 0 {
				exists, err := ledgerRowExistsForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID)
				if err != nil {
					return err
				}
				if !exists {
					if err := insertQuarantineTx(ctx, tx, requestID, attemptN, providerID, assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), intPtrFromNull(estimated), errorCode.String, in.Source, cacheQuarantineReason.String, now); err != nil {
						return err
					}
					quarantined++
				}
			}
			quarantined += affected
			continue
		}
		var snapshotID int64
		var rewards RewardsConfig
		var multiplier, share int64
		cacheProvenanceRequired := cached.Valid && cached.Int64 > 0 && attemptN == 0
		if identityConfigSnapshotID.Valid {
			snapshotID = identityConfigSnapshotID.Int64
			rewards, multiplier, share, err = snapshotByIDQueryer(ctx, tx, snapshotID)
		} else if cacheProvenanceRequired {
			err = ErrNoSnapshot
		} else {
			// Use the tx-bound queryer — at MaxOpenConns(1), calling
			// s.snapshotAt (which uses s.db) here would deadlock waiting for a
			// second connection that cannot be obtained while this tx pins the
			// only one. Issue #21 / ARCH-3.
			snapshotID, rewards, multiplier, share, err = snapshotAtTx(ctx, tx, ts)
		}
		if err != nil {
			reason := "missing_config_snapshot"
			if cacheProvenanceRequired {
				reason = "missing_cache_config_snapshot"
			}
			affected, quarantineErr := quarantineExistingLedgerForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID, reason, now)
			if quarantineErr != nil {
				return quarantineErr
			}
			if affected == 0 {
				exists, existsErr := ledgerRowExistsForRequestAttemptTx(ctx, tx, requestID, attemptN, assignedID)
				if existsErr != nil {
					return existsErr
				}
				if !exists {
					if err := insertQuarantineTx(ctx, tx, requestID, attemptN, providerID, assignedID, ts, model, status, stream == 1, ppFromNull(prompt), cpFromNull(completion), intPtrFromNull(estimated), errorCode.String, in.Source, reason, now); err != nil {
						return err
					}
					quarantined++
				}
			}
			quarantined += affected
			continue
		}
		var pp, cachedP, cp *int64
		var ep *int64
		if prompt.Valid {
			v := prompt.Int64
			pp = &v
		}
		reportedPP := pp
		if providerReportedPrompt.Valid {
			v := providerReportedPrompt.Int64
			reportedPP = &v
		}
		if cached.Valid && attemptN == 0 {
			v := cached.Int64
			cachedP = &v
		}
		if completion.Valid {
			v := completion.Int64
			cp = &v
		}
		if estimated.Valid {
			v := estimated.Int64
			ep = &v
		}
		settlementHash, settlementMode, settlementVersion, err := recoveredSettlementPolicyTx(ctx, tx, requestID, attemptN, providerID, accountID.String)
		if err != nil {
			return err
		}
		input := HotPathInput{
			RequestID:                    requestID,
			AttemptN:                     attemptN,
			ProviderAssignedID:           assignedID,
			ProviderID:                   providerID,
			Model:                        model,
			Status:                       status,
			Stream:                       stream == 1,
			TSUtc:                        ts,
			PromptTokens:                 pp,
			ProviderReportedPromptTokens: reportedPP,
			CachedPromptTokens:           cachedP,
			CompletionTokens:             cp,
			EstimatedCompTokens:          ep,
			ErrorCode:                    errorCode.String,
			FaultFlag:                    FaultNone,
			ConfigSnapshotID:             snapshotID,
			RateEntry:                    RateFor(rewards.RateCard, model),
			RateCard:                     rewards.RateCard,
			MultiplierPPM:                multiplier,
			ProviderShareBps:             share,
			SettlementAccountScopeHash:   settlementHash,
			SettlementPolicyMode:         settlementMode,
			SettlementPolicyVersion:      settlementVersion,
		}
		result := ComputeCreditsWithCache(pp, cachedP, cp, ep, usageFor(errorCode.String, ep), FaultNone, input.RateEntry, multiplier, share)
		// SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168): the v0.3.1
		// "attemptN > 1 unconditionally quarantines" branch is removed.
		// With persisted monotonic attempt_n (or its byte-identical
		// id-ASC fallback for legacy NULL rows), row 3+ has a stable
		// distinct ordinal and is credited normally. The ambiguousAttempt
		// flag above already captures the remaining quarantine class
		// (attempt_n==1 with retried==0) and was applied earlier in the
		// branch that resolved provider identity.
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
			if err := insertQuarantineTx(ctx, tx, requestID, attemptN, providerID, assignedID, ts, model, status, stream == 1, pp, cp, ep, errorCode.String, in.Source, "ambiguous_attempt_n", now); err != nil {
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
		reason, err := syncVerifiedReceiptLedgerCreditForAttemptTx(ctx, tx, requestID, int64(attemptN), providerID)
		if err != nil {
			return err
		}
		created++
		if reason == "" {
			buyerEquivalent += result.GrossCredits
			providerGross += result.GrossCredits
		} else {
			quarantined++
		}
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

func recoveredSettlementPolicyTx(ctx context.Context, tx *sql.Tx, requestID string, attemptN int, providerID, accountID string) (string, string, string, error) {
	var accountScope, mode, version string
	err := tx.QueryRowContext(ctx, `
SELECT account_scope, route_snapshot_mode, route_snapshot_policy_version
  FROM settlement_route_snapshots
 WHERE account_scope = ?
   AND request_id = ? AND attempt_n = ? AND provider_id = ?
 ORDER BY id DESC
 LIMIT 1`, AccountScopeForSettlement(accountID), requestID, attemptN, providerID).Scan(&accountScope, &mode, &version)
	if err == nil {
		return SettlementAccountScopeHash(accountScope), settlementPolicyModeOrLegacy(mode), version, nil
	}
	if err != sql.ErrNoRows {
		return "", "", "", err
	}
	return SettlementAccountScopeHashForAccountID(accountID), "legacy", "", nil
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

func insertQuarantineTx(ctx context.Context, tx *sql.Tx, requestID string, attemptN int, providerID, assignedID string, ts time.Time, model string, status int, stream bool, promptTokens, completionTokens, estimatedCompletionTokens *int64, errorCode, source, reason, now string) error {
	usage := usageFor(errorCode, estimatedCompletionTokens)
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
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 0, 0, ?, ?, ?, 1, ?)`,
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
		nullInt64(estimatedCompletionTokens),
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
	var cached, estimated sql.NullInt64
	var quarantined, settled int
	var settlementID sql.NullInt64
	err := tx.QueryRowContext(ctx, `
SELECT id, gross_credits, provider_credits, usage_source, cached_prompt_tokens, estimated_completion_tokens,
       prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm,
       provider_share_bps, fault_flag, quarantined, settled, settlement_id
  FROM ledger_request_credits
 WHERE request_id = ? AND attempt_n = ? AND provider_id = ?
 LIMIT 1`, input.RequestID, input.AttemptN, input.ProviderID).Scan(&id, &gross, &providerCredits, &usageSource, &cached, &estimated, &promptRate, &completionRate, &multiplier, &share, &faultFlag, &quarantined, &settled, &settlementID)
	if err == sql.ErrNoRows {
		return 0, 0, false, false, nil
	}
	if err != nil {
		return 0, 0, false, false, err
	}
	if quarantined == 1 {
		return 0, 0, true, false, nil
	}
	summaryExpected := expected
	rowRecomputed := expected
	recomputeRateEntry := input.RateEntry
	usesCachedDiscount := cached.Valid && cached.Int64 > 0
	if !usesCachedDiscount {
		recomputeRateEntry = RateCardEntry{
			PromptCreditsPerMtok:     promptRate,
			CompletionCreditsPerMtok: completionRate,
		}
	}
	allowByteEstimated := usageSource == UsageByteEstimated && input.CompletionTokens == nil && estimated.Valid
	if allowByteEstimated {
		summaryExpected = ComputeCreditsWithCache(input.PromptTokens, input.CachedPromptTokens, input.CompletionTokens, intPtrFromNull(estimated), usageSource, faultFlag, input.RateEntry, input.MultiplierPPM, input.ProviderShareBps)
		rowRecomputed = ComputeCreditsWithCache(input.PromptTokens, input.CachedPromptTokens, input.CompletionTokens, intPtrFromNull(estimated), usageSource, faultFlag, recomputeRateEntry, input.MultiplierPPM, input.ProviderShareBps)
	} else {
		rowRecomputed = ComputeCreditsWithCache(input.PromptTokens, input.CachedPromptTokens, input.CompletionTokens, input.EstimatedCompTokens, usageSource, faultFlag, recomputeRateEntry, input.MultiplierPPM, input.ProviderShareBps)
	}
	var operatorCredits sql.NullInt64
	var operatorRows int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(operator_credits), 0), COUNT(*) FROM ledger_operator_credits WHERE request_credit_id = ?`, id).Scan(&operatorCredits, &operatorRows); err != nil {
		return 0, 0, true, false, err
	}
	contractMismatch := multiplier != input.MultiplierPPM || share != input.ProviderShareBps
	if usesCachedDiscount {
		contractMismatch = contractMismatch ||
			promptRate != input.RateEntry.PromptCreditsPerMtok ||
			completionRate != input.RateEntry.CompletionCreditsPerMtok
	} else {
		contractMismatch = contractMismatch || !recoveryRateContractMatches(input, promptRate, completionRate)
	}
	receiptExpected, hasVerifiedReceipt, err := verifiedReceiptExpectedCreditTx(ctx, tx, id, input, cached, promptRate, completionRate, multiplier, share, faultFlag)
	if err != nil {
		return 0, 0, true, false, err
	}
	if hasVerifiedReceipt {
		summaryExpected = receiptExpected
		rowRecomputed = receiptExpected
		expected = receiptExpected
		contractMismatch = multiplier != input.MultiplierPPM || share != input.ProviderShareBps
		if usesCachedDiscount {
			contractMismatch = contractMismatch ||
				promptRate != input.RateEntry.PromptCreditsPerMtok ||
				completionRate != input.RateEntry.CompletionCreditsPerMtok
		} else {
			contractMismatch = contractMismatch || !recoveryRateContractMatches(input, promptRate, completionRate)
		}
	} else if faultFlag == FaultBreakerQualifying {
		// request_log does not persist breaker qualification. Existing hot-path
		// credits do, so recovery must preserve that ledger-side fault contract
		// instead of comparing it to the request-log-only FaultNone default.
		summaryExpected = rowRecomputed
		expected = rowRecomputed
	}
	if allowByteEstimated {
		contractMismatch = contractMismatch || usageSource != UsageByteEstimated || invalidBillableTokenCount(estimated.Int64)
	} else {
		contractMismatch = contractMismatch || usageSource != expected.UsageSource || faultFlag != expected.FaultFlag
	}
	mismatch := rowRecomputed.GrossCredits != gross ||
		rowRecomputed.ProviderCredits != providerCredits ||
		rowRecomputed.FaultFlag != faultFlag ||
		!nullInt64MatchesPtr(cached, input.CachedPromptTokens) ||
		contractMismatch ||
		operatorRows != 1 ||
		providerCredits+operatorCredits.Int64 != gross
	if mismatch {
		if settled == 1 || settlementID.Valid {
			return gross, summaryExpected.GrossCredits, true, false, fmt.Errorf("ledger mismatch on settled credit request_id=%s attempt_n=%d provider_id=%s", input.RequestID, input.AttemptN, input.ProviderID)
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
	return gross, summaryExpected.GrossCredits, true, mismatch, nil
}

func verifiedReceiptExpectedCreditTx(ctx context.Context, tx *sql.Tx, requestCreditID int64, input HotPathInput, cached sql.NullInt64, promptRate, completionRate, multiplier, share int64, faultFlag string) (BilledRow, bool, error) {
	var usageJSON string
	err := tx.QueryRowContext(ctx, `
SELECT sao.usage_canonical_json
  FROM ledger_request_credits lrc
  JOIN settlement_receipt_verdicts srv
    ON srv.account_scope_hash = lrc.settlement_account_scope_hash
   AND srv.request_id = lrc.request_id
   AND srv.attempt_n = lrc.attempt_n
   AND srv.provider_id = lrc.provider_id
   AND srv.route_snapshot_mode = 'enforce'
   AND srv.route_snapshot_policy_version = lrc.settlement_policy_version
   AND srv.closed = 1
   AND srv.settlement_outcome = 'verified'
  JOIN settlement_route_snapshots srs
    ON srs.request_id = lrc.request_id
   AND srs.attempt_n = lrc.attempt_n
   AND srs.provider_id = lrc.provider_id
   AND srs.route_snapshot_digest = srv.route_snapshot_digest
   AND srs.route_snapshot_mode = 'enforce'
   AND srs.route_snapshot_policy_version = lrc.settlement_policy_version
  JOIN settlement_attempt_outputs sao
    ON sao.account_scope = srs.account_scope
   AND sao.request_id = srs.request_id
   AND sao.attempt_n = srs.attempt_n
   AND sao.provider_id = srs.provider_id
   AND sao.overlapping_or_duplicate = 0
 WHERE lrc.id = ?
   AND lrc.settlement_policy_mode = 'enforce'
   AND lrc.settlement_account_scope_hash IS NOT NULL
   AND lrc.settlement_policy_version IS NOT NULL
 LIMIT 1`, requestCreditID).Scan(&usageJSON)
	if err != nil {
		if err == sql.ErrNoRows {
			return BilledRow{}, false, nil
		}
		return BilledRow{}, false, err
	}
	var usage settlementUsageV04
	if err := json.Unmarshal([]byte(usageJSON), &usage); err != nil {
		return BilledRow{}, false, fmt.Errorf("decode settlement receipt-bound usage: %w", err)
	}
	chargedPrompt := usage.BillableInputTokens
	if input.PromptTokens != nil && chargedPrompt > *input.PromptTokens {
		chargedPrompt = *input.PromptTokens
	}
	completion := usage.BillableOutputTokens
	rateEntry := RateCardEntry{PromptCreditsPerMtok: promptRate, CompletionCreditsPerMtok: completionRate}
	var cachedPrompt *int64
	if cached.Valid && cached.Int64 > 0 {
		if cached.Int64 > chargedPrompt {
			return BilledRow{}, false, nil
		}
		cachedPrompt = &cached.Int64
		rateEntry = input.RateEntry
	}
	return ComputeCreditsWithCache(&chargedPrompt, cachedPrompt, &completion, nil, UsageProviderReported, faultFlag, rateEntry, multiplier, share), true, nil
}

func recoveryRateContractMatches(input HotPathInput, promptRate, completionRate int64) bool {
	if rateEntryMatches(input.RateEntry, promptRate, completionRate) {
		return true
	}
	return recoveryLegacyDefaultRateMatches(input, promptRate, completionRate)
}

// recoveryLegacyDefaultRateCutoffUTC bounds the served-alias/default-rate
// compatibility carve-out to rows created before the catalog-alias resolver
// rollout. Read-only Pearl evidence on 2026-08-05 showed the affected
// mlx-community Llama rows ended at 05:11Z; the origin/main resolver commit
// followed at 05:21Z.
var recoveryLegacyDefaultRateCutoffUTC = time.Date(2026, 8, 5, 5, 21, 11, 0, time.UTC)

func recoveryLegacyDefaultRateMatches(input HotPathInput, promptRate, completionRate int64) bool {
	if input.RateCard == nil {
		return false
	}
	if !input.TSUtc.Before(recoveryLegacyDefaultRateCutoffUTC) {
		return false
	}
	if !legacyServedAliasDefaultFallbackModel(input.Model) {
		return false
	}
	if _, ok := input.RateCard[input.Model]; ok {
		return false
	}
	lowerModel := strings.ToLower(strings.TrimSpace(input.Model))
	if _, ok := input.RateCard[lowerModel]; ok {
		return false
	}
	normalizedModel := NormalizeModelKey(input.Model)
	if normalizedModel != "" {
		if _, ok := input.RateCard[normalizedModel]; ok {
			return false
		}
	}
	entry, ok := input.RateCard["default"]
	return ok && rateEntryMatches(entry, promptRate, completionRate)
}

func legacyServedAliasDefaultFallbackModel(model string) bool {
	key := strings.ToLower(strings.TrimSpace(model))
	namespace := ""
	if slash := strings.IndexByte(key, '/'); slash >= 0 {
		namespace = key[:slash]
		key = key[slash+1:]
	}
	for _, suffix := range []string{"-mxfp4-q8", "-4bit", "-8bit"} {
		key = strings.TrimSuffix(key, suffix)
	}
	return namespace == "mlx-community" && strings.HasPrefix(key, "llama-")
}

func rateEntryMatches(entry RateCardEntry, promptRate, completionRate int64) bool {
	return entry.PromptCreditsPerMtok == promptRate &&
		entry.CompletionCreditsPerMtok == completionRate
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

func invalidRecoveryCached(prompt, cached sql.NullInt64) bool {
	if !cached.Valid {
		return false
	}
	if invalidBillableTokenCount(cached.Int64) {
		return true
	}
	return cached.Int64 > 0 && (!prompt.Valid || cached.Int64 > prompt.Int64)
}

func intPtrFromNull(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
}

func nullInt64MatchesPtr(v sql.NullInt64, p *int64) bool {
	if !v.Valid {
		return p == nil
	}
	return p != nil && v.Int64 == *p
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

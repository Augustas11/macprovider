package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	settlementReceiptEventIngested = "settlement_receipt_ingested"
	settlementReceiptEventVerdict  = "settlement_receipt_verdict"

	settlementReceiptIDPending              = "pending"
	settlementReceiptIDPendingUpdated       = "pending_updated"
	settlementReceiptIDFirstTerminal        = "first_terminal"
	settlementReceiptIDTerminalAfterPending = "terminal_after_pending"
	settlementReceiptIDTerminalNoop         = "terminal_noop"

	settlementReceiptProfileV04             = "spec015-v0.4"
	settlementReceiptNoMoneyMovementStep5   = "no_money_movement_step5"
	settlementReceiptPayoutExcludedUntil022 = "excluded_until_spec022_verified"
)

type SettlementReceiptIdentity struct {
	AccountScope string
	RequestID    string
	AttemptN     int64
	ProviderID   string
}

type SettlementReceiptIngestionInput struct {
	SettlementReceiptIdentity
	Header                string
	ProviderReceiptPubkey []byte
	receiptReceivedUnixMS int64
}

type SettlementReceiptMissingInput struct {
	SettlementReceiptIdentity
	NowUnixMS int64
}

type SettlementReceiptState struct {
	SettlementReceiptIdentity
	ReceiptPresent                bool
	ReceiptVersion                string
	ReceiptResult                 string
	SettlementOutcome             string
	Reason                        string
	IdempotencyStatus             string
	Closed                        bool
	TerminalState                 string
	TerminalStateTSUnixMS         int64
	PendingDeadlineUnixMS         int64
	ReceivedAtUnixMS              int64
	RouteSnapshotDigest           string
	RouteSnapshotPolicyVersion    string
	RouteSnapshotMode             string
	PaidEntrypoint                string
	ProviderSessionID             string
	ProviderGenerationID          string
	Spec008HashStatus             string
	ProviderReportedModelHash     string
	ProviderReceiptKeyFingerprint string
	CatalogID                     string
	CatalogBodyDigest             string
	ExpectedCatalogModelHash      string
	ModelID                       string
	ModelHash                     string
	ReceiptProfile                string
	BuyerDebitOutcome             string
	ProviderSettlementOutcome     string
	PayoutExclusionOutcome        string
	PromptHash                    string
	OutputHash                    string
	UsageDigest                   string
	ReceiptTupleCanonicalSHA256   string
	Checks                        SettlementVerificationChecks
}

type SettlementReceiptAuthorization struct {
	SettlementReceiptIdentity
	ReceiptResult                 string
	SettlementOutcome             string
	Reason                        string
	PositiveSettlementCandidate   bool
	CandidateBlockedReason        string
	Closed                        bool
	TerminalState                 string
	TerminalStateTSUnixMS         int64
	PendingDeadlineUnixMS         int64
	ReceivedAtUnixMS              int64
	RouteSnapshotDigest           string
	RouteSnapshotPolicyVersion    string
	RouteSnapshotMode             string
	PaidEntrypoint                string
	ProviderSessionID             string
	ProviderGenerationID          string
	Spec008HashStatus             string
	ProviderReportedModelHash     string
	ProviderReceiptKeyFingerprint string
	CatalogID                     string
	CatalogBodyDigest             string
	ExpectedCatalogModelHash      string
	ModelID                       string
	ModelHash                     string
	ReceiptProfile                string
	BuyerDebitOutcome             string
	ProviderSettlementOutcome     string
	PayoutExclusionOutcome        string
	PromptHash                    string
	OutputHash                    string
	UsageDigest                   string
	Checks                        SettlementVerificationChecks
}

type settlementEvidence struct {
	route      RouteSnapshot
	routeHash  string
	attempt    settlementAttemptEvidence
	deadlineMS int64
}

type settlementAttemptEvidence struct {
	TerminalState          string
	TerminalStateTSUnixMS  int64
	OutputAvailable        bool
	OutputPrefixStartByte  int64
	OutputPrefixEndByte    int64
	OutputHash             string
	UsageHash              string
	Usage                  SettlementUsage
	UsageSource            string
	OverlappingOrDuplicate bool
}

type settlementReceiptPersisted struct {
	SettlementReceiptState
	checksJSON      string
	diagnosticsJSON string
	factsJSON       sql.NullString
}

func (s *Store) IngestSettlementReceipt(ctx context.Context, input SettlementReceiptIngestionInput) (SettlementReceiptState, error) {
	if err := input.SettlementReceiptIdentity.validate(); err != nil {
		return SettlementReceiptState{}, err
	}
	if input.Header == "" {
		return SettlementReceiptState{}, fmt.Errorf("receipt header is required")
	}
	if len(input.ProviderReceiptPubkey) == 0 {
		return SettlementReceiptState{}, fmt.Errorf("provider receipt pubkey is required")
	}
	receivedAt := input.receiptReceivedUnixMS
	if receivedAt == 0 {
		receivedAt = s.nowUTC().UnixMilli()
	}
	return s.applySettlementReceiptVerdict(ctx, input.SettlementReceiptIdentity, true, receivedAt, func(evidence settlementEvidence, alreadyTerminal bool) SettlementVerifyResult {
		return VerifySettlementReceipt(SettlementVerifyInput{
			Header:                   input.Header,
			ProviderReceiptPubkey:    input.ProviderReceiptPubkey,
			RouteSnapshot:            evidence.route,
			AccountScope:             input.AccountScope,
			RequestID:                input.RequestID,
			AttemptN:                 input.AttemptN,
			ProviderID:               input.ProviderID,
			ProviderReceiptKeyID:     evidence.route.ProviderReceiptKeyID,
			TerminalState:            evidence.attempt.TerminalState,
			TerminalStateTSUnixMS:    evidence.attempt.TerminalStateTSUnixMS,
			OutputHash:               evidence.attempt.OutputHash,
			OutputPrefixStartByte:    evidence.attempt.OutputPrefixStartByte,
			OutputPrefixEndByte:      evidence.attempt.OutputPrefixEndByte,
			ExpectedUsage:            evidence.attempt.Usage,
			UsageSource:              evidence.attempt.UsageSource,
			UsageCrossChecked:        evidence.attempt.UsageSource == UsageSourceCoordinatorObserved,
			OverlappingOrDuplicate:   evidence.attempt.OverlappingOrDuplicate,
			ReceiptReceivedUnixMS:    receivedAt,
			NowUnixMS:                receivedAt,
			CanonicalHashesAvailable: evidence.attempt.OutputAvailable && evidence.attempt.OutputHash != "",
			TerminalOutcomeFinal:     alreadyTerminal,
		})
	})
}

func (s *Store) RecordMissingSettlementReceipt(ctx context.Context, input SettlementReceiptMissingInput) (SettlementReceiptState, error) {
	if err := input.SettlementReceiptIdentity.validate(); err != nil {
		return SettlementReceiptState{}, err
	}
	now := input.NowUnixMS
	if now == 0 {
		now = s.nowUTC().UnixMilli()
	}
	return s.applySettlementReceiptVerdict(ctx, input.SettlementReceiptIdentity, false, now, func(evidence settlementEvidence, alreadyTerminal bool) SettlementVerifyResult {
		return VerifySettlementReceipt(SettlementVerifyInput{
			RouteSnapshot:            evidence.route,
			AccountScope:             input.AccountScope,
			RequestID:                input.RequestID,
			AttemptN:                 input.AttemptN,
			ProviderID:               input.ProviderID,
			ProviderReceiptKeyID:     evidence.route.ProviderReceiptKeyID,
			TerminalState:            evidence.attempt.TerminalState,
			TerminalStateTSUnixMS:    evidence.attempt.TerminalStateTSUnixMS,
			OutputHash:               evidence.attempt.OutputHash,
			OutputPrefixStartByte:    evidence.attempt.OutputPrefixStartByte,
			OutputPrefixEndByte:      evidence.attempt.OutputPrefixEndByte,
			ExpectedUsage:            evidence.attempt.Usage,
			UsageSource:              evidence.attempt.UsageSource,
			UsageCrossChecked:        evidence.attempt.UsageSource == UsageSourceCoordinatorObserved,
			OverlappingOrDuplicate:   evidence.attempt.OverlappingOrDuplicate,
			ReceiptReceivedUnixMS:    now,
			NowUnixMS:                now,
			ReceiptMissing:           true,
			CanonicalHashesAvailable: evidence.attempt.OutputAvailable && evidence.attempt.OutputHash != "",
			TerminalOutcomeFinal:     alreadyTerminal,
		})
	})
}

func (s *Store) applySettlementReceiptVerdict(ctx context.Context, id SettlementReceiptIdentity, receiptPresent bool, receivedAtUnixMS int64, verify func(settlementEvidence, bool) SettlementVerifyResult) (SettlementReceiptState, error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return SettlementReceiptState{}, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return SettlementReceiptState{}, err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	existing, found, err := loadSettlementReceiptStateConn(ctx, conn, id)
	if err != nil {
		return SettlementReceiptState{}, err
	}
	if found && existing.Closed {
		existing.IdempotencyStatus = settlementReceiptIDTerminalNoop
		if err := hydrateSettlementReceiptRouteAuditFieldsConn(ctx, conn, &existing); err != nil {
			return SettlementReceiptState{}, err
		}
		if err := insertSettlementReceiptVerdictAuditConn(ctx, conn, existing, nil, receivedAtUnixMS); err != nil {
			return SettlementReceiptState{}, err
		}
		if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
			return SettlementReceiptState{}, err
		}
		committed = true
		return existing, nil
	}
	evidence, err := loadSettlementEvidenceConn(ctx, conn, id)
	if err != nil {
		return SettlementReceiptState{}, err
	}

	result := verify(evidence, false)
	state, err := settlementReceiptStateFromResult(id, evidence, result, receiptPresent, receivedAtUnixMS, found)
	if err != nil {
		return SettlementReceiptState{}, err
	}
	persisted, err := settlementReceiptPersistedFromState(state, result)
	if err != nil {
		return SettlementReceiptState{}, err
	}
	if found {
		if err := updateSettlementReceiptStateConn(ctx, conn, persisted); err != nil {
			return SettlementReceiptState{}, err
		}
	} else if err := insertSettlementReceiptStateConn(ctx, conn, persisted); err != nil {
		return SettlementReceiptState{}, err
	}
	if reason, err := syncVerifiedReceiptLedgerCreditForAttemptTx(ctx, conn, state.RequestID, state.AttemptN, state.ProviderID); err != nil {
		return SettlementReceiptState{}, err
	} else if reason != "" {
		state.ReceiptResult = SettlementReceiptResultInvalid
		state.SettlementOutcome = SettlementOutcomeQuarantined
		state.Reason = reason
		state.Closed = true
		if err := markSettlementReceiptCacheQuarantinedConn(ctx, conn, state, reason); err != nil {
			return SettlementReceiptState{}, err
		}
	}
	if receiptPresent {
		if err := insertSettlementReceiptIngestedAuditConn(ctx, conn, state); err != nil {
			return SettlementReceiptState{}, err
		}
	}
	if err := insertSettlementReceiptVerdictAuditConn(ctx, conn, state, &result.Checks, receivedAtUnixMS); err != nil {
		return SettlementReceiptState{}, err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return SettlementReceiptState{}, err
	}
	committed = true
	return state, nil
}

type settlementReceiptCreditSyncDB interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func syncVerifiedReceiptLedgerCreditForAttemptTx(ctx context.Context, db settlementReceiptCreditSyncDB, requestID string, attemptN int64, providerID string) (string, error) {
	var requestCreditID int64
	var promptRate, completionRate, multiplier, share int64
	var cachedPromptTokens, configSnapshotID sql.NullInt64
	var ledgerPrompt, ledgerCompletion, ledgerEstimate sql.NullInt64
	var ledgerGross, ledgerProvider int64
	var accountScopeHash string
	var faultFlag, ledgerUsageSource string
	var model string
	var usageJSON string
	err := db.QueryRowContext(ctx, `
SELECT lrc.id, lrc.model, lrc.cached_prompt_tokens,
       lrc.prompt_tokens, lrc.completion_tokens, lrc.estimated_completion_tokens,
       lrc.prompt_rate_per_mtok, lrc.completion_rate_per_mtok,
       lrc.global_multiplier_ppm, lrc.provider_share_bps,
       lrc.gross_credits, lrc.provider_credits,
       lrc.settlement_account_scope_hash, lrc.usage_source, lrc.fault_flag,
       (
           SELECT lpis.config_snapshot_id
             FROM ledger_provider_identity_snapshots lpis
            WHERE lpis.request_id = lrc.request_id
              AND lpis.attempt_n = lrc.attempt_n
              AND lpis.provider_id = lrc.provider_id
              AND lpis.provider_assigned_id = lrc.provider_assigned_id
         ORDER BY lpis.id DESC
            LIMIT 1
       ) AS config_snapshot_id,
       sao.usage_canonical_json
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
 WHERE lrc.request_id = ?
   AND lrc.attempt_n = ?
   AND lrc.provider_id = ?
   AND lrc.settlement_policy_mode = 'enforce'
   AND lrc.settlement_account_scope_hash IS NOT NULL
   AND lrc.settlement_policy_version IS NOT NULL
   AND lrc.quarantined = 0
   AND lrc.settled = 0
   AND lrc.settlement_id IS NULL
 LIMIT 1`,
		requestID,
		attemptN,
		providerID,
	).Scan(&requestCreditID, &model, &cachedPromptTokens, &ledgerPrompt, &ledgerCompletion, &ledgerEstimate, &promptRate, &completionRate, &multiplier, &share, &ledgerGross, &ledgerProvider, &accountScopeHash, &ledgerUsageSource, &faultFlag, &configSnapshotID, &usageJSON)
	if err != nil {
		if err == sql.ErrNoRows {
			return "", nil
		}
		return "", err
	}
	var usage settlementUsageV04
	if err := json.Unmarshal([]byte(usageJSON), &usage); err != nil {
		return "", fmt.Errorf("decode settlement receipt-bound usage: %w", err)
	}
	prompt := usage.BillableInputTokens
	completion := usage.BillableOutputTokens
	rateEntry := RateCardEntry{PromptCreditsPerMtok: promptRate, CompletionCreditsPerMtok: completionRate}
	var cached *int64
	if cachedPromptTokens.Valid && cachedPromptTokens.Int64 > 0 {
		if cachedPromptTokens.Int64 > prompt {
			reason := "invalid_cached_prompt_tokens"
			if err := markVerifiedReceiptCacheQuarantinedTx(ctx, db, requestCreditID, reason); err != nil {
				return "", err
			}
			if err := markSettlementReceiptCacheQuarantinedTx(ctx, db, accountScopeHash, requestID, attemptN, providerID, reason); err != nil {
				return "", err
			}
			return reason, nil
		}
		if !configSnapshotID.Valid {
			reason := "missing_cache_config_snapshot"
			if err := markVerifiedReceiptCacheQuarantinedTx(ctx, db, requestCreditID, reason); err != nil {
				return "", err
			}
			if err := markSettlementReceiptCacheQuarantinedTx(ctx, db, accountScopeHash, requestID, attemptN, providerID, reason); err != nil {
				return "", err
			}
			return reason, nil
		}
		rewards, snapshotMultiplier, snapshotShare, err := snapshotByIDQueryer(ctx, db, configSnapshotID.Int64)
		if err != nil {
			if !errors.Is(err, ErrNoSnapshot) {
				return "", err
			}
			reason := "missing_cache_config_snapshot"
			if err := markVerifiedReceiptCacheQuarantinedTx(ctx, db, requestCreditID, reason); err != nil {
				return "", err
			}
			if err := markSettlementReceiptCacheQuarantinedTx(ctx, db, accountScopeHash, requestID, attemptN, providerID, reason); err != nil {
				return "", err
			}
			return reason, nil
		}
		rateEntry = RateFor(rewards.RateCard, model)
		if rateEntry.PromptCreditsPerMtok != promptRate ||
			rateEntry.CompletionCreditsPerMtok != completionRate ||
			snapshotMultiplier != multiplier ||
			snapshotShare != share {
			reason := "cache_config_snapshot_rate_mismatch"
			if err := markVerifiedReceiptCacheQuarantinedTx(ctx, db, requestCreditID, reason); err != nil {
				return "", err
			}
			if err := markSettlementReceiptCacheQuarantinedTx(ctx, db, accountScopeHash, requestID, attemptN, providerID, reason); err != nil {
				return "", err
			}
			return reason, nil
		}
		current := ComputeCreditsWithCache(
			ppFromNull(ledgerPrompt),
			&cachedPromptTokens.Int64,
			cpFromNull(ledgerCompletion),
			intPtrFromNull(ledgerEstimate),
			ledgerUsageSource,
			faultFlag,
			rateEntry,
			multiplier,
			share,
		)
		if current.GrossCredits != ledgerGross ||
			current.ProviderCredits != ledgerProvider ||
			current.UsageSource != ledgerUsageSource ||
			current.FaultFlag != faultFlag {
			reason := "cache_config_snapshot_rate_mismatch"
			if err := markVerifiedReceiptCacheQuarantinedTx(ctx, db, requestCreditID, reason); err != nil {
				return "", err
			}
			if err := markSettlementReceiptCacheQuarantinedTx(ctx, db, accountScopeHash, requestID, attemptN, providerID, reason); err != nil {
				return "", err
			}
			return reason, nil
		}
		cached = &cachedPromptTokens.Int64
	}
	result := ComputeCreditsWithCache(
		&prompt,
		cached,
		&completion,
		nil,
		UsageProviderReported,
		faultFlag,
		rateEntry,
		multiplier,
		share,
	)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET prompt_tokens = ?,
       completion_tokens = ?,
       estimated_completion_tokens = NULL,
       usage_source = ?,
       gross_credits = ?,
       provider_credits = ?,
       fault_flag = ?,
       updated_at_utc = ?
 WHERE id = ?`,
		nullInt64(result.PromptTokens),
		nullInt64(result.CompletionTokens),
		result.UsageSource,
		result.GrossCredits,
		result.ProviderCredits,
		result.FaultFlag,
		now,
		requestCreditID,
	); err != nil {
		return "", err
	}
	_, err = db.ExecContext(ctx, `
UPDATE ledger_operator_credits
   SET gross_credits = ?,
       operator_credits = ?,
       fault_flag = ?
 WHERE request_credit_id = ?`,
		result.GrossCredits,
		result.OperatorCredits,
		result.FaultFlag,
		requestCreditID,
	)
	return "", err
}

func markVerifiedReceiptCacheQuarantinedTx(ctx context.Context, db settlementReceiptCreditSyncDB, requestCreditID int64, reason string) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(ctx, `
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = ?,
       gross_credits = 0,
       provider_credits = 0,
       updated_at_utc = ?
 WHERE id = ?`, reason, now, requestCreditID); err != nil {
		return err
	}
	_, err := db.ExecContext(ctx, `
UPDATE ledger_operator_credits
   SET gross_credits = 0,
       operator_credits = 0
 WHERE request_credit_id = ?`, requestCreditID)
	return err
}

func markSettlementReceiptCacheQuarantinedTx(ctx context.Context, db settlementReceiptCreditSyncDB, accountScopeHash string, requestID string, attemptN int64, providerID string, reason string) error {
	_, err := db.ExecContext(ctx, `
UPDATE settlement_receipt_verdicts
   SET receipt_result = ?,
       settlement_outcome = ?,
       reason = ?,
       closed = 1,
       updated_at_utc = ?
 WHERE account_scope_hash = ?
   AND request_id = ?
   AND attempt_n = ?
   AND provider_id = ?`,
		SettlementReceiptResultInvalid,
		SettlementOutcomeQuarantined,
		reason,
		time.Now().UTC().Format(time.RFC3339Nano),
		accountScopeHash,
		requestID,
		attemptN,
		providerID,
	)
	return err
}

func markSettlementReceiptCacheQuarantinedConn(ctx context.Context, conn *sql.Conn, state SettlementReceiptState, reason string) error {
	_, err := conn.ExecContext(ctx, `
UPDATE settlement_receipt_verdicts
   SET receipt_result = ?,
       settlement_outcome = ?,
       reason = ?,
       closed = 1,
       updated_at_utc = ?
 WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		SettlementReceiptResultInvalid,
		SettlementOutcomeQuarantined,
		reason,
		time.Now().UTC().Format(time.RFC3339Nano),
		redactedAccountScopeHash(state.AccountScope),
		state.RequestID,
		state.AttemptN,
		state.ProviderID,
	)
	return err
}

func (id SettlementReceiptIdentity) validate() error {
	if id.AccountScope == "" {
		return fmt.Errorf("account_scope is required")
	}
	if id.RequestID == "" {
		return fmt.Errorf("request_id is required")
	}
	if id.AttemptN < 0 {
		return fmt.Errorf("attempt_n must be nonnegative")
	}
	if id.ProviderID == "" {
		return fmt.Errorf("provider_id is required")
	}
	return nil
}

func settlementReceiptStateFromResult(id SettlementReceiptIdentity, evidence settlementEvidence, result SettlementVerifyResult, receiptPresent bool, receivedAtUnixMS int64, updatingPending bool) (SettlementReceiptState, error) {
	checks := result.Checks
	closed := settlementOutcomeTerminal(result.Outcome)
	status := settlementReceiptIDPending
	if updatingPending && !closed {
		status = settlementReceiptIDPendingUpdated
	} else if updatingPending && closed {
		status = settlementReceiptIDTerminalAfterPending
	} else if closed {
		status = settlementReceiptIDFirstTerminal
	}
	state := SettlementReceiptState{
		SettlementReceiptIdentity:     id,
		ReceiptPresent:                receiptPresent,
		ReceiptVersion:                result.ReceiptVersion,
		ReceiptResult:                 result.ReceiptResult,
		SettlementOutcome:             result.Outcome,
		Reason:                        result.Reason,
		IdempotencyStatus:             status,
		Closed:                        closed,
		TerminalState:                 evidence.attempt.TerminalState,
		TerminalStateTSUnixMS:         evidence.attempt.TerminalStateTSUnixMS,
		PendingDeadlineUnixMS:         evidence.deadlineMS,
		ReceivedAtUnixMS:              receivedAtUnixMS,
		RouteSnapshotDigest:           evidence.routeHash,
		RouteSnapshotPolicyVersion:    evidence.route.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:             evidence.route.RouteSnapshotMode,
		PaidEntrypoint:                evidence.route.PaidEntrypoint,
		ProviderSessionID:             derefString(evidence.route.ProviderSessionID),
		ProviderGenerationID:          derefString(evidence.route.ProviderGenerationID),
		Spec008HashStatus:             evidence.route.Spec008HashStatus,
		ProviderReportedModelHash:     evidence.route.ProviderReportedModelHash,
		ProviderReceiptKeyFingerprint: evidence.route.ProviderReceiptKeyID,
		CatalogID:                     evidence.route.CatalogID,
		CatalogBodyDigest:             evidence.route.CatalogBodyDigest,
		ExpectedCatalogModelHash:      evidence.route.ExpectedCatalogModelHash,
		ModelID:                       evidence.route.ModelID,
		ModelHash:                     evidence.route.ProviderReportedModelHash,
		ReceiptProfile:                settlementReceiptProfileV04,
		BuyerDebitOutcome:             settlementReceiptNoMoneyMovementStep5,
		ProviderSettlementOutcome:     settlementReceiptNoMoneyMovementStep5,
		PayoutExclusionOutcome:        settlementReceiptPayoutExcludedUntil022,
		PromptHash:                    evidence.route.PromptHash,
		OutputHash:                    evidence.attempt.OutputHash,
		UsageDigest:                   evidence.attempt.UsageHash,
		Checks:                        checks,
	}
	if result.Facts != nil {
		state.ReceiptVersion = result.Facts.ReceiptVersion
		state.ReceiptTupleCanonicalSHA256 = result.Facts.TupleCanonicalSHA256
	}
	if state.ReceiptResult == "" || state.SettlementOutcome == "" || state.Reason == "" {
		return SettlementReceiptState{}, fmt.Errorf("settlement verifier returned incomplete state")
	}
	return state, nil
}

func (s *Store) nowUTC() time.Time {
	if s.now == nil {
		return time.Now().UTC()
	}
	return s.now().UTC()
}

func (s *Store) GetSettlementReceiptAuthorization(ctx context.Context, id SettlementReceiptIdentity) (SettlementReceiptAuthorization, bool, error) {
	if err := id.validate(); err != nil {
		return SettlementReceiptAuthorization{}, false, err
	}
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return SettlementReceiptAuthorization{}, false, err
	}
	defer conn.Close()
	state, found, err := loadSettlementReceiptStateConn(ctx, conn, id)
	if err != nil || !found {
		return SettlementReceiptAuthorization{}, found, err
	}
	attempt, err := loadSettlementAttemptOutputConn(ctx, conn, id)
	if err != nil {
		return SettlementReceiptAuthorization{}, false, err
	}
	authorization := settlementReceiptAuthorizationFromState(state)
	if state.SettlementOutcome == SettlementOutcomeVerified && state.Closed && !attempt.OverlappingOrDuplicate {
		authorization.PositiveSettlementCandidate = true
		return authorization, true, nil
	}
	switch {
	case attempt.OverlappingOrDuplicate:
		authorization.CandidateBlockedReason = "overlapping_or_duplicate_output"
	case !state.Closed:
		authorization.CandidateBlockedReason = "receipt_verdict_not_terminal"
	case state.SettlementOutcome != SettlementOutcomeVerified:
		authorization.CandidateBlockedReason = state.Reason
	default:
		authorization.CandidateBlockedReason = "receipt_not_verified_candidate"
	}
	return authorization, true, nil
}

func settlementReceiptAuthorizationFromState(state SettlementReceiptState) SettlementReceiptAuthorization {
	return SettlementReceiptAuthorization{
		SettlementReceiptIdentity:     state.SettlementReceiptIdentity,
		ReceiptResult:                 state.ReceiptResult,
		SettlementOutcome:             state.SettlementOutcome,
		Reason:                        state.Reason,
		Closed:                        state.Closed,
		TerminalState:                 state.TerminalState,
		TerminalStateTSUnixMS:         state.TerminalStateTSUnixMS,
		PendingDeadlineUnixMS:         state.PendingDeadlineUnixMS,
		ReceivedAtUnixMS:              state.ReceivedAtUnixMS,
		RouteSnapshotDigest:           state.RouteSnapshotDigest,
		RouteSnapshotPolicyVersion:    state.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:             state.RouteSnapshotMode,
		PaidEntrypoint:                state.PaidEntrypoint,
		Spec008HashStatus:             state.Spec008HashStatus,
		ProviderReportedModelHash:     state.ProviderReportedModelHash,
		ProviderReceiptKeyFingerprint: state.ProviderReceiptKeyFingerprint,
		CatalogID:                     state.CatalogID,
		CatalogBodyDigest:             state.CatalogBodyDigest,
		ExpectedCatalogModelHash:      state.ExpectedCatalogModelHash,
		ModelID:                       state.ModelID,
		ModelHash:                     state.ModelHash,
		ReceiptProfile:                state.ReceiptProfile,
		BuyerDebitOutcome:             state.BuyerDebitOutcome,
		ProviderSettlementOutcome:     state.ProviderSettlementOutcome,
		PayoutExclusionOutcome:        state.PayoutExclusionOutcome,
		PromptHash:                    state.PromptHash,
		OutputHash:                    state.OutputHash,
		UsageDigest:                   state.UsageDigest,
		Checks:                        state.Checks,
	}
}

func settlementReceiptPersistedFromState(state SettlementReceiptState, result SettlementVerifyResult) (settlementReceiptPersisted, error) {
	checksJSON, err := json.Marshal(state.Checks)
	if err != nil {
		return settlementReceiptPersisted{}, err
	}
	diagnosticsJSON, err := json.Marshal(map[string]any{
		"receipt_result":     state.ReceiptResult,
		"settlement_outcome": state.SettlementOutcome,
		"reason":             state.Reason,
		"idempotency_status": state.IdempotencyStatus,
		"closed":             state.Closed,
	})
	if err != nil {
		return settlementReceiptPersisted{}, err
	}
	var facts sql.NullString
	if result.Facts != nil {
		raw, err := json.Marshal(result.Facts)
		if err != nil {
			return settlementReceiptPersisted{}, err
		}
		facts = sql.NullString{String: string(raw), Valid: true}
	}
	return settlementReceiptPersisted{
		SettlementReceiptState: state,
		checksJSON:             string(checksJSON),
		diagnosticsJSON:        string(diagnosticsJSON),
		factsJSON:              facts,
	}, nil
}

func settlementOutcomeTerminal(outcome string) bool {
	return outcome == SettlementOutcomeVerified || outcome == SettlementOutcomeQuarantined || outcome == SettlementOutcomeZeroSettled
}

func loadSettlementEvidenceConn(ctx context.Context, conn *sql.Conn, id SettlementReceiptIdentity) (settlementEvidence, error) {
	route, routeHash, err := loadSettlementRouteSnapshotConn(ctx, conn, id)
	if err != nil {
		return settlementEvidence{}, err
	}
	attempt, err := loadSettlementAttemptOutputConn(ctx, conn, id)
	if err != nil {
		return settlementEvidence{}, err
	}
	return settlementEvidence{
		route:      route,
		routeHash:  routeHash,
		attempt:    attempt,
		deadlineMS: attempt.TerminalStateTSUnixMS + route.PendingDeadlineSeconds*1000,
	}, nil
}

func loadSettlementRouteSnapshotConn(ctx context.Context, conn *sql.Conn, id SettlementReceiptIdentity) (RouteSnapshot, string, error) {
	var r RouteSnapshot
	var providerSession, providerGeneration sql.NullString
	var digest string
	err := conn.QueryRowContext(ctx, `
SELECT provider_session_id, provider_generation_id, paid_entrypoint,
       provider_receipt_key_id, provider_receipt_key_source, model_id,
       provider_reported_model_hash, expected_catalog_model_hash, catalog_id,
       catalog_body_digest, catalog_signature_key_id,
       catalog_signature_pubkey_fingerprint, catalog_expires_at_unix_ms,
       spec008_hash_status, route_snapshot_policy_version, route_snapshot_mode,
       route_decision_ts_unix_ms, request_start_ts_unix_ms,
       pending_deadline_seconds, prompt_hash_basis, prompt_hash,
       route_snapshot_digest
FROM settlement_route_snapshots
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	).Scan(
		&providerSession, &providerGeneration, &r.PaidEntrypoint,
		&r.ProviderReceiptKeyID, &r.ProviderReceiptKeySource, &r.ModelID,
		&r.ProviderReportedModelHash, &r.ExpectedCatalogModelHash, &r.CatalogID,
		&r.CatalogBodyDigest, &r.CatalogSignatureKeyID,
		&r.CatalogSignaturePubkeyFingerprint, &r.CatalogExpiresAtUnixMS,
		&r.Spec008HashStatus, &r.RouteSnapshotPolicyVersion, &r.RouteSnapshotMode,
		&r.RouteDecisionTSUnixMS, &r.RequestStartTSUnixMS,
		&r.PendingDeadlineSeconds, &r.PromptHashBasis, &r.PromptHash,
		&digest,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return RouteSnapshot{}, "", fmt.Errorf("settlement route snapshot missing")
		}
		return RouteSnapshot{}, "", err
	}
	r.AccountScope = id.AccountScope
	r.RequestID = id.RequestID
	r.AttemptN = id.AttemptN
	r.ProviderID = id.ProviderID
	if providerSession.Valid {
		r.ProviderSessionID = &providerSession.String
	}
	if providerGeneration.Valid {
		r.ProviderGenerationID = &providerGeneration.String
	}
	computed, _, err := r.Digest()
	if err != nil {
		return RouteSnapshot{}, "", err
	}
	if digest != computed {
		return RouteSnapshot{}, "", fmt.Errorf("settlement route snapshot digest mismatch")
	}
	return r, computed, nil
}

func loadSettlementAttemptOutputConn(ctx context.Context, conn *sql.Conn, id SettlementReceiptIdentity) (settlementAttemptEvidence, error) {
	var outputHash sql.NullString
	var usageJSON string
	var outputAvailable, overlap int
	var attempt settlementAttemptEvidence
	err := conn.QueryRowContext(ctx, `
SELECT terminal_state, terminal_state_ts_unix_ms, output_available,
       output_prefix_start_byte, output_prefix_end_byte, output_hash,
       usage_hash, usage_canonical_json, usage_source, overlapping_or_duplicate
FROM settlement_attempt_outputs
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	).Scan(
		&attempt.TerminalState, &attempt.TerminalStateTSUnixMS, &outputAvailable,
		&attempt.OutputPrefixStartByte, &attempt.OutputPrefixEndByte, &outputHash,
		&attempt.UsageHash, &usageJSON, &attempt.UsageSource, &overlap,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return settlementAttemptEvidence{}, fmt.Errorf("settlement attempt output missing")
		}
		return settlementAttemptEvidence{}, err
	}
	var usage settlementUsageV04
	if err := json.Unmarshal([]byte(usageJSON), &usage); err != nil {
		return settlementAttemptEvidence{}, fmt.Errorf("decode settlement usage: %w", err)
	}
	attempt.OutputAvailable = outputAvailable == 1
	if outputHash.Valid {
		attempt.OutputHash = outputHash.String
	}
	attempt.Usage = SettlementUsage{
		BillableInputTokens:  usage.BillableInputTokens,
		BillableOutputTokens: usage.BillableOutputTokens,
		DeliveredOutputBytes: usage.DeliveredOutputBytes,
		ObservedInputTokens:  usage.ObservedInputTokens,
		ObservedOutputTokens: usage.ObservedOutputTokens,
	}
	attempt.OverlappingOrDuplicate = overlap == 1
	return attempt, nil
}

func insertSettlementReceiptStateConn(ctx context.Context, conn *sql.Conn, state settlementReceiptPersisted) error {
	_, err := conn.ExecContext(ctx, `
INSERT INTO settlement_receipt_verdicts (
    account_scope_hash, request_id, attempt_n, provider_id, receipt_present,
    receipt_version, receipt_result, settlement_outcome, reason,
    idempotency_status, closed, terminal_state, terminal_state_ts_unix_ms,
    pending_deadline_unix_ms, received_at_unix_ms, route_snapshot_digest,
	    route_snapshot_policy_version, route_snapshot_mode, paid_entrypoint,
	    spec008_hash_status, provider_reported_model_hash, provider_receipt_key_fingerprint,
	    catalog_id, catalog_body_digest,
	    expected_catalog_model_hash, model_id, model_hash, receipt_profile,
	    buyer_debit_outcome, provider_settlement_outcome,
	    payout_exclusion_outcome, prompt_hash,
	    output_hash, usage_digest, receipt_tuple_canonical_sha256, checks_json,
	    verifier_diagnostics_json, facts_json, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		redactedAccountScopeHash(state.AccountScope), state.RequestID, state.AttemptN, state.ProviderID, boolInt(state.ReceiptPresent),
		nullString(state.ReceiptVersion), state.ReceiptResult, state.SettlementOutcome, state.Reason,
		state.IdempotencyStatus, boolInt(state.Closed), state.TerminalState, state.TerminalStateTSUnixMS,
		state.PendingDeadlineUnixMS, state.ReceivedAtUnixMS, state.RouteSnapshotDigest,
		state.RouteSnapshotPolicyVersion, state.RouteSnapshotMode, state.PaidEntrypoint,
		state.Spec008HashStatus, state.ProviderReportedModelHash,
		state.ProviderReceiptKeyFingerprint, state.CatalogID, state.CatalogBodyDigest,
		state.ExpectedCatalogModelHash, state.ModelID, nullString(state.ModelHash),
		state.ReceiptProfile, state.BuyerDebitOutcome, state.ProviderSettlementOutcome,
		state.PayoutExclusionOutcome, state.PromptHash,
		nullString(state.OutputHash), nullString(state.UsageDigest), nullString(state.ReceiptTupleCanonicalSHA256), state.checksJSON,
		state.diagnosticsJSON, state.factsJSON, time.Now().UTC().Format(time.RFC3339Nano),
	)
	return err
}

func updateSettlementReceiptStateConn(ctx context.Context, conn *sql.Conn, state settlementReceiptPersisted) error {
	_, err := conn.ExecContext(ctx, `
UPDATE settlement_receipt_verdicts
   SET receipt_present = ?,
       receipt_version = ?,
       receipt_result = ?,
       settlement_outcome = ?,
       reason = ?,
       idempotency_status = ?,
       closed = ?,
       terminal_state = ?,
       terminal_state_ts_unix_ms = ?,
       pending_deadline_unix_ms = ?,
       received_at_unix_ms = ?,
	       route_snapshot_digest = ?,
	       route_snapshot_policy_version = ?,
	       route_snapshot_mode = ?,
	       paid_entrypoint = ?,
	       spec008_hash_status = ?,
	       provider_reported_model_hash = ?,
	       provider_receipt_key_fingerprint = ?,
	       catalog_id = ?,
	       catalog_body_digest = ?,
	       expected_catalog_model_hash = ?,
	       model_id = ?,
	       model_hash = ?,
	       receipt_profile = ?,
	       buyer_debit_outcome = ?,
	       provider_settlement_outcome = ?,
	       payout_exclusion_outcome = ?,
	       prompt_hash = ?,
       output_hash = ?,
       usage_digest = ?,
       receipt_tuple_canonical_sha256 = ?,
       checks_json = ?,
       verifier_diagnostics_json = ?,
       facts_json = ?,
       updated_at_utc = ?
 WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ? AND closed = 0`,
		boolInt(state.ReceiptPresent), nullString(state.ReceiptVersion), state.ReceiptResult,
		state.SettlementOutcome, state.Reason, state.IdempotencyStatus, boolInt(state.Closed),
		state.TerminalState, state.TerminalStateTSUnixMS, state.PendingDeadlineUnixMS,
		state.ReceivedAtUnixMS, state.RouteSnapshotDigest, state.RouteSnapshotPolicyVersion,
		state.RouteSnapshotMode, state.PaidEntrypoint, state.Spec008HashStatus,
		state.ProviderReportedModelHash, state.ProviderReceiptKeyFingerprint, state.CatalogID,
		state.CatalogBodyDigest, state.ExpectedCatalogModelHash, state.ModelID,
		nullString(state.ModelHash), state.ReceiptProfile, state.BuyerDebitOutcome,
		state.ProviderSettlementOutcome, state.PayoutExclusionOutcome,
		state.PromptHash, nullString(state.OutputHash),
		nullString(state.UsageDigest), nullString(state.ReceiptTupleCanonicalSHA256),
		state.checksJSON, state.diagnosticsJSON, state.factsJSON,
		time.Now().UTC().Format(time.RFC3339Nano),
		redactedAccountScopeHash(state.AccountScope), state.RequestID, state.AttemptN, state.ProviderID,
	)
	return err
}

func loadSettlementReceiptStateConn(ctx context.Context, conn *sql.Conn, id SettlementReceiptIdentity) (SettlementReceiptState, bool, error) {
	var state SettlementReceiptState
	var receiptPresent, closed int
	var receiptVersion, modelHash, outputHash, usageDigest, tupleDigest sql.NullString
	var checksJSON string
	err := conn.QueryRowContext(ctx, `
SELECT receipt_present, receipt_version, receipt_result, settlement_outcome,
       reason, idempotency_status, closed, terminal_state,
       terminal_state_ts_unix_ms, pending_deadline_unix_ms,
       received_at_unix_ms, route_snapshot_digest,
	       route_snapshot_policy_version, route_snapshot_mode, paid_entrypoint,
	       spec008_hash_status, provider_reported_model_hash, provider_receipt_key_fingerprint,
	       catalog_id, catalog_body_digest,
	       expected_catalog_model_hash, model_id, model_hash, receipt_profile,
	       buyer_debit_outcome, provider_settlement_outcome,
	       payout_exclusion_outcome, prompt_hash,
	       output_hash, usage_digest, receipt_tuple_canonical_sha256, checks_json
FROM settlement_receipt_verdicts
WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		redactedAccountScopeHash(id.AccountScope), id.RequestID, id.AttemptN, id.ProviderID,
	).Scan(
		&receiptPresent, &receiptVersion, &state.ReceiptResult, &state.SettlementOutcome,
		&state.Reason, &state.IdempotencyStatus, &closed, &state.TerminalState,
		&state.TerminalStateTSUnixMS, &state.PendingDeadlineUnixMS,
		&state.ReceivedAtUnixMS, &state.RouteSnapshotDigest,
		&state.RouteSnapshotPolicyVersion, &state.RouteSnapshotMode,
		&state.PaidEntrypoint, &state.Spec008HashStatus, &state.ProviderReportedModelHash,
		&state.ProviderReceiptKeyFingerprint, &state.CatalogID, &state.CatalogBodyDigest,
		&state.ExpectedCatalogModelHash, &state.ModelID, &modelHash,
		&state.ReceiptProfile, &state.BuyerDebitOutcome, &state.ProviderSettlementOutcome,
		&state.PayoutExclusionOutcome, &state.PromptHash,
		&outputHash, &usageDigest, &tupleDigest, &checksJSON,
	)
	if err != nil {
		if err == sql.ErrNoRows {
			return SettlementReceiptState{}, false, nil
		}
		return SettlementReceiptState{}, false, err
	}
	state.SettlementReceiptIdentity = id
	state.ReceiptPresent = receiptPresent == 1
	state.Closed = closed == 1
	state.ReceiptVersion = receiptVersion.String
	state.ModelHash = modelHash.String
	state.OutputHash = outputHash.String
	state.UsageDigest = usageDigest.String
	state.ReceiptTupleCanonicalSHA256 = tupleDigest.String
	if err := json.Unmarshal([]byte(checksJSON), &state.Checks); err != nil {
		return SettlementReceiptState{}, false, fmt.Errorf("decode settlement receipt checks: %w", err)
	}
	return state, true, nil
}

func insertSettlementReceiptIngestedAuditConn(ctx context.Context, conn *sql.Conn, state SettlementReceiptState) error {
	payload, err := settlementReceiptAuditPayload(state, nil, false, 0)
	if err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, ?, ?, ?)`,
		time.Now().UTC().Format(time.RFC3339Nano), settlementReceiptEventIngested, state.ProviderID, payload)
	return err
}

func insertSettlementReceiptVerdictAuditConn(ctx context.Context, conn *sql.Conn, state SettlementReceiptState, checks *SettlementVerificationChecks, attemptedReceivedAtUnixMS int64) error {
	payload, err := settlementReceiptAuditPayload(state, checks, true, attemptedReceivedAtUnixMS)
	if err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, ?, ?, ?)`,
		time.Now().UTC().Format(time.RFC3339Nano), settlementReceiptEventVerdict, state.ProviderID, payload)
	return err
}

func settlementReceiptAuditPayload(state SettlementReceiptState, checks *SettlementVerificationChecks, verdict bool, attemptedReceivedAtUnixMS int64) (string, error) {
	payload := map[string]any{
		"account_scope_hash":               redactedAccountScopeHash(state.AccountScope),
		"request_id":                       state.RequestID,
		"attempt_id":                       settlementReceiptAttemptID(state),
		"attempt_n":                        state.AttemptN,
		"provider_id":                      state.ProviderID,
		"receipt_version":                  state.ReceiptVersion,
		"receipt_profile":                  state.ReceiptProfile,
		"terminal_state":                   state.TerminalState,
		"route_snapshot_digest":            state.RouteSnapshotDigest,
		"route_snapshot_policy_version":    state.RouteSnapshotPolicyVersion,
		"route_snapshot_mode":              state.RouteSnapshotMode,
		"paid_entrypoint":                  state.PaidEntrypoint,
		"spec008_hash_status":              state.Spec008HashStatus,
		"catalog_id":                       state.CatalogID,
		"catalog_body_digest":              state.CatalogBodyDigest,
		"provider_receipt_key_fingerprint": state.ProviderReceiptKeyFingerprint,
		"model_id":                         state.ModelID,
		"provider_reported_model_hash":     state.ProviderReportedModelHash,
		"model_hash":                       state.ModelHash,
		"expected_catalog_model_hash":      state.ExpectedCatalogModelHash,
		"prompt_hash":                      state.PromptHash,
		"output_hash":                      state.OutputHash,
		"usage_digest":                     state.UsageDigest,
		"received_at_unix_ms":              state.ReceivedAtUnixMS,
	}
	if state.ProviderSessionID != "" {
		payload["provider_session_id"] = state.ProviderSessionID
	}
	if state.ProviderGenerationID != "" {
		payload["provider_generation_id"] = state.ProviderGenerationID
	}
	if verdict {
		if attemptedReceivedAtUnixMS == 0 {
			attemptedReceivedAtUnixMS = state.ReceivedAtUnixMS
		}
		payload["receipt_result"] = state.ReceiptResult
		payload["receipt_verification_outcome"] = state.SettlementOutcome
		payload["settlement_outcome"] = state.SettlementOutcome
		payload["reason"] = state.Reason
		payload["deadline_unix_ms"] = state.PendingDeadlineUnixMS
		payload["pending_deadline_unix_ms"] = state.PendingDeadlineUnixMS
		payload["idempotency_status"] = state.IdempotencyStatus
		payload["attempted_received_at_unix_ms"] = attemptedReceivedAtUnixMS
		payload["buyer_debit_outcome"] = state.BuyerDebitOutcome
		payload["provider_settlement_outcome"] = state.ProviderSettlementOutcome
		payload["payout_exclusion_outcome"] = state.PayoutExclusionOutcome
		if state.SettlementOutcome == SettlementOutcomeQuarantined || state.SettlementOutcome == SettlementOutcomeZeroSettled {
			payload["quarantine_zero_settle_reason"] = state.Reason
		}
	}
	if checks != nil {
		payload["verifier_checks"] = *checks
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func hydrateSettlementReceiptRouteAuditFieldsConn(ctx context.Context, conn *sql.Conn, state *SettlementReceiptState) error {
	var providerSession, providerGeneration sql.NullString
	err := conn.QueryRowContext(ctx, `
SELECT provider_session_id, provider_generation_id
FROM settlement_route_snapshots
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		state.AccountScope, state.RequestID, state.AttemptN, state.ProviderID,
	).Scan(&providerSession, &providerGeneration)
	if err != nil {
		return err
	}
	if providerSession.Valid {
		state.ProviderSessionID = providerSession.String
	}
	if providerGeneration.Valid {
		state.ProviderGenerationID = providerGeneration.String
	}
	return nil
}

func settlementReceiptAttemptID(state SettlementReceiptState) string {
	return fmt.Sprintf("%s:%d:%s", state.RequestID, state.AttemptN, state.ProviderID)
}

func derefString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func redactedAccountScopeHash(accountScope string) string {
	return SettlementAccountScopeHash(accountScope)
}

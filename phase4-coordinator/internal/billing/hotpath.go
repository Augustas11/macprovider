package billing

import (
	"context"
	"database/sql"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

type HotPathInput struct {
	RequestID           string
	AttemptN            int
	ProviderAssignedID  string
	ProviderID          string
	Model               string
	Status              int
	Stream              bool
	TSUtc               time.Time
	PromptTokens        *int64
	CompletionTokens    *int64
	EstimatedCompTokens *int64
	ErrorCode           string
	FaultFlag           string
	ConfigSnapshotID    int64
	RateEntry           RateCardEntry
	MultiplierPPM       int64
	ProviderShareBps    int64
}

func (s *Store) WriteHotPath(ctx context.Context, reqLogStore *requestlog.Store, reqRow requestlog.Row, in HotPathInput) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := reqLogStore.InsertTx(ctx, tx, reqRow); err != nil {
		return err
	}
	if in.ProviderAssignedID == "" {
		return tx.Commit()
	}
	if in.TSUtc.IsZero() {
		in.TSUtc = time.Now().UTC()
	}
	if in.FaultFlag == "" {
		in.FaultFlag = FaultNone
	}
	result := ComputeCredits(
		in.PromptTokens,
		in.CompletionTokens,
		in.EstimatedCompTokens,
		usageFor(in.ErrorCode, in.EstimatedCompTokens),
		in.FaultFlag,
		in.RateEntry,
		in.MultiplierPPM,
		in.ProviderShareBps,
	)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	requestCreditID, err := insertRequestCreditTx(ctx, tx, in, result, "hot_path", now, false, "")
	if err != nil {
		return err
	}
	if err := insertOperatorCreditTx(ctx, tx, requestCreditID, in, result, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from,
    pool_session_started_at_utc, created_at_utc
) VALUES (?, ?, ?, ?, 'pool_entry', NULL, ?)
ON CONFLICT(request_id, attempt_n, provider_assigned_id) DO NOTHING`,
		in.RequestID, in.AttemptN, in.ProviderAssignedID, in.ProviderID, now,
	); err != nil {
		return err
	}
	return tx.Commit()
}

func insertRequestCreditTx(ctx context.Context, tx *sql.Tx, in HotPathInput, result BilledRow, source, now string, quarantined bool, quarantineReason string) (int64, error) {
	res, err := tx.ExecContext(ctx, `
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, prompt_tokens, completion_tokens, estimated_completion_tokens,
    usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc, quarantined,
    quarantine_reason
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		in.RequestID,
		in.AttemptN,
		in.ProviderID,
		nullString(in.ProviderAssignedID),
		in.TSUtc.UTC().Format(time.RFC3339Nano),
		in.Model,
		in.Status,
		boolInt(in.Stream),
		nullInt64(result.PromptTokens),
		nullInt64(result.CompletionTokens),
		nullInt64(result.EstimatedCompTokens),
		result.UsageSource,
		result.PromptRatePerMtok,
		result.CompletionRatePerMtok,
		result.GlobalMultiplierPPM,
		result.GrossCredits,
		result.ProviderShareBps,
		result.ProviderCredits,
		result.FaultFlag,
		source,
		now,
		boolInt(quarantined),
		nullString(quarantineReason),
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func insertOperatorCreditTx(ctx context.Context, tx *sql.Tx, requestCreditID int64, in HotPathInput, result BilledRow, now string) error {
	_, err := tx.ExecContext(ctx, `
INSERT INTO ledger_operator_credits (
    request_credit_id, request_id, attempt_n, provider_id, ts_utc,
    gross_credits, operator_share_bps, operator_credits, fault_flag, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		requestCreditID,
		in.RequestID,
		in.AttemptN,
		in.ProviderID,
		in.TSUtc.UTC().Format(time.RFC3339Nano),
		result.GrossCredits,
		10000-result.ProviderShareBps,
		result.OperatorCredits,
		result.FaultFlag,
		now,
	)
	return err
}

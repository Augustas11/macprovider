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
	if err := reqLogStore.InsertExec(ctx, conn, reqRow); err != nil {
		return err
	}
	if in.ProviderAssignedID == "" {
		_, err := conn.ExecContext(ctx, `COMMIT`)
		committed = err == nil
		return err
	}
	var requestCount int
	if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_log WHERE request_id = ?`, in.RequestID).Scan(&requestCount); err == nil && requestCount > 0 {
		if derived := requestCount - 1; derived > in.AttemptN {
			if in.AttemptN != derived {
				in.AttemptN = derived
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
				result = zeroCredits(result)
				now := time.Now().UTC().Format(time.RFC3339Nano)
				if _, err := insertRequestCreditTx(ctx, conn, in, result, "hot_path", now, true, "ambiguous_attempt_n"); err != nil {
					return err
				}
				_, err := conn.ExecContext(ctx, `COMMIT`)
				committed = err == nil
				return err
			}
			in.AttemptN = derived
		}
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
	requestCreditID, err := insertRequestCreditTx(ctx, conn, in, result, "hot_path", now, false, "")
	if err != nil {
		return err
	}
	if err := insertOperatorCreditTx(ctx, conn, requestCreditID, in, result, now); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from,
    pool_session_started_at_utc, created_at_utc
) VALUES (?, ?, ?, ?, 'pool_entry', NULL, ?)
ON CONFLICT(request_id, attempt_n, provider_assigned_id) DO NOTHING`,
		in.RequestID, in.AttemptN, in.ProviderAssignedID, in.ProviderID, now,
	); err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `COMMIT`)
	committed = err == nil
	return err
}

type sqlExecutor interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func insertRequestCreditTx(ctx context.Context, db sqlExecutor, in HotPathInput, result BilledRow, source, now string, quarantined bool, quarantineReason string) (int64, error) {
	res, err := db.ExecContext(ctx, `
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

func insertOperatorCreditTx(ctx context.Context, db sqlExecutor, requestCreditID int64, in HotPathInput, result BilledRow, now string) error {
	_, err := db.ExecContext(ctx, `
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

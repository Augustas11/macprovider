package billing

import (
	"context"
	"database/sql"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

type HotPathInput struct {
	RequestID                  string
	AttemptN                   int
	ProviderAssignedID         string
	ProviderID                 string
	Model                      string
	Status                     int
	Stream                     bool
	TSUtc                      time.Time
	PromptTokens               *int64
	CachedPromptTokens         *int64
	CompletionTokens           *int64
	EstimatedCompTokens        *int64
	ErrorCode                  string
	FaultFlag                  string
	StickyResult               string
	StickyMissReason           string
	ConfigSnapshotID           int64
	RateEntry                  RateCardEntry
	MultiplierPPM              int64
	ProviderShareBps           int64
	SettlementAccountScopeHash string
	SettlementPolicyMode       string
	SettlementPolicyVersion    string
	RoutingDecisionLog         func(CacheBillingRoutingDecision)
}

type CacheBillingRoutingDecision struct {
	RequestID          string
	AttemptN           int
	ProviderID         string
	ProviderAssignedID string
	CachedPromptTokens int64
	StickyResult       string
	StickyMissReason   string
	ValidationReason   string
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
	if in.SettlementAccountScopeHash == "" {
		in.SettlementAccountScopeHash = SettlementAccountScopeHashForAccountID(reqRow.AccountID)
	}
	if in.SettlementPolicyMode == "" {
		in.SettlementPolicyMode = "legacy"
	}
	// SPEC-002 v1.5.0 / issue #211 money-path defense-in-depth:
	// scope the AttemptN-derivation COUNT by (account_id, request_id)
	// using SQLite `IS` semantics so all three sites (this one,
	// recovery.go, endpoints.go admin-reconcile) compute the same
	// attempt ordinal for any given row. Note that request_log.request_id
	// is coordinator-internal (server-minted UUID v4); the buyer-
	// supplied #211 collision class lives on external_request_id and
	// is addressed by the composite (account_id, external_request_id)
	// reconciliation key. This account scoping is defense-in-depth:
	// if a UUID v4 collision or retry-loop bug ever causes the same
	// internal request_id to recur across accounts, each account's
	// attempt sequence is computed within its own scope. NULL-
	// account_id legacy rows cluster with NULL-account_id legacy
	// rows only (NULL = NULL under `IS`). For an empty in-memory
	// AccountID, pass an explicit nil so SQLite matches IS NULL.
	var accountIDArg any
	if reqRow.AccountID != "" {
		accountIDArg = reqRow.AccountID
	}
	var requestCount int
	countErr := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM request_log WHERE account_id IS ? AND request_id = ?`, accountIDArg, in.RequestID).Scan(&requestCount)
	if countErr == nil && requestCount > 0 {
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
				if err := insertProviderIdentitySnapshotTx(ctx, conn, in, now); err != nil {
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
	cacheQuarantineReason := normalizeCachedPromptTokens(&in)
	logCacheBillingRoutingDecision(in, cacheQuarantineReason)
	// SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168) quarantine rule:
	// with persisted monotonic attempt_n, row 3+ (attempt_n >= 2) is
	// credited normally — the v0.3.1 "row 3+ MUST quarantine until
	// SPEC-002 gains monotonic attempt_n" rule is now satisfied. The
	// remaining quarantine class is attempt_n==1 with retried==0:
	// legitimate-retry-without-explicit-marker that cannot be safely
	// distinguished from a buggy duplicate INSERT. This narrowing is
	// safe in the hot path because reqRow.AttemptN here is the value
	// just persisted by InsertExec (v1.5.2 always writes a non-NULL
	// value); the in.AttemptN was already aligned to the persisted
	// value by the post-INSERT COUNT-1 derivation above.
	if in.AttemptN == 1 && reqRow.Retried == 0 {
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
		if err := insertProviderIdentitySnapshotTx(ctx, conn, in, now); err != nil {
			return err
		}
		_, err := conn.ExecContext(ctx, `COMMIT`)
		committed = err == nil
		return err
	}
	result := ComputeCreditsWithCache(
		in.PromptTokens,
		in.CachedPromptTokens,
		in.CompletionTokens,
		in.EstimatedCompTokens,
		usageFor(in.ErrorCode, in.EstimatedCompTokens),
		in.FaultFlag,
		in.RateEntry,
		in.MultiplierPPM,
		in.ProviderShareBps,
	)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if cacheQuarantineReason != "" {
		result = zeroCredits(result)
		if _, err := insertRequestCreditTx(ctx, conn, in, result, "hot_path", now, true, cacheQuarantineReason); err != nil {
			return err
		}
		if err := insertProviderIdentitySnapshotTx(ctx, conn, in, now); err != nil {
			return err
		}
		_, err := conn.ExecContext(ctx, `COMMIT`)
		committed = err == nil
		return err
	}
	requestCreditID, err := insertRequestCreditTx(ctx, conn, in, result, "hot_path", now, false, "")
	if err != nil {
		return err
	}
	if err := insertOperatorCreditTx(ctx, conn, requestCreditID, in, result, now); err != nil {
		return err
	}
	if err := syncVerifiedReceiptLedgerCreditForAttemptTx(ctx, conn, in.RequestID, int64(in.AttemptN), in.ProviderID); err != nil {
		return err
	}
	if err := insertProviderIdentitySnapshotTx(ctx, conn, in, now); err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `COMMIT`)
	committed = err == nil
	return err
}

func normalizeCachedPromptTokens(in *HotPathInput) string {
	if in.CachedPromptTokens == nil {
		return ""
	}
	cached := *in.CachedPromptTokens
	if cached < 0 || in.PromptTokens == nil || cached > *in.PromptTokens {
		in.CachedPromptTokens = nil
		return "invalid_cached_prompt_tokens"
	}
	if in.AttemptN > 0 {
		in.CachedPromptTokens = nil
		return ""
	}
	if in.StickyResult != "hit" {
		if cached > 0 {
			in.CachedPromptTokens = nil
			return "ambiguous_cache"
		}
		in.CachedPromptTokens = nil
		return ""
	}
	return ""
}

func logCacheBillingRoutingDecision(in HotPathInput, validationReason string) {
	if in.RoutingDecisionLog == nil {
		return
	}
	effectiveCached := int64(0)
	if in.CachedPromptTokens != nil {
		effectiveCached = *in.CachedPromptTokens
	}
	in.RoutingDecisionLog(CacheBillingRoutingDecision{
		RequestID:          in.RequestID,
		AttemptN:           in.AttemptN,
		ProviderID:         in.ProviderID,
		ProviderAssignedID: in.ProviderAssignedID,
		CachedPromptTokens: effectiveCached,
		StickyResult:       in.StickyResult,
		StickyMissReason:   in.StickyMissReason,
		ValidationReason:   validationReason,
	})
}

func (s *Store) WriteRequestLogWithIdentity(ctx context.Context, reqLogStore *requestlog.Store, reqRow requestlog.Row, in HotPathInput) error {
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
	if in.ProviderAssignedID != "" && in.ProviderID != "" {
		now := time.Now().UTC().Format(time.RFC3339Nano)
		if err := insertProviderIdentitySnapshotTx(ctx, conn, in, now); err != nil {
			return err
		}
	}
	_, err = conn.ExecContext(ctx, `COMMIT`)
	committed = err == nil
	return err
}

func insertProviderIdentitySnapshotTx(ctx context.Context, db sqlExecutor, in HotPathInput, now string) error {
	_, err := db.ExecContext(ctx, `
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from,
    pool_session_started_at_utc, created_at_utc
) VALUES (?, ?, ?, ?, 'pool_entry', NULL, ?)
ON CONFLICT(request_id, attempt_n, provider_assigned_id) DO NOTHING`,
		in.RequestID, in.AttemptN, in.ProviderAssignedID, in.ProviderID, now,
	)
	return err
}

type sqlExecutor interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func insertRequestCreditTx(ctx context.Context, db sqlExecutor, in HotPathInput, result BilledRow, source, now string, quarantined bool, quarantineReason string) (int64, error) {
	res, err := db.ExecContext(ctx, `
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, prompt_tokens, cached_prompt_tokens, completion_tokens, estimated_completion_tokens,
    usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, settlement_account_scope_hash, settlement_policy_mode,
    settlement_policy_version, recovery_source, created_at_utc, quarantined,
    quarantine_reason
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		in.RequestID,
		in.AttemptN,
		in.ProviderID,
		nullString(in.ProviderAssignedID),
		in.TSUtc.UTC().Format(time.RFC3339Nano),
		in.Model,
		in.Status,
		boolInt(in.Stream),
		nullInt64(result.PromptTokens),
		nullInt64(result.CachedPromptTokens),
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
		nullString(in.SettlementAccountScopeHash),
		settlementPolicyModeOrLegacy(in.SettlementPolicyMode),
		nullString(in.SettlementPolicyVersion),
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

func settlementPolicyModeOrLegacy(mode string) string {
	switch mode {
	case "observe", "enforce":
		return mode
	default:
		return "legacy"
	}
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

package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
)

type RequestSettlementFinality struct {
	RequestID                string `json:"request_id"`
	PolicyVersion            string `json:"policy_version"`
	Mode                     string `json:"mode"`
	Outcome                  string `json:"outcome"`
	ReceiptResult            string `json:"receipt_result"`
	Reason                   string `json:"reason"`
	Closed                   bool   `json:"closed"`
	PendingDeadlineUnixMS    int64  `json:"pending_deadline_unix_ms,omitempty"`
	PromptTokens             int64  `json:"prompt_tokens,omitempty"`
	CompletionTokens         int64  `json:"completion_tokens,omitempty"`
	TotalTokens              int64  `json:"total_tokens,omitempty"`
	TokenSource              string `json:"token_source,omitempty"`
	VerifiedAttempts         int64  `json:"verified_attempts"`
	PendingAttempts          int64  `json:"pending_attempts"`
	QuarantinedAttempts      int64  `json:"quarantined_attempts"`
	ZeroSettledAttempts      int64  `json:"zero_settled_attempts"`
	OverlappingBlockedTokens int64  `json:"overlapping_blocked_tokens,omitempty"`
}

type requestSettlementVerdictRow struct {
	attemptN              int64
	providerID            string
	receiptResult         string
	settlementOutcome     string
	reason                string
	closed                bool
	pendingDeadlineUnixMS int64
	policyVersion         string
	mode                  string
}

func (s *Store) RequestSettlementFinalityForAccount(ctx context.Context, accountID, requestID string, nowUnixMS int64) (RequestSettlementFinality, bool, error) {
	return s.RequestSettlementFinality(ctx, AccountScopeForSettlement(accountID), requestID, nowUnixMS)
}

func (s *Store) RequestSettlementFinality(ctx context.Context, accountScope, requestID string, nowUnixMS int64) (RequestSettlementFinality, bool, error) {
	if accountScope == "" {
		return RequestSettlementFinality{}, false, fmt.Errorf("account scope is required")
	}
	if requestID == "" {
		return RequestSettlementFinality{}, false, fmt.Errorf("request id is required")
	}
	if nowUnixMS == 0 {
		nowUnixMS = s.nowUTC().UnixMilli()
	}
	rows, err := s.requestSettlementVerdicts(ctx, accountScope, requestID)
	if err != nil || len(rows) == 0 {
		return RequestSettlementFinality{}, len(rows) > 0, err
	}
	changed := false
	for _, row := range rows {
		if row.settlementOutcome == SettlementOutcomePending && !row.closed && row.pendingDeadlineUnixMS > 0 && nowUnixMS >= row.pendingDeadlineUnixMS {
			_, err := s.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
				SettlementReceiptIdentity: SettlementReceiptIdentity{
					AccountScope: accountScope,
					RequestID:    requestID,
					AttemptN:     row.attemptN,
					ProviderID:   row.providerID,
				},
				NowUnixMS: nowUnixMS,
			})
			if err != nil {
				return RequestSettlementFinality{}, false, err
			}
			changed = true
		}
	}
	if changed {
		rows, err = s.requestSettlementVerdicts(ctx, accountScope, requestID)
		if err != nil || len(rows) == 0 {
			return RequestSettlementFinality{}, len(rows) > 0, err
		}
	}
	finality := RequestSettlementFinality{
		RequestID:     requestID,
		PolicyVersion: rows[0].policyVersion,
		Mode:          rows[0].mode,
	}
	var firstTerminalRefund *requestSettlementVerdictRow
	for i := range rows {
		row := rows[i]
		if row.policyVersion != finality.PolicyVersion || row.mode != finality.Mode {
			finality.Outcome = SettlementOutcomePending
			finality.ReceiptResult = SettlementReceiptResultInconclusive
			finality.Reason = "mixed_settlement_policy_snapshot"
			finality.Closed = false
			finality.PendingAttempts++
			finality.PendingDeadlineUnixMS = minPositiveDeadline(finality.PendingDeadlineUnixMS, row.pendingDeadlineUnixMS)
			return finality, true, nil
		}
		switch row.settlementOutcome {
		case SettlementOutcomePending:
			finality.PendingAttempts++
			finality.PendingDeadlineUnixMS = minPositiveDeadline(finality.PendingDeadlineUnixMS, row.pendingDeadlineUnixMS)
		case SettlementOutcomeVerified:
			if row.closed && row.receiptResult == SettlementReceiptResultValid {
				usage, blocked, err := s.requestSettlementUsage(ctx, accountScope, requestID, row.attemptN, row.providerID)
				if err != nil {
					return RequestSettlementFinality{}, false, err
				}
				if blocked {
					finality.OverlappingBlockedTokens += usage.BillableInputTokens + usage.BillableOutputTokens
					continue
				}
				finality.PromptTokens += usage.BillableInputTokens
				finality.CompletionTokens += usage.BillableOutputTokens
				finality.VerifiedAttempts++
			} else {
				finality.PendingAttempts++
				finality.PendingDeadlineUnixMS = minPositiveDeadline(finality.PendingDeadlineUnixMS, row.pendingDeadlineUnixMS)
			}
		case SettlementOutcomeQuarantined:
			finality.QuarantinedAttempts++
			if firstTerminalRefund == nil {
				firstTerminalRefund = &row
			}
		case SettlementOutcomeZeroSettled:
			finality.ZeroSettledAttempts++
			if firstTerminalRefund == nil {
				firstTerminalRefund = &row
			}
		default:
			finality.PendingAttempts++
			finality.PendingDeadlineUnixMS = minPositiveDeadline(finality.PendingDeadlineUnixMS, row.pendingDeadlineUnixMS)
		}
	}
	if finality.PendingAttempts > 0 {
		finality.Outcome = SettlementOutcomePending
		finality.ReceiptResult = SettlementReceiptResultInconclusive
		finality.Reason = "receipt_verdict_pending"
		finality.Closed = false
		return finality, true, nil
	}
	if finality.VerifiedAttempts > 0 {
		finality.Outcome = SettlementOutcomeVerified
		finality.ReceiptResult = SettlementReceiptResultValid
		finality.Reason = "verified_settlement"
		finality.Closed = true
		finality.TokenSource = UsageSourceCoordinatorObserved
		finality.TotalTokens = finality.PromptTokens + finality.CompletionTokens
		return finality, true, nil
	}
	if firstTerminalRefund != nil {
		finality.Outcome = firstTerminalRefund.settlementOutcome
		finality.ReceiptResult = firstTerminalRefund.receiptResult
		finality.Reason = firstTerminalRefund.reason
		finality.Closed = true
		return finality, true, nil
	}
	finality.Outcome = SettlementOutcomePending
	finality.ReceiptResult = SettlementReceiptResultInconclusive
	finality.Reason = "no_settlement_candidate"
	finality.Closed = false
	return finality, true, nil
}

func (s *Store) requestSettlementVerdicts(ctx context.Context, accountScope, requestID string) ([]requestSettlementVerdictRow, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT attempt_n, provider_id, receipt_result, settlement_outcome, reason, closed,
       pending_deadline_unix_ms, route_snapshot_policy_version, route_snapshot_mode
  FROM settlement_receipt_verdicts
 WHERE account_scope_hash = ? AND request_id = ?
 ORDER BY attempt_n ASC, id ASC`, SettlementAccountScopeHash(accountScope), requestID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []requestSettlementVerdictRow
	for rows.Next() {
		var row requestSettlementVerdictRow
		var closed int
		if err := rows.Scan(&row.attemptN, &row.providerID, &row.receiptResult, &row.settlementOutcome, &row.reason, &closed, &row.pendingDeadlineUnixMS, &row.policyVersion, &row.mode); err != nil {
			return nil, err
		}
		row.closed = closed == 1
		out = append(out, row)
	}
	return out, rows.Err()
}

func (s *Store) requestSettlementUsage(ctx context.Context, accountScope, requestID string, attemptN int64, providerID string) (SettlementUsage, bool, error) {
	var raw string
	var overlap int
	err := s.db.QueryRowContext(ctx, `
SELECT usage_canonical_json, overlapping_or_duplicate
  FROM settlement_attempt_outputs
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		accountScope, requestID, attemptN, providerID).Scan(&raw, &overlap)
	if err != nil {
		if err == sql.ErrNoRows {
			return SettlementUsage{}, false, fmt.Errorf("verified settlement attempt output missing for request %s attempt %d provider %s", requestID, attemptN, providerID)
		}
		return SettlementUsage{}, false, err
	}
	var usage struct {
		BillableInputTokens  int64 `json:"billable_input_tokens"`
		BillableOutputTokens int64 `json:"billable_output_tokens"`
		DeliveredOutputBytes int64 `json:"delivered_output_bytes"`
		ObservedInputTokens  int64 `json:"observed_input_tokens"`
		ObservedOutputTokens int64 `json:"observed_output_tokens"`
	}
	if err := json.Unmarshal([]byte(raw), &usage); err != nil {
		return SettlementUsage{}, false, err
	}
	out := SettlementUsage{
		BillableInputTokens:  usage.BillableInputTokens,
		BillableOutputTokens: usage.BillableOutputTokens,
		DeliveredOutputBytes: usage.DeliveredOutputBytes,
		ObservedInputTokens:  usage.ObservedInputTokens,
		ObservedOutputTokens: usage.ObservedOutputTokens,
	}
	if err := out.Validate(); err != nil {
		return SettlementUsage{}, false, err
	}
	return out, overlap == 1, nil
}

func minPositiveDeadline(current, candidate int64) int64 {
	if candidate <= 0 {
		return current
	}
	if current <= 0 || candidate < current {
		return candidate
	}
	return current
}

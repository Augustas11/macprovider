package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
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

const externalRequestFinalityLookupSkew = 5 * time.Minute
const SettlementOutcomeOverlapBlockedTerminal = "overlap_blocked_terminal"

func (s *Store) RequestSettlementFinalityForAccount(ctx context.Context, accountID, requestID string, nowUnixMS int64, notBeforeUnixMS ...int64) (RequestSettlementFinality, bool, error) {
	accountScope := AccountScopeForSettlement(accountID)
	notBefore := int64(0)
	if len(notBeforeUnixMS) > 0 {
		notBefore = notBeforeUnixMS[0]
	}
	directLookupAllowed := true
	if notBefore > 0 {
		var err error
		directLookupAllowed, err = s.directRequestIDWithinReservationWindow(ctx, accountID, requestID, notBefore)
		if err != nil {
			return RequestSettlementFinality{}, false, err
		}
	}
	if directLookupAllowed {
		finality, found, err := s.RequestSettlementFinality(ctx, accountScope, requestID, nowUnixMS)
		if err != nil || found {
			return finality, found, err
		}
	}
	internalRequestIDs, err := s.requestIDsForExternalRequest(ctx, accountID, requestID, notBefore)
	if err != nil || len(internalRequestIDs) == 0 {
		return RequestSettlementFinality{}, false, err
	}
	finalities := make([]RequestSettlementFinality, 0, len(internalRequestIDs))
	missingFinality := false
	for _, internalRequestID := range internalRequestIDs {
		resolved, resolvedFound, err := s.RequestSettlementFinality(ctx, accountScope, internalRequestID, nowUnixMS)
		if err != nil {
			return RequestSettlementFinality{}, false, err
		}
		if resolvedFound {
			finalities = append(finalities, resolved)
		} else {
			missingFinality = true
		}
	}
	if len(finalities) == 0 {
		return RequestSettlementFinality{}, false, nil
	}
	finality := aggregateExternalRequestFinality(requestID, finalities)
	if missingFinality && finality.Outcome == SettlementOutcomeVerified && finality.Closed {
		finality.Outcome = SettlementOutcomePending
		finality.ReceiptResult = SettlementReceiptResultInconclusive
		finality.Reason = "missing_current_settlement_finality"
		finality.Closed = false
		finality.TokenSource = ""
		finality.PromptTokens = 0
		finality.CompletionTokens = 0
		finality.TotalTokens = 0
		finality.PendingAttempts++
	}
	return finality, true, nil
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
	if finality.OverlappingBlockedTokens > 0 {
		finality.Outcome = SettlementOutcomeOverlapBlockedTerminal
		finality.ReceiptResult = SettlementReceiptResultValid
		finality.Reason = "overlap_blocked_terminal"
		finality.Closed = true
		finality.TokenSource = UsageSourceCoordinatorObserved
		finality.TotalTokens = 0
		return finality, true, nil
	}
	finality.Outcome = SettlementOutcomePending
	finality.ReceiptResult = SettlementReceiptResultInconclusive
	finality.Reason = "no_settlement_candidate"
	finality.Closed = false
	return finality, true, nil
}

func (s *Store) directRequestIDWithinReservationWindow(ctx context.Context, accountID, requestID string, notBeforeUnixMS int64) (bool, error) {
	if notBeforeUnixMS <= 0 {
		return true, nil
	}
	notBeforeUnixMS -= externalRequestFinalityLookupSkew.Milliseconds()
	if notBeforeUnixMS < 0 {
		notBeforeUnixMS = 0
	}
	var n int
	err := s.db.QueryRowContext(ctx, `
SELECT COUNT(*)
  FROM request_log
 WHERE account_id = ?
   AND request_id = ?
   AND `+sqliteTimeSince("ts_utc"),
		accountID,
		requestID,
		sqliteTimeText(time.UnixMilli(notBeforeUnixMS)),
	).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
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
	var ledgerPrompt, ledgerChargedPrompt, ledgerCompletion sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
	SELECT sao.usage_canonical_json, sao.overlapping_or_duplicate,
	       lrc.prompt_tokens, lrc.charged_prompt_tokens, lrc.completion_tokens
	  FROM settlement_attempt_outputs sao
	  JOIN ledger_request_credits lrc
	    ON lrc.settlement_account_scope_hash = ?
	   AND lrc.request_id = sao.request_id
	   AND lrc.attempt_n = sao.attempt_n
	   AND lrc.provider_id = sao.provider_id
	   AND lrc.quarantined = 0
	 WHERE sao.account_scope = ? AND sao.request_id = ? AND sao.attempt_n = ? AND sao.provider_id = ?
	 ORDER BY lrc.id DESC
	 LIMIT 1`,
		SettlementAccountScopeHash(accountScope), accountScope, requestID, attemptN, providerID).Scan(&raw, &overlap, &ledgerPrompt, &ledgerChargedPrompt, &ledgerCompletion)
	if err != nil {
		if err == sql.ErrNoRows {
			return SettlementUsage{}, false, fmt.Errorf("verified charged ledger usage missing for request %s attempt %d provider %s", requestID, attemptN, providerID)
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
		BillableInputTokens:  chargedPromptTokensFromLedger(ledgerChargedPrompt, ledgerPrompt),
		BillableOutputTokens: int64FromNull(ledgerCompletion),
		DeliveredOutputBytes: usage.DeliveredOutputBytes,
		ObservedInputTokens:  usage.ObservedInputTokens,
		ObservedOutputTokens: usage.ObservedOutputTokens,
	}
	if err := out.Validate(); err != nil {
		return SettlementUsage{}, false, err
	}
	return out, overlap == 1, nil
}

func chargedPromptTokensFromLedger(charged, prompt sql.NullInt64) int64 {
	if charged.Valid {
		return charged.Int64
	}
	return int64FromNull(prompt)
}

func int64FromNull(v sql.NullInt64) int64 {
	if !v.Valid {
		return 0
	}
	return v.Int64
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

func (s *Store) requestIDsForExternalRequest(ctx context.Context, accountID, externalRequestID string, notBeforeUnixMS int64) ([]string, error) {
	args := []any{accountID, externalRequestID}
	notBeforeClause := ""
	if notBeforeUnixMS > 0 {
		notBeforeUnixMS -= externalRequestFinalityLookupSkew.Milliseconds()
		if notBeforeUnixMS < 0 {
			notBeforeUnixMS = 0
		}
		notBeforeClause = " AND " + sqliteTimeSince("ts_utc")
		args = append(args, sqliteTimeText(time.UnixMilli(notBeforeUnixMS)))
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT request_id
  FROM (
        SELECT request_id, MIN(id) AS first_id
          FROM request_log
         WHERE account_id = ? AND external_request_id = ? AND request_id IS NOT NULL AND request_id != ''`+notBeforeClause+`
         GROUP BY request_id
       )
 ORDER BY first_id ASC`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var requestID string
		if err := rows.Scan(&requestID); err != nil {
			return nil, err
		}
		out = append(out, requestID)
	}
	return out, rows.Err()
}

func aggregateExternalRequestFinality(externalRequestID string, finalities []RequestSettlementFinality) RequestSettlementFinality {
	out := RequestSettlementFinality{
		RequestID:     externalRequestID,
		PolicyVersion: finalities[0].PolicyVersion,
		Mode:          finalities[0].Mode,
	}
	var firstTerminalRefund RequestSettlementFinality
	hasTerminalRefund := false
	for i := range finalities {
		finality := finalities[i]
		if finality.PolicyVersion != out.PolicyVersion || finality.Mode != out.Mode {
			out.Outcome = SettlementOutcomePending
			out.ReceiptResult = SettlementReceiptResultInconclusive
			out.Reason = "mixed_settlement_policy_snapshot"
			out.Closed = false
			out.PendingAttempts++
			out.PendingDeadlineUnixMS = minPositiveDeadline(out.PendingDeadlineUnixMS, finality.PendingDeadlineUnixMS)
			return out
		}
		out.VerifiedAttempts += finality.VerifiedAttempts
		out.PendingAttempts += finality.PendingAttempts
		out.QuarantinedAttempts += finality.QuarantinedAttempts
		out.ZeroSettledAttempts += finality.ZeroSettledAttempts
		out.OverlappingBlockedTokens += finality.OverlappingBlockedTokens
		out.PendingDeadlineUnixMS = minPositiveDeadline(out.PendingDeadlineUnixMS, finality.PendingDeadlineUnixMS)
		out.PromptTokens += finality.PromptTokens
		out.CompletionTokens += finality.CompletionTokens
		out.TotalTokens += finality.TotalTokens
		if !hasTerminalRefund &&
			finality.Closed &&
			finality.Outcome != SettlementOutcomeVerified &&
			(finality.QuarantinedAttempts > 0 || finality.ZeroSettledAttempts > 0) {
			firstTerminalRefund = finality
			hasTerminalRefund = true
		}
	}
	if out.PendingAttempts > 0 {
		out.Outcome = SettlementOutcomePending
		out.ReceiptResult = SettlementReceiptResultInconclusive
		out.Reason = "receipt_verdict_pending"
		out.Closed = false
		return out
	}
	if out.VerifiedAttempts > 0 {
		out.Outcome = SettlementOutcomeVerified
		out.ReceiptResult = SettlementReceiptResultValid
		out.Reason = "verified_settlement"
		out.Closed = true
		out.TokenSource = UsageSourceCoordinatorObserved
		return out
	}
	if hasTerminalRefund {
		out.Outcome = firstTerminalRefund.Outcome
		out.ReceiptResult = firstTerminalRefund.ReceiptResult
		out.Reason = firstTerminalRefund.Reason
		out.Closed = true
		return out
	}
	if out.OverlappingBlockedTokens > 0 {
		out.Outcome = SettlementOutcomeOverlapBlockedTerminal
		out.ReceiptResult = SettlementReceiptResultValid
		out.Reason = "overlap_blocked_terminal"
		out.Closed = true
		out.TokenSource = UsageSourceCoordinatorObserved
		out.TotalTokens = 0
		return out
	}
	out.Outcome = SettlementOutcomePending
	out.ReceiptResult = SettlementReceiptResultInconclusive
	out.Reason = "no_settlement_candidate"
	out.Closed = false
	return out
}

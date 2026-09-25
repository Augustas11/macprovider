package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

type RequestSettlementFinality struct {
	RequestID     string `json:"request_id"`
	PolicyVersion string `json:"policy_version"`
	Mode          string `json:"mode"`
	// Present only after the required internal request is included in the
	// account/generation-scoped external lookup, never a direct-ID lookup.
	RequiredInternalRequestID string `json:"required_internal_request_id,omitempty"`
	// Scope completeness covers policy/mode, not receipt verification. It binds
	// the selected internal request, or every linked request for an external ID.
	ModeScopeComplete        bool   `json:"mode_scope_complete"`
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
	// noSnapshot marks an enforce credit recorded without a route snapshot
	// (store pressure): the snapshot scope check does not apply to it.
	noSnapshot bool
}

// SettlementEvidenceMissingReason closes an enforce-mode attempt whose
// ledger credit has no settlement attempt output and no verdict once its
// evidence deadline passed. Enforce payability needs both
// (spec022_payable_request_credits) and only the in-request recorder writes
// an attempt output, so such a credit can never be paid; reporting it closed
// quarantined lets a held buyer reservation refund instead of waiting on a
// lookup that would otherwise 404 forever (SPEC-022 v0.2.2).
const SettlementEvidenceMissingReason = "settlement_evidence_missing"

// enforceEvidenceMissingGrace bounds how long an enforce credit without a
// route snapshot waits for evidence before it is closed; one with a snapshot
// uses the snapshot's pending deadline.
const enforceEvidenceMissingGrace = 5 * time.Minute

// enforceCreditWithoutEvidence is the finality row for an enforce credit that
// has no attempt output and no verdict: pending until creditTS plus grace,
// then closed quarantined.
func enforceCreditWithoutEvidence(row requestSettlementVerdictRow, creditTS string, grace time.Duration, nowUnixMS int64) (requestSettlementVerdictRow, bool) {
	ts, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(creditTS))
	if err != nil {
		return row, false
	}
	row.receiptResult = SettlementReceiptResultInconclusive
	deadline := ts.Add(grace).UnixMilli()
	if nowUnixMS < deadline {
		row.settlementOutcome = SettlementOutcomePending
		row.reason = "settlement_evidence_pending"
		row.pendingDeadlineUnixMS = deadline
		return row, true
	}
	row.settlementOutcome = SettlementOutcomeQuarantined
	row.reason = SettlementEvidenceMissingReason
	row.closed = true
	row.pendingDeadlineUnixMS = 0
	return row, true
}

const externalRequestFinalityLookupSkew = 5 * time.Minute
const SettlementOutcomeOverlapBlockedTerminal = "overlap_blocked_terminal"

func (s *Store) RequestSettlementFinalityForAccount(ctx context.Context, accountID, requestID string, nowUnixMS int64, notBeforeUnixMS ...int64) (RequestSettlementFinality, bool, error) {
	notBefore := int64(0)
	if len(notBeforeUnixMS) > 0 {
		notBefore = notBeforeUnixMS[0]
	}
	return s.requestSettlementFinalityForAccount(ctx, accountID, requestID, "", nowUnixMS, notBefore)
}

// RequestSettlementFinalityForAccountBound prevents a prior logged retry from
// authorizing recovery while the current stream has not written its request log.
func (s *Store) RequestSettlementFinalityForAccountBound(ctx context.Context, accountID, requestID, requiredInternalRequestID string, nowUnixMS, notBeforeUnixMS int64) (RequestSettlementFinality, bool, error) {
	if requiredInternalRequestID == "" || notBeforeUnixMS <= 0 {
		return RequestSettlementFinality{}, false, fmt.Errorf("required internal request id and reservation timestamp are required")
	}
	return s.requestSettlementFinalityForAccount(ctx, accountID, requestID, requiredInternalRequestID, nowUnixMS, notBeforeUnixMS)
}

func (s *Store) requestSettlementFinalityForAccount(ctx context.Context, accountID, requestID, requiredInternalRequestID string, nowUnixMS, notBefore int64) (RequestSettlementFinality, bool, error) {
	accountScope := AccountScopeForSettlement(accountID)
	directLookupAllowed := requiredInternalRequestID == ""
	if directLookupAllowed && notBefore > 0 {
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
	if requiredInternalRequestID != "" {
		included := false
		for _, internalRequestID := range internalRequestIDs {
			if internalRequestID == requiredInternalRequestID {
				included = true
				break
			}
		}
		if !included {
			return RequestSettlementFinality{}, false, nil
		}
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
	finality.RequiredInternalRequestID = requiredInternalRequestID
	if missingFinality {
		finality.ModeScopeComplete = false
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
	if err != nil {
		return RequestSettlementFinality{}, false, err
	}
	missing, err := s.requestSettlementAttemptsWithoutVerdict(ctx, accountScope, requestID, rows, nowUnixMS)
	if err != nil {
		return RequestSettlementFinality{}, false, err
	}
	withoutSnapshot, err := s.requestEnforceCreditsWithoutSnapshot(ctx, accountScope, requestID, nowUnixMS)
	if err != nil {
		return RequestSettlementFinality{}, false, err
	}
	missing = append(missing, withoutSnapshot...)
	changed := false
	pending := make([]requestSettlementVerdictRow, 0, len(missing))
	for _, row := range missing {
		if row.pendingDeadlineUnixMS <= 0 || nowUnixMS < row.pendingDeadlineUnixMS {
			pending = append(pending, row)
			continue
		}
		if _, err := s.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
			SettlementReceiptIdentity: SettlementReceiptIdentity{
				AccountScope: accountScope,
				RequestID:    requestID,
				AttemptN:     row.attemptN,
				ProviderID:   row.providerID,
			},
			NowUnixMS: nowUnixMS,
		}); err != nil {
			return RequestSettlementFinality{}, false, err
		}
		changed = true
	}
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
		if err != nil {
			return RequestSettlementFinality{}, false, err
		}
	}
	rows = append(rows, pending...)
	if len(rows) == 0 {
		return RequestSettlementFinality{}, false, nil
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].attemptN != rows[j].attemptN {
			return rows[i].attemptN < rows[j].attemptN
		}
		return rows[i].providerID < rows[j].providerID
	})
	finality := RequestSettlementFinality{
		RequestID:     requestID,
		PolicyVersion: rows[0].policyVersion,
		Mode:          rows[0].mode,
	}
	var firstTerminalRefund *requestSettlementVerdictRow
	poolOperatorAttested := false
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
				usage, blocked, source, err := s.requestSettlementUsage(ctx, accountScope, requestID, row.attemptN, row.providerID)
				if err != nil {
					return RequestSettlementFinality{}, false, err
				}
				// SPEC-022-R012.6a: the reported source comes from the
				// persisted per-attempt sources; the weaker one governs.
				if source == UsageSourcePoolOperatorAttested {
					poolOperatorAttested = true
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
	scopeReason, err := s.requestSettlementScopeReason(ctx, accountScope, requestID, rows)
	if err != nil {
		return RequestSettlementFinality{}, false, err
	}
	if scopeReason != "" {
		finality.Outcome = SettlementOutcomePending
		finality.ReceiptResult = SettlementReceiptResultInconclusive
		finality.Reason = scopeReason
		finality.Closed = false
		finality.TokenSource = ""
		finality.PromptTokens = 0
		finality.CompletionTokens = 0
		finality.TotalTokens = 0
		finality.PendingAttempts++
		return finality, true, nil
	}
	finality.ModeScopeComplete = true
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
		finality.TokenSource = finalityTokenSource(poolOperatorAttested)
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
		finality.TokenSource = finalityTokenSource(poolOperatorAttested)
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

// requestSettlementAttemptsWithoutVerdict recovers the finality boundary from
// immutable route snapshots plus durable attempt outputs. Receipt bytes are
// deliberately absent: before the deadline the gateway must hold, and after
// the deadline RecordMissingSettlementReceipt produces an explicit terminal
// classification instead of leaving the reservation unresolved forever.
func (s *Store) requestSettlementAttemptsWithoutVerdict(ctx context.Context, accountScope, requestID string, verdicts []requestSettlementVerdictRow, nowUnixMS int64) ([]requestSettlementVerdictRow, error) {
	type attemptKey struct {
		attemptN   int64
		providerID string
	}
	covered := make(map[attemptKey]struct{}, len(verdicts))
	for _, verdict := range verdicts {
		covered[attemptKey{attemptN: verdict.attemptN, providerID: verdict.providerID}] = struct{}{}
	}
	// An attempt with no attempt output is closed quarantined when the
	// coordinator quarantined its credit after a delivered response's
	// evidence failed (UndeliveredSettlementQuarantineReasons), and, for an
	// enforce snapshot with an enforce credit, once the snapshot's pending
	// deadline after the credit passed (SettlementEvidenceMissingReason).
	// Either way a gateway that never received the refund trailer refunds
	// instead of holding forever (SPEC-022 v0.2.2). With no credit there is
	// nothing to settle and the attempt is skipped.
	rows, err := s.db.QueryContext(ctx, `
SELECT rs.attempt_n, rs.provider_id,
       COALESCE(sao.terminal_state_ts_unix_ms + (rs.pending_deadline_seconds * 1000), 0),
       rs.pending_deadline_seconds,
       rs.route_snapshot_policy_version, rs.route_snapshot_mode,
       sao.request_id IS NOT NULL,
       COALESCE((
           SELECT lrc.quarantine_reason
             FROM ledger_request_credits lrc
            WHERE lrc.request_id = rs.request_id
              AND lrc.provider_id = rs.provider_id
              AND lrc.settlement_account_scope_hash = ?
              AND lrc.quarantined = 1
              AND lrc.quarantine_reason IN (?, ?, ?)
            ORDER BY lrc.attempt_n DESC
            LIMIT 1), ''),
       COALESCE((
           SELECT MIN(lrc.ts_utc)
             FROM ledger_request_credits lrc
            WHERE lrc.request_id = rs.request_id
              AND lrc.provider_id = rs.provider_id
              AND lrc.settlement_account_scope_hash = ?
              AND lrc.settlement_policy_mode = 'enforce'), '')
  FROM settlement_route_snapshots rs
  LEFT JOIN settlement_attempt_outputs sao
    ON sao.account_scope = rs.account_scope
   AND sao.request_id = rs.request_id
   AND sao.attempt_n = rs.attempt_n
   AND sao.provider_id = rs.provider_id
 WHERE rs.account_scope = ? AND rs.request_id = ?
 ORDER BY rs.attempt_n ASC, rs.provider_id ASC`,
		SettlementAccountScopeHash(accountScope),
		UndeliveredSettlementQuarantineReasons[0], UndeliveredSettlementQuarantineReasons[1], UndeliveredSettlementQuarantineReasons[2],
		SettlementAccountScopeHash(accountScope),
		accountScope, requestID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var missing []requestSettlementVerdictRow
	for rows.Next() {
		var row requestSettlementVerdictRow
		var hasOutput bool
		var quarantineReason, creditTS string
		var pendingDeadlineSeconds int64
		if err := rows.Scan(&row.attemptN, &row.providerID, &row.pendingDeadlineUnixMS, &pendingDeadlineSeconds, &row.policyVersion, &row.mode, &hasOutput, &quarantineReason, &creditTS); err != nil {
			return nil, err
		}
		if _, ok := covered[attemptKey{attemptN: row.attemptN, providerID: row.providerID}]; ok {
			continue
		}
		switch {
		case hasOutput:
			row.receiptResult = SettlementReceiptResultInconclusive
			row.settlementOutcome = SettlementOutcomePending
			row.reason = "receipt_verdict_pending"
		case quarantineReason != "":
			row.receiptResult = SettlementReceiptResultInconclusive
			row.settlementOutcome = SettlementOutcomeQuarantined
			row.reason = quarantineReason
			row.closed = true
			row.pendingDeadlineUnixMS = 0
		case creditTS != "" && row.mode == RouteSnapshotModeEnforce:
			evidenceRow, ok := enforceCreditWithoutEvidence(row, creditTS, time.Duration(pendingDeadlineSeconds)*time.Second, nowUnixMS)
			if !ok {
				continue
			}
			row = evidenceRow
		default:
			continue
		}
		missing = append(missing, row)
	}
	return missing, rows.Err()
}

// requestEnforceCreditsWithoutSnapshot covers enforce credits recorded with
// no route snapshot (store pressure): no attempt output, no verdict, and no
// snapshot for the provider. Each is pending for enforceEvidenceMissingGrace
// after the credit, then closed quarantined; one the coordinator already
// quarantined after a delivery closes at once with that reason.
func (s *Store) requestEnforceCreditsWithoutSnapshot(ctx context.Context, accountScope, requestID string, nowUnixMS int64) ([]requestSettlementVerdictRow, error) {
	scopeHash := SettlementAccountScopeHash(accountScope)
	rows, err := s.db.QueryContext(ctx, `
SELECT lrc.attempt_n, lrc.provider_id, lrc.ts_utc,
       COALESCE(lrc.settlement_policy_version, ''),
       CASE WHEN lrc.quarantined = 1 AND lrc.quarantine_reason IN (?, ?, ?) THEN lrc.quarantine_reason ELSE '' END
  FROM ledger_request_credits lrc
 WHERE lrc.request_id = ?
   AND lrc.settlement_account_scope_hash = ?
   AND lrc.settlement_policy_mode = 'enforce'
   AND NOT EXISTS (SELECT 1 FROM settlement_route_snapshots rs
                    WHERE rs.account_scope = ? AND rs.request_id = lrc.request_id AND rs.provider_id = lrc.provider_id)
   AND NOT EXISTS (SELECT 1 FROM settlement_attempt_outputs sao
                    WHERE sao.account_scope = ? AND sao.request_id = lrc.request_id AND sao.provider_id = lrc.provider_id)
   AND NOT EXISTS (SELECT 1 FROM settlement_receipt_verdicts srv
                    WHERE srv.account_scope_hash = ? AND srv.request_id = lrc.request_id AND srv.provider_id = lrc.provider_id)
 ORDER BY lrc.attempt_n ASC, lrc.provider_id ASC`,
		UndeliveredSettlementQuarantineReasons[0], UndeliveredSettlementQuarantineReasons[1], UndeliveredSettlementQuarantineReasons[2],
		requestID, scopeHash, accountScope, accountScope, scopeHash)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []requestSettlementVerdictRow
	for rows.Next() {
		row := requestSettlementVerdictRow{mode: RouteSnapshotModeEnforce, noSnapshot: true}
		var creditTS, quarantineReason string
		if err := rows.Scan(&row.attemptN, &row.providerID, &creditTS, &row.policyVersion, &quarantineReason); err != nil {
			return nil, err
		}
		if quarantineReason != "" {
			row.receiptResult = SettlementReceiptResultInconclusive
			row.settlementOutcome = SettlementOutcomeQuarantined
			row.reason = quarantineReason
			row.closed = true
			out = append(out, row)
			continue
		}
		if evidenceRow, ok := enforceCreditWithoutEvidence(row, creditTS, enforceEvidenceMissingGrace, nowUnixMS); ok {
			out = append(out, evidenceRow)
		}
	}
	return out, rows.Err()
}

// Snapshots exist before pending verdicts do. Looking only at verdict rows can
// hide a later attempt's policy or mode while advertising earlier observe scope.
func (s *Store) requestSettlementScopeReason(ctx context.Context, accountScope, requestID string, verdicts []requestSettlementVerdictRow) (string, error) {
	if len(verdicts) == 0 {
		return "missing_current_settlement_finality", nil
	}
	type attemptKey struct {
		attemptN   int64
		providerID string
	}
	remaining := make(map[attemptKey]requestSettlementVerdictRow, len(verdicts))
	for _, verdict := range verdicts {
		if verdict.noSnapshot {
			continue
		}
		remaining[attemptKey{verdict.attemptN, verdict.providerID}] = verdict
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT attempt_n, provider_id, route_snapshot_policy_version, route_snapshot_mode
  FROM settlement_route_snapshots
 WHERE account_scope = ? AND request_id = ?`, accountScope, requestID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	reason := ""
	for rows.Next() {
		var key attemptKey
		var policy, mode string
		if err := rows.Scan(&key.attemptN, &key.providerID, &policy, &mode); err != nil {
			return "", err
		}
		if policy != verdicts[0].policyVersion || mode != verdicts[0].mode {
			return "mixed_settlement_policy_snapshot", nil
		}
		verdict, found := remaining[key]
		if !found {
			reason = "missing_current_settlement_finality"
			continue
		}
		if verdict.policyVersion != policy || verdict.mode != mode {
			return "mixed_settlement_policy_snapshot", nil
		}
		delete(remaining, key)
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	if len(remaining) > 0 {
		return "missing_current_settlement_finality", nil
	}
	return reason, nil
}

// finalityTokenSource is SPEC-022-R012.6a: coordinator_observed only when
// every verified attempt persisted coordinator_observed; pool_operator_attested
// when any did (the weaker provenance governs a mixed request).
func finalityTokenSource(poolOperatorAttested bool) string {
	if poolOperatorAttested {
		return UsageSourcePoolOperatorAttested
	}
	return UsageSourceCoordinatorObserved
}

func anyPoolOperatorAttested(finalities []RequestSettlementFinality) bool {
	for _, f := range finalities {
		if f.TokenSource == UsageSourcePoolOperatorAttested {
			return true
		}
	}
	return false
}

func (s *Store) requestSettlementUsage(ctx context.Context, accountScope, requestID string, attemptN int64, providerID string) (SettlementUsage, bool, string, error) {
	var raw, source string
	var overlap int
	var ledgerPrompt, ledgerChargedPrompt, ledgerCompletion sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
	SELECT sao.usage_canonical_json, sao.overlapping_or_duplicate, sao.usage_source,
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
		SettlementAccountScopeHash(accountScope), accountScope, requestID, attemptN, providerID).Scan(&raw, &overlap, &source, &ledgerPrompt, &ledgerChargedPrompt, &ledgerCompletion)
	if err != nil {
		if err == sql.ErrNoRows {
			return SettlementUsage{}, false, "", fmt.Errorf("verified charged ledger usage missing for request %s attempt %d provider %s", requestID, attemptN, providerID)
		}
		return SettlementUsage{}, false, "", err
	}
	var usage struct {
		BillableInputTokens  int64 `json:"billable_input_tokens"`
		BillableOutputTokens int64 `json:"billable_output_tokens"`
		DeliveredOutputBytes int64 `json:"delivered_output_bytes"`
		ObservedInputTokens  int64 `json:"observed_input_tokens"`
		ObservedOutputTokens int64 `json:"observed_output_tokens"`
	}
	if err := json.Unmarshal([]byte(raw), &usage); err != nil {
		return SettlementUsage{}, false, "", err
	}
	out := SettlementUsage{
		BillableInputTokens:  chargedPromptTokensFromLedger(ledgerChargedPrompt, ledgerPrompt),
		BillableOutputTokens: int64FromNull(ledgerCompletion),
		DeliveredOutputBytes: usage.DeliveredOutputBytes,
		ObservedInputTokens:  usage.ObservedInputTokens,
		ObservedOutputTokens: usage.ObservedOutputTokens,
	}
	if err := out.Validate(); err != nil {
		return SettlementUsage{}, false, "", err
	}
	return out, overlap == 1, source, nil
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
		RequestID:         externalRequestID,
		PolicyVersion:     finalities[0].PolicyVersion,
		Mode:              finalities[0].Mode,
		ModeScopeComplete: true,
	}
	var firstTerminalRefund RequestSettlementFinality
	hasTerminalRefund := false
	for i := range finalities {
		finality := finalities[i]
		if !finality.ModeScopeComplete {
			out.ModeScopeComplete = false
		}
		if finality.PolicyVersion != out.PolicyVersion || finality.Mode != out.Mode {
			out.ModeScopeComplete = false
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
		out.TokenSource = finalityTokenSource(anyPoolOperatorAttested(finalities))
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
		out.TokenSource = finalityTokenSource(anyPoolOperatorAttested(finalities))
		out.TotalTokens = 0
		return out
	}
	out.Outcome = SettlementOutcomePending
	out.ReceiptResult = SettlementReceiptResultInconclusive
	out.Reason = "no_settlement_candidate"
	out.Closed = false
	return out
}

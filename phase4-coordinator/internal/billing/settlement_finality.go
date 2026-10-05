package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
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
	// RelayBlindSettledAttempts counts SPEC-022 R-13 attempts that closed
	// relay_blind_settled under the R-7.9 binding. They are never counted as
	// verified attempts.
	RelayBlindSettledAttempts int64 `json:"relay_blind_settled_attempts"`
	// RelayBlindSettlementCoverage is the coordinator's authoritative SPEC-022
	// R-13 coverage answer for a relay-blind attempt lookup:
	// RelayBlindCoverageEnforce or RelayBlindCoverageObserve. It is set only
	// when the caller asked for a relay-blind attempt.
	RelayBlindSettlementCoverage string `json:"relay_blind_settlement_coverage,omitempty"`
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
	// relayBlindBound is the SPEC-022 R-7.9 binding of a relay_blind_settled
	// verdict: relay-blind entrypoint and basis on its snapshot, relay-blind
	// profile on the verdict.
	relayBlindBound bool
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
	if nowUnixMS <= deadline {
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
const settlementFinalityReadTimeout = 5 * time.Second

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
	if err != nil {
		return RequestSettlementFinality{}, false, err
	}
	if len(internalRequestIDs) == 0 {
		return s.relayBlindRequiredFinality(ctx, accountScope, requestID, requiredInternalRequestID, nowUnixMS)
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
			return s.relayBlindRequiredFinality(ctx, accountScope, requestID, requiredInternalRequestID, nowUnixMS)
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

// defaultRelayBlindAttemptTimeout is the relay-blind dispatch bound used
// until SetRelayBlindAttemptTimeout installs the configured buyer request
// timeout. It is deliberately longer than any configured timeout, so an
// unconfigured store never closes an attempt that may still be running.
const defaultRelayBlindAttemptTimeout = time.Hour

// SetRelayBlindAttemptTimeout installs the buyer request timeout that bounds
// every relay-blind dispatch (SPEC-022 R-13.10). A non-positive value keeps
// the conservative default.
func (s *Store) SetRelayBlindAttemptTimeout(timeout time.Duration) {
	s.relayBlindAttemptTimeoutMS.Store(timeout.Milliseconds())
}

// RelayBlindAttemptTimeout is the relay-blind dispatch bound in effect.
func (s *Store) RelayBlindAttemptTimeout() time.Duration {
	if ms := s.relayBlindAttemptTimeoutMS.Load(); ms > 0 {
		return time.Duration(ms) * time.Millisecond
	}
	return defaultRelayBlindAttemptTimeout
}

// relayBlindUnrecordedTerminalUnixMS is the latest terminal an enforce
// relay-blind attempt can have: the dispatch is bounded by the request
// timeout, and dispatch follows the route decision (SPEC-022 R-13.10). An
// attempt whose terminal was never recorded is measured from it, so its
// R-8.3 deadline is this plus pending_deadline_seconds.
func (s *Store) relayBlindUnrecordedTerminalUnixMS(routeDecisionUnixMS int64) int64 {
	return routeDecisionUnixMS + s.RelayBlindAttemptTimeout().Milliseconds()
}

// RelayBlindAttemptUnrecordedReason closes an enforce relay-blind attempt
// whose snapshot was committed before dispatch but whose credit and attempt
// output were never written (SPEC-022 R-13.6): nothing is payable, so the
// buyer is refunded.
const RelayBlindAttemptUnrecordedReason = "relay_blind_attempt_unrecorded"

// relayBlindRequiredFinality answers a bound lookup whose required internal
// request id has no request_log row under the external id. A SPEC-022 R-13
// relay-blind snapshot is committed before dispatch, so its existence is the
// coordinator's authority that the attempt was enforce-covered even when the
// coordinator stopped before writing the request log. Anything else stays
// not found.
func (s *Store) relayBlindRequiredFinality(ctx context.Context, accountScope, externalRequestID, requiredInternalRequestID string, nowUnixMS int64) (RequestSettlementFinality, bool, error) {
	if requiredInternalRequestID == "" {
		return RequestSettlementFinality{}, false, nil
	}
	readCtx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	var exists bool
	err := s.reader().QueryRowContext(readCtx, `
SELECT EXISTS (
    SELECT 1 FROM settlement_route_snapshots
     WHERE account_scope = ? AND request_id = ?
       AND paid_entrypoint = ? AND prompt_hash_basis = ? AND route_snapshot_mode = ?)`,
		accountScope, requiredInternalRequestID, PaidEntrypointRelayBlindChat, PromptHashBasisRelayBlindEnvelopeV1, RouteSnapshotModeEnforce).Scan(&exists)
	cancel()
	if err != nil || !exists {
		return RequestSettlementFinality{}, false, err
	}
	finality, found, err := s.RequestSettlementFinality(ctx, accountScope, requiredInternalRequestID, nowUnixMS)
	if err != nil || !found {
		return RequestSettlementFinality{}, false, err
	}
	finality.RequestID = externalRequestID
	finality.RequiredInternalRequestID = requiredInternalRequestID
	return finality, true, nil
}

// SPEC-022 R-13 coverage answers for a relay-blind attempt lookup.
const (
	// RelayBlindCoverageEnforce: an enforce R-13 relay-blind route snapshot
	// exists for the attempt; only R-13 finality decides money.
	RelayBlindCoverageEnforce = "enforce"
	// RelayBlindCoverageObserve: the attempt ran without R-13 coverage
	// (observe or off). The gateway may use its status-row recovery.
	RelayBlindCoverageObserve = "observe"
)

// RelayBlindSettlementCoverage answers whether coordinator attempt
// internalRequestID, the relay-blind attempt for external request
// externalRequestID bound to the given provider-binding and envelope digests,
// was R-13 enforce-covered. It returns RelayBlindCoverageEnforce when an
// enforce relay-blind route snapshot exists for the attempt (committed before
// dispatch, R-13.3), RelayBlindCoverageObserve only when the attempt's
// request-log row carries those digests and no relay-blind snapshot exists,
// and "" (unknown, the caller holds) otherwise.
func (s *Store) RelayBlindSettlementCoverage(ctx context.Context, accountID, externalRequestID, internalRequestID, providerBindingDigest, envelopeDigest string) (string, error) {
	if accountID == "" || externalRequestID == "" || internalRequestID == "" || providerBindingDigest == "" || envelopeDigest == "" {
		return "", nil
	}
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	var enforceSnapshot, anyRelayBlindSnapshot, logged bool
	err := s.reader().QueryRowContext(ctx, `
SELECT EXISTS (SELECT 1 FROM settlement_route_snapshots
                WHERE account_scope = ? AND request_id = ?
                  AND paid_entrypoint = ? AND prompt_hash_basis = ? AND route_snapshot_mode = ?),
       EXISTS (SELECT 1 FROM settlement_route_snapshots
                WHERE account_scope = ? AND request_id = ?
                  AND (paid_entrypoint = ? OR prompt_hash_basis = ?)),
       EXISTS (SELECT 1 FROM request_log
                WHERE account_id = ? AND external_request_id = ? AND request_id = ?
                  AND relay_blind_provider_binding_digest = ? AND relay_blind_envelope_digest = ?)`,
		AccountScopeForSettlement(accountID), internalRequestID, PaidEntrypointRelayBlindChat, PromptHashBasisRelayBlindEnvelopeV1, RouteSnapshotModeEnforce,
		AccountScopeForSettlement(accountID), internalRequestID, PaidEntrypointRelayBlindChat, PromptHashBasisRelayBlindEnvelopeV1,
		accountID, externalRequestID, internalRequestID, providerBindingDigest, envelopeDigest).Scan(&enforceSnapshot, &anyRelayBlindSnapshot, &logged)
	if err != nil {
		return "", err
	}
	switch {
	case enforceSnapshot:
		return RelayBlindCoverageEnforce, nil
	case !anyRelayBlindSnapshot && logged:
		return RelayBlindCoverageObserve, nil
	default:
		return "", nil
	}
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
		if row.pendingDeadlineUnixMS <= 0 || nowUnixMS <= row.pendingDeadlineUnixMS {
			pending = append(pending, row)
			continue
		}
		state, err := s.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
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
		if !state.Closed && state.SettlementOutcome == SettlementOutcomePending {
			pending = append(pending, row)
			continue
		}
		changed = true
	}
	for _, row := range rows {
		if row.settlementOutcome == SettlementOutcomePending && !row.closed && row.pendingDeadlineUnixMS > 0 && nowUnixMS > row.pendingDeadlineUnixMS {
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
				if errors.Is(err, errVerifiedCreditQuarantined) {
					// E2E-F5: the receipt verified but the ledger had
					// already quarantined the attempt's credit at zero
					// (a ledger-validity reason, not a receipt trust
					// failure), so no provider credit is owed: a terminal
					// zero_settled refund (R-7.5, R-8.4), never an error
					// that holds the buyer reservation forever.
					finality.ZeroSettledAttempts++
					if firstTerminalRefund == nil {
						refund := row
						refund.settlementOutcome = SettlementOutcomeZeroSettled
						refund.receiptResult = SettlementReceiptResultValid
						refund.reason = VerifiedCreditQuarantinedReason
						firstTerminalRefund = &refund
					}
					continue
				}
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
		case SettlementOutcomeRelayBlindSettled:
			if !row.closed || row.receiptResult != SettlementReceiptResultValid {
				finality.PendingAttempts++
				finality.PendingDeadlineUnixMS = minPositiveDeadline(finality.PendingDeadlineUnixMS, row.pendingDeadlineUnixMS)
				continue
			}
			if !row.relayBlindBound {
				// R-7.9: not payable without the entrypoint, basis, and
				// profile binding; the buyer is refunded.
				finality.QuarantinedAttempts++
				if firstTerminalRefund == nil {
					refund := row
					refund.settlementOutcome = SettlementOutcomeQuarantined
					refund.receiptResult = SettlementReceiptResultInvalid
					refund.reason = "relay_blind_settlement_unbound"
					firstTerminalRefund = &refund
				}
				continue
			}
			usage, blocked, _, err := s.requestSettlementUsage(ctx, accountScope, requestID, row.attemptN, row.providerID)
			if errors.Is(err, errVerifiedCreditQuarantined) {
				finality.ZeroSettledAttempts++
				if firstTerminalRefund == nil {
					refund := row
					refund.settlementOutcome = SettlementOutcomeZeroSettled
					refund.receiptResult = SettlementReceiptResultValid
					refund.reason = VerifiedCreditQuarantinedReason
					firstTerminalRefund = &refund
				}
				continue
			}
			if err != nil {
				return RequestSettlementFinality{}, false, err
			}
			if blocked {
				finality.OverlappingBlockedTokens += usage.BillableInputTokens + usage.BillableOutputTokens
				continue
			}
			finality.PromptTokens += usage.BillableInputTokens
			finality.CompletionTokens += usage.BillableOutputTokens
			finality.RelayBlindSettledAttempts++
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
	if finality.RelayBlindSettledAttempts > 0 {
		return relayBlindSettledFinality(finality), true, nil
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
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	var n int
	err := s.reader().QueryRowContext(ctx, `
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
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	rows, err := s.reader().QueryContext(ctx, `
SELECT srv.attempt_n, srv.provider_id, srv.receipt_result, srv.settlement_outcome, srv.reason, srv.closed,
       srv.pending_deadline_unix_ms, srv.route_snapshot_policy_version, srv.route_snapshot_mode,
       srv.receipt_profile, COALESCE(srv.receipt_version, ''), srv.paid_entrypoint,
       COALESCE(srs.paid_entrypoint, ''), COALESCE(srs.prompt_hash_basis, '')
  FROM settlement_receipt_verdicts srv
  LEFT JOIN settlement_route_snapshots srs
    ON srs.account_scope = ?
   AND srs.request_id = srv.request_id
   AND srs.attempt_n = srv.attempt_n
   AND srs.provider_id = srv.provider_id
   AND srs.route_snapshot_digest = srv.route_snapshot_digest
 WHERE srv.account_scope_hash = ? AND srv.request_id = ?
 ORDER BY srv.attempt_n ASC, srv.id ASC`, accountScope, SettlementAccountScopeHash(accountScope), requestID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []requestSettlementVerdictRow
	for rows.Next() {
		var row requestSettlementVerdictRow
		var closed int
		var profile, version, verdictEntrypoint, snapshotEntrypoint, snapshotBasis string
		if err := rows.Scan(&row.attemptN, &row.providerID, &row.receiptResult, &row.settlementOutcome, &row.reason, &closed, &row.pendingDeadlineUnixMS, &row.policyVersion, &row.mode,
			&profile, &version, &verdictEntrypoint, &snapshotEntrypoint, &snapshotBasis); err != nil {
			return nil, err
		}
		row.closed = closed == 1
		row.relayBlindBound = relayBlindSettledBound(profile, version, verdictEntrypoint, snapshotEntrypoint, snapshotBasis)
		out = append(out, row)
	}
	return out, rows.Err()
}

// relayBlindSettledFinality closes a request whose payable attempts settled
// relay_blind_settled. A request never mixes it with verified: relay-blind
// work has one pinned attempt and no failover, so any mix holds.
func relayBlindSettledFinality(finality RequestSettlementFinality) RequestSettlementFinality {
	if finality.VerifiedAttempts > 0 {
		finality.Outcome = SettlementOutcomePending
		finality.ReceiptResult = SettlementReceiptResultInconclusive
		finality.Reason = "mixed_settlement_outcome"
		finality.Closed = false
		finality.TokenSource = ""
		finality.PromptTokens = 0
		finality.CompletionTokens = 0
		finality.TotalTokens = 0
		return finality
	}
	finality.Outcome = SettlementOutcomeRelayBlindSettled
	finality.ReceiptResult = SettlementReceiptResultValid
	finality.Reason = "relay_blind_settlement"
	finality.Closed = true
	finality.TokenSource = UsageSourceCoordinatorObserved
	finality.TotalTokens = finality.PromptTokens + finality.CompletionTokens
	return finality
}

// requestSettlementAttemptsWithoutVerdict recovers the finality boundary from
// immutable route snapshots plus durable attempt outputs. Receipt bytes are
// deliberately absent: before the deadline the gateway must hold, and after
// the deadline RecordMissingSettlementReceipt produces an explicit terminal
// classification instead of leaving the reservation unresolved forever.
func (s *Store) requestSettlementAttemptsWithoutVerdict(ctx context.Context, accountScope, requestID string, verdicts []requestSettlementVerdictRow, nowUnixMS int64) ([]requestSettlementVerdictRow, error) {
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
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
	rows, err := s.reader().QueryContext(ctx, `
SELECT rs.attempt_n, rs.provider_id,
       COALESCE(sao.terminal_state_ts_unix_ms + (rs.pending_deadline_seconds * 1000), 0),
       rs.pending_deadline_seconds, rs.paid_entrypoint, rs.route_decision_ts_unix_ms,
       rs.route_snapshot_policy_version, rs.route_snapshot_mode,
       sao.request_id IS NOT NULL,
       COALESCE((
           SELECT lrc.quarantine_reason
             FROM ledger_request_credits lrc
            WHERE lrc.request_id = rs.request_id
              AND lrc.attempt_n = rs.attempt_n
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
              AND lrc.attempt_n = rs.attempt_n
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
		var quarantineReason, creditTS, entrypoint string
		var pendingDeadlineSeconds, routeDecisionUnixMS int64
		if err := rows.Scan(&row.attemptN, &row.providerID, &row.pendingDeadlineUnixMS, &pendingDeadlineSeconds, &entrypoint, &routeDecisionUnixMS, &row.policyVersion, &row.mode, &hasOutput, &quarantineReason, &creditTS); err != nil {
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
		case row.mode == RouteSnapshotModeEnforce && entrypoint == PaidEntrypointRelayBlindChat:
			// SPEC-022 R-13.6 / R-13.10: an enforce relay-blind snapshot is
			// committed before dispatch. Without a credit or an attempt
			// output the attempt is pending until its deadline, measured from
			// the latest terminal the dispatch bound allows. Past it the
			// caller closes the attempt through the missing-receipt writer:
			// closed quarantined, never payable.
			row.receiptResult = SettlementReceiptResultInconclusive
			row.settlementOutcome = SettlementOutcomePending
			row.reason = "relay_blind_attempt_pending"
			row.pendingDeadlineUnixMS = s.relayBlindUnrecordedTerminalUnixMS(routeDecisionUnixMS) + pendingDeadlineSeconds*1000
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
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	scopeHash := SettlementAccountScopeHash(accountScope)
	rows, err := s.reader().QueryContext(ctx, `
SELECT lrc.attempt_n, lrc.provider_id, lrc.ts_utc,
       COALESCE(lrc.settlement_policy_version, ''),
       CASE WHEN lrc.quarantined = 1 AND lrc.quarantine_reason IN (?, ?, ?) THEN lrc.quarantine_reason ELSE '' END
  FROM ledger_request_credits lrc
 WHERE lrc.request_id = ?
   AND lrc.settlement_account_scope_hash = ?
   AND lrc.settlement_policy_mode = 'enforce'
   AND NOT EXISTS (SELECT 1 FROM settlement_route_snapshots rs
                    WHERE rs.account_scope = ? AND rs.request_id = lrc.request_id
                      AND rs.attempt_n = lrc.attempt_n AND rs.provider_id = lrc.provider_id)
   AND NOT EXISTS (SELECT 1 FROM settlement_attempt_outputs sao
                    WHERE sao.account_scope = ? AND sao.request_id = lrc.request_id
                      AND sao.attempt_n = lrc.attempt_n AND sao.provider_id = lrc.provider_id)
   AND NOT EXISTS (SELECT 1 FROM settlement_receipt_verdicts srv
                    WHERE srv.account_scope_hash = ? AND srv.request_id = lrc.request_id
                      AND srv.attempt_n = lrc.attempt_n AND srv.provider_id = lrc.provider_id)
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
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	rows, err := s.reader().QueryContext(ctx, `
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
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	var raw, source string
	var overlap int
	var ledgerPrompt, ledgerChargedPrompt, ledgerCompletion sql.NullInt64
	err := s.reader().QueryRowContext(ctx, `
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
			quarantined, qErr := s.attemptCreditOnlyQuarantined(ctx, accountScope, requestID, attemptN, providerID)
			if qErr != nil {
				return SettlementUsage{}, false, "", qErr
			}
			if quarantined {
				return SettlementUsage{}, false, "", errVerifiedCreditQuarantined
			}
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

// VerifiedCreditQuarantinedReason closes an attempt whose receipt verified
// while its only ledger credit is quarantined (E2E-F5).
const VerifiedCreditQuarantinedReason = "verified_receipt_credit_quarantined"

var errVerifiedCreditQuarantined = errors.New("verified attempt credit is quarantined")

// attemptCreditOnlyQuarantined reports whether the attempt has a ledger credit
// and every one of its credits is quarantined.
func (s *Store) attemptCreditOnlyQuarantined(ctx context.Context, accountScope, requestID string, attemptN int64, providerID string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	var quarantined, unquarantined int64
	err := s.reader().QueryRowContext(ctx, `
SELECT COALESCE(SUM(CASE WHEN quarantined = 1 THEN 1 ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN quarantined = 0 THEN 1 ELSE 0 END), 0)
  FROM ledger_request_credits
 WHERE settlement_account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		SettlementAccountScopeHash(accountScope), requestID, attemptN, providerID).Scan(&quarantined, &unquarantined)
	if err != nil {
		return false, err
	}
	return quarantined > 0 && unquarantined == 0, nil
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
	ctx, cancel := context.WithTimeout(ctx, settlementFinalityReadTimeout)
	defer cancel()
	rows, err := s.reader().QueryContext(ctx, `
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
		out.RelayBlindSettledAttempts += finality.RelayBlindSettledAttempts
		out.OverlappingBlockedTokens += finality.OverlappingBlockedTokens
		out.PendingDeadlineUnixMS = minPositiveDeadline(out.PendingDeadlineUnixMS, finality.PendingDeadlineUnixMS)
		out.PromptTokens += finality.PromptTokens
		out.CompletionTokens += finality.CompletionTokens
		out.TotalTokens += finality.TotalTokens
		if !hasTerminalRefund &&
			finality.Closed &&
			finality.Outcome != SettlementOutcomeVerified &&
			finality.Outcome != SettlementOutcomeRelayBlindSettled &&
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
	if out.RelayBlindSettledAttempts > 0 {
		return relayBlindSettledFinality(out)
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

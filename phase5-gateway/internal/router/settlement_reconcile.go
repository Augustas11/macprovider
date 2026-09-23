package router

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

const defaultSettlementReconcileLimit = 100
const maxSettlementReconcileLimit = 500
const settlementReconcileNudgeDelay = 50 * time.Millisecond
const settlementReconcileNudgeRetryBaseDelay = 250 * time.Millisecond
const maxSettlementReconcileNudgeQueue = 1024
const maxSettlementReconcileNudgeWorkers = 4
const maxSettlementReconcileNudgeAttempts = 4
const maxSettlementReconcileOverflowCatchupPasses = maxSettlementReconcileNudgeQueue/maxSettlementReconcileLimit + 2

type settlementReconcileNudge struct {
	reservation storage.ActiveReservation
	attempt     int
	notBefore   time.Time
}

type coordinatorFinalityStatusError struct {
	statusCode int
}

func (e coordinatorFinalityStatusError) Error() string {
	return fmt.Sprintf("coordinator finality status=%d", e.statusCode)
}

type coordinatorRequestSettlementFinality struct {
	RequestID                 string `json:"request_id"`
	RequiredInternalRequestID string `json:"required_internal_request_id"`
	PolicyVersion             string `json:"policy_version"`
	Mode                      string `json:"mode"`
	ModeScopeComplete         bool   `json:"mode_scope_complete"`
	Outcome                   string `json:"outcome"`
	ReceiptResult             string `json:"receipt_result"`
	Reason                    string `json:"reason"`
	Closed                    bool   `json:"closed"`
	PendingDeadlineUnixMS     int64  `json:"pending_deadline_unix_ms"`
	PromptTokens              int64  `json:"prompt_tokens"`
	CompletionTokens          int64  `json:"completion_tokens"`
	TotalTokens               int64  `json:"total_tokens"`
	TokenSource               string `json:"token_source"`
	VerifiedAttempts          int64  `json:"verified_attempts"`
	PendingAttempts           int64  `json:"pending_attempts"`
	QuarantinedAttempts       int64  `json:"quarantined_attempts"`
	ZeroSettledAttempts       int64  `json:"zero_settled_attempts"`
}

type SettlementReconcileSummary struct {
	Scanned        int `json:"scanned"`
	Verified       int `json:"verified"`
	Observed       int `json:"observed"`
	Refunded       int `json:"refunded"`
	Expired        int `json:"expired"`
	StaleHeld      int `json:"stale_held"`
	Held           int `json:"held"`
	Skipped        int `json:"skipped"`
	Errors         int `json:"errors"`
	Coordinator404 int `json:"coordinator_404"`
}

type settlementReconcileSummary = SettlementReconcileSummary

func (s *Server) handleSettlementReconcile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	query := r.URL.Query()
	accountID := strings.TrimSpace(query.Get("account_id"))
	requestID := strings.TrimSpace(query.Get("request_id"))
	if (accountID == "") != (requestID == "") {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_settlement_target", "account_id and request_id must be provided together")
		return
	}
	if accountID != "" && strings.TrimSpace(query.Get("limit")) != "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_settlement_target", "limit cannot be combined with account_id and request_id")
		return
	}
	limit, err := parseSettlementReconcileLimit(query.Get("limit"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_limit", err.Error())
		return
	}
	ctx := r.Context()
	if timeout := time.Duration(s.cfg.Settlement.ReconcileRequestTimeoutSeconds) * time.Second; timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	var summary SettlementReconcileSummary
	if accountID != "" {
		summary, err = s.ReconcileSettlementHold(ctx, accountID, requestID)
		if errors.Is(err, storage.ErrReservationNotFound) {
			writeError(w, http.StatusNotFound, "invalid_request_error", "settlement_hold_not_found", "Settlement hold not found")
			return
		}
	} else {
		summary, err = s.ReconcileSettlementHolds(ctx, limit)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "settlement_reconcile_load_failed", "Could not load active reservations")
		return
	}
	writeJSON(w, http.StatusOK, summary)
}

func (s *Server) ReconcileSettlementHold(ctx context.Context, accountID, requestID string) (SettlementReconcileSummary, error) {
	reservation, err := s.store.LookupSettlementHeldReservation(ctx, accountID, requestID)
	if err != nil {
		return SettlementReconcileSummary{}, err
	}
	summary := SettlementReconcileSummary{Scanned: 1}
	result, err := s.reconcileSettlementReservation(ctx, reservation)
	if err != nil {
		summary.Errors = 1
		return summary, err
	}
	summary.applyResult(result)
	return summary, nil
}

func (s *Server) ReconcileSettlementHolds(ctx context.Context, limit int) (SettlementReconcileSummary, error) {
	if limit <= 0 {
		limit = defaultSettlementReconcileLimit
	}
	if limit > maxSettlementReconcileLimit {
		limit = maxSettlementReconcileLimit
	}
	reservations, err := s.store.ListSettlementHeldReservations(ctx, limit)
	if err != nil {
		return SettlementReconcileSummary{}, err
	}
	summary := SettlementReconcileSummary{Scanned: len(reservations)}
	for _, reservation := range reservations {
		result, err := s.reconcileSettlementReservation(ctx, reservation)
		if err != nil {
			summary.Errors++
			slog.Error("gateway SPEC-022 settlement reconciliation failed",
				"account_id", reservation.AccountID,
				"request_id", reservation.RequestID,
				"error", err,
			)
			if reservation.WalletSessionID != "" {
				s.recordWalletSessionAudit(ctx, reservation.AccountID, reservation.WalletSessionID, "wallet_session_settlement_reconcile_failed", "gateway", map[string]any{
					"request_id": reservation.RequestID,
					"phase":      "settlement_reconcile",
					"error":      safeAuditError(err),
				})
			}
			continue
		}
		summary.applyResult(result)
	}
	return summary, nil
}

func (s *Server) CatchUpSettlementHolds(ctx context.Context, limit int) (SettlementReconcileSummary, error) {
	if limit <= 0 {
		limit = defaultSettlementReconcileLimit
	}
	if limit > maxSettlementReconcileLimit {
		limit = maxSettlementReconcileLimit
	}
	reservations, err := s.store.ListSettlementHeldReservations(ctx, limit)
	if err != nil {
		return SettlementReconcileSummary{}, err
	}
	summary := SettlementReconcileSummary{Scanned: len(reservations)}
	timeout := time.Duration(s.cfg.Settlement.ReconcileRequestTimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	for _, reservation := range reservations {
		select {
		case <-ctx.Done():
			return summary, ctx.Err()
		default:
		}
		reservationCtx, cancel := context.WithTimeout(context.Background(), timeout)
		result, err := s.reconcileSettlementReservation(reservationCtx, reservation)
		cancel()
		if err != nil {
			summary.Errors++
			slog.Warn("SPEC-022 settlement reconciler catch-up reservation failed",
				"request_id", reservation.RequestID,
				"account_id", reservation.AccountID,
				"error", err,
			)
			continue
		}
		summary.applyResult(result)
	}
	return summary, nil
}

func (s *SettlementReconcileSummary) applyResult(result string) {
	switch result {
	case "verified":
		s.Verified++
	case "observed":
		s.Observed++
	case "refunded":
		s.Refunded++
	case "expired":
		s.Expired++
	case "stale_held":
		s.StaleHeld++
	case "held":
		s.Held++
	case "coordinator_404_expired":
		s.Coordinator404++
		s.StaleHeld++
	case "coordinator_404":
		s.Coordinator404++
		s.Skipped++
	case "coordinator_404_held":
		s.Coordinator404++
		s.Held++
	default:
		s.Skipped++
	}
}

func (s *Server) nudgeSettlementReconciler(reservation storage.ActiveReservation) {
	if !s.cfg.Settlement.ReconcileEnabled || reservation.AccountID == "" || reservation.RequestID == "" || reservation.CreatedAt.IsZero() {
		return
	}
	key := settlementReconcileNudgeKey(reservation)
	s.settlementReconcileNudgeMu.Lock()
	if s.settlementReconcileNudgeKeys == nil {
		s.settlementReconcileNudgeKeys = make(map[string]struct{})
	}
	if _, exists := s.settlementReconcileNudgeKeys[key]; exists {
		s.settlementReconcileNudgeMu.Unlock()
		return
	}
	if len(s.settlementReconcileNudgePending) >= maxSettlementReconcileNudgeQueue {
		s.requestSettlementReconcileCatchupLocked()
		s.settlementReconcileNudgeMu.Unlock()
		slog.Warn("SPEC-022 settlement reconciler nudge queue full; requested catch-up pass",
			"request_id", reservation.RequestID,
			"account_id", reservation.AccountID,
			"queue_limit", maxSettlementReconcileNudgeQueue,
		)
		return
	}
	s.settlementReconcileNudgePending = append(s.settlementReconcileNudgePending, settlementReconcileNudge{
		reservation: reservation,
		attempt:     1,
	})
	s.settlementReconcileNudgeKeys[key] = struct{}{}
	if s.settlementReconcileNudgeActiveWorkers < maxSettlementReconcileNudgeWorkers {
		s.settlementReconcileNudgeActiveWorkers++
		go s.drainSettlementReconcileNudges()
	}
	s.settlementReconcileNudgeMu.Unlock()
}

func settlementReconcileNudgeKey(reservation storage.ActiveReservation) string {
	return reservation.AccountID + "\x00" + reservation.RequestID + "\x00" + reservation.CreatedAt.UTC().Format(time.RFC3339Nano)
}

func (s *Server) requestSettlementReconcileCatchupLocked() {
	s.settlementReconcileCatchupPending = true
	if s.settlementReconcileCatchupRunning {
		return
	}
	s.settlementReconcileCatchupRunning = true
	go s.drainSettlementReconcileCatchups()
}

func (s *Server) drainSettlementReconcileNudges() {
	timeout := time.Duration(s.cfg.Settlement.ReconcileRequestTimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	for {
		s.settlementReconcileNudgeMu.Lock()
		if len(s.settlementReconcileNudgePending) == 0 {
			s.settlementReconcileNudgeActiveWorkers--
			s.settlementReconcileNudgeMu.Unlock()
			return
		}
		nudge := s.settlementReconcileNudgePending[0]
		copy(s.settlementReconcileNudgePending, s.settlementReconcileNudgePending[1:])
		s.settlementReconcileNudgePending = s.settlementReconcileNudgePending[:len(s.settlementReconcileNudgePending)-1]
		s.settlementReconcileNudgeMu.Unlock()

		delay := settlementReconcileNudgeDelay
		if until := time.Until(nudge.notBefore); until > delay {
			delay = until
		}
		timer := time.NewTimer(delay)
		<-timer.C
		timer.Stop()

		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		result, err := s.reconcileSettlementReservation(ctx, nudge.reservation)
		cancel()
		key := settlementReconcileNudgeKey(nudge.reservation)
		retryableResult := err == nil && retryableSettlementReconcileNudgeResult(result)
		if ((err != nil && retryableSettlementReconcileNudgeError(err)) || retryableResult) && nudge.attempt < maxSettlementReconcileNudgeAttempts {
			nudge.attempt++
			nudge.notBefore = time.Now().Add(settlementReconcileNudgeRetryDelay(nudge.attempt))
			s.settlementReconcileNudgeMu.Lock()
			s.settlementReconcileNudgePending = append(s.settlementReconcileNudgePending, nudge)
			s.settlementReconcileNudgeMu.Unlock()
			slog.Warn("SPEC-022 settlement reconciler nudge retry scheduled",
				"request_id", nudge.reservation.RequestID,
				"account_id", nudge.reservation.AccountID,
				"attempt", nudge.attempt,
				"max_attempts", maxSettlementReconcileNudgeAttempts,
				"result", result,
				"error", err,
			)
			continue
		}
		s.settlementReconcileNudgeMu.Lock()
		delete(s.settlementReconcileNudgeKeys, key)
		s.settlementReconcileNudgeMu.Unlock()
		if err != nil {
			slog.Warn("SPEC-022 settlement reconciler nudge failed",
				"request_id", nudge.reservation.RequestID,
				"account_id", nudge.reservation.AccountID,
				"attempts", nudge.attempt,
				"error", err,
			)
			continue
		}
		slog.Info("SPEC-022 settlement reconciler nudge completed",
			"request_id", nudge.reservation.RequestID,
			"account_id", nudge.reservation.AccountID,
			"attempts", nudge.attempt,
			"result", result,
		)
	}
}

func retryableSettlementReconcileNudgeResult(result string) bool {
	return result == "held" || result == "coordinator_404_held"
}

func settlementReconcileNudgeRetryDelay(attempt int) time.Duration {
	if attempt <= 2 {
		return settlementReconcileNudgeRetryBaseDelay
	}
	delay := settlementReconcileNudgeRetryBaseDelay
	for i := 2; i < attempt; i++ {
		delay *= 4
	}
	return delay
}

func retryableSettlementReconcileNudgeError(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) || errors.Is(err, io.ErrUnexpectedEOF) {
		return true
	}
	var networkError net.Error
	if errors.As(err, &networkError) {
		return true
	}
	var statusError coordinatorFinalityStatusError
	return errors.As(err, &statusError) && (statusError.statusCode == http.StatusRequestTimeout || statusError.statusCode == http.StatusTooEarly || statusError.statusCode == http.StatusTooManyRequests || statusError.statusCode >= 500)
}

func (s *Server) drainSettlementReconcileCatchups() {
	for {
		s.settlementReconcileNudgeMu.Lock()
		if !s.settlementReconcileCatchupPending {
			s.settlementReconcileCatchupRunning = false
			s.settlementReconcileNudgeMu.Unlock()
			return
		}
		s.settlementReconcileCatchupPending = false
		s.settlementReconcileNudgeMu.Unlock()

		timer := time.NewTimer(settlementReconcileNudgeDelay)
		<-timer.C
		timer.Stop()

		s.runSettlementReconcileCatchup()
	}
}

func (s *Server) runSettlementReconcileCatchup() {
	timeout := time.Duration(s.cfg.Settlement.ReconcileRequestTimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	for pass := 0; pass < maxSettlementReconcileOverflowCatchupPasses; pass++ {
		listCtx, cancel := context.WithTimeout(context.Background(), timeout)
		reservations, err := s.store.ListSettlementHeldReservations(listCtx, maxSettlementReconcileLimit)
		cancel()
		if err != nil {
			slog.Warn("SPEC-022 settlement reconciler catch-up load failed", "error", err, "pass", pass+1)
			return
		}
		if len(reservations) == 0 {
			return
		}
		summary := SettlementReconcileSummary{Scanned: len(reservations)}
		for _, reservation := range reservations {
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			result, err := s.reconcileSettlementReservation(ctx, reservation)
			cancel()
			if err != nil {
				summary.Errors++
				slog.Warn("SPEC-022 settlement reconciler catch-up reservation failed",
					"request_id", reservation.RequestID,
					"account_id", reservation.AccountID,
					"error", err,
				)
				continue
			}
			summary.applyResult(result)
		}
		slog.Info("SPEC-022 settlement reconciler catch-up completed",
			"pass", pass+1,
			"scanned", summary.Scanned,
			"verified", summary.Verified,
			"refunded", summary.Refunded,
			"held", summary.Held,
			"skipped", summary.Skipped,
			"errors", summary.Errors,
			"coordinator_404", summary.Coordinator404,
		)
		if len(reservations) < maxSettlementReconcileLimit {
			return
		}
	}
}

func parseSettlementReconcileLimit(raw string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return defaultSettlementReconcileLimit, nil
	}
	limit, err := strconv.Atoi(raw)
	if err != nil || limit <= 0 {
		return 0, fmt.Errorf("limit must be a positive integer")
	}
	if limit > maxSettlementReconcileLimit {
		return 0, fmt.Errorf("limit must be <= %d", maxSettlementReconcileLimit)
	}
	return limit, nil
}

func (s *Server) reconcileSettlementReservation(ctx context.Context, reservation storage.ActiveReservation) (string, error) {
	if err := s.store.MarkSettlementReconcileAttempt(ctx, reservation); err != nil {
		if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
			return "already_terminal", nil
		}
		return "", err
	}
	if reservation.RelayBlind != nil {
		return s.reconcileRelayBlindReservation(ctx, reservation)
	}
	candidate, candidateErr := s.store.LookupSettlementFallbackCandidate(ctx, reservation)
	if errors.Is(candidateErr, storage.ErrNotFound) {
		// Reconciliation without the coordinator-owned current-attempt binding
		// could apply an earlier retry's otherwise valid finality to this hold.
		// Legacy and persistence-failure rows remain quarantined until an
		// operator can establish that binding through a separate recovery path.
		return "held", nil
	}
	if candidateErr != nil {
		return "", candidateErr
	}
	if candidate.RequiredInternalRequestID == "" {
		// A missing trusted header quarantines this delivery. An unbound
		// lookup could return a previous retry's otherwise valid finality.
		return "held", nil
	}
	finality, found, err := s.fetchCoordinatorRequestSettlementFinality(ctx, reservation, candidate.RequiredInternalRequestID)
	if err != nil {
		return "", err
	}
	if !found {
		// A missing coordinator lookup is not authority to discard local
		// delivered usage. Keep this specific hold discoverable for retry.
		return "coordinator_404_held", nil
	}
	if finality.RequiredInternalRequestID != candidate.RequiredInternalRequestID {
		return "held", nil
	}
	if finality.RequestID == reservation.RequestID && !reservation.CreatedAt.IsZero() && coordinatorObserveFallbackAllowed(finality) {
		if err := s.settleObserveFallbackCandidate(ctx, candidate); err != nil {
			if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
				return "already_terminal", nil
			}
			return "", err
		}
		return "observed", nil
	}
	action := coordinatorSettlementFinalityFromHeaders(finalityHeaders(finality))
	switch action.Action {
	case settlementFinalityLegacy:
		return "legacy", nil
	case settlementFinalityDebit:
		prompt, completion, total, err := finalityTokenTotals(finality)
		if err != nil {
			return "", err
		}
		settlement := storage.ReservationSettlement{
			ExpectedReservationCreatedAt: reservation.CreatedAt,
			AccountID:                    reservation.AccountID,
			RequestID:                    reservation.RequestID,
			PromptTokens:                 prompt,
			CompletionTokens:             completion,
			TotalTokens:                  total,
			MaxTotalTokens:               reservation.ReservedTokens,
			TokenSource:                  finality.TokenSource,
			Outcome:                      "spec022_verified",
			SettledAt:                    s.now(),
		}
		var settleErr error
		if reservation.WalletSessionID != "" {
			settleErr = s.store.FinalizeWalletSessionReservation(ctx, storage.WalletSessionReservationSettlement{
				ExpectedReservationCreatedAt: reservation.CreatedAt,
				AccountID:                    settlement.AccountID,
				SessionID:                    reservation.WalletSessionID,
				RequestID:                    settlement.RequestID,
				PromptTokens:                 settlement.PromptTokens,
				CompletionTokens:             settlement.CompletionTokens,
				TotalTokens:                  settlement.TotalTokens,
				MaxTotalTokens:               settlement.MaxTotalTokens,
				TokenSource:                  settlement.TokenSource,
				Outcome:                      settlement.Outcome,
				SettledAt:                    settlement.SettledAt,
			})
		} else if candidate.DemoIdentity != "" {
			settleErr = s.store.SettleDemoReservation(ctx, settlement, storage.DemoUsageEvent{
				RequestID:     candidate.RequestID,
				ClientIP:      candidate.DemoIdentity,
				DemoTokenHash: candidate.DemoTokenHash,
				WindowDate:    candidate.WindowDate,
				CreatedAt:     settlement.SettledAt,
			})
		} else {
			settleErr = s.store.SettleReservation(ctx, settlement)
		}
		if settleErr != nil {
			if errors.Is(settleErr, storage.ErrReservationNotFound) || errors.Is(settleErr, storage.ErrReservationTerminal) {
				return "already_terminal", nil
			}
			return "", settleErr
		}
		return "verified", nil
	case settlementFinalityRefund:
		var err error
		if reservation.WalletSessionID != "" {
			err = s.store.RefundWalletSessionReservation(ctx, reservation.AccountID, reservation.WalletSessionID, reservation.RequestID, s.now())
		} else {
			err = s.store.RefundReservation(ctx, reservation.AccountID, reservation.RequestID, s.now().Unix())
		}
		if err != nil {
			if errors.Is(err, storage.ErrReservationNotFound) {
				return "already_terminal", nil
			}
			return "", err
		}
		return "refunded", nil
	case settlementFinalityHold:
		req := &http.Request{}
		req = req.WithContext(ctx)
		ctx = context.WithValue(ctx, requestIDKey{}, reservation.RequestID)
		req = req.WithContext(ctx)
		if !s.boundStreamingSettlementHold(ctx, req, usageSubject{AccountID: reservation.AccountID, WalletSessionID: reservation.WalletSessionID}, action) {
			return "", fmt.Errorf("failed to bound settlement hold")
		}
		return "held", nil
	default:
		return "legacy", nil
	}
}

// Observe recovery needs positive, complete request-scoped mode authority.
// Older coordinators omit the completeness flag and remain fail-closed.
func coordinatorObserveFallbackAllowed(finality coordinatorRequestSettlementFinality) bool {
	if !finality.ModeScopeComplete || finality.RequestID == "" || strings.TrimSpace(finality.RequiredInternalRequestID) == "" || finality.Mode != "observe" ||
		(finality.PolicyVersion != settlementPolicyVersion && finality.PolicyVersion != legacySettlementPolicyVersion) ||
		finality.Reason == "mixed_settlement_policy_snapshot" || finality.Reason == "missing_current_settlement_finality" {
		return false
	}
	if finality.Outcome == "pending" {
		return !finality.Closed && finality.ReceiptResult == "inconclusive" &&
			finality.Reason == "receipt_verdict_pending" && finality.PendingAttempts > 0
	}
	if finality.PendingAttempts != 0 {
		return false
	}
	finality.Mode = "enforce"
	action := coordinatorSettlementFinalityFromHeaders(finalityHeaders(finality)).Action
	return action == settlementFinalityDebit || action == settlementFinalityRefund
}

// The caller must first establish observe authority. Only the persisted local
// tuple is used here; coordinator receipt totals cannot replace legacy usage.
func (s *Server) settleObserveFallbackCandidate(ctx context.Context, candidate storage.SettlementFallbackCandidate) error {
	if candidate.ReservationCreatedAt.IsZero() || strings.TrimSpace(candidate.RequiredInternalRequestID) == "" {
		return fmt.Errorf("observe fallback reservation creation time and current internal request ID are required")
	}
	settlement := storage.ReservationSettlement{
		RelayBlind:                   candidate.RelayBlind,
		ExpectedReservationCreatedAt: candidate.ReservationCreatedAt,
		AccountID:                    candidate.AccountID, RequestID: candidate.RequestID,
		PromptTokens: candidate.PromptTokens, CompletionTokens: candidate.CompletionTokens,
		MaxTotalTokens: candidate.MaxTotalTokens,
		TokenSource:    candidate.TokenSource, Outcome: candidate.Outcome, SettledAt: s.now(),
	}
	if candidate.WalletSessionID != "" {
		return s.store.FinalizeWalletSessionReservation(ctx, storage.WalletSessionReservationSettlement{
			RelayBlind:                   candidate.RelayBlind,
			ExpectedReservationCreatedAt: candidate.ReservationCreatedAt,
			AccountID:                    candidate.AccountID, SessionID: candidate.WalletSessionID, RequestID: candidate.RequestID,
			PromptTokens: settlement.PromptTokens, CompletionTokens: settlement.CompletionTokens,
			TotalTokens: settlement.TotalTokens, MaxTotalTokens: settlement.MaxTotalTokens,
			TokenSource: settlement.TokenSource, Outcome: settlement.Outcome, SettledAt: settlement.SettledAt,
		})
	}
	if candidate.DemoIdentity != "" {
		return s.store.SettleDemoReservation(ctx, settlement, storage.DemoUsageEvent{
			RequestID: candidate.RequestID, ClientIP: candidate.DemoIdentity, DemoTokenHash: candidate.DemoTokenHash,
			WindowDate: candidate.WindowDate, CreatedAt: settlement.SettledAt,
		})
	}
	return s.store.SettleReservation(ctx, settlement)
}

func (s *Server) fetchCoordinatorRequestSettlementFinality(ctx context.Context, reservation storage.ActiveReservation, requiredInternalRequestID ...string) (coordinatorRequestSettlementFinality, bool, error) {
	base := strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")
	if base == "" {
		return coordinatorRequestSettlementFinality{}, false, fmt.Errorf("coordinator operator URL is not configured")
	}
	u, err := url.Parse(base + "/internal/settlement/finality")
	if err != nil {
		return coordinatorRequestSettlementFinality{}, false, err
	}
	q := u.Query()
	q.Set("account_id", reservation.AccountID)
	q.Set("request_id", reservation.RequestID)
	if len(requiredInternalRequestID) > 0 && strings.TrimSpace(requiredInternalRequestID[0]) != "" {
		q.Set("required_internal_request_id", requiredInternalRequestID[0])
	}
	if !reservation.CreatedAt.IsZero() {
		q.Set("reservation_created_at_unix_ms", strconv.FormatInt(reservation.CreatedAt.UTC().UnixMilli(), 10))
	}
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return coordinatorRequestSettlementFinality{}, false, err
	}
	req.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
	req.Header.Set("X-Request-ID", reservation.RequestID)
	resp, err := s.client.Do(req)
	if err != nil {
		return coordinatorRequestSettlementFinality{}, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		io.Copy(io.Discard, resp.Body)
		return coordinatorRequestSettlementFinality{}, false, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return coordinatorRequestSettlementFinality{}, false, coordinatorFinalityStatusError{statusCode: resp.StatusCode}
	}
	var finality coordinatorRequestSettlementFinality
	if err := json.NewDecoder(resp.Body).Decode(&finality); err != nil {
		return coordinatorRequestSettlementFinality{}, false, err
	}
	if finality.RequestID != "" && finality.RequestID != reservation.RequestID {
		return coordinatorRequestSettlementFinality{}, false, fmt.Errorf("coordinator finality request_id mismatch")
	}
	return finality, true, nil
}

func finalityHeaders(finality coordinatorRequestSettlementFinality) http.Header {
	h := http.Header{}
	h.Set(settlementModeHeader, finality.Mode)
	h.Set(settlementPolicyVersionHeader, finality.PolicyVersion)
	h.Set(settlementOutcomeHeader, finality.Outcome)
	h.Set(settlementReceiptResultHeader, finality.ReceiptResult)
	h.Set(settlementReasonHeader, finality.Reason)
	h.Set(settlementClosedHeader, strconv.FormatBool(finality.Closed))
	if finality.PendingDeadlineUnixMS > 0 {
		h.Set(settlementPendingUntilHeader, strconv.FormatInt(finality.PendingDeadlineUnixMS, 10))
	}
	return h
}

func finalityTokenTotals(finality coordinatorRequestSettlementFinality) (int64, int64, int64, error) {
	prompt := finality.PromptTokens
	completion := finality.CompletionTokens
	total := finality.TotalTokens
	if prompt < 0 || completion < 0 || total < 0 {
		return 0, 0, 0, fmt.Errorf("coordinator finality tokens must be non-negative")
	}
	if total == 0 {
		total = prompt + completion
	}
	if total != prompt+completion {
		return 0, 0, 0, fmt.Errorf("coordinator finality total_tokens mismatch")
	}
	source := strings.TrimSpace(finality.TokenSource)
	if source != "coordinator_observed" {
		return 0, 0, 0, fmt.Errorf("coordinator finality token_source %q is not settlement-capable", source)
	}
	return prompt, completion, total, nil
}

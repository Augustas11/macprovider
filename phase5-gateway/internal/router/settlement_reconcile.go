package router

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

const defaultSettlementReconcileLimit = 100
const maxSettlementReconcileLimit = 500

type coordinatorRequestSettlementFinality struct {
	RequestID             string `json:"request_id"`
	PolicyVersion         string `json:"policy_version"`
	Mode                  string `json:"mode"`
	Outcome               string `json:"outcome"`
	ReceiptResult         string `json:"receipt_result"`
	Reason                string `json:"reason"`
	Closed                bool   `json:"closed"`
	PendingDeadlineUnixMS int64  `json:"pending_deadline_unix_ms"`
	PromptTokens          int64  `json:"prompt_tokens"`
	CompletionTokens      int64  `json:"completion_tokens"`
	TotalTokens           int64  `json:"total_tokens"`
	TokenSource           string `json:"token_source"`
	VerifiedAttempts      int64  `json:"verified_attempts"`
	PendingAttempts       int64  `json:"pending_attempts"`
	QuarantinedAttempts   int64  `json:"quarantined_attempts"`
	ZeroSettledAttempts   int64  `json:"zero_settled_attempts"`
}

type SettlementReconcileSummary struct {
	Scanned        int `json:"scanned"`
	Verified       int `json:"verified"`
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
	limit, err := parseSettlementReconcileLimit(r.URL.Query().Get("limit"))
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
	summary, err := s.ReconcileSettlementHolds(ctx, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "settlement_reconcile_load_failed", "Could not load active reservations")
		return
	}
	writeJSON(w, http.StatusOK, summary)
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
			continue
		}
		switch result {
		case "verified":
			summary.Verified++
		case "refunded":
			summary.Refunded++
		case "held":
			summary.Held++
		case "coordinator_404_expired":
			summary.Coordinator404++
			summary.StaleHeld++
		case "coordinator_404":
			summary.Coordinator404++
			summary.Skipped++
		default:
			summary.Skipped++
		}
	}
	return summary, nil
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
	finality, found, err := s.fetchCoordinatorRequestSettlementFinality(ctx, reservation)
	if err != nil || !found {
		if !found {
			now := s.now()
			if !reservation.ExpiresAt.IsZero() && !now.Before(reservation.ExpiresAt) {
				return "coordinator_404_expired", nil
			}
			return "coordinator_404", nil
		}
		return "", err
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
		if err := s.store.SettleReservation(ctx, storage.ReservationSettlement{
			AccountID:        reservation.AccountID,
			RequestID:        reservation.RequestID,
			PromptTokens:     prompt,
			CompletionTokens: completion,
			TotalTokens:      total,
			MaxTotalTokens:   reservation.ReservedTokens,
			TokenSource:      finality.TokenSource,
			Outcome:          "spec022_verified",
			SettledAt:        s.now(),
		}); err != nil {
			if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
				return "already_terminal", nil
			}
			return "", err
		}
		return "verified", nil
	case settlementFinalityRefund:
		if err := s.store.RefundReservation(ctx, reservation.AccountID, reservation.RequestID, s.now().Unix()); err != nil {
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
		if !s.boundStreamingSettlementHold(ctx, req, usageSubject{AccountID: reservation.AccountID}, action) {
			return "", fmt.Errorf("failed to bound settlement hold")
		}
		return "held", nil
	default:
		return "legacy", nil
	}
}

func (s *Server) fetchCoordinatorRequestSettlementFinality(ctx context.Context, reservation storage.ActiveReservation) (coordinatorRequestSettlementFinality, bool, error) {
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
		return coordinatorRequestSettlementFinality{}, false, fmt.Errorf("coordinator finality status=%d", resp.StatusCode)
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

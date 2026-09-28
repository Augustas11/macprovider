package router

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

const defaultSettlementReleaseHoldsLimit = 100
const maxSettlementReleaseHoldsLimit = 1000

type settlementReleaseHoldsRequest struct {
	AccountID     string `json:"account_id"`
	CreatedBefore string `json:"created_before"`
	Limit         *int   `json:"limit"`
	Apply         *bool  `json:"apply"`
}

type settlementReleaseHoldsCounts struct {
	Settle          int `json:"settle"`
	Refund          int `json:"refund"`
	Release         int `json:"release"`
	SkipUnsupported int `json:"skip_unsupported"`
	SkipLookupError int `json:"skip_lookup_error"`
}

type settlementReleaseHoldsFinality struct {
	Found                 bool   `json:"found"`
	AuthoritativeNotFound bool   `json:"authoritative_not_found,omitempty"`
	Outcome               string `json:"outcome,omitempty"`
	ReceiptResult         string `json:"receipt_result,omitempty"`
	Reason                string `json:"reason,omitempty"`
	Closed                bool   `json:"closed,omitempty"`
	PromptTokens          int64  `json:"prompt_tokens,omitempty"`
	CompletionTokens      int64  `json:"completion_tokens,omitempty"`
	TotalTokens           int64  `json:"total_tokens,omitempty"`
	TokenSource           string `json:"token_source,omitempty"`
	LookupError           bool   `json:"lookup_error,omitempty"`
}

type settlementReleaseHoldsRow struct {
	AccountID      string                         `json:"account_id"`
	RequestID      string                         `json:"request_id"`
	CreatedAt      time.Time                      `json:"created_at"`
	ReservedTokens int64                          `json:"reserved_tokens"`
	Finality       settlementReleaseHoldsFinality `json:"finality"`
	Disposition    string                         `json:"disposition"`
	Applied        bool                           `json:"applied"`
	Error          string                         `json:"error"`
}

type settlementReleaseHoldsResponse struct {
	AccountID     string                       `json:"account_id"`
	CreatedBefore time.Time                    `json:"created_before"`
	Apply         bool                         `json:"apply"`
	Scanned       int                          `json:"scanned"`
	Counts        settlementReleaseHoldsCounts `json:"counts"`
	Rows          []settlementReleaseHoldsRow  `json:"rows"`
}

func (s *Server) handleSettlementReleaseHolds(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	req, createdBefore, limit, apply, err := parseSettlementReleaseHoldsRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_settlement_release_holds_request", err.Error())
		return
	}
	ctx := r.Context()
	if timeout := time.Duration(s.cfg.Settlement.ReconcileRequestTimeoutSeconds) * time.Second; timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	reservations, err := s.store.ListSettlementHeldReservationsForDrain(ctx, req.AccountID, createdBefore, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "settlement_release_holds_load_failed", "Could not load settlement holds")
		return
	}
	response := settlementReleaseHoldsResponse{
		AccountID: req.AccountID, CreatedBefore: createdBefore, Apply: apply,
		Scanned: len(reservations), Rows: make([]settlementReleaseHoldsRow, 0, len(reservations)),
	}
	for _, reservation := range reservations {
		row := s.releaseSettlementHold(ctx, reservation, apply)
		response.Counts.add(row.Disposition)
		response.Rows = append(response.Rows, row)
	}
	writeJSON(w, http.StatusOK, response)
}

func parseSettlementReleaseHoldsRequest(r *http.Request) (settlementReleaseHoldsRequest, time.Time, int, bool, error) {
	var req settlementReleaseHoldsRequest
	body, err := io.ReadAll(io.LimitReader(r.Body, 16*1024+1))
	if err != nil {
		return req, time.Time{}, 0, false, fmt.Errorf("could not read request body")
	}
	if len(body) > 16*1024 {
		return req, time.Time{}, 0, false, fmt.Errorf("request body is too large")
	}
	if len(bytes.TrimSpace(body)) > 0 {
		decoder := json.NewDecoder(bytes.NewReader(body))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&req); err != nil {
			return req, time.Time{}, 0, false, fmt.Errorf("invalid JSON body")
		}
		if decoder.Decode(&struct{}{}) != io.EOF {
			return req, time.Time{}, 0, false, fmt.Errorf("request body must contain one JSON object")
		}
	}
	query := r.URL.Query()
	if query.Has("account_id") {
		req.AccountID = query.Get("account_id")
	}
	if query.Has("created_before") {
		req.CreatedBefore = query.Get("created_before")
	}
	if query.Has("limit") {
		value, err := strconv.Atoi(query.Get("limit"))
		if err != nil {
			return req, time.Time{}, 0, false, fmt.Errorf("limit must be a positive integer")
		}
		req.Limit = &value
	}
	if query.Has("apply") {
		value, err := strconv.ParseBool(query.Get("apply"))
		if err != nil || (query.Get("apply") != "true" && query.Get("apply") != "false") {
			return req, time.Time{}, 0, false, fmt.Errorf("apply must be true or false")
		}
		req.Apply = &value
	}
	req.AccountID = strings.TrimSpace(req.AccountID)
	if req.AccountID == "" {
		return req, time.Time{}, 0, false, fmt.Errorf("account_id is required")
	}
	if strings.TrimSpace(req.CreatedBefore) == "" {
		return req, time.Time{}, 0, false, fmt.Errorf("created_before is required")
	}
	createdBefore, err := time.Parse(time.RFC3339, strings.TrimSpace(req.CreatedBefore))
	if err != nil {
		return req, time.Time{}, 0, false, fmt.Errorf("created_before must be RFC3339")
	}
	limit := defaultSettlementReleaseHoldsLimit
	if req.Limit != nil {
		limit = *req.Limit
	}
	if limit <= 0 || limit > maxSettlementReleaseHoldsLimit {
		return req, time.Time{}, 0, false, fmt.Errorf("limit must be between 1 and %d", maxSettlementReleaseHoldsLimit)
	}
	apply := req.Apply != nil && *req.Apply
	return req, createdBefore.UTC(), limit, apply, nil
}

func (s *Server) releaseSettlementHold(ctx context.Context, reservation storage.ActiveReservation, apply bool) settlementReleaseHoldsRow {
	row := settlementReleaseHoldsRow{
		AccountID: reservation.AccountID, RequestID: reservation.RequestID,
		CreatedAt: reservation.CreatedAt, ReservedTokens: reservation.ReservedTokens,
	}
	if reservation.RelayBlind != nil {
		row.Disposition = "skip_unsupported"
		row.Error = "relay-blind reservations require their specialized reconciliation path"
		return row
	}
	candidate, candidateErr := s.store.LookupSettlementFallbackCandidate(ctx, reservation)
	if candidateErr != nil && !errors.Is(candidateErr, storage.ErrNotFound) {
		row.Disposition = "skip_unsupported"
		row.Error = candidateErr.Error()
		return row
	}
	if errors.Is(candidateErr, storage.ErrNotFound) || strings.TrimSpace(candidate.RequiredInternalRequestID) == "" {
		row.Finality.Reason = "missing_fallback_candidate"
		row.Disposition = "release"
		return s.applySettlementHoldDisposition(ctx, reservation, candidate, row, apply, false)
	}
	finality, found, authoritativeNotFound, err := s.fetchCoordinatorRequestSettlementFinalityDetail(ctx, reservation, candidate.RequiredInternalRequestID)
	if err != nil {
		row.Finality.LookupError = true
		row.Error = err.Error()
		if apply && !reservation.OperatorReview && !reservation.Coordinator404 {
			row.Disposition = "skip_lookup_error"
			return row
		}
		row.Disposition = "release"
		return s.applySettlementHoldDisposition(ctx, reservation, candidate, row, apply, false)
	}
	row.Finality = settlementReleaseHoldsFinality{
		Found: found, AuthoritativeNotFound: authoritativeNotFound,
		Outcome: finality.Outcome, ReceiptResult: finality.ReceiptResult, Reason: finality.Reason,
		Closed: finality.Closed, PromptTokens: finality.PromptTokens, CompletionTokens: finality.CompletionTokens,
		TotalTokens: finality.TotalTokens, TokenSource: finality.TokenSource,
	}
	if !found || finality.RequiredInternalRequestID != candidate.RequiredInternalRequestID {
		row.Disposition = "release"
		return s.applySettlementHoldDisposition(ctx, reservation, candidate, row, apply, false)
	}
	if coordinatorObserveFallbackAllowed(finality) {
		if !settlementCandidateSupportsReservationSettle(reservation, candidate) {
			row.Disposition = "skip_unsupported"
			row.Error = "reservation lacks type-correct settlement metadata"
			return row
		}
		row.Disposition = "settle"
		return s.applySettlementHoldDisposition(ctx, reservation, candidate, row, apply, true)
	}
	action := coordinatorSettlementFinalityFromHeaders(finalityHeaders(finality)).Action
	switch action {
	case settlementFinalityDebit:
		if _, _, _, err := finalityTokenTotals(finality); err != nil {
			row.Disposition = "release"
			row.Error = err.Error()
			return s.applySettlementHoldDisposition(ctx, reservation, candidate, row, apply, false)
		}
		if !settlementCandidateSupportsReservationSettle(reservation, candidate) {
			row.Disposition = "skip_unsupported"
			row.Error = "reservation lacks type-correct settlement metadata"
			return row
		}
		row.Disposition = "settle"
	case settlementFinalityRefund:
		row.Disposition = "refund"
	default:
		row.Disposition = "release"
	}
	return s.applySettlementHoldDisposition(ctx, reservation, candidate, row, apply, false)
}

func settlementCandidateSupportsReservationSettle(reservation storage.ActiveReservation, candidate storage.SettlementFallbackCandidate) bool {
	if reservation.WalletSessionID != "" {
		return candidate.WalletSessionID == reservation.WalletSessionID && candidate.DemoIdentity == "" && candidate.DemoTokenHash == ""
	}
	if strings.HasPrefix(reservation.AccountID, "demo:") {
		return candidate.DemoIdentity != "" && candidate.DemoTokenHash != ""
	}
	return candidate.WalletSessionID == "" && candidate.DemoIdentity == "" && candidate.DemoTokenHash == ""
}

func (s *Server) applySettlementHoldDisposition(ctx context.Context, reservation storage.ActiveReservation, candidate storage.SettlementFallbackCandidate, row settlementReleaseHoldsRow, apply, observeSettlement bool) settlementReleaseHoldsRow {
	if !apply {
		return row
	}
	if err := s.store.MarkSettlementReconcileAttempt(ctx, reservation); err != nil {
		if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
			row.Error = "reservation is no longer active"
			return row
		}
		row.Error = err.Error()
		return row
	}
	var err error
	reconcileResult := "operator_drain_" + row.Disposition
	switch row.Disposition {
	case "settle":
		if observeSettlement {
			err = s.settleObserveFallbackCandidateWithResult(ctx, candidate, reconcileResult)
		} else {
			finality := coordinatorRequestSettlementFinality{
				PromptTokens: row.Finality.PromptTokens, CompletionTokens: row.Finality.CompletionTokens,
				TotalTokens: row.Finality.TotalTokens, TokenSource: row.Finality.TokenSource,
			}
			err = s.settleVerifiedReservationWithResult(ctx, reservation, candidate, finality, reconcileResult)
		}
	case "refund", "release":
		err = s.refundHeldReservationWithResult(ctx, reservation, candidate, reconcileResult)
	default:
		return row
	}
	if err != nil {
		if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
			row.Error = "reservation is no longer active"
			return row
		}
		row.Error = err.Error()
		return row
	}
	row.Applied = true
	slog.Info("settlement hold drained",
		"event", "settlement_hold_drained",
		"account", reservation.AccountID,
		"request", reservation.RequestID,
		"disposition", row.Disposition,
		"actor", "operator",
	)
	return row
}

func (c *settlementReleaseHoldsCounts) add(disposition string) {
	switch disposition {
	case "settle":
		c.Settle++
	case "refund":
		c.Refund++
	case "release":
		c.Release++
	case "skip_unsupported":
		c.SkipUnsupported++
	case "skip_lookup_error":
		c.SkipLookupError++
	}
}

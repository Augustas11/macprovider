package buyer

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// SPEC-050 allowance admission on the coordinator chat hop. The gateway sends
// these internal headers (stripped from buyers at its ingress) only for
// API-key plaintext and relay-blind requests. The coordinator admits the
// request against the account's allowance before any provider is dispatched
// and tells the gateway the funding in its response headers.
const (
	allowanceModelHeader        = "X-MacProvider-Internal-Allowance-Model"
	allowanceInputTokensHeader  = "X-MacProvider-Internal-Allowance-Input-Tokens"
	allowanceOutputTokensHeader = "X-MacProvider-Internal-Allowance-Output-Tokens"
	allowanceRequiredHeader     = "X-MacProvider-Internal-Allowance-Required"
	allowanceFundingHeader      = "X-MacProvider-Internal-Allowance-Funding"
	allowanceActiveHeader       = "X-MacProvider-Internal-Allowance-Active"

	// allowanceHookTimeout bounds the admission and close writes so a slow
	// billing database never holds a chat request.
	allowanceHookTimeout = 2 * time.Second
	maxAllowanceTokens   = 1_000_000_000
)

func parseAllowanceTokens(raw string) (int64, bool) {
	v, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || v < 0 || v > maxAllowanceTokens || strconv.FormatInt(v, 10) != strings.TrimSpace(raw) {
		return 0, false
	}
	return v, true
}

// admitAllowance runs SPEC-050-R007 admission for a gateway-authenticated
// request that carries the allowance headers. It returns false after writing
// a refusal; the caller must then stop.
func (s *Server) admitAllowance(w http.ResponseWriter, r *http.Request, rec *billingRecorder, accountID, externalRequestID string, hasAuthenticatedAccount bool) bool {
	model := strings.TrimSpace(r.Header.Get(allowanceModelHeader))
	if model == "" || !hasAuthenticatedAccount || accountID == "" || externalRequestID == "" || len(model) > 256 {
		return true
	}
	billingStore, _, _ := s.billingState()
	if billingStore == nil {
		return true
	}
	input, okIn := parseAllowanceTokens(r.Header.Get(allowanceInputTokensHeader))
	output, okOut := parseAllowanceTokens(r.Header.Get(allowanceOutputTokensHeader))
	if !okIn || !okOut {
		return true
	}
	required := strings.TrimSpace(r.Header.Get(allowanceRequiredHeader)) == "1"
	ctx, cancel := context.WithTimeout(r.Context(), allowanceHookTimeout)
	defer cancel()
	decision, err := billingStore.AdmitAllowance(ctx, billing.AllowanceAdmission{
		AccountID: accountID, RequestID: externalRequestID, Model: model,
		BoundCredits: s.AllowanceCreditBound(model, input, output), Required: required, Now: s.now(),
	})
	if err != nil {
		s.log.Warn().Err(err).Str("request_id", externalRequestID).Msg("allowance admission failed")
		if required {
			// The gateway's paid quota cannot take this request; without an
			// allowance answer it must not run.
			rec.logBuyerFailure(http.StatusServiceUnavailable, "allowance admission unavailable")
			writeError(w, http.StatusServiceUnavailable, "allowance_unavailable", "Allowance is unavailable; retry shortly")
			return false
		}
		return true
	}
	active := "0"
	if decision.HasAllowance {
		active = "1"
	}
	w.Header().Set(allowanceActiveHeader, active)
	if decision.Funding == billing.AllowanceFundingRefused {
		code, msg := "allowance_exhausted", "Daily allowance exhausted and overage is off"
		if required && decision.OverageEnabled {
			code, msg = "quota_exhausted", "Quota exhausted"
		}
		w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(decision.ResetAt.Unix(), 10))
		rec.logBuyerFailure(http.StatusTooManyRequests, msg)
		writeError(w, http.StatusTooManyRequests, code, msg)
		return false
	}
	w.Header().Set(allowanceFundingHeader, decision.Funding)
	if decision.HasAllowance {
		rec.allowanceFunding = decision.Funding
	}
	return true
}

// closeAllowance records the request's per-attempt split and allowance spend
// once the handler is done with every attempt (SPEC-050-R008). A failure is
// left to the reaper, which closes stale holds.
func (s *Server) closeAllowance(rec *billingRecorder, accountID, externalRequestID string) {
	if rec.allowanceFunding == "" {
		return
	}
	billingStore, _, _ := s.billingState()
	if billingStore == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), allowanceHookTimeout)
	defer cancel()
	if err := billingStore.CloseAllowanceReservation(ctx, accountID, externalRequestID, s.now()); err != nil {
		s.log.Warn().Err(err).Str("request_id", externalRequestID).Msg("allowance close failed; the reaper will close it")
	}
}

// AllowanceCreditBound prices a request's SPEC-050 credit bound at the rate
// card in force (billing.AllowanceCreditBound).
func (s *Server) AllowanceCreditBound(model string, promptTokens, completionTokens int64) int64 {
	economics := s.economicsSnapshotForModel(model)
	return billing.AllowanceCreditBound(economics.rateEntry, economics.multiplierPPM, promptTokens, completionTokens)
}

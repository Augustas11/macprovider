package rewards

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

type tokenValidator interface {
	ValidateAndMarkTokenUsed(ctx context.Context, raw string) (subject string, ok bool, err error)
}

// AccrualHandlerDeps wires the provider MALIBU accrual endpoint.
type AccrualHandlerDeps struct {
	DB                    *sql.DB
	PayoutDB              *sql.DB
	TokenStore            tokenValidator
	RequireProviderTokens bool
	Config                Config
	Connectivity          ProviderConnectivity
}

// NewAccrualHandler serves GET /v1/provider/malibu-accrual.
func NewAccrualHandler(deps AccrualHandlerDeps) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method_not_allowed"}` + "\n"))
			return
		}
		if !deps.RequireProviderTokens {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"unavailable"}` + "\n"))
			return
		}
		raw := bearerToken(r.Header.Get("Authorization"))
		if raw == "" || deps.TokenStore == nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}` + "\n"))
			return
		}
		providerID, ok, err := auth.ValidateProviderAPIReadAndMark(r.Context(), deps.TokenStore, raw)
		if err != nil || !ok || providerID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}` + "\n"))
			return
		}

		bal, err := QueryAccrualBalance(r.Context(), deps.DB, providerID, deps.Config)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":"internal_error"}` + "\n"))
			return
		}
		trust, err := QueryTrustCriteriaStatus(r.Context(), deps.DB, providerID, deps.Config, deps.Connectivity)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":"internal_error"}` + "\n"))
			return
		}
		rewardProjection, err := queryRewardWalletProjection(r.Context(), deps.DB, providerID)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":"internal_error"}` + "\n"))
			return
		}
		payoutWallet, err := queryPayoutWalletStatus(r.Context(), deps.PayoutDB, providerID, deps.Config.PayoutHotWalletAddress)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":"internal_error"}` + "\n"))
			return
		}
		currentWalletAllowed, walletMismatch := currentWalletBinding(payoutWallet, rewardProjection)
		trust = trustCriteriaWithWalletBinding(trust, currentWalletAllowed && !walletMismatch)
		eligibility := RewardEligibilityFromBalanceAndTrust(bal, trust)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"provider_id":             providerID,
			"accrued_malibu":          bal.AccruedMALIBU,
			"withdrawable_malibu":     bal.WithdrawableMALIBU,
			"held_malibu":             bal.HeldMALIBU,
			"trust_tier":              bal.TrustTier,
			"daily_cap_malibu":        bal.ProviderDailyCap,
			"provider_daily_capped":   bal.ProviderDailyCapped,
			"wallet_daily_cap_malibu": bal.WalletDailyCap,
			"withdrawal_hold_reasons": bal.HoldReasons,
			"trust_criteria_met":      trust.CriteriaMet,
			"trust_criteria_required": trust.CriteriaRequired,
			"economic_criteria":       trust.EconomicSatisfied,
			"additional_criteria":     trust.AdditionalSatisfied,
			"verified_receipt_count":  trust.VerifiedReceiptCount,
			"wallet_bound":            trust.WalletBound,
			"wallet_mismatch":         walletMismatch,
			"app_attested":            trust.AppAttested,
			"reward_eligibility":      eligibility,
		})
	})
}

// AuditHandlerDeps wires provider/operator MALIBU reward audit endpoints.
type AuditHandlerDeps struct {
	DB                    *sql.DB
	TokenStore            tokenValidator
	RequireProviderTokens bool
	OperatorKey           string
	Limiter               *RewardAuditLimiter
}

// NewRewardAuditHandler serves GET /v1/provider/malibu-reward-audit.
func NewRewardAuditHandler(deps AuditHandlerDeps) http.Handler {
	limiter := deps.Limiter
	if limiter == nil {
		limiter = NewRewardAuditLimiter(60, 4)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			writeAuditJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
			return
		}
		if !deps.RequireProviderTokens {
			writeAuditJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
			return
		}
		raw := bearerToken(r.Header.Get("Authorization"))
		if raw == "" || deps.TokenStore == nil {
			writeAuditJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		providerID, ok, err := validateAuditToken(r.Context(), deps.TokenStore, raw)
		if err != nil || !ok || providerID == "" {
			writeAuditJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		release, ok := limiter.Allow(providerID, time.Now().UTC())
		if !ok {
			w.Header().Set("Retry-After", "1")
			writeAuditJSON(w, http.StatusTooManyRequests, map[string]any{"error": "rate_limited"})
			return
		}
		defer release()
		limit, beforeID, ok := parseAuditPage(w, r)
		if !ok {
			return
		}
		page, err := QueryRewardAuditEvents(r.Context(), deps.DB, RewardAuditQuery{
			ProviderID: providerID,
			Limit:      limit,
			BeforeID:   beforeID,
		})
		if err != nil {
			writeAuditJSON(w, http.StatusInternalServerError, map[string]any{"error": "internal_error"})
			return
		}
		writeAuditJSON(w, http.StatusOK, page)
	})
}

func validateAuditToken(ctx context.Context, store tokenValidator, raw string) (string, bool, error) {
	return auth.ValidateProviderAPIRead(ctx, store, raw)
}

// NewRewardAuditAdminHandler serves GET /admin/malibu-reward-audit?provider_id=...
func NewRewardAuditAdminHandler(deps AuditHandlerDeps) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			writeAuditJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
			return
		}
		if deps.OperatorKey == "" || !auth.OperatorOnlyBearerMatches(r.Header, deps.OperatorKey) {
			writeAuditJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		providerID := strings.TrimSpace(r.URL.Query().Get("provider_id"))
		if providerID == "" {
			writeAuditJSON(w, http.StatusBadRequest, map[string]any{"error": "provider_id_required"})
			return
		}
		limit, beforeID, ok := parseAuditPage(w, r)
		if !ok {
			return
		}
		page, err := QueryRewardAuditEvents(r.Context(), deps.DB, RewardAuditQuery{
			ProviderID:      providerID,
			Limit:           limit,
			BeforeID:        beforeID,
			IncludeProvider: true,
			IncludeOperator: true,
		})
		if err != nil {
			writeAuditJSON(w, http.StatusInternalServerError, map[string]any{"error": "internal_error"})
			return
		}
		writeAuditJSON(w, http.StatusOK, page)
	})
}

func parseAuditPage(w http.ResponseWriter, r *http.Request) (limit int, beforeID int64, ok bool) {
	limit, err := ParseAuditLimit(r.URL.Query().Get("limit"))
	if err != nil {
		writeAuditJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_limit"})
		return 0, 0, false
	}
	beforeID, err = ParseAuditBeforeID(r.URL.Query().Get("before_id"))
	if err != nil {
		writeAuditJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_before_id"})
		return 0, 0, false
	}
	return limit, beforeID, true
}

func writeAuditJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(header, prefix))
}

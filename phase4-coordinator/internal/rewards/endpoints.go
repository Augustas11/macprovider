package rewards

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
)

type tokenValidator interface {
	ValidateAndMarkTokenUsed(ctx context.Context, raw string) (subject string, ok bool, err error)
}

// AccrualHandlerDeps wires the provider MALIBU accrual endpoint.
type AccrualHandlerDeps struct {
	DB                    *sql.DB
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
		providerID, ok, err := deps.TokenStore.ValidateAndMarkTokenUsed(r.Context(), raw)
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
			"wallet_daily_cap_malibu": bal.WalletDailyCap,
			"withdrawal_hold_reasons": bal.HoldReasons,
			"trust_criteria_met":      trust.CriteriaMet,
			"trust_criteria_required": trust.CriteriaRequired,
			"economic_criteria":       trust.EconomicSatisfied,
			"additional_criteria":     trust.AdditionalSatisfied,
			"verified_receipt_count":  trust.VerifiedReceiptCount,
			"wallet_bound":            trust.WalletBound,
			"app_attested":            trust.AppAttested,
			"reward_eligibility":      eligibility,
		})
	})
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(header, prefix))
}

package rewards

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const ProviderWalletStatusSchemaV1 = "provider_wallet_status.v1"

type WalletHandlerDeps struct {
	RewardsDB             *sql.DB
	PayoutDB              *sql.DB
	TokenStore            tokenValidator
	RequireProviderTokens bool
	Config                Config
	Connectivity          ProviderConnectivity
	Limiter               *RewardAuditLimiter
}

type ProviderWalletStatus struct {
	SchemaVersion        string                           `json:"schema_version"`
	ProviderID           string                           `json:"provider_id"`
	WalletBound          bool                             `json:"wallet_bound"`
	WalletMismatch       bool                             `json:"wallet_mismatch"`
	HoldOrMismatchReason string                           `json:"hold_or_mismatch_reason,omitempty"`
	PayoutWallet         *ProviderPayoutWalletStatus      `json:"payout_wallet"`
	RewardWallet         ProviderRewardWalletStatus       `json:"reward_wallet"`
	RewardAmounts        ProviderWalletRewardAmounts      `json:"reward_amounts"`
	EligibilityInputs    ProviderWalletEligibilityInput   `json:"eligibility_inputs"`
	RewardEligibility    MalibuRewardEligibilityReadModel `json:"reward_eligibility"`
	Audit                RewardAuditPage                  `json:"audit"`
}

type ProviderPayoutWalletStatus struct {
	Chain                      string `json:"chain"`
	Address                    string `json:"address"`
	PayoutAllowed              bool   `json:"payout_allowed"`
	PendingUntilUTC            string `json:"pending_until_utc,omitempty"`
	RotatedFrom                string `json:"rotated_from,omitempty"`
	RegisteredAtUTC            string `json:"registered_at_utc,omitempty"`
	RegisteredAgainstHotWallet string `json:"registered_against_hot_wallet,omitempty"`
	VerificationSource         string `json:"verification_source"`
	LastUpdateUTC              string `json:"last_update_utc,omitempty"`
}

type ProviderRewardWalletStatus struct {
	Address            string `json:"address,omitempty"`
	VerificationSource string `json:"verification_source"`
	LastUpdateUTC      string `json:"last_update_utc,omitempty"`
	CapReplayPending   bool   `json:"cap_replay_pending"`
}

type ProviderWalletRewardAmounts struct {
	AccruedMALIBU      string  `json:"accrued_malibu"`
	WithdrawableMALIBU string  `json:"withdrawable_malibu"`
	HeldMALIBU         string  `json:"held_malibu"`
	ProviderDailyCap   float64 `json:"provider_daily_cap_malibu"`
	ProviderDayMALIBU  string  `json:"provider_day_malibu"`
	ProviderCapped     bool    `json:"provider_daily_capped"`
	WalletDailyCap     float64 `json:"wallet_daily_cap_malibu"`
	WalletDayMALIBU    string  `json:"wallet_day_malibu"`
	WalletCapped       bool    `json:"wallet_daily_capped"`
}

type ProviderWalletEligibilityInput struct {
	TrustTier             string     `json:"trust_tier"`
	DemotionCooldownUntil *time.Time `json:"demotion_cooldown_until,omitempty"`
	Quarantined           bool       `json:"quarantined"`
	ReceiptQuality        string     `json:"receipt_quality"`
	VerifiedReceiptCount  int        `json:"verified_receipt_count"`
	RequiredReceiptCount  int        `json:"required_receipt_count"`
	ComputeIntegrityState string     `json:"compute_integrity_state"`
	AttestationTier       string     `json:"attestation_tier"`
	AppAttested           bool       `json:"app_attested"`
	CriteriaMet           int        `json:"criteria_met"`
	CriteriaRequired      int        `json:"criteria_required"`
	EconomicCriteria      []string   `json:"economic_criteria"`
	AdditionalCriteria    []string   `json:"additional_criteria"`
	WalletBalanceOK       bool       `json:"wallet_balance_ok"`
	UptimeOK              bool       `json:"uptime_ok"`
}

type rewardWalletProjection struct {
	Address           string
	CapReplayPending  bool
	ProviderDayMALIBU string
	EmissionDay       string
	UpdatedAt         *time.Time
}

func NewWalletStatusHandler(deps WalletHandlerDeps) http.Handler {
	limiter := deps.Limiter
	if limiter == nil {
		limiter = NewRewardAuditLimiter(60, 4)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			writeWalletJSON(w, http.StatusNotImplemented, map[string]any{"error": "wallet_change_requires_spec_027"})
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET, POST")
			writeWalletJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
			return
		}
		if !deps.RequireProviderTokens {
			writeWalletJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
			return
		}
		raw := bearerToken(r.Header.Get("Authorization"))
		if raw == "" || deps.TokenStore == nil {
			writeWalletJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		providerID, ok, err := validateAuditToken(r.Context(), deps.TokenStore, raw)
		if err != nil || !ok || providerID == "" {
			writeWalletJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		release, ok := limiter.Allow(providerID, time.Now().UTC())
		if !ok {
			w.Header().Set("Retry-After", "1")
			writeWalletJSON(w, http.StatusTooManyRequests, map[string]any{"error": "rate_limited"})
			return
		}
		defer release()
		if deps.RewardsDB == nil {
			writeWalletJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
			return
		}
		status, err := QueryProviderWalletStatus(r.Context(), deps.RewardsDB, deps.PayoutDB, providerID, deps.Config, deps.Connectivity)
		if err != nil {
			writeWalletJSON(w, http.StatusInternalServerError, map[string]any{"error": "internal_error"})
			return
		}
		writeWalletJSON(w, http.StatusOK, status)
	})
}

func QueryProviderWalletStatus(ctx context.Context, rewardsDB, payoutDB *sql.DB, providerID string, cfg Config, connectivity ProviderConnectivity) (ProviderWalletStatus, error) {
	if rewardsDB == nil {
		return ProviderWalletStatus{}, errors.New("rewards db is required")
	}
	cfg = cfg.DefaultsApplied()
	bal, err := QueryAccrualBalance(ctx, rewardsDB, providerID, cfg)
	if err != nil {
		return ProviderWalletStatus{}, err
	}
	trust, err := QueryTrustCriteriaStatus(ctx, rewardsDB, providerID, cfg, connectivity)
	if err != nil {
		return ProviderWalletStatus{}, err
	}
	rewardProjection, err := queryRewardWalletProjection(ctx, rewardsDB, providerID)
	if err != nil {
		return ProviderWalletStatus{}, err
	}
	payoutWallet, err := queryPayoutWalletStatus(ctx, payoutDB, providerID, cfg.PayoutHotWalletAddress)
	if err != nil {
		return ProviderWalletStatus{}, err
	}
	walletDay, walletCapped, err := queryWalletDayUsage(ctx, rewardsDB, rewardProjection.Address, cfg.WalletDailyCapMALIBU)
	if err != nil {
		return ProviderWalletStatus{}, err
	}
	auditPage, err := QueryRewardAuditEvents(ctx, rewardsDB, RewardAuditQuery{ProviderID: providerID, Limit: 10})
	if err != nil {
		return ProviderWalletStatus{}, err
	}
	currentWalletAllowed, mismatch := currentWalletBinding(payoutWallet, rewardProjection)
	walletBound := currentWalletAllowed && !mismatch
	trust = trustCriteriaWithWalletBinding(trust, walletBound)
	eligibility := RewardEligibilityFromBalanceAndTrust(bal, trust)
	reason := holdOrMismatchReason(mismatch, eligibility, bal.HoldReasons)
	return ProviderWalletStatus{
		SchemaVersion:        ProviderWalletStatusSchemaV1,
		ProviderID:           providerID,
		WalletBound:          walletBound,
		WalletMismatch:       mismatch,
		HoldOrMismatchReason: reason,
		PayoutWallet:         payoutWallet,
		RewardWallet: ProviderRewardWalletStatus{
			Address:            rewardProjection.Address,
			VerificationSource: rewardWalletVerificationSource(rewardProjection.Address),
			LastUpdateUTC:      formatOptionalTime(rewardProjection.UpdatedAt),
			CapReplayPending:   rewardProjection.CapReplayPending,
		},
		RewardAmounts: ProviderWalletRewardAmounts{
			AccruedMALIBU:      bal.AccruedMALIBU,
			WithdrawableMALIBU: bal.WithdrawableMALIBU,
			HeldMALIBU:         bal.HeldMALIBU,
			ProviderDailyCap:   bal.ProviderDailyCap,
			ProviderDayMALIBU:  rewardProjection.ProviderDayMALIBU,
			ProviderCapped:     bal.ProviderDailyCapped,
			WalletDailyCap:     bal.WalletDailyCap,
			WalletDayMALIBU:    walletDay,
			WalletCapped:       walletCapped,
		},
		EligibilityInputs: ProviderWalletEligibilityInput{
			TrustTier:             trust.TrustTier,
			DemotionCooldownUntil: trust.DemotionCooldownUntil,
			Quarantined:           eligibility.EarningState == EarningStateIneligible || eligibility.WithdrawalState == WithdrawalStateIneligible,
			ReceiptQuality:        receiptQuality(trust.VerifiedReceiptCount),
			VerifiedReceiptCount:  trust.VerifiedReceiptCount,
			RequiredReceiptCount:  minVerifiedReceipts,
			ComputeIntegrityState: ComputeIntegrityStateUnknown,
			AttestationTier:       attestationTier(trust.AppAttested),
			AppAttested:           trust.AppAttested,
			CriteriaMet:           trust.CriteriaMet,
			CriteriaRequired:      trust.CriteriaRequired,
			EconomicCriteria:      trust.EconomicSatisfied,
			AdditionalCriteria:    trust.AdditionalSatisfied,
			WalletBalanceOK:       trust.WalletBalanceOK,
			UptimeOK:              trust.UptimeOK,
		},
		RewardEligibility: eligibility,
		Audit:             auditPage,
	}, nil
}

func currentWalletBinding(payoutWallet *ProviderPayoutWalletStatus, rewardProjection rewardWalletProjection) (bool, bool) {
	rewardAddress := strings.TrimSpace(rewardProjection.Address)
	if payoutWallet == nil {
		return false, rewardAddress != ""
	}
	currentWalletBound := payoutWallet.PayoutAllowed
	if rewardAddress == "" {
		return currentWalletBound, currentWalletBound
	}
	return currentWalletBound, !strings.EqualFold(strings.TrimSpace(payoutWallet.Address), rewardAddress)
}

func trustCriteriaWithWalletBinding(trust TrustCriteriaStatus, walletBound bool) TrustCriteriaStatus {
	trust.WalletBound = walletBound
	if !walletBound {
		trust.WalletBalanceOK = false
	}
	economic, additional := satisfiedCriteria(satisfiedInput{
		ReceiptCount:     trust.VerifiedReceiptCount,
		WalletBound:      trust.WalletBound,
		WalletBalanceOK:  trust.WalletBalanceOK,
		OperatorPromoted: trust.OperatorPromoted,
		UptimeOK:         trust.UptimeOK,
		AppAttested:      trust.AppAttested,
	})
	trust.EconomicSatisfied = economic
	trust.AdditionalSatisfied = additional
	trust.CriteriaMet = len(uniqueCriterionIDs(append(append([]string{}, economic...), additional...)))
	return trust
}

func queryRewardWalletProjection(ctx context.Context, db *sql.DB, providerID string) (rewardWalletProjection, error) {
	var out rewardWalletProjection
	var addr, providerDay, emissionDay sql.NullString
	var updated sql.NullTime
	err := db.QueryRowContext(ctx, `
        SELECT bound_wallet, cap_replay_pending, provider_day_malibu::TEXT,
               emission_day::TEXT, updated_at
          FROM provider_emission_state
         WHERE provider_id = $1
    `, providerID).Scan(&addr, &out.CapReplayPending, &providerDay, &emissionDay, &updated)
	if err == sql.ErrNoRows {
		out.ProviderDayMALIBU = "0"
		return out, nil
	}
	if err != nil {
		return rewardWalletProjection{}, err
	}
	out.Address = strings.TrimSpace(addr.String)
	if providerDay.Valid {
		out.ProviderDayMALIBU = providerDay.String
	} else {
		out.ProviderDayMALIBU = "0"
	}
	if emissionDay.Valid {
		out.EmissionDay = emissionDay.String
	}
	if updated.Valid {
		t := updated.Time.UTC()
		out.UpdatedAt = &t
	}
	return out, nil
}

func queryPayoutWalletStatus(ctx context.Context, db *sql.DB, providerID, hotWalletAddress string) (*ProviderPayoutWalletStatus, error) {
	if db == nil || !tableExists(ctx, db, "provider_payout_addresses") {
		return nil, nil
	}
	hotWalletAddress = strings.TrimSpace(hotWalletAddress)
	if hotWalletAddress == "" {
		return nil, nil
	}
	var address, pending, rotated, registered, hot sql.NullString
	var chain string
	var allowed int
	err := db.QueryRowContext(ctx, `
        SELECT chain, address, payout_allowed, pending_until_utc, rotated_from,
               registered_at_utc, registered_against_hot_wallet
          FROM provider_payout_addresses
         WHERE provider_id = ? AND chain = 'base-mainnet'
           AND registered_against_hot_wallet = ?
    `, providerID, hotWalletAddress).Scan(&chain, &address, &allowed, &pending, &rotated, &registered, &hot)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	last := registered.String
	return &ProviderPayoutWalletStatus{
		Chain:                      chain,
		Address:                    address.String,
		PayoutAllowed:              allowed == 1,
		PendingUntilUTC:            walletNullString(pending),
		RotatedFrom:                walletNullString(rotated),
		RegisteredAtUTC:            walletNullString(registered),
		RegisteredAgainstHotWallet: walletNullString(hot),
		VerificationSource:         "provider_payout_addresses",
		LastUpdateUTC:              last,
	}, nil
}

func queryWalletDayUsage(ctx context.Context, db *sql.DB, wallet string, cap float64) (string, bool, error) {
	if strings.TrimSpace(wallet) == "" {
		return "0", false, nil
	}
	var sum string
	err := db.QueryRowContext(ctx, `
        SELECT COALESCE(sum_malibu, 0)::TEXT
          FROM wallet_daily_malibu_emission
         WHERE bound_wallet = $1 AND emission_day = $2
    `, strings.ToLower(strings.TrimSpace(wallet)), utcDay(time.Now().UTC())).Scan(&sum)
	if err == sql.ErrNoRows {
		return "0", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return sum, cap > 0 && decimalAtLeast(sum, cap), nil
}

func holdOrMismatchReason(mismatch bool, eligibility MalibuRewardEligibilityReadModel, holds []string) string {
	if mismatch {
		return "wallet_projection_mismatch"
	}
	if eligibility.PrimaryReason != "" &&
		eligibility.PrimaryReason != ReasonWithdrawableBalanceAvailable &&
		eligibility.PrimaryReason != ReasonWithdrawableNoBalance &&
		eligibility.PrimaryReason != ReasonEligibleIdleNoWork &&
		eligibility.PrimaryReason != ReasonEarningVerifiedWork {
		return eligibility.PrimaryReason
	}
	if len(holds) > 0 {
		return holds[0]
	}
	return ""
}

func receiptQuality(verified int) string {
	if verified >= minVerifiedReceipts {
		return "sufficient_verified_receipts"
	}
	return "insufficient_verified_receipts"
}

func attestationTier(appAttested bool) string {
	if appAttested {
		return "app_attested"
	}
	return "missing"
}

func rewardWalletVerificationSource(address string) string {
	if strings.TrimSpace(address) == "" {
		return "not_bound"
	}
	return "provider_emission_state"
}

func decimalAtLeast(raw string, threshold float64) bool {
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return false
	}
	return value >= threshold
}

func formatOptionalTime(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}

func walletNullString(v sql.NullString) string {
	if !v.Valid {
		return ""
	}
	return v.String
}

func writeWalletJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

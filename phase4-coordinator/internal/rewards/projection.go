package rewards

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
)

// RecentVerifiedWorkWindow is the bounded observation window for the
// earning_verified_work reason. It is deliberately independent from emission
// scheduling: a settled mirror row proves recently observed useful work, not a
// reward issuance, payment, or a live request that has not settled yet.
const RecentVerifiedWorkWindow = 30 * time.Minute

const rewardProjectionFreshnessWindow = time.Minute

// ProviderRewardProjection is the coherent reward-owner read used by both the
// accrual and wallet endpoints. Wallet and payout fields are retained here so
// every caller derives wallet binding and eligibility from the same inputs.
type ProviderRewardProjection struct {
	GeneratedAt time.Time
	StaleAfter  time.Time

	Balance          AccrualBalance
	Trust            TrustCriteriaStatus
	RewardWallet     rewardWalletProjection
	PayoutWallet     *ProviderPayoutWalletStatus
	WalletBound      bool
	WalletMismatch   bool
	Eligibility      MalibuRewardEligibilityReadModel
	RecentWorkAt     *time.Time
	RecentWorkSource string
}

// ProviderRewardProjectionDeps supplies the authoritative sources for the
// coordinator-owned MALIBU projection. Compute integrity deliberately has no
// dependency here until a production, covered-key source exists.
type ProviderRewardProjectionDeps struct {
	RewardsDB           *sql.DB
	PayoutDB            *sql.DB
	Config              Config
	Connectivity        ProviderConnectivity
	HardwareEvidence    autotune.EvidenceStore
	HardwareEvidenceTTL time.Duration
	Now                 func() time.Time
}

// BuildProviderRewardProjection loads one complete MALIBU read bundle. A
// source failure is returned for ledger/trust/wallet facts, while optional
// proof and recent-work observations remain explicitly unavailable in the
// coordinator eligibility object instead of making up a state from raw data.
func BuildProviderRewardProjection(ctx context.Context, providerID string, deps ProviderRewardProjectionDeps) (ProviderRewardProjection, error) {
	if deps.RewardsDB == nil {
		return ProviderRewardProjection{}, errors.New("rewards db is required")
	}
	now := time.Now().UTC()
	if deps.Now != nil {
		now = deps.Now().UTC()
	}
	cfg := deps.Config.DefaultsApplied()

	bal, err := QueryAccrualBalance(ctx, deps.RewardsDB, providerID, cfg)
	if err != nil {
		return ProviderRewardProjection{}, err
	}
	trust, err := QueryTrustCriteriaStatus(ctx, deps.RewardsDB, providerID, cfg, deps.Connectivity)
	if err != nil {
		return ProviderRewardProjection{}, err
	}
	bal = balanceWithAuthoritativeTrustTier(bal, trust.TrustTier)
	rewardWallet, err := queryRewardWalletProjection(ctx, deps.RewardsDB, providerID)
	if err != nil {
		return ProviderRewardProjection{}, err
	}
	payoutWallet, err := queryPayoutWalletStatus(ctx, deps.PayoutDB, providerID, cfg.PayoutHotWalletAddress)
	if err != nil {
		return ProviderRewardProjection{}, err
	}
	currentWalletAllowed, walletMismatch := currentWalletBinding(payoutWallet, rewardWallet)
	walletBound := currentWalletAllowed && !walletMismatch
	trust = trustCriteriaWithWalletBinding(trust, walletBound)

	hardwareState, hardwareExpiresAt := hardwareEvidenceObservation(ctx, providerID, deps.HardwareEvidence, deps.HardwareEvidenceTTL)
	recentWorkAt, recentWorkErr := queryRecentVerifiedWork(ctx, deps.RewardsDB, providerID, now)
	facts := MalibuRewardEligibilityFacts{
		AccruedMALIBU:         bal.AccruedMALIBU,
		WithdrawableMALIBU:    bal.WithdrawableMALIBU,
		HeldMALIBU:            bal.HeldMALIBU,
		TrustTier:             bal.TrustTier,
		WithdrawalHoldReasons: bal.HoldReasons,
		ProviderDailyCapped:   bal.ProviderDailyCapped,
		WalletBound:           walletBound,
		VerifiedReceiptCount:  trust.VerifiedReceiptCount,
		AppAttested:           trust.AppAttested,
		HardwareEvidenceState: hardwareState,
		// No production compute-integrity source is wired. The v1 model must
		// continue to say unavailable instead of treating a test seam or one
		// covered key as provider-wide proof.
		ComputeIntegrityState: ComputeIntegrityStateUnknown,
	}
	facts.LocalRuntimeReasons, facts.TelemetryUnavailable = recentWorkEligibilityFacts(recentWorkAt, recentWorkErr)

	return ProviderRewardProjection{
		GeneratedAt:      now,
		StaleAfter:       rewardProjectionStaleAfter(now, recentWorkAt, hardwareExpiresAt),
		Balance:          bal,
		Trust:            trust,
		RewardWallet:     rewardWallet,
		PayoutWallet:     payoutWallet,
		WalletBound:      walletBound,
		WalletMismatch:   walletMismatch,
		Eligibility:      BuildMalibuRewardEligibility(facts),
		RecentWorkAt:     recentWorkAt,
		RecentWorkSource: "settlement_mirror_spec022_verified",
	}, nil
}

func balanceWithAuthoritativeTrustTier(balance AccrualBalance, trustTier string) AccrualBalance {
	balance.TrustTier = trustTier
	return balance
}

func recentWorkEligibilityFacts(observedAt *time.Time, err error) ([]string, bool) {
	if err != nil {
		return nil, true
	}
	if observedAt != nil {
		return []string{ReasonEarningVerifiedWork}, false
	}
	// The v0.2 mirror has no provider-independent watermark proving that a
	// no-row query is current. A settlement/mirror delay is indistinguishable
	// from idle here, so do not invent eligible_idle_no_work from absence.
	return nil, true
}

func hardwareEvidenceState(ctx context.Context, providerID string, source autotune.EvidenceStore, ttl time.Duration) string {
	state, _ := hardwareEvidenceObservation(ctx, providerID, source, ttl)
	return state
}

func hardwareEvidenceObservation(ctx context.Context, providerID string, source autotune.EvidenceStore, ttl time.Duration) (string, *time.Time) {
	if source == nil || ttl <= 0 {
		return HardwareEvidenceStateUnavailable, nil
	}
	evidence, ok, err := source.LatestVerified(ctx, providerID, ttl)
	if err != nil {
		return HardwareEvidenceStateUnavailable, nil
	}
	if !ok {
		return HardwareEvidenceStateMissing, nil
	}
	if evidence.GeneratedAt.IsZero() {
		return HardwareEvidenceStateUnavailable, nil
	}
	expiresAt := evidence.GeneratedAt.UTC().Add(ttl)
	return HardwareEvidenceStateVerified, &expiresAt
}

func queryRecentVerifiedWork(ctx context.Context, db *sql.DB, providerID string, now time.Time) (*time.Time, error) {
	var observed any
	err := db.QueryRowContext(ctx, `
        SELECT MAX(ts_utc)
          FROM ledger_request_credits lrc
         WHERE provider_id = $1
           AND spec022_verified = TRUE
           AND COALESCE((to_jsonb(lrc)->>'rewards_excluded')::BOOLEAN, FALSE) = FALSE
           AND settlement_policy_mode = 'enforce'
           AND quarantined = FALSE
           AND provider_credits > 0
           AND ts_utc >= $2
           AND ts_utc <= $3
    `, providerID, now.Add(-RecentVerifiedWorkWindow), now).Scan(&observed)
	if err != nil {
		return nil, err
	}
	return parseRecentVerifiedWorkTime(observed)
}

func parseRecentVerifiedWorkTime(observed any) (*time.Time, error) {
	if observed == nil {
		return nil, nil
	}
	var at time.Time
	switch value := observed.(type) {
	case time.Time:
		at = value
	case string:
		var err error
		for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02 15:04:05.999999999Z07:00", "2006-01-02 15:04:05.999999999 -0700 MST"} {
			at, err = time.Parse(layout, value)
			if err == nil {
				break
			}
		}
		if err != nil {
			return nil, err
		}
	case []byte:
		return parseRecentVerifiedWorkTime(string(value))
	default:
		return nil, errors.New("recent verified work timestamp has unsupported type")
	}
	at = at.UTC()
	return &at, nil
}

func rewardProjectionStaleAfter(now time.Time, recentWorkAt, hardwareExpiresAt *time.Time) time.Time {
	staleAfter := now.Add(rewardProjectionFreshnessWindow)
	if recentWorkAt != nil {
		workExpiry := recentWorkAt.Add(RecentVerifiedWorkWindow)
		if workExpiry.Before(staleAfter) {
			staleAfter = workExpiry
		}
	}
	if hardwareExpiresAt != nil && hardwareExpiresAt.Before(staleAfter) {
		staleAfter = *hardwareExpiresAt
	}
	return staleAfter
}

package rewards

import (
	"context"
	"database/sql"
	"time"
)

// ProviderTrustProgress is the provider-facing live trust state (SPEC-021
// §5.3). It reports the unlock evaluator's own windows so a client can show
// real progress instead of inferring it from ledger hold reasons.
type ProviderTrustProgress struct {
	Tier                         string     `json:"tier"`
	DemotionCooldownUntil        *time.Time `json:"demotion_cooldown_until,omitempty"`
	DemotionCooldownActive       bool       `json:"demotion_cooldown_active"`
	RequalificationRequired      bool       `json:"requalification_required"`
	UptimeOKSince                *time.Time `json:"uptime_ok_since,omitempty"`
	UptimeRequiredSeconds        int64      `json:"uptime_required_seconds"`
	UnlockPairOKSince            *time.Time `json:"unlock_pair_ok_since,omitempty"`
	RequalificationWindowSeconds int64      `json:"requalification_window_seconds"`
	VerifiedReceiptCount         int        `json:"verified_receipt_count"`
	RequiredReceiptCount         int        `json:"required_receipt_count"`
	CriteriaMet                  []string   `json:"criteria_met"`
	EarliestPromotionAt          *time.Time `json:"earliest_promotion_at,omitempty"`
}

// ProviderEmissionStatus says whether any MALIBU emission path runs on this
// coordinator, and when this provider last accrued MALIBU.
type ProviderEmissionStatus struct {
	Active        bool       `json:"active"`
	LastAccrualAt *time.Time `json:"last_accrual_at,omitempty"`
}

// EmissionActive reports whether a MALIBU issuance worker runs. The v0.4
// epoch path has no policy engine yet: with epoch_enabled set, both workers
// return ErrEpochPolicyEngineUnavailable, so nothing emits.
func (c Config) EmissionActive() bool {
	return c.Enabled && !c.EpochEnabled && (c.BootstrapTickEnabled || c.UsefulWorkEnabled)
}

// BuildTrustProgress derives the live trust block from the evaluator state.
// EarliestPromotionAt is set only when the remaining path is fixed by time
// alone: E1 already met, the A1 uptime window running (or the pair already
// held), and no gap in the hourly heartbeat samples from now on. A provider
// that still needs receipts or has no current heartbeat gets no estimate.
func BuildTrustProgress(trust TrustCriteriaStatus, now time.Time) ProviderTrustProgress {
	out := ProviderTrustProgress{
		Tier:                         trust.TrustTier,
		DemotionCooldownUntil:        utcTimePtr(trust.DemotionCooldownUntil),
		UptimeOKSince:                utcTimePtr(trust.UptimeOKSince),
		UptimeRequiredSeconds:        int64(uptimeRequiredWindow / time.Second),
		UnlockPairOKSince:            utcTimePtr(trust.UnlockPairOKSince),
		RequalificationWindowSeconds: int64(trustRequalifyWindow / time.Second),
		VerifiedReceiptCount:         trust.VerifiedReceiptCount,
		RequiredReceiptCount:         minVerifiedReceipts,
		CriteriaMet:                  uniqueCriterionIDs(append(append([]string{}, trust.EconomicSatisfied...), trust.AdditionalSatisfied...)),
	}
	if out.Tier == "" {
		out.Tier = TierProvisional
	}
	if out.Tier == TierTrusted {
		return out
	}
	// After any demotion the evaluator requires the pair to hold for the
	// requalification window, even once the cooldown itself has elapsed.
	out.RequalificationRequired = trust.DemotionCooldownUntil != nil
	out.DemotionCooldownActive = trust.DemotionCooldownUntil != nil && now.Before(*trust.DemotionCooldownUntil)

	var pairStart time.Time
	switch {
	case distinctUnlockPair(trust.EconomicSatisfied, trust.AdditionalSatisfied):
		pairStart = now
		if trust.UnlockPairOKSince != nil {
			pairStart = trust.UnlockPairOKSince.UTC()
		}
	case containsReason(trust.EconomicSatisfied, CriterionE1Receipts) && trust.UptimeOKSince != nil:
		pairStart = trust.UptimeOKSince.UTC().Add(uptimeRequiredWindow)
	default:
		return out
	}
	earliest := pairStart
	if out.RequalificationRequired {
		earliest = pairStart.Add(trustRequalifyWindow)
		if cooldown := trust.DemotionCooldownUntil.UTC(); earliest.Before(cooldown) {
			earliest = cooldown
		}
	}
	if earliest.Before(now) {
		earliest = now
	}
	out.EarliestPromotionAt = &earliest
	return out
}

// queryLastMalibuAccrual returns the provider's most recent positive MALIBU
// ledger row time, nil when it never accrued.
func queryLastMalibuAccrual(ctx context.Context, db *sql.DB, providerID string) (*time.Time, error) {
	var last sql.NullInt64
	err := db.QueryRowContext(ctx, `
        SELECT MAX(unix_ts)
          FROM provider_rewards_ledger
         WHERE provider_id = $1
           AND amount_malibu IS NOT NULL
           AND amount_malibu > 0
    `, providerID).Scan(&last)
	if err != nil {
		return nil, err
	}
	if !last.Valid {
		return nil, nil
	}
	t := time.Unix(last.Int64, 0).UTC()
	return &t, nil
}

func utcTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	v := t.UTC()
	return &v
}

package rewards

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
)

type projectionEvidenceStore struct {
	ok          bool
	err         error
	generatedAt time.Time
}

func (s projectionEvidenceStore) LatestVerified(context.Context, string, time.Duration) (autotune.VerifiedEvidence, bool, error) {
	return autotune.VerifiedEvidence{GeneratedAt: s.generatedAt}, s.ok, s.err
}

func TestHardwareEvidenceStateFailsClosed(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, time.September, 10, 12, 0, 0, 0, time.UTC)
	ttl := 30 * 24 * time.Hour
	for _, tc := range []struct {
		name   string
		source autotune.EvidenceStore
		ttl    time.Duration
		want   string
	}{
		{name: "missing source", want: HardwareEvidenceStateUnavailable},
		{name: "nonpositive ttl", source: projectionEvidenceStore{ok: true, generatedAt: now}, want: HardwareEvidenceStateUnavailable},
		{name: "owner error", source: projectionEvidenceStore{err: errors.New("unavailable")}, ttl: ttl, want: HardwareEvidenceStateUnavailable},
		{name: "no current verified evidence", source: projectionEvidenceStore{}, ttl: ttl, want: HardwareEvidenceStateMissing},
		{name: "malformed verified evidence", source: projectionEvidenceStore{ok: true}, ttl: ttl, want: HardwareEvidenceStateUnavailable},
		{name: "current verified evidence", source: projectionEvidenceStore{ok: true, generatedAt: now}, ttl: ttl, want: HardwareEvidenceStateVerified},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := hardwareEvidenceState(ctx, "provider-a", tc.source, tc.ttl); got != tc.want {
				t.Fatalf("hardware evidence state = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestRecentWorkEligibilityFactsPreserveMirrorUncertainty(t *testing.T) {
	now := time.Date(2026, time.September, 10, 12, 0, 0, 0, time.UTC)

	if reasons, unavailable := recentWorkEligibilityFacts(&now, nil); unavailable || len(reasons) != 1 || reasons[0] != ReasonEarningVerifiedWork {
		t.Fatalf("verified observation = reasons %v unavailable %v", reasons, unavailable)
	}
	if reasons, unavailable := recentWorkEligibilityFacts(nil, nil); !unavailable || reasons != nil {
		t.Fatalf("no mirror watermark = reasons %v unavailable %v", reasons, unavailable)
	}
	if reasons, unavailable := recentWorkEligibilityFacts(nil, errors.New("mirror unavailable")); !unavailable || reasons != nil {
		t.Fatalf("mirror failure = reasons %v unavailable %v", reasons, unavailable)
	}
}

func TestRewardProjectionStaleAfterIsShortAndCannotOutliveEvidence(t *testing.T) {
	now := time.Date(2026, time.September, 10, 12, 0, 0, 0, time.UTC)
	if got := rewardProjectionStaleAfter(now, nil, nil); !got.Equal(now.Add(rewardProjectionFreshnessWindow)) {
		t.Fatalf("default stale after = %v, want %v", got, now.Add(rewardProjectionFreshnessWindow))
	}
	nearBoundary := now.Add(-RecentVerifiedWorkWindow + 10*time.Second)
	if got := rewardProjectionStaleAfter(now, &nearBoundary, nil); !got.Equal(now.Add(10 * time.Second)) {
		t.Fatalf("recent-work stale after = %v, want %v", got, now.Add(10*time.Second))
	}
	hardwareExpiry := now.Add(5 * time.Second)
	if got := rewardProjectionStaleAfter(now, nil, &hardwareExpiry); !got.Equal(hardwareExpiry) {
		t.Fatalf("hardware stale after = %v, want %v", got, hardwareExpiry)
	}
}

func TestRecentWorkDoesNotChangeWithdrawableBalance(t *testing.T) {
	now := time.Now().UTC()
	reasons, telemetryUnavailable := recentWorkEligibilityFacts(&now, nil)
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         "5",
		WithdrawableMALIBU:    "5",
		TrustTier:             TierTrusted,
		WalletBound:           true,
		VerifiedReceiptCount:  minVerifiedReceipts,
		AppAttested:           true,
		HardwareEvidenceState: HardwareEvidenceStateVerified,
		ComputeIntegrityState: ComputeIntegrityStateVerified,
		LocalRuntimeReasons:   reasons,
		TelemetryUnavailable:  telemetryUnavailable,
	})
	if got.EarningState != EarningStateEarning {
		t.Fatalf("earning state = %q, want %q", got.EarningState, EarningStateEarning)
	}
	if got.WithdrawalState != WithdrawalStateWithdrawable {
		t.Fatalf("withdrawal state = %q, want %q", got.WithdrawalState, WithdrawalStateWithdrawable)
	}
}

func TestProjectionUsesTrustCriteriaTierAcrossBalanceAndEligibilityFacts(t *testing.T) {
	holdReasons := []string{HoldDemotionCooldown}
	ledgerBalance := AccrualBalance{
		AccruedMALIBU:       "7.50000000",
		WithdrawableMALIBU:  "2.50000000",
		HeldMALIBU:          "5.00000000",
		TrustTier:           TierProvisional,
		HoldReasons:         holdReasons,
		ProviderDailyCapped: true,
		ProviderDailyCap:    25,
		WalletDailyCap:      100,
	}
	trust := TrustCriteriaStatus{TrustTier: TierTrusted}

	balance := balanceWithAuthoritativeTrustTier(ledgerBalance, trust.TrustTier)
	facts := MalibuRewardEligibilityFacts{
		AccruedMALIBU:         balance.AccruedMALIBU,
		WithdrawableMALIBU:    balance.WithdrawableMALIBU,
		HeldMALIBU:            balance.HeldMALIBU,
		TrustTier:             balance.TrustTier,
		WithdrawalHoldReasons: balance.HoldReasons,
		ProviderDailyCapped:   balance.ProviderDailyCapped,
	}
	bundle := ProviderRewardProjection{Balance: balance, Trust: trust, Eligibility: BuildMalibuRewardEligibility(facts)}

	if bundle.Balance.TrustTier != TierTrusted || facts.TrustTier != TierTrusted || bundle.Trust.TrustTier != TierTrusted {
		t.Fatalf("effective trust tiers disagree: balance=%q facts=%q trust=%q", bundle.Balance.TrustTier, facts.TrustTier, bundle.Trust.TrustTier)
	}
	if bundle.Balance.AccruedMALIBU != ledgerBalance.AccruedMALIBU ||
		bundle.Balance.WithdrawableMALIBU != ledgerBalance.WithdrawableMALIBU ||
		bundle.Balance.HeldMALIBU != ledgerBalance.HeldMALIBU ||
		bundle.Balance.ProviderDailyCapped != ledgerBalance.ProviderDailyCapped ||
		bundle.Balance.ProviderDailyCap != ledgerBalance.ProviderDailyCap ||
		bundle.Balance.WalletDailyCap != ledgerBalance.WalletDailyCap {
		t.Fatalf("normalization changed ledger balance: got=%+v want=%+v", bundle.Balance, ledgerBalance)
	}
	if len(bundle.Balance.HoldReasons) != 1 || bundle.Balance.HoldReasons[0] != HoldDemotionCooldown {
		t.Fatalf("normalization changed ledger holds: %v", bundle.Balance.HoldReasons)
	}
	if bundle.Eligibility.WithdrawalState != WithdrawalStateCapped {
		t.Fatalf("eligibility did not retain normalized balance facts: %+v", bundle.Eligibility)
	}
}

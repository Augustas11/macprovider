package rewards

import (
	"database/sql"
	"reflect"
	"testing"
	"time"
)

func TestClassifyHoldReasonsSeparatesLiveFromRetainedTrustHolds(t *testing.T) {
	now := time.Date(2026, 10, 18, 0, 40, 0, 0, time.UTC)
	expired := sql.NullTime{Time: time.Date(2026, 10, 10, 16, 54, 0, 0, time.UTC), Valid: true}
	running := sql.NullTime{Time: now.Add(time.Hour), Valid: true}
	all := []string{HoldPerWalletDailyCap, ReasonHeldEpochDisposition, HoldDemotionCooldown, HoldTrustTierProvisional}

	cases := []struct {
		name             string
		tier             string
		cooldown         sql.NullTime
		active, retained []string
	}{
		{"provisional, cooldown elapsed", TierProvisional, expired,
			[]string{HoldPerWalletDailyCap, ReasonHeldEpochDisposition, HoldTrustTierProvisional},
			[]string{HoldDemotionCooldown}},
		{"provisional, cooldown running", TierProvisional, running, all, nil},
		{"provisional, never demoted", TierProvisional, sql.NullTime{},
			[]string{HoldPerWalletDailyCap, ReasonHeldEpochDisposition, HoldTrustTierProvisional},
			[]string{HoldDemotionCooldown}},
		{"trusted", TierTrusted, sql.NullTime{},
			[]string{HoldPerWalletDailyCap, ReasonHeldEpochDisposition},
			[]string{HoldDemotionCooldown, HoldTrustTierProvisional}},
	}
	for _, tc := range cases {
		active, retained := classifyHoldReasons(all, tc.tier, tc.cooldown, now)
		if !reflect.DeepEqual(active, tc.active) || !reflect.DeepEqual(retained, tc.retained) {
			t.Errorf("%s: active=%v retained=%v, want %v / %v", tc.name, active, retained, tc.active, tc.retained)
		}
	}
}

// The 2026-10-18 audit case: rows held by an August demotion cooldown that
// ended on 10 Oct must not be reported as a running cooldown.
func TestElapsedCooldownRowsAreRetainedNotACurrentCooldown(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         "257.03",
		WithdrawableMALIBU:    "43.49",
		HeldMALIBU:            "213.54",
		TrustTier:             TierProvisional,
		WithdrawalHoldReasons: []string{HoldTrustTierProvisional},
		RetainedTrustHold:     true,
		WalletBound:           true,
		VerifiedReceiptCount:  12587,
		HardwareEvidenceState: HardwareEvidenceStateMissing,
	})
	if containsReason(got.Reasons, ReasonHeldDemotionCooldown) {
		t.Fatalf("reasons = %v, must not claim a running demotion cooldown", got.Reasons)
	}
	for _, want := range []string{ReasonHeldProvisionalTrustTier, ReasonHeldRetainedTrustHold, ReasonHardwareEvidenceMissingOrExpired} {
		if !containsReason(got.Reasons, want) {
			t.Fatalf("reasons = %v, want %s", got.Reasons, want)
		}
	}
	if got.WithdrawalState != WithdrawalStateHeld {
		t.Fatalf("withdrawal_state = %q, want held", got.WithdrawalState)
	}
	if got.PrimaryReason != ReasonHardwareEvidenceMissingOrExpired {
		t.Fatalf("primary_reason = %q, want the actionable hardware blocker", got.PrimaryReason)
	}
}

func TestTrustedProviderRetainedHoldsStayHeld(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         "257.03",
		WithdrawableMALIBU:    "43.49",
		HeldMALIBU:            "213.54",
		TrustTier:             TierTrusted,
		RetainedTrustHold:     true,
		WalletBound:           true,
		VerifiedReceiptCount:  12587,
		HardwareEvidenceState: HardwareEvidenceStateVerified,
		ComputeIntegrityState: ComputeIntegrityStateVerified,
	})
	if got.WithdrawalState != WithdrawalStateHeld || got.PrimaryReason != ReasonHeldRetainedTrustHold {
		t.Fatalf("got %+v, want held / %s", got, ReasonHeldRetainedTrustHold)
	}
	if got.EarningState == EarningStateHeld {
		t.Fatalf("earning_state = held; retained rows must not block new accrual")
	}
}

func TestRetainedHoldWithoutHeldBalanceAddsNoReason(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:      "10",
		WithdrawableMALIBU: "10",
		HeldMALIBU:         "0",
		TrustTier:          TierTrusted,
		RetainedTrustHold:  true,
		WalletBound:        true,
	})
	if containsReason(got.Reasons, ReasonHeldRetainedTrustHold) {
		t.Fatalf("reasons = %v, want no retained hold without held MALIBU", got.Reasons)
	}
}

func TestBuildTrustProgressEarliestPromotion(t *testing.T) {
	now := time.Date(2026, 10, 18, 0, 40, 0, 0, time.UTC)
	cooldown := time.Date(2026, 10, 10, 16, 54, 0, 0, time.UTC)
	uptimeSince := time.Date(2026, 10, 16, 3, 52, 0, 0, time.UTC)
	pairSince := time.Date(2026, 10, 19, 4, 45, 0, 0, time.UTC)
	ptr := func(t time.Time) *time.Time { return &t }

	cases := []struct {
		name  string
		trust TrustCriteriaStatus
		want  *time.Time
	}{
		{
			name: "audit case: E1 met, A1 window running, cooldown elapsed",
			trust: TrustCriteriaStatus{TrustTier: TierProvisional, DemotionCooldownUntil: &cooldown,
				UptimeOKSince: &uptimeSince, VerifiedReceiptCount: 12587,
				EconomicSatisfied: []string{CriterionE1Receipts}, AdditionalSatisfied: []string{CriterionE1Receipts}},
			want: ptr(uptimeSince.Add(72 * time.Hour).Add(72 * time.Hour)),
		},
		{
			name: "pair held after demotion",
			trust: TrustCriteriaStatus{TrustTier: TierProvisional, DemotionCooldownUntil: &cooldown,
				UptimeOKSince: &uptimeSince, UnlockPairOKSince: &pairSince,
				EconomicSatisfied: []string{CriterionE1Receipts}, AdditionalSatisfied: []string{CriterionE1Receipts, CriterionUptime72h}},
			want: ptr(pairSince.Add(72 * time.Hour)),
		},
		{
			name: "pair met, never demoted: next evaluation",
			trust: TrustCriteriaStatus{TrustTier: TierProvisional,
				EconomicSatisfied: []string{CriterionE1Receipts}, AdditionalSatisfied: []string{CriterionE1Receipts, CriterionUptime72h}},
			want: ptr(now),
		},
		{
			name: "E1 met, A1 window running, never demoted",
			trust: TrustCriteriaStatus{TrustTier: TierProvisional, UptimeOKSince: &uptimeSince,
				EconomicSatisfied: []string{CriterionE1Receipts}, AdditionalSatisfied: []string{CriterionE1Receipts}},
			want: ptr(uptimeSince.Add(72 * time.Hour)),
		},
		{
			name:  "receipts still needed: no estimate",
			trust: TrustCriteriaStatus{TrustTier: TierProvisional, UptimeOKSince: &uptimeSince, VerifiedReceiptCount: 12},
		},
		{
			name: "no current heartbeat: no estimate",
			trust: TrustCriteriaStatus{TrustTier: TierProvisional, DemotionCooldownUntil: &cooldown,
				EconomicSatisfied: []string{CriterionE1Receipts}, AdditionalSatisfied: []string{CriterionE1Receipts}},
		},
		{
			name:  "trusted: nothing to estimate",
			trust: TrustCriteriaStatus{TrustTier: TierTrusted, EconomicSatisfied: []string{CriterionE1Receipts}, AdditionalSatisfied: []string{CriterionUptime72h}},
		},
	}
	for _, tc := range cases {
		got := BuildTrustProgress(tc.trust, now)
		switch {
		case tc.want == nil && got.EarliestPromotionAt != nil:
			t.Errorf("%s: earliest = %v, want none", tc.name, *got.EarliestPromotionAt)
		case tc.want != nil && (got.EarliestPromotionAt == nil || !got.EarliestPromotionAt.Equal(*tc.want)):
			t.Errorf("%s: earliest = %v, want %v", tc.name, got.EarliestPromotionAt, *tc.want)
		}
	}
}

func TestBuildTrustProgressReportsEvaluatorWindows(t *testing.T) {
	now := time.Date(2026, 10, 18, 0, 40, 0, 0, time.UTC)
	cooldown := time.Date(2026, 10, 10, 16, 54, 0, 0, time.UTC)
	got := BuildTrustProgress(TrustCriteriaStatus{
		TrustTier:             TierProvisional,
		DemotionCooldownUntil: &cooldown,
		VerifiedReceiptCount:  12587,
		EconomicSatisfied:     []string{CriterionE1Receipts},
		AdditionalSatisfied:   []string{CriterionE1Receipts},
	}, now)
	if got.DemotionCooldownActive {
		t.Fatal("cooldown elapsed on 10 Oct; must not be reported active")
	}
	if !got.RequalificationRequired {
		t.Fatal("a demoted provider must requalify for 72 h")
	}
	if got.UptimeRequiredSeconds != 72*3600 || got.RequalificationWindowSeconds != 72*3600 {
		t.Fatalf("windows = %d / %d", got.UptimeRequiredSeconds, got.RequalificationWindowSeconds)
	}
	if got.RequiredReceiptCount != 100 || !reflect.DeepEqual(got.CriteriaMet, []string{CriterionE1Receipts}) {
		t.Fatalf("receipts/criteria = %d %v", got.RequiredReceiptCount, got.CriteriaMet)
	}
}

func TestEmissionActiveRequiresAnIssuanceWorker(t *testing.T) {
	cases := []struct {
		cfg  Config
		want bool
	}{
		{Config{}, false},
		{Config{Enabled: true}, false},
		{Config{BootstrapTickEnabled: true}, false},
		{Config{Enabled: true, EpochEnabled: true}, false},
		{Config{Enabled: true, BootstrapTickEnabled: true}, true},
		{Config{Enabled: true, UsefulWorkEnabled: true}, true},
		{Config{Enabled: true, UsefulWorkEnabled: true, EpochEnabled: true}, false},
	}
	for _, tc := range cases {
		if got := tc.cfg.EmissionActive(); got != tc.want {
			t.Errorf("%+v: EmissionActive = %v, want %v", tc.cfg, got, tc.want)
		}
	}
}

package rewards

import "testing"

func TestRewardEligibilityHeldWinsOverTelemetryUnavailableForWithdrawal(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         "12.50000000",
		WithdrawableMALIBU:    "0",
		HeldMALIBU:            "12.50000000",
		TrustTier:             TierProvisional,
		WithdrawalHoldReasons: []string{HoldTrustTierProvisional},
		WalletBound:           true,
		VerifiedReceiptCount:  minVerifiedReceipts,
		AppAttested:           true,
		TelemetryUnavailable:  true,
	})

	if got.SchemaVersion != MalibuRewardEligibilitySchemaV1 {
		t.Fatalf("schema = %q", got.SchemaVersion)
	}
	if got.WithdrawalState != WithdrawalStateHeld {
		t.Fatalf("withdrawal_state = %q, want %q", got.WithdrawalState, WithdrawalStateHeld)
	}
	if got.PrimaryReason != ReasonHeldProvisionalTrustTier {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonHeldProvisionalTrustTier)
	}
	if !containsReason(got.Reasons, ReasonTelemetryUnavailable) {
		t.Fatalf("reasons = %v, want telemetry reason retained", got.Reasons)
	}
}

func TestRewardEligibilityWalletCapWinsOverProvisionalHold(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         "25.00000000",
		WithdrawableMALIBU:    "0",
		HeldMALIBU:            "25.00000000",
		TrustTier:             TierProvisional,
		WithdrawalHoldReasons: []string{HoldTrustTierProvisional, HoldPerWalletDailyCap},
		WalletBound:           true,
		VerifiedReceiptCount:  minVerifiedReceipts,
		AppAttested:           true,
	})

	if got.EarningState != EarningStateCapped {
		t.Fatalf("earning_state = %q, want %q", got.EarningState, EarningStateCapped)
	}
	if got.WithdrawalState != WithdrawalStateCapped {
		t.Fatalf("withdrawal_state = %q, want %q", got.WithdrawalState, WithdrawalStateCapped)
	}
	if got.PrimaryReason != ReasonHeldWalletDailyCap {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonHeldWalletDailyCap)
	}
}

func TestRewardEligibilityComputeBlockedWinsOverPending(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         "0",
		WithdrawableMALIBU:    "0",
		HeldMALIBU:            "0",
		TrustTier:             TierTrusted,
		WalletBound:           true,
		VerifiedReceiptCount:  minVerifiedReceipts,
		AppAttested:           true,
		ComputeIntegrityState: "blocked:manual_review_required",
		LocalRuntimeReasons:   []string{ReasonEarningVerifiedWork},
	})

	if got.EarningState != EarningStateIneligible {
		t.Fatalf("earning_state = %q, want %q", got.EarningState, EarningStateIneligible)
	}
	if got.PrimaryReason != ReasonComputeIntegrityBlocked {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonComputeIntegrityBlocked)
	}
	if containsReason(got.Reasons, ReasonComputeIntegrityPending) {
		t.Fatalf("reasons = %v, blocked state must not also report pending", got.Reasons)
	}
}

func TestRewardEligibilityComputePendingBeatsEarningWork(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         "0",
		WithdrawableMALIBU:    "0",
		HeldMALIBU:            "0",
		TrustTier:             TierTrusted,
		WalletBound:           true,
		VerifiedReceiptCount:  minVerifiedReceipts,
		AppAttested:           true,
		ComputeIntegrityState: ComputeIntegrityStatePending,
		LocalRuntimeReasons:   []string{ReasonEarningVerifiedWork},
	})

	if got.EarningState != EarningStateUnavailable {
		t.Fatalf("earning_state = %q, want %q", got.EarningState, EarningStateUnavailable)
	}
	if got.PrimaryReason != ReasonComputeIntegrityPending {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonComputeIntegrityPending)
	}
}

func TestRewardEligibilityComputeUnavailableBeatsNoBalance(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:          "0",
		WithdrawableMALIBU:     "0",
		HeldMALIBU:             "0",
		TrustTier:              TierTrusted,
		WalletBound:            true,
		VerifiedReceiptCount:   minVerifiedReceipts,
		AppAttested:            true,
		ComputeIntegrityState:  ComputeIntegrityStateUnknown,
		HardwareEvidenceState:  HardwareEvidenceStateVerified,
		LocalRuntimeReasons:    []string{ReasonEligibleIdleNoWork},
		TelemetryUnavailable:   false,
		ProviderTokenUntrusted: false,
	})

	if got.EarningState != EarningStateUnavailable {
		t.Fatalf("earning_state = %q, want %q", got.EarningState, EarningStateUnavailable)
	}
	if got.PrimaryReason != ReasonComputeIntegrityUnavailable {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonComputeIntegrityUnavailable)
	}
}

func TestRewardEligibilityEndpointDefaultsUnwiredSourcesUnavailable(t *testing.T) {
	got := RewardEligibilityFromBalanceAndTrust(
		AccrualBalance{
			AccruedMALIBU:      "0",
			WithdrawableMALIBU: "0",
			HeldMALIBU:         "0",
			TrustTier:          TierTrusted,
		},
		TrustCriteriaStatus{
			WalletBound:          true,
			VerifiedReceiptCount: minVerifiedReceipts,
			AppAttested:          true,
		},
	)

	if got.EarningState != EarningStateUnavailable {
		t.Fatalf("earning_state = %q, want %q", got.EarningState, EarningStateUnavailable)
	}
	if got.PrimaryReason != ReasonComputeIntegrityUnavailable {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonComputeIntegrityUnavailable)
	}
	if !containsReason(got.Reasons, ReasonHardwareEvidenceUnavailable) {
		t.Fatalf("reasons = %v, want hardware unavailable", got.Reasons)
	}
}

func TestRewardEligibilityEarningWorkCanBePrimary(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:        "0",
		WithdrawableMALIBU:   "0",
		HeldMALIBU:           "0",
		TrustTier:            TierTrusted,
		WalletBound:          true,
		VerifiedReceiptCount: minVerifiedReceipts,
		AppAttested:          true,
		LocalRuntimeReasons:  []string{ReasonEarningVerifiedWork},
	})

	if got.EarningState != EarningStateEarning {
		t.Fatalf("earning_state = %q, want %q", got.EarningState, EarningStateEarning)
	}
	if got.PrimaryReason != ReasonEarningVerifiedWork {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonEarningVerifiedWork)
	}
}

func TestRewardEligibilityTrustedBalanceIsWithdrawable(t *testing.T) {
	got := BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:        "5.00000000",
		WithdrawableMALIBU:   "5.00000000",
		HeldMALIBU:           "0",
		TrustTier:            TierTrusted,
		WalletBound:          true,
		VerifiedReceiptCount: minVerifiedReceipts,
		AppAttested:          true,
	})

	if got.EarningState != EarningStateEligibleIdle {
		t.Fatalf("earning_state = %q, want %q", got.EarningState, EarningStateEligibleIdle)
	}
	if got.WithdrawalState != WithdrawalStateWithdrawable {
		t.Fatalf("withdrawal_state = %q, want %q", got.WithdrawalState, WithdrawalStateWithdrawable)
	}
	if got.PrimaryReason != ReasonWithdrawableBalanceAvailable {
		t.Fatalf("primary_reason = %q, want %q", got.PrimaryReason, ReasonWithdrawableBalanceAvailable)
	}
}

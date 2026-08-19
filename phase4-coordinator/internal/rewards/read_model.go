package rewards

import "strconv"

const MalibuRewardEligibilitySchemaV1 = "malibu_reward_eligibility.v1"

const (
	EarningStateEarning      = "earning"
	EarningStateEligibleIdle = "eligible_idle"
	EarningStateHeld         = "held"
	EarningStateCapped       = "capped"
	EarningStateIneligible   = "ineligible"
	EarningStateUnavailable  = "unavailable"
)

const (
	WithdrawalStateWithdrawable = "withdrawable"
	WithdrawalStateHeld         = "held"
	WithdrawalStateCapped       = "capped"
	WithdrawalStateIneligible   = "ineligible"
	WithdrawalStateUnavailable  = "unavailable"
)

const (
	ReasonEarningVerifiedWork              = "earning_verified_work"
	ReasonEligibleIdleNoWork               = "eligible_idle_no_work"
	ReasonHeldProvisionalTrustTier         = "held_provisional_trust_tier"
	ReasonHeldProviderDailyCap             = "held_provider_daily_cap"
	ReasonHeldWalletDailyCap               = "held_wallet_daily_cap"
	ReasonHeldDemotionCooldown             = "held_demotion_cooldown"
	ReasonHeldEpochDisposition             = "held_epoch_disposition"
	ReasonExcludedEpochDisposition         = "excluded_epoch_disposition"
	ReasonBurnedOrRetiredEpochDisposition  = "burned_or_retired_epoch_disposition"
	ReasonWithdrawableBalanceAvailable     = "withdrawable_balance_available"
	ReasonWithdrawableNoBalance            = "withdrawable_no_balance"
	ReasonMissingWalletBinding             = "missing_wallet_binding"
	ReasonInsufficientVerifiedReceipts     = "insufficient_verified_receipts"
	ReasonAppAttestationMissing            = "app_attestation_missing"
	ReasonHardwareEvidenceUnavailable      = "hardware_evidence_unavailable"
	ReasonHardwareEvidenceMissingOrExpired = "hardware_evidence_missing_or_expired"
	ReasonComputeIntegrityUnavailable      = "compute_integrity_unavailable"
	ReasonComputeIntegrityPending          = "compute_integrity_pending"
	ReasonComputeIntegrityBlocked          = "compute_integrity_blocked"
	ReasonProviderTokenUntrusted           = "provider_token_untrusted"
	ReasonLocalOnBattery                   = "local_on_battery"
	ReasonLocalThermalPressure             = "local_thermal_pressure"
	ReasonModelNotReady                    = "model_not_ready"
	ReasonTelemetryUnavailable             = "telemetry_unavailable"
)

const (
	ComputeIntegrityStateUnknown                 = "unknown"
	ComputeIntegrityStatePending                 = "pending"
	ComputeIntegrityStateVerified                = "verified"
	ComputeIntegrityStateWarn                    = "warn"
	ComputeIntegrityStateExpired                 = "expired"
	ComputeIntegrityStateQuarantinedComputeDrift = "quarantined_compute_drift"
)

const (
	HardwareEvidenceStateUnavailable = "unavailable"
	HardwareEvidenceStateVerified    = "verified"
	HardwareEvidenceStateMissing     = "missing"
	HardwareEvidenceStateExpired     = "expired"
)

// MalibuRewardEligibilityReadModel is the provider-facing, coordinator-owned
// reason model returned by GET /v1/provider/malibu-accrual.
type MalibuRewardEligibilityReadModel struct {
	SchemaVersion   string   `json:"schema_version"`
	EarningState    string   `json:"earning_state"`
	WithdrawalState string   `json:"withdrawal_state"`
	PrimaryReason   string   `json:"primary_reason"`
	Reasons         []string `json:"reasons"`
}

// MalibuRewardEligibilityFacts contains policy facts from their owning systems.
// The accrual endpoint currently fills the ledger/trust subset; the remaining
// fields are extension points for facts reported to the reward owner by
// runtime-health, hardware-evidence, and compute-integrity owners without
// changing the response shape.
type MalibuRewardEligibilityFacts struct {
	AccruedMALIBU          string
	WithdrawableMALIBU     string
	HeldMALIBU             string
	TrustTier              string
	WithdrawalHoldReasons  []string
	ProviderDailyCapped    bool
	WalletBound            bool
	VerifiedReceiptCount   int
	AppAttested            bool
	LocalRuntimeReasons    []string
	TelemetryUnavailable   bool
	HardwareEvidenceState  string
	ComputeIntegrityState  string
	ProviderTokenUntrusted bool
}

func RewardEligibilityFromBalanceAndTrust(bal AccrualBalance, trust TrustCriteriaStatus) MalibuRewardEligibilityReadModel {
	return rewardEligibilityFromBalanceTrustAndWallet(bal, trust, trust.WalletBound)
}

func rewardEligibilityFromBalanceTrustAndWallet(bal AccrualBalance, trust TrustCriteriaStatus, walletBound bool) MalibuRewardEligibilityReadModel {
	return BuildMalibuRewardEligibility(MalibuRewardEligibilityFacts{
		AccruedMALIBU:         bal.AccruedMALIBU,
		WithdrawableMALIBU:    bal.WithdrawableMALIBU,
		HeldMALIBU:            bal.HeldMALIBU,
		TrustTier:             bal.TrustTier,
		WithdrawalHoldReasons: bal.HoldReasons,
		ProviderDailyCapped:   bal.ProviderDailyCapped,
		WalletBound:           walletBound,
		VerifiedReceiptCount:  trust.VerifiedReceiptCount,
		AppAttested:           trust.AppAttested,
		HardwareEvidenceState: HardwareEvidenceStateUnavailable,
		ComputeIntegrityState: ComputeIntegrityStateUnknown,
	})
}

func BuildMalibuRewardEligibility(f MalibuRewardEligibilityFacts) MalibuRewardEligibilityReadModel {
	f = normalizeRewardEligibilityFacts(f)
	reasons := orderedRewardReasons(f)
	earningState := earningStateFor(f, reasons)
	withdrawalState := withdrawalStateFor(f, reasons)
	primary := primaryRewardReason(withdrawalState, earningState, reasons)
	return MalibuRewardEligibilityReadModel{
		SchemaVersion:   MalibuRewardEligibilitySchemaV1,
		EarningState:    earningState,
		WithdrawalState: withdrawalState,
		PrimaryReason:   primary,
		Reasons:         reasons,
	}
}

func normalizeRewardEligibilityFacts(f MalibuRewardEligibilityFacts) MalibuRewardEligibilityFacts {
	if f.ComputeIntegrityState == "" {
		f.ComputeIntegrityState = ComputeIntegrityStateUnknown
	}
	if f.HardwareEvidenceState == "" {
		f.HardwareEvidenceState = HardwareEvidenceStateUnavailable
	}
	return f
}

func orderedRewardReasons(f MalibuRewardEligibilityFacts) []string {
	out := make([]string, 0, 8)
	add := func(reason string) {
		if reason == "" {
			return
		}
		for _, existing := range out {
			if existing == reason {
				return
			}
		}
		out = append(out, reason)
	}

	if f.ProviderTokenUntrusted {
		add(ReasonProviderTokenUntrusted)
	}
	switch {
	case f.ComputeIntegrityState == ComputeIntegrityStateVerified:
	case computeIntegrityBlocked(f.ComputeIntegrityState):
		add(ReasonComputeIntegrityBlocked)
	case f.ComputeIntegrityState == ComputeIntegrityStatePending ||
		f.ComputeIntegrityState == ComputeIntegrityStateWarn:
		add(ReasonComputeIntegrityPending)
	case f.ComputeIntegrityState == ComputeIntegrityStateUnknown ||
		f.ComputeIntegrityState == ComputeIntegrityStateExpired:
		add(ReasonComputeIntegrityUnavailable)
	default:
		add(ReasonComputeIntegrityUnavailable)
	}
	switch f.HardwareEvidenceState {
	case HardwareEvidenceStateVerified:
	case HardwareEvidenceStateMissing, HardwareEvidenceStateExpired:
		add(ReasonHardwareEvidenceMissingOrExpired)
	case HardwareEvidenceStateUnavailable:
		add(ReasonHardwareEvidenceUnavailable)
	default:
		add(ReasonHardwareEvidenceUnavailable)
	}

	for _, hold := range f.WithdrawalHoldReasons {
		switch hold {
		case HoldPerWalletDailyCap:
			add(ReasonHeldWalletDailyCap)
		case HoldDemotionCooldown:
			add(ReasonHeldDemotionCooldown)
		case HoldTrustTierProvisional:
			add(ReasonHeldProvisionalTrustTier)
		case ReasonHeldEpochDisposition:
			add(ReasonHeldEpochDisposition)
		case ReasonExcludedEpochDisposition:
			add(ReasonExcludedEpochDisposition)
		case ReasonBurnedOrRetiredEpochDisposition:
			add(ReasonBurnedOrRetiredEpochDisposition)
		}
	}
	if f.ProviderDailyCapped {
		add(ReasonHeldProviderDailyCap)
	}

	if !f.WalletBound {
		add(ReasonMissingWalletBinding)
	}
	if f.VerifiedReceiptCount < minVerifiedReceipts {
		add(ReasonInsufficientVerifiedReceipts)
	}
	if !f.AppAttested {
		add(ReasonAppAttestationMissing)
	}

	for _, reason := range f.LocalRuntimeReasons {
		switch reason {
		case ReasonLocalOnBattery, ReasonLocalThermalPressure, ReasonModelNotReady,
			ReasonEarningVerifiedWork, ReasonEligibleIdleNoWork:
			add(reason)
		}
	}
	if f.TelemetryUnavailable {
		add(ReasonTelemetryUnavailable)
	}

	if decimalPositive(f.WithdrawableMALIBU) {
		add(ReasonWithdrawableBalanceAvailable)
	} else if !decimalPositive(f.HeldMALIBU) {
		add(ReasonWithdrawableNoBalance)
	}
	return out
}

func earningStateFor(f MalibuRewardEligibilityFacts, reasons []string) string {
	if containsReason(reasons, ReasonProviderTokenUntrusted) ||
		containsReason(reasons, ReasonExcludedEpochDisposition) ||
		containsReason(reasons, ReasonBurnedOrRetiredEpochDisposition) ||
		containsReason(reasons, ReasonComputeIntegrityBlocked) ||
		containsReason(reasons, ReasonHardwareEvidenceMissingOrExpired) {
		return EarningStateIneligible
	}
	if containsReason(reasons, ReasonComputeIntegrityPending) ||
		containsReason(reasons, ReasonComputeIntegrityUnavailable) ||
		containsReason(reasons, ReasonHardwareEvidenceUnavailable) {
		return EarningStateUnavailable
	}
	if containsReason(reasons, ReasonLocalOnBattery) ||
		containsReason(reasons, ReasonLocalThermalPressure) ||
		containsReason(reasons, ReasonModelNotReady) {
		return EarningStateIneligible
	}
	if containsReason(reasons, ReasonHeldWalletDailyCap) ||
		containsReason(reasons, ReasonHeldProviderDailyCap) {
		return EarningStateCapped
	}
	if containsReason(reasons, ReasonHeldProvisionalTrustTier) ||
		containsReason(reasons, ReasonHeldDemotionCooldown) ||
		containsReason(reasons, ReasonHeldEpochDisposition) {
		return EarningStateHeld
	}
	if containsReason(reasons, ReasonEarningVerifiedWork) {
		return EarningStateEarning
	}
	if f.TelemetryUnavailable {
		return EarningStateUnavailable
	}
	return EarningStateEligibleIdle
}

func withdrawalStateFor(f MalibuRewardEligibilityFacts, reasons []string) string {
	if containsReason(reasons, ReasonProviderTokenUntrusted) {
		return WithdrawalStateIneligible
	}
	if containsReason(reasons, ReasonExcludedEpochDisposition) ||
		containsReason(reasons, ReasonBurnedOrRetiredEpochDisposition) {
		return WithdrawalStateIneligible
	}
	if containsReason(reasons, ReasonHeldWalletDailyCap) ||
		containsReason(reasons, ReasonHeldProviderDailyCap) {
		return WithdrawalStateCapped
	}
	if containsReason(reasons, ReasonHeldProvisionalTrustTier) ||
		containsReason(reasons, ReasonHeldDemotionCooldown) ||
		containsReason(reasons, ReasonHeldEpochDisposition) {
		return WithdrawalStateHeld
	}
	if containsReason(reasons, ReasonMissingWalletBinding) {
		return WithdrawalStateIneligible
	}
	if decimalPositive(f.WithdrawableMALIBU) {
		return WithdrawalStateWithdrawable
	}
	return WithdrawalStateIneligible
}

func primaryRewardReason(withdrawalState, earningState string, reasons []string) string {
	priority := []string{
		ReasonProviderTokenUntrusted,
		ReasonComputeIntegrityBlocked,
		ReasonComputeIntegrityPending,
		ReasonHeldWalletDailyCap,
		ReasonHeldProviderDailyCap,
		ReasonBurnedOrRetiredEpochDisposition,
		ReasonExcludedEpochDisposition,
		ReasonHeldEpochDisposition,
		ReasonHeldDemotionCooldown,
		ReasonHeldProvisionalTrustTier,
		ReasonMissingWalletBinding,
		ReasonComputeIntegrityUnavailable,
		ReasonHardwareEvidenceMissingOrExpired,
		ReasonHardwareEvidenceUnavailable,
		ReasonLocalOnBattery,
		ReasonLocalThermalPressure,
		ReasonModelNotReady,
		ReasonEarningVerifiedWork,
		ReasonWithdrawableBalanceAvailable,
		ReasonInsufficientVerifiedReceipts,
		ReasonAppAttestationMissing,
		ReasonTelemetryUnavailable,
		ReasonEligibleIdleNoWork,
		ReasonWithdrawableNoBalance,
	}
	for _, candidate := range priority {
		if containsReason(reasons, candidate) {
			return candidate
		}
	}
	if withdrawalState == WithdrawalStateWithdrawable {
		return ReasonWithdrawableBalanceAvailable
	}
	if earningState == EarningStateEligibleIdle {
		return ReasonEligibleIdleNoWork
	}
	return ReasonTelemetryUnavailable
}

func computeIntegrityBlocked(state string) bool {
	return state == ComputeIntegrityStateQuarantinedComputeDrift || hasBlockedPrefix(state)
}

func hasBlockedPrefix(state string) bool {
	const prefix = "blocked:"
	return len(state) > len(prefix) && state[:len(prefix)] == prefix
}

func containsReason(reasons []string, reason string) bool {
	for _, r := range reasons {
		if r == reason {
			return true
		}
	}
	return false
}

func decimalPositive(raw string) bool {
	if raw == "" {
		return false
	}
	v, err := strconv.ParseFloat(raw, 64)
	return err == nil && v > 0
}

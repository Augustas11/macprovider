package computeintegrity

// FR-1 enforce activation preconditions. enforce MUST refuse activation unless every
// precondition holds. Per §6.1 the v0.1 enforce path is maintainer-gated and not
// reachable at current beta supply: in particular the named stable-device/operator-
// identity authority does not yet exist for the shipped CLI track, so ActivationCheck
// returns a refusal for any realistic beta policy. This function makes that refusal
// explicit and testable rather than implicit.

// ActivationDeps carries the runtime facts an enforce activation decision reads.
type ActivationDeps struct {
	SPEC030PrimitivesExposed     bool // SPEC-030 auth/load-bound/support/TV primitives available
	SPEC022Enforce               bool // SPEC-022 verified_model_settlement is enforce for the coverage
	SPEC022CoverageSubset        bool // SPEC-036 coverage is a subset of SPEC-022 enforce coverage
	AllModelsSignedCatalog       bool
	TwoIndependentFreshRefs      bool // >=2 independent fresh references for every covered key
	SettlementStorageReady       bool
	BillingExcludesNonVerified   bool
	DisclosureApproved           bool // approved copy present, not stale, no forbidden claims
	AuditorBundlesAvailable      bool
	OperatorControlsReady        bool // FR-16 controls implemented
	StableIdentityAuthorityNamed bool // §6.1 hard prerequisite
	ApprovedCostModel            bool // FR-17
	// Calibration is the covered key's calibration validation result (nil => ready).
	CalibrationRefusals []string
}

// samplerStageEnforceable reports whether a sampler stage has a SPEC-036-defined
// provider-side capture and coherent normalization basis for v0.1 enforce (FR-1). v0.1
// enforce MUST refuse pre_temperature_logits and post_temperature_logits.
func samplerStageEnforceable(stage string) bool {
	return stage == SamplerStagePostSampler
}

// ttlAtLeastTwiceCadence reports the FR-1 gate that positive_state_freshness_ttl is at
// least twice the scheduled per-key canary cadence, so a single missed probe does not
// routinely expire payable state.
func ttlAtLeastTwiceCadence(p Policy) bool {
	if p.CanaryCadenceMinutes <= 0 {
		return false
	}
	return p.PositiveStateFreshnessTTLHrs*60 >= 2*p.CanaryCadenceMinutes
}

// ActivationCheck returns the list of FR-1 enforce-activation refusal reasons for a
// policy and its runtime dependencies. An empty result means enforce may activate; any
// non-empty result means enforce MUST be refused and the policy remains observe/
// warn-only. This is also the startup gate.
func ActivationCheck(p Policy, deps ActivationDeps) []string {
	var reasons []string
	add := func(cond bool, msg string) {
		if !cond {
			reasons = append(reasons, msg)
		}
	}
	if err := p.Validate(); err != nil {
		reasons = append(reasons, "policy invalid: "+err.Error())
	}
	// FR-1 load-bearing coverage/identity fields must be present so the authoritative
	// policy surface can prove an exact covered-route/key match; enforce refuses an
	// empty/underspecified policy.
	add(p.PolicyVersion != "", "policy_version missing")
	add(len(p.ModelIDs) > 0, "covered model_ids missing")
	add((p.TargetModelHash != "") != (p.SignedCatalogSelector != ""),
		"exactly one of target_model_hash / signed_catalog_selector must be set")
	add(p.TokenizerIdentity != "", "tokenizer_identity missing")
	add(len(p.Entrypoints) > 0, "covered entrypoints missing")
	add(len(p.SamplingProfiles) > 0, "covered sampling_profiles missing")
	add(p.ReferenceFaultCheckVersion != "", "reference_fault_check_version missing")
	add(p.HardwareRuntimeClass != "", "hardware_runtime_class missing")
	add(p.CorpusVersion != "", "corpus_version missing")
	add(p.ThresholdVersion != "", "threshold_version missing")
	add(p.DisclosureCopyVersion != "" && p.DisclosureCopyDigest != "", "disclosure copy binding missing")
	add(deps.SPEC030PrimitivesExposed, "SPEC-030 primitives not exposed")
	add(deps.SPEC022Enforce, "SPEC-022 is not in enforce for the covered coverage")
	add(deps.SPEC022CoverageSubset, "SPEC-036 coverage is not a subset of SPEC-022 enforce coverage")
	add(deps.AllModelsSignedCatalog, "not all covered models have signed catalog entries")
	add(deps.TwoIndependentFreshRefs, "fewer than two independent fresh trusted references for a covered key")
	add(samplerStageEnforceable(p.SamplerStage), "sampler stage has no defined v0.1 enforce capture/normalization")
	add(deps.SettlementStorageReady, "settlement storage cannot persist request-start state")
	add(deps.BillingExcludesNonVerified, "billing/payout does not exclude non-verified SPEC-022 outcomes")
	add(deps.DisclosureApproved, "disclosure surfaces are missing/stale or use forbidden claims")
	add(deps.AuditorBundlesAvailable, "signed third-party auditor bundles are unavailable")
	add(deps.OperatorControlsReady, "FR-16 operator/circuit-breaker/manual-review controls not implemented")
	add(deps.StableIdentityAuthorityNamed, "no named stable-device/operator-identity authority (§6.1)")
	add(deps.ApprovedCostModel, "no maintainer-approved FR-17 cost model")
	add(ttlAtLeastTwiceCadence(p), "positive_state_freshness_ttl is less than twice the canary cadence")
	if len(deps.CalibrationRefusals) > 0 {
		reasons = append(reasons, deps.CalibrationRefusals...)
	}
	return reasons
}

// CanActivateEnforce reports whether enforce may activate (no refusals).
func CanActivateEnforce(p Policy, deps ActivationDeps) bool {
	return len(ActivationCheck(p, deps)) == 0
}

// Package computeintegrity implements the coordinator-side SPEC-036
// Compute-Integrity Receipt Companion: an additive, coordinator-owned
// compute-integrity drift gate that sits on top of SPEC-022 paid settlement.
//
// SPEC-036 is a strictly subordinate AND-gate on SPEC-022: it holds no
// independent money authority and can only ever *narrow* creditability where
// SPEC-022 is itself enforcing. It maps provider next-token distribution drift
// (measured against coordinator-held trusted references) to SPEC-022
// outcome=quarantined, reason=compute_drift_quarantined. It never adds fields to
// SPEC-015 v0.4 receipts or usage.
//
// Per SPEC-036 §6.1 the v0.1 enforce path is maintainer-gated and not reachable
// at current beta supply; v0.1 primarily delivers observe/warn-only drift
// telemetry. This package implements the full gate so enforce activation is a
// policy+precondition decision, and it fails closed at every non-payable
// request-start condition.
package computeintegrity

// This file defines the SPEC-036 key algebra (FR-8, FR-10 §"State ownership").
//
// Three related keys are projected from a single canary/request identity:
//
//   - ComputeIntegrityKey — the full identity a canary result is labeled by.
//   - WindowKey           — owns positive measurement/verdict state
//     (unknown/pending/verified/warn/expired) and the rolling verdict window.
//     Obtained by projecting away provider_id/assigned_id.
//   - OverlayKey           — owns active quarantine/block state and the three
//     rolling accumulators. Obtained by projecting away provider_id/assigned_id
//     *and* target_generation, so a warm swap (which bumps target_generation)
//     cannot shed an active quarantine.
//
// ThresholdKey is the 8-tuple thresholds and calibration records are keyed by
// (FR-8); it is the WindowKey minus target_generation and the provider identity,
// i.e. it depends only on the measurement conditions, not on which provider or
// generation produced the canary.

// ComputeIntegrityKey is the full identity that labels a single canary result
// (FR-10). All other keys are deterministic projections of it.
type ComputeIntegrityKey struct {
	StableProviderIdentity string
	ProviderID             string
	AssignedID             string
	ModelID                string
	TargetModelHash        string
	TokenizerIdentity      string
	SamplerStage           string
	TargetGeneration       int64
	SamplingProfile        string
	CorpusVersion          string
	ThresholdVersion       string
	HardwareRuntimeClass   string
}

// WindowKey owns positive measurement/verdict state and the rolling verdict
// window (FR-10). It projects away the concrete provider/assigned identity but
// retains target_generation, so a generation boundary starts a fresh positive
// window (a positive state never authorizes across a generation boundary).
// hardware_runtime_class is NOT a WindowKey field: FR-8 pins exactly one class per
// covered key, so the class is functionally determined by the other dimensions and is
// a policy invariant, not a key discriminator (it is bound instead via the FR-4
// hardware_runtime_class_digest capture and the FR-12 hardware_class_changed expiry).
type WindowKey struct {
	StableProviderIdentity string
	ModelID                string
	TargetModelHash        string
	TokenizerIdentity      string
	SamplerStage           string
	TargetGeneration       int64
	SamplingProfile        string
	CorpusVersion          string
	ThresholdVersion       string
}

// OverlayKey owns active quarantine_compute_drift/blocked:<reason> state and the
// three rolling accumulators (quarantine-candidate window count, 24h
// abusive-inconclusive count, 24h onboarding-failure count) (FR-10, §3). It is the
// WindowKey minus target_generation, so an assigned_id/generation churn cannot reset
// accumulated risk for the same stable identity + measurement conditions. Like the
// window key it omits hardware_runtime_class (a per-key policy invariant, FR-8).
type OverlayKey struct {
	StableProviderIdentity string
	ModelID                string
	TargetModelHash        string
	TokenizerIdentity      string
	SamplerStage           string
	SamplingProfile        string
	CorpusVersion          string
	ThresholdVersion       string
}

// ThresholdKey is the 8-tuple thresholds and calibration records are keyed by
// (FR-8). It depends only on the measurement conditions, so a reference or
// threshold of one hardware_runtime_class never authorizes or quarantines a
// provider of another class.
type ThresholdKey struct {
	ModelID              string
	TargetModelHash      string
	TokenizerIdentity    string
	SamplerStage         string
	SamplingProfile      string
	CorpusVersion        string
	ThresholdVersion     string
	HardwareRuntimeClass string
}

// SwapLaunderingScope is the higher-level swap-laundering overlay scope
// (stable_provider_identity, model_id) — spanning ALL hashes/tokenizers/generations/
// profiles for that provider and model (FR-12). A blocked:swap_laundering_suspected
// block recorded here therefore follows the provider across any artifact churn.
type SwapLaunderingScope struct {
	StableProviderIdentity string
	ModelID                string
}

// TombstoneScope is the narrower adverse-state lineage tombstone scope
// (stable_provider_identity, model_id, target_model_hash, tokenizer_identity,
// sampler_stage) written on a corpus/threshold rotation over an active adverse overlay
// (FR-10 clear rule). It deliberately omits corpus_version and threshold_version so an
// operator corpus/threshold rotation cannot grant an active quarantine amnesty for the
// same artifact.
type TombstoneScope struct {
	StableProviderIdentity string
	ModelID                string
	TargetModelHash        string
	TokenizerIdentity      string
	SamplerStage           string
}

// Window projects a ComputeIntegrityKey to its WindowKey.
func (k ComputeIntegrityKey) Window() WindowKey {
	return WindowKey{
		StableProviderIdentity: k.StableProviderIdentity,
		ModelID:                k.ModelID,
		TargetModelHash:        k.TargetModelHash,
		TokenizerIdentity:      k.TokenizerIdentity,
		SamplerStage:           k.SamplerStage,
		TargetGeneration:       k.TargetGeneration,
		SamplingProfile:        k.SamplingProfile,
		CorpusVersion:          k.CorpusVersion,
		ThresholdVersion:       k.ThresholdVersion,
	}
}

// Overlay projects a ComputeIntegrityKey to its OverlayKey.
func (k ComputeIntegrityKey) Overlay() OverlayKey {
	return OverlayKey{
		StableProviderIdentity: k.StableProviderIdentity,
		ModelID:                k.ModelID,
		TargetModelHash:        k.TargetModelHash,
		TokenizerIdentity:      k.TokenizerIdentity,
		SamplerStage:           k.SamplerStage,
		SamplingProfile:        k.SamplingProfile,
		CorpusVersion:          k.CorpusVersion,
		ThresholdVersion:       k.ThresholdVersion,
	}
}

// Threshold projects a ComputeIntegrityKey to its ThresholdKey (FR-8). The
// ThresholdKey retains hardware_runtime_class because thresholds/calibration are
// explicitly keyed by the full 8-tuple (a reference/threshold of one class must never
// authorize another class).
func (k ComputeIntegrityKey) Threshold() ThresholdKey {
	return ThresholdKey{
		ModelID:              k.ModelID,
		TargetModelHash:      k.TargetModelHash,
		TokenizerIdentity:    k.TokenizerIdentity,
		SamplerStage:         k.SamplerStage,
		SamplingProfile:      k.SamplingProfile,
		CorpusVersion:        k.CorpusVersion,
		ThresholdVersion:     k.ThresholdVersion,
		HardwareRuntimeClass: k.HardwareRuntimeClass,
	}
}

// Threshold projects a WindowKey to its ThresholdKey given the covered
// hardware_runtime_class (the per-key policy invariant that the WindowKey omits, FR-8).
func (w WindowKey) Threshold(hardwareRuntimeClass string) ThresholdKey {
	return ThresholdKey{
		ModelID:              w.ModelID,
		TargetModelHash:      w.TargetModelHash,
		TokenizerIdentity:    w.TokenizerIdentity,
		SamplerStage:         w.SamplerStage,
		SamplingProfile:      w.SamplingProfile,
		CorpusVersion:        w.CorpusVersion,
		ThresholdVersion:     w.ThresholdVersion,
		HardwareRuntimeClass: hardwareRuntimeClass,
	}
}

// SwapLaunderingScope projects an OverlayKey to the (stable_provider_identity,
// model_id) swap-laundering overlay scope, which spans all artifacts for that
// provider/model (FR-12).
func (o OverlayKey) SwapLaunderingScope() SwapLaunderingScope {
	return SwapLaunderingScope{
		StableProviderIdentity: o.StableProviderIdentity,
		ModelID:                o.ModelID,
	}
}

// TombstoneScope projects an OverlayKey to the narrower lineage-tombstone scope
// (stable_provider_identity, model_id, target_model_hash, tokenizer_identity,
// sampler_stage) (FR-10 clear rule).
func (o OverlayKey) TombstoneScope() TombstoneScope {
	return TombstoneScope{
		StableProviderIdentity: o.StableProviderIdentity,
		ModelID:                o.ModelID,
		TargetModelHash:        o.TargetModelHash,
		TokenizerIdentity:      o.TokenizerIdentity,
		SamplerStage:           o.SamplerStage,
	}
}

package computeintegrity

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestStatusForKeyCoversAbsentWarnExpiredAndBlockedStates(t *testing.T) {
	base := int64(1_800_000_000_000)
	key := statusKey()
	policy := statusPolicy(ModeObserve)

	t.Run("absent state", func(t *testing.T) {
		store := NewStore()
		got := store.StatusForKey(key, StatusInput{
			Policy:                policy,
			NowMs:                 base,
			AdmissibilityStatus:   AdmissibilityAdmissible,
			ComputePolicyDigest:   "sha256:policy",
			ThresholdRecordDigest: "sha256:threshold",
		})
		if got.State != StateUnknown || got.ProviderReadiness != ReadinessNone || got.SettlementEffect != "would_block_in_enforce" {
			t.Fatalf("status = state=%s readiness=%s effect=%s", got.State, got.ProviderReadiness, got.SettlementEffect)
		}
	})

	t.Run("observe warn state is telemetry only", func(t *testing.T) {
		store := NewStore()
		for i := 0; i < policy.MinWindowCanaries-1; i++ {
			store.RecordCanary(key, VerdictPass, base+int64(i)*1000, OriginTelemetryOnly)
		}
		store.RecordCanary(key, VerdictWarn, base+int64(policy.MinWindowCanaries)*1000, OriginTelemetryOnly)
		got := store.StatusForKey(key, StatusInput{
			Policy:                policy,
			NowMs:                 base + int64(policy.MinWindowCanaries+1)*1000,
			AdmissibilityStatus:   AdmissibilityAdmissible,
			ReferenceSetID:        "refset-1",
			ReferenceSetDigest:    "sha256:refs",
			ReferenceEventDigests: []string{"sha256:ref-a", "sha256:ref-b"},
			LatestCanaryDigests:   []string{"sha256:canary-a"},
		})
		if got.State != StateWarn || got.PolicyMode != ModeObserve || got.ProviderReadiness != "warn" || got.SettlementEffect != "telemetry_only" {
			t.Fatalf("status = state=%s mode=%s readiness=%s effect=%s", got.State, got.PolicyMode, got.ProviderReadiness, got.SettlementEffect)
		}
	})

	t.Run("stale state exposes expiry cause", func(t *testing.T) {
		store := NewStore()
		stalePolicy := statusPolicy(ModeEnforce)
		stalePolicy.PositiveStateFreshnessTTLHrs = 1
		for i := 0; i < stalePolicy.MinWindowCanaries; i++ {
			store.RecordCanary(key, VerdictPass, base+int64(i)*1000, OriginEnforcePreserved)
		}
		got := store.StatusForKey(key, StatusInput{
			Policy:                  stalePolicy,
			NowMs:                   base + 3*3600*1000,
			AdmissibilityStatus:     AdmissibilityAdmissible,
			Spec022EffectiveEnforce: true,
		})
		if got.State != StateExpired || got.ExpiryCause != ExpiryWindowTTLExpired || got.ProviderReadiness != "expired" || got.SettlementEffect != "blocks_new_paid_admission" {
			t.Fatalf("status = state=%s expiry=%s readiness=%s effect=%s", got.State, got.ExpiryCause, got.ProviderReadiness, got.SettlementEffect)
		}
	})

	t.Run("enforce unknown state actively blocks", func(t *testing.T) {
		store := NewStore()
		enforce := statusPolicy(ModeEnforce)
		got := store.StatusForKey(key, StatusInput{
			Policy:                  enforce,
			NowMs:                   base,
			AdmissibilityStatus:     AdmissibilityAdmissible,
			Spec022EffectiveEnforce: true,
		})
		if got.State != StateUnknown || got.ProviderReadiness != ReadinessNone || got.SettlementEffect != "blocks_new_paid_admission" {
			t.Fatalf("status = state=%s readiness=%s effect=%s", got.State, got.ProviderReadiness, got.SettlementEffect)
		}
	})

	t.Run("enforce pending state actively blocks", func(t *testing.T) {
		store := NewStore()
		enforce := statusPolicy(ModeEnforce)
		for i := 0; i < enforce.MinWindowCanaries-1; i++ {
			store.RecordCanary(key, VerdictPass, base+int64(i)*1000, OriginEnforcePreserved)
		}
		got := store.StatusForKey(key, StatusInput{
			Policy:                  enforce,
			NowMs:                   base + int64(enforce.MinWindowCanaries+1)*1000,
			AdmissibilityStatus:     AdmissibilityAdmissible,
			Spec022EffectiveEnforce: true,
		})
		if got.State != StatePending || got.ProviderReadiness != "pending" || got.SettlementEffect != "blocks_new_paid_admission" {
			t.Fatalf("status = state=%s readiness=%s effect=%s", got.State, got.ProviderReadiness, got.SettlementEffect)
		}
	})

	t.Run("quarantined state blocks when enforce-preserved", func(t *testing.T) {
		store := NewStore()
		enforce := statusPolicy(ModeEnforce)
		store.SetOverlayAdverse(key.Overlay(), StateQuarantinedDrift, OriginEnforcePreserved)
		got := store.StatusForKey(key, StatusInput{
			Policy:                  enforce,
			NowMs:                   base,
			AdmissibilityStatus:     AdmissibilityAdmissible,
			Spec022EffectiveEnforce: true,
			CircuitBreakerActive:    true,
			CircuitBreakerScope:     BreakerScopeKey,
			CircuitBreakerOrigin:    OriginEnforcePreserved,
		})
		if got.State != StateQuarantinedDrift || got.ProviderReadiness != "blocked" || got.SettlementEffect != "blocks_new_paid_admission" {
			t.Fatalf("status = state=%s readiness=%s effect=%s", got.State, got.ProviderReadiness, got.SettlementEffect)
		}
		if !strings.Contains(got.ProviderStatusMessage, "appeal/manual-review") {
			t.Fatalf("blocking message missing appeal/manual-review path: %q", got.ProviderStatusMessage)
		}
	})
}

func TestStatusForKeyDoesNotMutateState(t *testing.T) {
	base := int64(1_800_000_000_000)
	key := statusKey()
	policy := statusPolicy(ModeObserve)
	store := NewStore()
	for i := 0; i < policy.MinWindowCanaries; i++ {
		store.RecordCanary(key, VerdictQuarantineCandidate, base+int64(i)*1000, OriginTelemetryOnly)
	}
	got := store.StatusForKey(key, StatusInput{
		Policy:              policy,
		NowMs:               base + int64(policy.MinWindowCanaries+1)*1000,
		AdmissibilityStatus: AdmissibilityAdmissible,
	})
	if got.State != StateQuarantinedDrift || got.SettlementEffect != "telemetry_only" || got.ProviderReadiness != "quarantined" {
		t.Fatalf("status = state=%s effect=%s readiness=%s", got.State, got.SettlementEffect, got.ProviderReadiness)
	}
	if got := store.OverlayState(key.Overlay()); got != "" {
		t.Fatalf("StatusForKey mutated overlay state to %q", got)
	}
}

func TestStatusSnapshotOmitsRawPromptAndOutputFields(t *testing.T) {
	got := NewStore().StatusForKey(statusKey(), StatusInput{
		Policy:              statusPolicy(ModeObserve),
		NowMs:               1,
		AdmissibilityStatus: AdmissibilityAdmissible,
	})
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal status: %v", err)
	}
	lower := strings.ToLower(string(b))
	for _, forbidden := range []string{"prompt_text", "output_text", "raw_prompt", "raw_output", "buyer_output"} {
		if strings.Contains(lower, forbidden) {
			t.Fatalf("status leaked forbidden marker %q: %s", forbidden, lower)
		}
	}
	if !strings.Contains(got.Disclosure, "not cryptographic proof") || !strings.Contains(got.Disclosure, "not hardware integrity") {
		t.Fatalf("disclosure does not disclaim proof/attestation claims: %q", got.Disclosure)
	}
}

func statusPolicy(mode Mode) Policy {
	p := NewDefaultPolicy()
	p.PolicyVersion = "spec036-test"
	p.Mode = mode
	p.MinWindowCanaries = 5
	p.ClearPassCount = 5
	p.PositiveStateFreshnessTTLHrs = 24
	p.WindowSizeDays = 7
	return p
}

func statusKey() ComputeIntegrityKey {
	return ComputeIntegrityKey{
		StableProviderIdentity: "stable-provider-a",
		ProviderID:             "provider-a",
		AssignedID:             "assigned-a",
		ModelID:                "model-a",
		TargetModelHash:        strings.Repeat("a", 64),
		TokenizerIdentity:      "tok-a",
		SamplerStage:           SamplerStagePostSampler,
		TargetGeneration:       2,
		SamplingProfile:        "temp-0.7",
		CorpusVersion:          "corpus-a",
		ThresholdVersion:       "threshold-a",
		HardwareRuntimeClass:   "apple-m4",
	}
}

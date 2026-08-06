package computeintegrity

import "testing"

func winPolicy() Policy {
	p := NewDefaultPolicy()
	p.Mode = ModeEnforce
	return p // min_window_canaries=5, quarantine_candidate_count=3, clear_pass_count=5
}

func winKey(assigned string, gen int64, profile string) ComputeIntegrityKey {
	return ComputeIntegrityKey{
		StableProviderIdentity: "stable-1",
		ProviderID:             "prov-1",
		AssignedID:             assigned,
		ModelID:                "model-x",
		TargetModelHash:        "hash-x",
		TokenizerIdentity:      "tok-x",
		SamplerStage:           SamplerStagePostSampler,
		TargetGeneration:       gen,
		SamplingProfile:        profile,
		CorpusVersion:          "corpus-1",
		ThresholdVersion:       "thr-1",
		HardwareRuntimeClass:   "m3-max",
	}
}

func winResolveInput(p Policy, nowMs int64) ResolveInput {
	return ResolveInput{Policy: p, NowMs: nowMs, AdmissibilityStatus: AdmissibilityAdmissible, Spec022EffectiveEnforce: true}
}

// TestKeyAlgebra_ProviderIsolationAndScopes covers the audit-hardened key algebra:
// window state is per stable provider identity; window/overlay keys omit
// hardware_runtime_class; and swap-laundering scope is (stable, model) only.
func TestKeyAlgebra_ProviderIsolationAndScopes(t *testing.T) {
	p := winPolicy()
	base := int64(1_000_000)
	hour := int64(3600 * 1000)

	t.Run("provider A passes do not verify provider B (window keyed by stable identity)", func(t *testing.T) {
		s := NewStore()
		a := winKey("asg-a", 1, "temp-0.7")
		a.StableProviderIdentity = "provider-A"
		b := winKey("asg-b", 1, "temp-0.7")
		b.StableProviderIdentity = "provider-B"
		for i := 0; i < 5; i++ {
			s.RecordCanary(a, VerdictPass, base+int64(i)*hour)
		}
		if st, _ := s.ResolveState(a, winResolveInput(p, base+5*hour)); st != StateVerified {
			t.Fatalf("provider A should be verified, got %s", st)
		}
		if st, _ := s.ResolveState(b, winResolveInput(p, base+5*hour)); st == StateVerified {
			t.Fatal("provider B must NOT inherit provider A's verified window")
		}
	})

	t.Run("window/overlay keys omit hardware_runtime_class (per-key policy invariant)", func(t *testing.T) {
		a := winKey("asg", 1, "temp-0.7")
		b := a
		b.HardwareRuntimeClass = "m4-pro"
		if a.Window() != b.Window() || a.Overlay() != b.Overlay() {
			t.Fatal("hardware_runtime_class must not discriminate window/overlay keys")
		}
		if a.Threshold() == b.Threshold() {
			t.Fatal("hardware_runtime_class MUST discriminate the threshold key")
		}
	})

	t.Run("swap-laundering block spans a hash/tokenizer change (scope = stable+model)", func(t *testing.T) {
		s := NewStore()
		prior := winKey("asg", 1, "temp-0.7") // hash-x
		s.RecordCanary(prior, VerdictQuarantineCandidate, base)
		if !s.EscalateSwapLaunderingIfRisky(prior, ArtifactChangeEvent{
			HashTokenizerOrGenerationChanged: true, AtMs: base, Mode: ModeEnforce, Spec022EffectiveEnforce: true,
		}) {
			t.Fatal("risky change should escalate")
		}
		// Successor with a DIFFERENT hash and tokenizer, same provider+model, is blocked.
		succ := winKey("asg2", 2, "temp-1.0")
		succ.TargetModelHash = "hash-NEW"
		succ.TokenizerIdentity = "tok-NEW"
		if st, _ := s.ResolveState(succ, winResolveInput(p, base)); st != StateBlockedSwapLaunder {
			t.Fatalf("swap-laundering must follow the provider across artifact churn, got %s", st)
		}
	})

	t.Run("a quarantine adjudicated under observe is telemetry_only and does not block money", func(t *testing.T) {
		s := NewStore()
		k := winKey("asg", 1, "temp-0.7")
		obs := winPolicy()
		obs.Mode = ModeObserve
		in := ResolveInput{Policy: obs, NowMs: base, AdmissibilityStatus: AdmissibilityAdmissible, Spec022EffectiveEnforce: true}
		for i := 0; i < 5; i++ {
			s.RecordCanary(k, VerdictQuarantineCandidate, base+int64(i)*hour)
		}
		st, _ := s.ResolveState(k, in) // promotes quarantine under observe -> telemetry_only
		if st != StateQuarantinedDrift {
			t.Fatalf("expected quarantine, got %s", st)
		}
		// Under observe/warn_only, a telemetry_only quarantine has no money effect.
		c := payableCapture()
		c.State = StateQuarantinedDrift
		c.AdjudicationOrigin = OriginTelemetryOnly
		c.ComputeIntegrityPolicyMode = ModeObserve
		if d := Evaluate(c); d.Applies {
			t.Fatalf("telemetry_only quarantine must not block money, got %+v", d)
		}
	})
}

// AC-4: window state machine.
func TestAC04_WindowStateMachine(t *testing.T) {
	p := winPolicy()
	base := int64(1_000_000)
	hour := int64(3600 * 1000)

	t.Run("under-sampled window remains pending, never expired", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		for i := 0; i < 3; i++ { // fewer than min_window_canaries=5
			s.RecordCanary(k, VerdictPass, base+int64(i)*hour)
		}
		st, _ := s.ResolveState(k, winResolveInput(p, base+4*hour))
		if st != StatePending {
			t.Fatalf("under-sampled: want pending, got %s", st)
		}
	})

	t.Run("quarantine_candidate_count of latest min_window_canaries; intervening passes do not reset", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		// latest 5 = qc, pass, qc, pass, qc -> 3 quarantine_candidates -> quarantine.
		seq := []Verdict{VerdictQuarantineCandidate, VerdictPass, VerdictQuarantineCandidate, VerdictPass, VerdictQuarantineCandidate}
		for i, v := range seq {
			s.RecordCanary(k, v, base+int64(i)*hour)
		}
		st, _ := s.ResolveState(k, winResolveInput(p, base+5*hour))
		if st != StateQuarantinedDrift {
			t.Fatalf("intervening passes must not prevent quarantine: got %s", st)
		}
	})

	t.Run("5 consecutive passes make a fresh verified window", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		for i := 0; i < 5; i++ {
			s.RecordCanary(k, VerdictPass, base+int64(i)*hour)
		}
		st, _ := s.ResolveState(k, winResolveInput(p, base+5*hour))
		if st != StateVerified {
			t.Fatalf("5 passes: want verified, got %s", st)
		}
	})

	t.Run("stale verified re-evaluates as expired/window_ttl_expired", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		for i := 0; i < 5; i++ {
			s.RecordCanary(k, VerdictPass, base+int64(i)*hour)
		}
		// Now is > positive_state_freshness_ttl_hours (24h) after the newest canary:
		// the window expires (non-payable), it does not silently linger as pending.
		st, cause := s.ResolveState(k, winResolveInput(p, base+5*hour+25*hour))
		if st != StateExpired || cause != ExpiryWindowTTLExpired {
			t.Fatalf("stale verified: want expired/window_ttl_expired, got %s/%s", st, cause)
		}
	})

	t.Run("abusive-inconclusive over the limit blocks the key", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		for i := 0; i < 4; i++ { // limit is "more than 3" -> 4 blocks
			s.RecordAbusiveInconclusive(k, base+int64(i)*hour, p.AbusiveInconclusiveLimit, OriginEnforcePreserved)
		}
		if s.OverlayState(k.Overlay()) != StateBlockedAbusive {
			t.Fatalf("4 abusive events: want blocked:abusive_inconclusive, got %s", s.OverlayState(k.Overlay()))
		}
	})

	t.Run("quarantine clears only after clear_pass_count passes over >=24h", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		s.SetOverlayAdverse(k.Overlay(), StateQuarantinedDrift, OriginEnforcePreserved)
		// 5 passes within a couple hours: streak reached but < 24h -> no clear.
		for i := 0; i < 5; i++ {
			s.RecordCanary(k, VerdictPass, base+int64(i)*hour)
		}
		if s.AttemptClear(k, p, base+5*hour) {
			t.Fatal("must not clear before 24h elapsed")
		}
		// 5 passes spanning >24h -> clears.
		s2 := NewStore()
		s2.SetOverlayAdverse(k.Overlay(), StateQuarantinedDrift, OriginEnforcePreserved)
		for i := 0; i < 5; i++ {
			s2.RecordCanary(k, VerdictPass, base+int64(i)*7*hour) // spread over 28h
		}
		if !s2.AttemptClear(k, p, base+5*7*hour) {
			t.Fatal("should clear after 5 passes over >=24h")
		}
		if s2.OverlayState(k.Overlay()) != "" {
			t.Fatal("overlay should be cleared")
		}
	})

	t.Run("manual-review block clears only by dual approval, not pass sequence", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		s.SetOverlayAdverse(k.Overlay(), StateBlockedManualReview, OriginEnforcePreserved)
		for i := 0; i < 6; i++ {
			s.RecordCanary(k, VerdictPass, base+int64(i)*7*hour)
		}
		if s.AttemptClear(k, p, base+6*7*hour) {
			t.Fatal("manual_review must not clear by pass sequence")
		}
		if !s.DualApproveClear(k, "ops-a", "ops-b") {
			t.Fatal("manual_review should clear by dual approval")
		}
	})

	t.Run("accumulators live on the overlay key and are not reset by assigned_id churn", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		s.RecordCanary(k, VerdictQuarantineCandidate, base)
		s.RecordCanary(k, VerdictQuarantineCandidate, base+hour)
		before := s.QuarantineCandidateWindowCount(k.Overlay())
		// assigned_id change: purge positive window but keep overlay accumulators.
		s.InvalidatePositiveWindow(k.Window())
		k2 := winKey("b", 1, "temp-0.7") // new assigned_id, same overlay key
		if s.QuarantineCandidateWindowCount(k2.Overlay()) != before || before != 2 {
			t.Fatalf("accumulators must survive assigned_id churn: before=%d after=%d",
				before, s.QuarantineCandidateWindowCount(k2.Overlay()))
		}
	})

	t.Run("accumulators are not merged across policy-separated profiles", func(t *testing.T) {
		s := NewStore()
		ka := winKey("a", 1, "temp-0.7")
		kb := winKey("a", 1, "temp-1.0")
		s.RecordCanary(ka, VerdictQuarantineCandidate, base)
		if s.QuarantineCandidateWindowCount(kb.Overlay()) != 0 {
			t.Fatal("distinct profiles must not share overlay accumulators")
		}
	})

	t.Run("flapping policy is disabled by default", func(t *testing.T) {
		if NewDefaultPolicy().FlappingPolicy.Enabled {
			t.Fatal("flapping_window_policy_v0_1 must default to disabled")
		}
	})
}

// AC-8: warm-swap / re-onboarding.
func TestAC08_WarmSwapReOnboarding(t *testing.T) {
	p := winPolicy()
	base := int64(1_000_000)

	t.Run("positive state expires across a target-generation boundary", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		in := winResolveInput(p, base)
		in.InvalidationCause = ExpiryTargetGenerationChg
		st, cause := s.ResolveState(k, in)
		if st != StateExpired || cause != ExpiryTargetGenerationChg {
			t.Fatalf("generation change: want expired/target_generation_changed, got %s/%s", st, cause)
		}
	})

	t.Run("overlay quarantine is inherited across generation churn and settles non-payable", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		s.SetOverlayAdverse(k.Overlay(), StateQuarantinedDrift, OriginEnforcePreserved)
		// A generation-churned key shares the overlay key (which omits target_generation).
		churned := winKey("b", 2, "temp-0.7")
		st, _ := s.ResolveState(churned, winResolveInput(p, base))
		if st != StateQuarantinedDrift {
			t.Fatalf("churned key must inherit overlay quarantine, got %s", st)
		}
		// Request-start capture consults the overlay -> settles non-payable.
		c := payableCapture()
		c.State = st
		if d := Evaluate(c); d.Payable || d.Reason != ReasonDriftQuarantined {
			t.Fatalf("churned quarantined key must settle non-payable drift, got %+v", d)
		}
	})

	t.Run("provider-originated artifact change with active risk escalates swap-laundering", func(t *testing.T) {
		s := NewStore()
		prior := winKey("a", 1, "temp-0.7")
		s.RecordCanary(prior, VerdictQuarantineCandidate, base) // non-zero accumulator = active risk
		escalated := s.EscalateSwapLaunderingIfRisky(prior, ArtifactChangeEvent{
			HashTokenizerOrGenerationChanged: true, AtMs: base,
		})
		if !escalated {
			t.Fatal("risky artifact change must escalate swap-laundering")
		}
		// Every covered key of that provider/model is now blocked.
		other := winKey("z", 9, "temp-1.0")
		st, _ := s.ResolveState(other, winResolveInput(p, base))
		if st != StateBlockedSwapLaunder {
			t.Fatalf("swap-laundering must span the provider/model, got %s", st)
		}
	})

	t.Run("benign changes do not escalate", func(t *testing.T) {
		// clean provider (no risk) changing artifacts.
		s := NewStore()
		prior := winKey("a", 1, "temp-0.7")
		if s.EscalateSwapLaunderingIfRisky(prior, ArtifactChangeEvent{HashTokenizerOrGenerationChanged: true, AtMs: base}) {
			t.Fatal("clean provider must not escalate")
		}
		// risky provider but continuity-proven reconnect / same-hash reload are exempt.
		s2 := NewStore()
		s2.RecordCanary(prior, VerdictQuarantineCandidate, base)
		if s2.EscalateSwapLaunderingIfRisky(prior, ArtifactChangeEvent{ContinuityProvenReconnect: true, AtMs: base}) {
			t.Fatal("continuity-proven reconnect must not escalate")
		}
		if s2.EscalateSwapLaunderingIfRisky(prior, ArtifactChangeEvent{SameHashReload: true, AtMs: base}) {
			t.Fatal("same-hash reload must not escalate")
		}
	})

	t.Run("assigned_id change purges positive window but preserves overlay", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		for i := 0; i < 5; i++ {
			s.RecordCanary(k, VerdictPass, base+int64(i)*3600*1000)
		}
		s.SetOverlayAdverse(k.Overlay(), StateBlockedAbusive, OriginEnforcePreserved)
		s.InvalidatePositiveWindow(k.Window())
		// Positive window gone -> unknown positive path, but overlay block persists.
		if s.OverlayState(k.Overlay()) != StateBlockedAbusive {
			t.Fatal("overlay must survive assigned_id purge")
		}
	})

	t.Run("lineage tombstone blocks short onboarding re-qualification", func(t *testing.T) {
		s := NewStore()
		prior := winKey("a", 1, "temp-0.7")
		s.SetOverlayAdverse(prior.Overlay(), StateQuarantinedDrift, OriginEnforcePreserved)
		if !s.WriteTombstoneIfAdverse(prior) {
			t.Fatal("adverse overlay should write a tombstone")
		}
		// A successor corpus/threshold key shares the swap-laundering scope.
		succ := winKey("a", 1, "temp-0.7")
		succ.CorpusVersion = "corpus-2"
		if !s.HasTombstone(succ) {
			t.Fatal("successor key must see the tombstone")
		}
		r := s.EvaluateOnboarding(succ, ModeEnforce, []int64{base, base + onboardingMinElapsedMs + 1, base, base, base})
		if r.Status != OnboardingFailed {
			t.Fatal("onboarding must not clear a tombstoned lineage")
		}
	})
}

package computeintegrity

import "testing"

func breakerPolicy() CircuitBreakerPolicy {
	return CircuitBreakerPolicy{
		RollingWindowMinutes: 60,
		EventTimeBasis:       eventTimeBasisTransitionRecorded,
		ModelScopeThreshold:  3,
		FleetScopeThreshold:  5,
		QuietWindowMinutes:   120,
	}
}

func breakerKey(i int, model string) OverlayKey {
	return OverlayKey{
		StableProviderIdentity: "stable",
		ModelID:                model,
		TargetModelHash:        "hash",
		TokenizerIdentity:      "tok",
		SamplerStage:           SamplerStagePostSampler,
		SamplingProfile:        "temp-0.7",
		CorpusVersion:          "corpus-1",
		ThresholdVersion:       "thr-1",
	}
}

// AC-13 (operator controls): circuit breaker, manual review, override, clear.
func TestAC13_OperatorControls(t *testing.T) {
	now := int64(10_000_000)

	t.Run("breaker fails closed at the model threshold", func(t *testing.T) {
		var trs []BreakerTransition
		for i := 0; i < 3; i++ { // 3 distinct keys, same model
			k := breakerKey(i, "model-x")
			k.TargetModelHash = "hash-" + string(rune('a'+i)) // distinct keys
			trs = append(trs, BreakerTransition{OverlayKey: k, ModelID: "model-x", Kind: TransitionDrift, AtMs: now})
		}
		st, scope := EvaluateBreaker(trs, breakerPolicy(), now)
		if st != BreakerActive || scope != BreakerScopeModel {
			t.Fatalf("model threshold: want active/model, got %s/%s", st, scope)
		}
	})

	t.Run("fleet threshold takes precedence (whole-policy)", func(t *testing.T) {
		var trs []BreakerTransition
		for i := 0; i < 5; i++ { // 5 distinct keys across models
			k := breakerKey(i, "model-"+string(rune('a'+i)))
			trs = append(trs, BreakerTransition{OverlayKey: k, ModelID: "model-" + string(rune('a'+i)), Kind: TransitionReferenceFault, AtMs: now})
		}
		st, scope := EvaluateBreaker(trs, breakerPolicy(), now)
		if st != BreakerActive || scope != BreakerScopePolicy {
			t.Fatalf("fleet threshold: want active/policy, got %s/%s", st, scope)
		}
	})

	t.Run("repeated transitions on one key count once (dedup)", func(t *testing.T) {
		k := breakerKey(0, "model-x")
		trs := []BreakerTransition{
			{OverlayKey: k, ModelID: "model-x", Kind: TransitionDrift, AtMs: now},
			{OverlayKey: k, ModelID: "model-x", Kind: TransitionDrift, AtMs: now + 1},
			{OverlayKey: k, ModelID: "model-x", Kind: TransitionDrift, AtMs: now + 2},
		}
		if st, _ := EvaluateBreaker(trs, breakerPolicy(), now+2); st != BreakerInactive {
			t.Fatal("one key hit repeatedly must not reach the 3-distinct-key threshold")
		}
	})

	t.Run("override_routing_only never admits billable buyer traffic", func(t *testing.T) {
		if OverrideAdmitsBillable(BreakerOverrideRoute) {
			t.Fatal("override_routing_only must not admit billable buyer traffic")
		}
	})

	t.Run("breaker clear requires quiet window, fresh refs, dual approval, and audit", func(t *testing.T) {
		if CanClearBreaker(BreakerClearInput{QuietWindowSatisfied: true, FreshReferenceAdmission: true, DualApproved: true}) {
			t.Fatal("clear must also require an audit row")
		}
		if !CanClearBreaker(BreakerClearInput{QuietWindowSatisfied: true, FreshReferenceAdmission: true, DualApproved: true, AuditRowRecorded: true}) {
			t.Fatal("all requirements met should clear")
		}
	})

	t.Run("manual review requires two distinct approvers", func(t *testing.T) {
		if (ManualReviewDecision{ApproverA: "a", ApproverB: "a", Decision: "clear", EvidenceDigest: "d"}).Valid() {
			t.Fatal("same approver twice is not dual approval")
		}
		if !(ManualReviewDecision{ApproverA: "a", ApproverB: "b", Decision: "clear", EvidenceDigest: "d"}).Valid() {
			t.Fatal("two distinct approvers with evidence should be valid")
		}
	})

	t.Run("enforce->warn_only rollback preserves an already-captured non-payable row", func(t *testing.T) {
		// A row captured non-payable under enforce keeps that outcome even though the
		// mode is now warn_only (settlement reads the captured mode).
		c := payableCapture()
		c.State = StateQuarantinedDrift
		c.ComputeIntegrityPolicyMode = ModeEnforce // captured under enforce
		d := Evaluate(c)
		if d.Payable {
			t.Fatal("captured-under-enforce drift must stay non-payable")
		}
	})
}

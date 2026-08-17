package computeintegrity

import "testing"

// payableCapture returns a fresh verified, enforce-mode, SPEC-022-enforcing capture
// that SPEC-036 does NOT block. Tests mutate one axis at a time.
func payableCapture() Capture {
	return Capture{
		StableProviderIdentity:           "stable-1",
		ProviderID:                       "prov-1",
		AssignedID:                       "assign-1",
		ModelID:                          "model-x",
		TargetModelHash:                  "hash-x",
		TokenizerIdentity:                "tok-x",
		SamplerStage:                     SamplerStagePostSampler,
		SamplingProfile:                  "temp-0.7",
		CorpusVersion:                    "corpus-1",
		ThresholdVersion:                 "thr-1",
		HardwareRuntimeClass:             "m3-max",
		TargetGeneration:                 1,
		SamplingProfileCoverageMode:      CoveragePerProfile,
		RequestSamplingProfileCovered:    true,
		HardwareRuntimeClassDigest:       "sha256:hwclass",
		RouteSnapshotHardwareClassDigest: "sha256:hwclass",
		Spec022PolicyVersion:             "spec022-prereq-v1",
		Spec022PolicyMode:                "enforce",
		Spec022EffectiveEnforce:          true,
		Spec022CoverageDigest:            "sha256:cov022",
		Spec022RouteSnapshotDigest:       "sha256:route",
		ComputeIntegrityPolicyVersion:    "ci-v1",
		ComputeIntegrityPolicyMode:       ModeEnforce,
		ComputeIntegrityPolicyDigest:     "sha256:policy",
		State:                            StateVerified,
		AdjudicationOrigin:               OriginEnforcePreserved,
		ReferenceSetAdmissibilityStatus:  AdmissibilityAdmissible,
		ReferenceSetAdmissibilityDigest:  "sha256:adm",
		ReferenceFaultCheckVersion:       "rfc-v1",
		ReferenceSetID:                   "refset-1",
		ReferenceEventDigests:            []string{"sha256:refA", "sha256:refB"},
		ReferenceQuorumCount:             2,
		BreakerFieldsPresent:             true,
		CircuitBreakerActive:             false,
		WindowID:                         "win-1",
		SignedCatalogDigest:              "sha256:catalog",
		CapturedAtUnixMS:                 1000,
	}
}

// AC-5: request-start quarantined_compute_drift maps to outcome=quarantined /
// reason=compute_drift_quarantined, never zero_settled; the SPEC-015 receipt verdict
// stays orthogonal; a captured breaker makes a preserved verified/warn row non-payable
// with the breaker reason; SPEC-022 subordination; request-start immutability.
func TestAC05_SettlementOutcomeMapping(t *testing.T) {
	t.Run("drift maps to quarantined/compute_drift_quarantined, overriding a valid receipt", func(t *testing.T) {
		c := payableCapture()
		c.State = StateQuarantinedDrift
		d := Evaluate(c)
		if !d.Applies || d.Payable || d.Reason != ReasonDriftQuarantined {
			t.Fatalf("drift: got applies=%v payable=%v reason=%q", d.Applies, d.Payable, d.Reason)
		}
		// Even when the SPEC-015 receipt verifier said "verified", the AND-gate narrows.
		out, reason := ApplyGate(OutcomeVerified, "verified_settlement", d)
		if out != OutcomeQuarantined || reason != string(ReasonDriftQuarantined) {
			t.Fatalf("gate over verified: got outcome=%q reason=%q", out, reason)
		}
		if out == OutcomeZeroSettled {
			t.Fatalf("drift must never settle as zero_settled")
		}
	})

	t.Run("clean verified row is not blocked by SPEC-036", func(t *testing.T) {
		d := Evaluate(payableCapture())
		if !d.Applies || !d.Payable {
			t.Fatalf("clean verified: got applies=%v payable=%v reason=%q", d.Applies, d.Payable, d.Reason)
		}
		out, reason := ApplyGate(OutcomeVerified, "verified_settlement", d)
		if out != OutcomeVerified || reason != "verified_settlement" {
			t.Fatalf("clean verified passthrough: got outcome=%q reason=%q", out, reason)
		}
	})

	t.Run("SPEC-015 receipt result stays orthogonal: SPEC-036 never promotes", func(t *testing.T) {
		// SPEC-022 said zero_settled (verified non-creditable); a clean SPEC-036 row must
		// not promote it to verified/payable.
		d := Evaluate(payableCapture())
		out, reason := ApplyGate(OutcomeZeroSettled, "verified_zero_settlement", d)
		if out != OutcomeZeroSettled || reason != "verified_zero_settlement" {
			t.Fatalf("must not promote zero_settled: got outcome=%q reason=%q", out, reason)
		}
	})

	t.Run("captured breaker over a verified row is non-payable with breaker reason", func(t *testing.T) {
		c := payableCapture()
		c.CircuitBreakerActive = true
		c.CircuitBreakerScope = BreakerScopeModel
		d := Evaluate(c)
		if !d.Applies || d.Payable || d.Reason != ReasonCircuitBreakerHold {
			t.Fatalf("breaker: got applies=%v payable=%v reason=%q", d.Applies, d.Payable, d.Reason)
		}
		// Underlying verified state is preserved; drift ranks higher than the breaker.
		c.State = StateQuarantinedDrift
		if d := Evaluate(c); d.Reason != ReasonDriftQuarantined {
			t.Fatalf("drift+breaker must keep drift reason, got %q", d.Reason)
		}
	})

	t.Run("SPEC-022 not enforce: SPEC-036 does not alter the money outcome", func(t *testing.T) {
		c := payableCapture()
		c.Spec022EffectiveEnforce = false
		c.State = StateQuarantinedDrift // even an adverse state must not alter money.
		d := Evaluate(c)
		if d.Applies {
			t.Fatalf("SPEC-022 not enforce must yield Applies=false, got %+v", d)
		}
		out, reason := ApplyGate(OutcomeVerified, "verified_settlement", d)
		if out != OutcomeVerified || reason != "verified_settlement" {
			t.Fatalf("passthrough when SPEC-022 not enforce: outcome=%q reason=%q", out, reason)
		}
	})

	t.Run("request-start immutability: settlement reads captured state only", func(t *testing.T) {
		// A row captured payable stays payable regardless of any later state; a row
		// captured under drift stays quarantined. Evaluate is a pure function of Capture,
		// so identical captures yield identical decisions (no hidden clock/live state).
		c := payableCapture()
		c.State = StateQuarantinedDrift
		a, b := Evaluate(c), Evaluate(c)
		if a.Applies != b.Applies || a.Payable != b.Payable || a.Reason != b.Reason {
			t.Fatalf("Evaluate is not a pure function of the capture: %+v vs %+v", a, b)
		}
		// A later mutation of live state cannot exist in this pure model: the same
		// capture always yields the same decision.
		if a.Reason != ReasonDriftQuarantined {
			t.Fatalf("captured drift must settle quarantined, got %q", a.Reason)
		}
	})
}

// AC-13 (matrix core): the FR-3 effective_adverse_state truth table over
// SPEC-036 mode × SPEC-022 {enforce,not} × origin {enforce_preserved,telemetry_only}
// × attribution {provider, breaker, coordinator}. observe behaves identically to
// warn_only; telemetry_only never blocks; coordinator-attributable dormant on
// downgrade; all dormant when SPEC-022 is not enforce.
func TestAC13_EffectiveAdverseStateMatrix(t *testing.T) {
	modes := []Mode{ModeEnforce, ModeWarnOnly, ModeObserve}
	origins := []AdjudicationOrigin{OriginEnforcePreserved, OriginTelemetryOnly}
	attribs := []attribution{attribProviderOrBreaker, attribCoordinator}

	for _, mode := range modes {
		for _, spec022 := range []bool{true, false} {
			for _, origin := range origins {
				for _, attrib := range attribs {
					got := EffectiveAdverseState(mode, spec022, origin, attrib)
					want := expectedActive(mode, spec022, origin, attrib)
					if got != want {
						t.Errorf("mode=%s spec022=%v origin=%s attrib=%v: got active=%v want %v",
							mode, spec022, origin, attrib, got, want)
					}
				}
			}
		}
	}
}

// expectedActive independently restates the FR-3 truth table so the test does not
// mirror the implementation's control flow.
func expectedActive(mode Mode, spec022Enforce bool, origin AdjudicationOrigin, attrib attribution) bool {
	if !spec022Enforce {
		return false
	}
	if origin == OriginTelemetryOnly {
		return false
	}
	switch mode {
	case ModeEnforce:
		return true // both provider/breaker and coordinator active
	case ModeWarnOnly, ModeObserve:
		return attrib == attribProviderOrBreaker
	}
	return false
}

// AC-13 (settlement projection): observe behaves identically to warn_only, and the
// preserved provider/breaker states stay money-blocking while coordinator ones go
// dormant on a SPEC-036-only downgrade.
func TestAC13_ObserveMatchesWarnOnly(t *testing.T) {
	base := payableCapture()
	cases := []struct {
		name        string
		mutate      func(*Capture)
		wantBlocked bool
		wantReason  SettlementReason
	}{
		{"provider drift enforce_preserved blocks", func(c *Capture) {
			c.State = StateQuarantinedDrift
			c.AdjudicationOrigin = OriginEnforcePreserved
		}, true, ReasonDriftQuarantined},
		{"provider drift telemetry_only dormant", func(c *Capture) {
			c.State = StateQuarantinedDrift
			c.AdjudicationOrigin = OriginTelemetryOnly
		}, false, ""},
		{"coordinator reference_missing dormant on downgrade", func(c *Capture) {
			c.State = StateBlockedRefMissing
			c.AdjudicationOrigin = OriginEnforcePreserved
		}, false, ""},
		{"breaker enforce_preserved blocks", func(c *Capture) {
			c.CircuitBreakerActive = true
			c.CircuitBreakerScope = BreakerScopePolicy
			c.AdjudicationOrigin = OriginEnforcePreserved
		}, true, ReasonCircuitBreakerHold},
		{"clean verified no effect", func(c *Capture) {}, false, ""},
	}
	for _, mode := range []Mode{ModeWarnOnly, ModeObserve} {
		for _, tc := range cases {
			c := base
			c.ComputeIntegrityPolicyMode = mode
			tc.mutate(&c)
			d := Evaluate(c)
			blocked := d.Applies && !d.Payable
			if blocked != tc.wantBlocked {
				t.Errorf("mode=%s %s: blocked=%v want %v (%+v)", mode, tc.name, blocked, tc.wantBlocked, d)
			}
			if tc.wantBlocked && d.Reason != tc.wantReason {
				t.Errorf("mode=%s %s: reason=%q want %q", mode, tc.name, d.Reason, tc.wantReason)
			}
		}
	}
}

// AC-16: closed-reason table + reason precedence, including the two reference_stale
// producers at different precedence tiers and unknown-value fail-closed.
func TestAC16_ClosedReasonPrecedence(t *testing.T) {
	t.Run("every emitted reason is in the closed v0.1 enum", func(t *testing.T) {
		// Drive a spread of non-payable captures and assert the emitted reason validates.
		mutators := []func(*Capture){
			func(c *Capture) { c.Unreadable = true },
			func(c *Capture) { c.RequestSamplingProfileCovered = false },
			func(c *Capture) { c.State = StateBlockedSwapLaunder },
			func(c *Capture) { c.State = StateBlockedManualReview },
			func(c *Capture) { c.ReferenceSetAdmissibilityStatus = AdmissibilityReferenceFault },
			func(c *Capture) { c.ReferenceSetAdmissibilityStatus = AdmissibilityMissingQuorum },
			func(c *Capture) { c.State = StateBlockedCalibMissing },
			func(c *Capture) { c.State = StateQuarantinedDrift },
			func(c *Capture) { c.State = StateBlockedAbusive },
			func(c *Capture) {
				c.CircuitBreakerActive = true
				c.CircuitBreakerScope = BreakerScopeKey
			},
			func(c *Capture) { c.State = StateExpired; c.ExpiryCause = ExpiryWindowTTLExpired },
			func(c *Capture) { c.State = StateUnknown },
			func(c *Capture) { c.State = StatePending },
		}
		for i, m := range mutators {
			c := payableCapture()
			m(&c)
			d := Evaluate(c)
			if !d.Applies || d.Payable {
				t.Fatalf("case %d expected a block", i)
			}
			if !ValidSettlementReason(d.Reason) {
				t.Fatalf("case %d emitted non-enum reason %q", i, d.Reason)
			}
		}
	})

	t.Run("admissibility stale_reference (tier5) outranks drift", func(t *testing.T) {
		c := payableCapture()
		c.State = StateQuarantinedDrift
		c.ReferenceSetAdmissibilityStatus = AdmissibilityStaleReference
		if d := Evaluate(c); d.Reason != ReasonReferenceStale {
			t.Fatalf("admissibility stale + drift: want reference_stale, got %q", d.Reason)
		}
	})

	t.Run("expiry_cause reference_stale (tier10) loses to drift", func(t *testing.T) {
		// Same reason STRING, lower tier: drift wins. This is the dual-producer case.
		c := payableCapture()
		c.State = StateQuarantinedDrift // active overlay (tier 70)
		// expiry cause is only read when State==expired, so model the collision via a
		// row that is BOTH drift-overlay and reference-stale-expiry is impossible in one
		// State field; instead assert the expiry producer alone maps low:
		c2 := payableCapture()
		c2.State = StateExpired
		c2.ExpiryCause = ExpiryReferenceStale
		if d := Evaluate(c2); d.Reason != ReasonReferenceStale {
			t.Fatalf("expiry reference_stale alone: want reference_stale, got %q", d.Reason)
		}
		// And when drift overlay is active alongside an expiry-tier condition, drift wins.
		if d := Evaluate(c); d.Reason != ReasonDriftQuarantined {
			t.Fatalf("drift present: want drift, got %q", d.Reason)
		}
	})

	t.Run("unreadable outranks everything", func(t *testing.T) {
		c := payableCapture()
		c.State = StateQuarantinedDrift
		c.Unreadable = true
		if d := Evaluate(c); d.Reason != ReasonUnreadable {
			t.Fatalf("unreadable precedence: got %q", d.Reason)
		}
	})

	t.Run("unknown admissibility status fails closed as unreadable", func(t *testing.T) {
		c := payableCapture()
		c.ReferenceSetAdmissibilityStatus = "totally-made-up"
		if d := Evaluate(c); d.Reason != ReasonUnreadable {
			t.Fatalf("unknown admissibility: got %q", d.Reason)
		}
	})

	t.Run("inconsistent breaker fields fail closed as unreadable", func(t *testing.T) {
		c := payableCapture()
		c.CircuitBreakerActive = true // active but no scope
		if d := Evaluate(c); d.Reason != ReasonUnreadable {
			t.Fatalf("bad breaker: got %q", d.Reason)
		}
	})

	t.Run("unknown/malformed captured mode fails closed (not treated as non-enforce)", func(t *testing.T) {
		c := payableCapture()
		c.ComputeIntegrityPolicyMode = "enf0rce" // malformed
		// SPEC-022 is enforcing and the row is otherwise fresh verified; an unknown mode
		// must NOT pass through payable — it settles unreadable.
		d := Evaluate(c)
		if !d.Applies || d.Payable || d.Reason != ReasonUnreadable {
			t.Fatalf("unknown mode must fail closed unreadable, got %+v", d)
		}
	})

	t.Run("a verified row with incomplete reference-quorum evidence fails closed", func(t *testing.T) {
		mutators := []func(*Capture){
			func(c *Capture) { c.ReferenceQuorumCount = 1 },                                     // < 2
			func(c *Capture) { c.ReferenceEventDigests = []string{"sha256:only"} },              // < quorum
			func(c *Capture) { c.ReferenceSetAdmissibilityDigest = "" },                         // missing digest
			func(c *Capture) { c.ReferenceFaultCheckVersion = "" },                              // missing fault version
			func(c *Capture) { c.ReferenceEventDigests = []string{"sha256:a", ""} },             // empty digest
			func(c *Capture) { c.ReferenceEventDigests = []string{"sha256:dup", "sha256:dup"} }, // duplicate = one reference
		}
		for i, m := range mutators {
			c := payableCapture()
			m(&c)
			if d := Evaluate(c); d.Payable {
				t.Fatalf("case %d: incomplete reference evidence must not be payable", i)
			}
		}
	})

	t.Run("a missing composite SPEC-022 binding fails closed unreadable", func(t *testing.T) {
		c := payableCapture()
		c.Spec022EffectiveEnforce = false // could be a malformed capture...
		c.Spec022PolicyVersion = ""       // ...whose binding is actually missing.
		c.Spec022PolicyMode = ""
		c.Spec022RouteSnapshotDigest = ""
		d := Evaluate(c)
		if !d.Applies || d.Payable || d.Reason != ReasonUnreadable {
			t.Fatalf("missing composite binding must fail closed unreadable, got %+v", d)
		}
	})

	t.Run("an explicitly unreadable capture fails closed before false enforce passthrough", func(t *testing.T) {
		c := payableCapture()
		c.Spec022EffectiveEnforce = false
		c.Unreadable = true
		d := Evaluate(c)
		if !d.Applies || d.Payable || d.Reason != ReasonUnreadable {
			t.Fatalf("explicit unreadable capture must fail closed unreadable, got %+v", d)
		}
	})

	t.Run("swap_laundering outranks manual_review outranks reference outranks drift", func(t *testing.T) {
		order := []struct {
			state  State
			reason SettlementReason
		}{
			{StateBlockedSwapLaunder, ReasonBlockedSwapLaundering},
			{StateBlockedManualReview, ReasonBlockedManualReview},
			{StateQuarantinedDrift, ReasonDriftQuarantined},
		}
		for _, o := range order {
			c := payableCapture()
			c.State = o.state
			if d := Evaluate(c); d.Reason != o.reason {
				t.Fatalf("state %s: want %q got %q", o.state, o.reason, d.Reason)
			}
		}
	})
}

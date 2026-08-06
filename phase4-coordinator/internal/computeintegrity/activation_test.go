package computeintegrity

import "testing"

func goodThresholdRecord() ThresholdRecord {
	r := DeriveThresholds(0.004, 0.010)
	r.ModelID = "model-x"
	r.TargetModelHash = "hash-x"
	r.TokenizerIdentity = "tok-x"
	r.SamplerStage = SamplerStagePostSampler
	r.SamplingProfile = "temp-0.7"
	r.CorpusVersion = "corpus-1"
	r.ThresholdVersion = "thr-1"
	r.HardwareRuntimeClass = "m3-max"
	r.CalibrationSource = "warn-only-period"
	r.CalibrationSampleCount = 200
	r.MinEligibleCanaryCount = 100
	r.MeasurementPositionCount = 8
	r.BaselineTailMassFeasibilityRate = 0.99
	r.FalsePositiveBudget = 0.01
	r.KnownGoodCohortDigest = "sha256:cohort"
	r.MeasuredFalseQuarantineNumerator = 1
	r.MeasuredFalseQuarantineDenominator = 200
	r.MeasuredFalseQuarantineRate = 0.005
	r.MeasuredFPWindow = "2026-07-01T00:00:00Z/2026-07-31T00:00:00Z"
	r.ApprovalTimestamp = "2026-08-01T00:00:00Z"
	r.ApproverGroup = "spec-maintainers"
	return r
}

func calMins() CalibrationMinimums {
	return CalibrationMinimums{MinEligibleCanaryCount: 100, MinMeasurementPositions: 8, MinTailMassFeasibility: 0.95}
}

// AC-1: threshold calibration fixture.
func TestAC01_ThresholdCalibration(t *testing.T) {
	t.Run("initial threshold formulas apply the floors", func(t *testing.T) {
		r := DeriveThresholds(0.0, 0.0)
		if r.TauWarnMedian != 0.015 || r.TauWarnPosition != 0.030 ||
			r.TauQuarantineMedian != 0.060 || r.TauQuarantinePosition != 0.120 ||
			r.TauReferenceFaultMedian != 0.010 || r.TauReferenceFaultPosition != 0.020 {
			t.Fatalf("floors not applied: %+v", r.Thresholds())
		}
	})

	t.Run("thresholds widen for noisier keys, never below the floor", func(t *testing.T) {
		r := DeriveThresholds(0.05, 0.10)
		if r.TauQuarantineMedian <= 0.060 {
			t.Fatalf("noisy key should widen quarantine median, got %v", r.TauQuarantineMedian)
		}
	})

	t.Run("a complete approved record is enforce-ready", func(t *testing.T) {
		if refs := goodThresholdRecord().ValidateCalibrationForEnforce(ThresholdKey{}, calMins()); len(refs) != 0 {
			t.Fatalf("good record should be enforce-ready, got %v", refs)
		}
	})

	t.Run("activation refuses calibration missing measured false-quarantine evidence", func(t *testing.T) {
		r := goodThresholdRecord()
		r.KnownGoodCohortDigest = ""
		r.MeasuredFPWindow = ""
		r.MeasuredFalseQuarantineDenominator = 0
		if refs := r.ValidateCalibrationForEnforce(ThresholdKey{}, calMins()); len(refs) == 0 {
			t.Fatal("missing measured-FP evidence must refuse enforce")
		}
	})

	t.Run("activation refuses measured false-quarantine rate above budget", func(t *testing.T) {
		r := goodThresholdRecord()
		r.MeasuredFalseQuarantineNumerator = 10 // 10/200 = 0.05 > budget 0.01
		r.MeasuredFalseQuarantineRate = 0.05
		if refs := r.ValidateCalibrationForEnforce(ThresholdKey{}, calMins()); len(refs) == 0 {
			t.Fatal("measured rate above budget must refuse enforce")
		}
	})

	t.Run("activation refuses an underpowered calibration", func(t *testing.T) {
		r := goodThresholdRecord()
		r.CalibrationSampleCount = 10
		r.MinEligibleCanaryCount = 10
		if refs := r.ValidateCalibrationForEnforce(ThresholdKey{}, calMins()); len(refs) == 0 {
			t.Fatal("underpowered calibration must refuse enforce")
		}
	})

	t.Run("calibration record must match the covered key's 8-tuple", func(t *testing.T) {
		r := goodThresholdRecord()
		want := r.ThresholdKey()
		if refs := r.ValidateCalibrationForEnforce(want, calMins()); len(refs) != 0 {
			t.Fatalf("matching 8-tuple should be enforce-ready, got %v", refs)
		}
		wrong := want
		wrong.HardwareRuntimeClass = "m4-pro"
		if refs := r.ValidateCalibrationForEnforce(wrong, calMins()); len(refs) == 0 {
			t.Fatal("a mismatched 8-tuple must refuse enforce")
		}
	})

	t.Run("thresholds below the FR-8 floor refuse enforce", func(t *testing.T) {
		r := goodThresholdRecord()
		r.TauQuarantineMedian = 0.01 // below the 0.060 floor
		if refs := r.ValidateCalibrationForEnforce(ThresholdKey{}, calMins()); len(refs) == 0 {
			t.Fatal("a threshold below the floor must refuse enforce")
		}
	})

	t.Run("threshold record digest is deterministic and closed over the payload", func(t *testing.T) {
		a, err := goodThresholdRecord().Digest()
		if err != nil {
			t.Fatal(err)
		}
		b, _ := goodThresholdRecord().Digest()
		if a != b {
			t.Fatal("threshold digest must be deterministic")
		}
		changed := goodThresholdRecord()
		changed.ThresholdVersion = "thr-2"
		c, _ := changed.Digest()
		if a == c {
			t.Fatal("a threshold-version change must change the digest")
		}
	})

	t.Run("enforce is class-restricted: a mismatched hardware class is uncovered", func(t *testing.T) {
		cap := payableCapture()
		cap.RouteSnapshotHardwareClassDigest = "sha256:different-class"
		if d := Evaluate(cap); d.Reason != ReasonUncoveredProfile {
			t.Fatalf("mismatched class must be uncovered_profile, got %s", d.Reason)
		}
	})
}

func goodActivationDeps() ActivationDeps {
	return ActivationDeps{
		SPEC030PrimitivesExposed:     true,
		SPEC022Enforce:               true,
		SPEC022CoverageSubset:        true,
		AllModelsSignedCatalog:       true,
		TwoIndependentFreshRefs:      true,
		SettlementStorageReady:       true,
		BillingExcludesNonVerified:   true,
		DisclosureApproved:           true,
		AuditorBundlesAvailable:      true,
		OperatorControlsReady:        true,
		StableIdentityAuthorityNamed: true,
		ApprovedCostModel:            true,
	}
}

func goodEnforcePolicy() Policy {
	p := NewDefaultPolicy()
	p.Mode = ModeEnforce
	p.SamplerStage = SamplerStagePostSampler
	p.PositiveStateFreshnessTTLHrs = 24
	p.CanaryCadenceMinutes = 360 // 24h*60=1440 >= 2*360=720
	return p
}

// AC-10: enforce activation preconditions.
func TestAC10_ActivationPreconditions(t *testing.T) {
	t.Run("a fully-provisioned policy with a named identity authority may activate", func(t *testing.T) {
		if refs := ActivationCheck(goodEnforcePolicy(), goodActivationDeps()); len(refs) != 0 {
			t.Fatalf("fully-provisioned enforce should activate, got %v", refs)
		}
	})

	t.Run("missing named stable-identity authority refuses enforce (positive fixture requires it)", func(t *testing.T) {
		deps := goodActivationDeps()
		deps.StableIdentityAuthorityNamed = false
		if CanActivateEnforce(goodEnforcePolicy(), deps) {
			t.Fatal("enforce must refuse without a named identity authority (§6.1)")
		}
	})

	t.Run("each missing precondition independently refuses enforce", func(t *testing.T) {
		mutators := []func(*ActivationDeps){
			func(d *ActivationDeps) { d.SPEC022Enforce = false },
			func(d *ActivationDeps) { d.SPEC022CoverageSubset = false },
			func(d *ActivationDeps) { d.TwoIndependentFreshRefs = false },
			func(d *ActivationDeps) { d.SettlementStorageReady = false },
			func(d *ActivationDeps) { d.DisclosureApproved = false },
			func(d *ActivationDeps) { d.AuditorBundlesAvailable = false },
			func(d *ActivationDeps) { d.OperatorControlsReady = false },
			func(d *ActivationDeps) { d.ApprovedCostModel = false },
			func(d *ActivationDeps) { d.CalibrationRefusals = []string{"calibration missing"} },
		}
		for i, m := range mutators {
			deps := goodActivationDeps()
			m(&deps)
			if CanActivateEnforce(goodEnforcePolicy(), deps) {
				t.Fatalf("precondition case %d should refuse enforce", i)
			}
		}
	})

	t.Run("TTL below twice cadence refuses enforce", func(t *testing.T) {
		p := goodEnforcePolicy()
		p.CanaryCadenceMinutes = 900 // 2*900=1800 > 1440
		if CanActivateEnforce(p, goodActivationDeps()) {
			t.Fatal("TTL < 2x cadence must refuse enforce")
		}
	})
}

// AC-17: sampler stage keying and enforce refusal for undefined stages.
func TestAC17_SamplerStage(t *testing.T) {
	t.Run("sampler stage is part of the compute-integrity, window, overlay, and threshold keys", func(t *testing.T) {
		a := winKey("a", 1, "temp-0.7")
		b := a
		b.SamplerStage = "some_other_stage"
		if a.Window() == b.Window() || a.Overlay() == b.Overlay() || a.Threshold() == b.Threshold() {
			t.Fatal("sampler_stage must discriminate window/overlay/threshold keys")
		}
	})

	t.Run("v0.1 enforce refuses sampler stages without defined capture/normalization", func(t *testing.T) {
		for _, stage := range []string{"pre_temperature_logits", "post_temperature_logits", ""} {
			p := goodEnforcePolicy()
			p.SamplerStage = stage
			if CanActivateEnforce(p, goodActivationDeps()) {
				t.Fatalf("enforce must refuse sampler stage %q", stage)
			}
		}
	})

	t.Run("probe request validation binds the sampler stage", func(t *testing.T) {
		req := sampleRequest()
		req.Payload.SamplerStage = "pre_temperature_logits"
		if err := ValidateRequestBounds(req); err == nil {
			t.Fatal("probe validation must reject an undefined sampler stage")
		}
	})
}

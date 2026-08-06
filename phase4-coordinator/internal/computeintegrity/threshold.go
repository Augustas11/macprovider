package computeintegrity

import (
	"math"
	"time"
)

func rfc3339OK(s string) bool {
	if s == "" {
		return false
	}
	_, err := time.Parse(time.RFC3339, s)
	return err == nil
}

// FR-8 threshold calibration. Thresholds are keyed by the 8-tuple ThresholdKey.
// hardware_runtime_class is a policy invariant per covered key (one class per key), so
// it is a threshold-key discriminator but constant within any single key's
// measurements. The threshold record is a closed object; its digest is over the
// canonical {type, schema_version, payload}.

const (
	ThresholdRecordType   = "compute_integrity_threshold_record_v1"
	ThresholdRecordSchema = "compute_integrity_threshold_record_v1"
)

// ThresholdRecord is the closed FR-8 threshold/calibration record for a covered key.
type ThresholdRecord struct {
	// 8-tuple key.
	ModelID              string `json:"model_id"`
	TargetModelHash      string `json:"target_model_hash"`
	TokenizerIdentity    string `json:"tokenizer_identity"`
	SamplerStage         string `json:"sampler_stage"`
	SamplingProfile      string `json:"sampling_profile"`
	CorpusVersion        string `json:"corpus_version"`
	ThresholdVersion     string `json:"threshold_version"`
	HardwareRuntimeClass string `json:"hardware_runtime_class"`

	BaselineMedianTVUpperP99   float64 `json:"baseline_median_tv_upper_p99"`
	BaselinePositionTVUpperP99 float64 `json:"baseline_position_tv_upper_p99"`
	TauWarnMedian              float64 `json:"tau_warn_median"`
	TauWarnPosition            float64 `json:"tau_warn_position"`
	TauQuarantineMedian        float64 `json:"tau_quarantine_median"`
	TauQuarantinePosition      float64 `json:"tau_quarantine_position"`
	TauReferenceFaultMedian    float64 `json:"tau_reference_fault_median"`
	TauReferenceFaultPosition  float64 `json:"tau_reference_fault_position"`

	CalibrationSource        string `json:"calibration_source"`
	CalibrationSampleCount   int    `json:"calibration_sample_count"`
	MinEligibleCanaryCount   int    `json:"min_eligible_canary_count"`
	MeasurementPositionCount int    `json:"measurement_position_count"`

	// Coverage binds the covered provider/model/hash/tokenizer/sampler-stage/profile/
	// hardware_runtime_class set the calibration applies to (FR-8).
	Coverage ThresholdCoverage `json:"coverage"`

	CalibrationWindowStart string `json:"calibration_window_start"`
	CalibrationWindowEnd   string `json:"calibration_window_end"`

	BaselineTailMassFeasibilityRate float64 `json:"baseline_tail_mass_feasibility_rate"`
	BaselineMedianTVUpper           float64 `json:"baseline_median_tv_upper"`
	BaselineMaxTVUpper              float64 `json:"baseline_max_tv_upper"`

	FalsePositiveBudget                float64 `json:"false_positive_budget"`
	KnownGoodCohortDigest              string  `json:"known_good_cohort_digest"`
	MeasuredFalseQuarantineNumerator   int     `json:"measured_false_quarantine_numerator"`
	MeasuredFalseQuarantineDenominator int     `json:"measured_false_quarantine_denominator"`
	MeasuredFalseQuarantineRate        float64 `json:"measured_false_quarantine_rate"`
	MeasuredFPWindow                   string  `json:"measured_fp_window"`

	ApprovalTimestamp string `json:"approval_timestamp"`
	ApproverGroup     string `json:"approver_group"`
}

// ThresholdCoverage is the closed FR-8 coverage object binding the calibration to a
// covered key set.
type ThresholdCoverage struct {
	ModelID              string `json:"model_id"`
	TargetModelHash      string `json:"target_model_hash"`
	TokenizerIdentity    string `json:"tokenizer_identity"`
	SamplerStage         string `json:"sampler_stage"`
	SamplingProfile      string `json:"sampling_profile"`
	HardwareRuntimeClass string `json:"hardware_runtime_class"`
}

// DeriveThresholds applies the FR-8 initial threshold formulas (floors) to the two
// baseline p99 inputs. Thresholds only widen for noisier keys, never tighten below
// the floor.
func DeriveThresholds(baselineMedianP99, baselinePositionP99 float64) ThresholdRecord {
	return ThresholdRecord{
		BaselineMedianTVUpperP99:   baselineMedianP99,
		BaselinePositionTVUpperP99: baselinePositionP99,
		TauWarnMedian:              math.Max(0.015, baselineMedianP99+0.005),
		TauWarnPosition:            math.Max(0.030, baselinePositionP99+0.010),
		TauQuarantineMedian:        math.Max(0.060, baselineMedianP99+0.050),
		TauQuarantinePosition:      math.Max(0.120, baselinePositionP99+0.080),
		TauReferenceFaultMedian:    math.Max(0.010, baselineMedianP99+0.003),
		TauReferenceFaultPosition:  math.Max(0.020, baselinePositionP99+0.006),
	}
}

// Thresholds returns the provider-verdict TV thresholds carried by this record.
func (r ThresholdRecord) Thresholds() Thresholds {
	return Thresholds{
		TauWarnMedian:         r.TauWarnMedian,
		TauWarnPosition:       r.TauWarnPosition,
		TauQuarantineMedian:   r.TauQuarantineMedian,
		TauQuarantinePosition: r.TauQuarantinePosition,
	}
}

// ReferenceFaultThresholds returns the reference-vs-reference fault floors.
func (r ThresholdRecord) ReferenceFaultThresholds() ReferenceFaultThresholds {
	return ReferenceFaultThresholds{Median: r.TauReferenceFaultMedian, Position: r.TauReferenceFaultPosition}
}

// Digest returns the FR-13 threshold_record_digest over the canonical
// {type, schema_version, payload}.
func (r ThresholdRecord) Digest() (string, error) {
	return jcsDigest(map[string]any{
		"type":           ThresholdRecordType,
		"schema_version": ThresholdRecordSchema,
		"payload":        r,
	})
}

// CalibrationMinimums are the approved minimum calibration requirements a covered key
// must meet before enforce (FR-8).
type CalibrationMinimums struct {
	MinEligibleCanaryCount  int
	MinMeasurementPositions int
	MinTailMassFeasibility  float64
}

// ThresholdKey returns the record's 8-tuple key.
func (r ThresholdRecord) ThresholdKey() ThresholdKey {
	return ThresholdKey{
		ModelID:              r.ModelID,
		TargetModelHash:      r.TargetModelHash,
		TokenizerIdentity:    r.TokenizerIdentity,
		SamplerStage:         r.SamplerStage,
		SamplingProfile:      r.SamplingProfile,
		CorpusVersion:        r.CorpusVersion,
		ThresholdVersion:     r.ThresholdVersion,
		HardwareRuntimeClass: r.HardwareRuntimeClass,
	}
}

func finiteNonNeg(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0 }

// ValidateCalibrationForEnforce reports whether a calibration record is sufficient to
// activate enforce for the given covered key (FR-8). It verifies the full 8-tuple
// matches, thresholds meet the FR-8 floors, all calibration values are finite and
// non-negative, and a MEASURED realized false-quarantine rate at or below the numeric
// budget is present (an aspirational target without measured validation is
// insufficient). Returns a non-empty slice of refusal reasons, or nil if enforce-ready.
func (r ThresholdRecord) ValidateCalibrationForEnforce(expectedKey ThresholdKey, min CalibrationMinimums) []string {
	var reasons []string
	if r.ThresholdVersion == "" || r.HardwareRuntimeClass == "" {
		reasons = append(reasons, "threshold record missing key fields")
	}
	if (expectedKey != ThresholdKey{}) && r.ThresholdKey() != expectedKey {
		reasons = append(reasons, "threshold record 8-tuple does not match the covered key")
	}
	// Thresholds must be finite/non-negative and at or above the FR-8 floors (they may
	// only widen for noisier keys, never tighten below the floor).
	floors := DeriveThresholds(r.BaselineMedianTVUpperP99, r.BaselinePositionTVUpperP99)
	for _, chk := range []struct {
		name       string
		val, floor float64
	}{
		{"tau_warn_median", r.TauWarnMedian, floors.TauWarnMedian},
		{"tau_warn_position", r.TauWarnPosition, floors.TauWarnPosition},
		{"tau_quarantine_median", r.TauQuarantineMedian, floors.TauQuarantineMedian},
		{"tau_quarantine_position", r.TauQuarantinePosition, floors.TauQuarantinePosition},
		{"tau_reference_fault_median", r.TauReferenceFaultMedian, floors.TauReferenceFaultMedian},
		{"tau_reference_fault_position", r.TauReferenceFaultPosition, floors.TauReferenceFaultPosition},
	} {
		if !finiteNonNeg(chk.val) {
			reasons = append(reasons, chk.name+" is non-finite or negative")
		} else if chk.val < chk.floor {
			reasons = append(reasons, chk.name+" is below the FR-8 floor")
		}
	}
	if !finiteNonNeg(r.BaselineMedianTVUpperP99) || !finiteNonNeg(r.BaselinePositionTVUpperP99) {
		reasons = append(reasons, "baseline p99 values are non-finite or negative")
	}
	if r.ApprovalTimestamp == "" || r.ApproverGroup == "" {
		reasons = append(reasons, "calibration not approved")
	}
	if r.CalibrationSampleCount < min.MinEligibleCanaryCount || r.MinEligibleCanaryCount < min.MinEligibleCanaryCount {
		reasons = append(reasons, "calibration sample/eligible count below minimum")
	}
	if r.MeasurementPositionCount < min.MinMeasurementPositions {
		reasons = append(reasons, "measurement position count below minimum")
	}
	// The coverage object must match the covered key, and the calibration window bounds
	// must be present and parseable RFC3339 (FR-8).
	cov := ThresholdCoverage{
		ModelID: r.ModelID, TargetModelHash: r.TargetModelHash, TokenizerIdentity: r.TokenizerIdentity,
		SamplerStage: r.SamplerStage, SamplingProfile: r.SamplingProfile, HardwareRuntimeClass: r.HardwareRuntimeClass,
	}
	if r.Coverage != cov {
		reasons = append(reasons, "coverage object does not match the covered key")
	}
	if !rfc3339OK(r.CalibrationWindowStart) || !rfc3339OK(r.CalibrationWindowEnd) {
		reasons = append(reasons, "calibration window bounds missing or not RFC3339")
	}
	if r.BaselineTailMassFeasibilityRate < min.MinTailMassFeasibility {
		reasons = append(reasons, "tail-mass feasibility below minimum")
	}
	if r.BaselineTailMassFeasibilityRate < 0 || r.BaselineTailMassFeasibilityRate > 1 {
		reasons = append(reasons, "baseline_tail_mass_feasibility_rate out of [0,1]")
	}
	// The false-positive budget may be anywhere in [0,1] (a zero budget is the strictest
	// setting, requiring a measured zero false-quarantine rate).
	if math.IsNaN(r.FalsePositiveBudget) || r.FalsePositiveBudget < 0 || r.FalsePositiveBudget > 1 {
		reasons = append(reasons, "false_positive_budget out of [0,1]")
	}
	// Measured evidence MUST be present, finite, in range, and the measured rate at or
	// below the budget (FR-8): reject negative/NaN numerator/denominator/rate and any
	// numerator exceeding the denominator.
	if r.KnownGoodCohortDigest == "" || r.MeasuredFPWindow == "" ||
		r.MeasuredFalseQuarantineDenominator <= 0 {
		reasons = append(reasons, "missing measured false-quarantine evidence")
	} else if r.MeasuredFalseQuarantineNumerator < 0 ||
		r.MeasuredFalseQuarantineNumerator > r.MeasuredFalseQuarantineDenominator {
		reasons = append(reasons, "measured false-quarantine numerator out of [0, denominator]")
	} else if math.IsNaN(r.MeasuredFalseQuarantineRate) ||
		r.MeasuredFalseQuarantineRate < 0 || r.MeasuredFalseQuarantineRate > 1 {
		reasons = append(reasons, "measured_false_quarantine_rate out of [0,1]")
	} else {
		measured := float64(r.MeasuredFalseQuarantineNumerator) / float64(r.MeasuredFalseQuarantineDenominator)
		if math.Abs(measured-r.MeasuredFalseQuarantineRate) > 1e-9 {
			reasons = append(reasons, "measured_false_quarantine_rate inconsistent with numerator/denominator")
		}
		if r.MeasuredFalseQuarantineRate > r.FalsePositiveBudget {
			reasons = append(reasons, "measured false-quarantine rate exceeds budget")
		}
	}
	return reasons
}

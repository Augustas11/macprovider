package computeintegrity

import "math"

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

// ValidateCalibrationForEnforce reports whether a calibration record is sufficient to
// activate enforce for its key (FR-8). Enforce MUST refuse a key whose record lacks a
// MEASURED realized false-quarantine rate at or below the numeric budget; an
// aspirational target without measured validation is insufficient. Returns a non-empty
// slice of refusal reasons, or nil if the record is enforce-ready.
func (r ThresholdRecord) ValidateCalibrationForEnforce(min CalibrationMinimums) []string {
	var reasons []string
	if r.ThresholdVersion == "" || r.HardwareRuntimeClass == "" {
		reasons = append(reasons, "threshold record missing key fields")
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
	if r.BaselineTailMassFeasibilityRate < min.MinTailMassFeasibility {
		reasons = append(reasons, "tail-mass feasibility below minimum")
	}
	if r.FalsePositiveBudget <= 0 || r.FalsePositiveBudget > 1 {
		reasons = append(reasons, "false_positive_budget out of (0,1]")
	}
	// Measured evidence MUST be present and the measured rate at or below the budget.
	if r.KnownGoodCohortDigest == "" || r.MeasuredFPWindow == "" ||
		r.MeasuredFalseQuarantineDenominator <= 0 {
		reasons = append(reasons, "missing measured false-quarantine evidence")
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

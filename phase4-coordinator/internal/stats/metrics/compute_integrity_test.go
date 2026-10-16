package metrics

import (
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

// SPEC-036 FR-25: compute-integrity metrics accept closed label values only.
func TestComputeIntegrityMetricsUseClosedLabels(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)
	m.IncComputeIntegrityVerification("in_band")
	m.IncComputeIntegrityVerification("provider-123")
	m.IncComputeIntegrityInconclusive("no_scorer")
	m.IncComputeIntegrityInconclusive("prompt text here")
	m.IncComputeIntegrityTransition("passing", "suspect")
	m.IncComputeIntegrityTransition("passing", "model-x")
	m.IncComputeIntegrityScoringJob("ok")
	m.IncComputeIntegrityScoringJob("weird")
	m.SetComputeIntegrityKeys("failed", 2)
	m.SetComputeIntegrityKeys("github:1", 9)
	m.SetComputeIntegrityHeldHolds(3)
	var nilMetrics *Metrics
	nilMetrics.IncComputeIntegrityVerification("in_band")

	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	series := map[string]int{}
	values := map[string]float64{}
	for _, fam := range families {
		name := fam.GetName()
		if !strings.HasPrefix(name, "compute_integrity_") {
			continue
		}
		for _, metric := range fam.GetMetric() {
			series[name]++
			key := name
			for _, label := range metric.GetLabel() {
				key += "|" + label.GetValue()
			}
			switch {
			case metric.GetCounter() != nil:
				values[key] = metric.GetCounter().GetValue()
			case metric.GetGauge() != nil:
				values[key] = metric.GetGauge().GetValue()
			}
		}
	}
	for name, want := range map[string]int{
		"compute_integrity_verifications_total": 1,
		"compute_integrity_inconclusive_total":  1,
		"compute_integrity_transitions_total":   1,
		"compute_integrity_scoring_jobs_total":  1,
		"compute_integrity_keys":                1,
		"compute_integrity_held_holds":          1,
	} {
		if series[name] != want {
			t.Fatalf("%s series=%d want %d (open label leaked or metric missing)", name, series[name], want)
		}
	}
	for key, want := range map[string]float64{
		"compute_integrity_verifications_total|in_band":       1,
		"compute_integrity_transitions_total|passing|suspect": 1,
		"compute_integrity_keys|failed":                       2,
		"compute_integrity_held_holds":                        3,
	} {
		if values[key] != want {
			t.Fatalf("%s=%v want %v", key, values[key], want)
		}
	}
}

package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// SPEC-036 FR-25 cross-provider scoring metrics. Every label is a closed
// set; provider ids, model ids and operator keys never become labels.

type computeIntegrityMetrics struct {
	verifications *prometheus.CounterVec
	inconclusive  *prometheus.CounterVec
	transitions   *prometheus.CounterVec
	scoringJobs   *prometheus.CounterVec
	keys          *prometheus.GaugeVec
	heldHolds     prometheus.Gauge
}

func newComputeIntegrityMetrics(f promauto.Factory) *computeIntegrityMetrics {
	return &computeIntegrityMetrics{
		verifications: f.NewCounterVec(prometheus.CounterOpts{
			Name: "compute_integrity_verifications_total",
			Help: "SPEC-036 cross-provider verification measurements by closed-set outcome.",
		}, []string{"outcome"}),
		inconclusive: f.NewCounterVec(prometheus.CounterOpts{
			Name: "compute_integrity_inconclusive_total",
			Help: "SPEC-036 inconclusive verification requests by closed-set reason.",
		}, []string{"reason"}),
		transitions: f.NewCounterVec(prometheus.CounterOpts{
			Name: "compute_integrity_transitions_total",
			Help: "SPEC-036 verification state transitions by closed-set from/to state.",
		}, []string{"from", "to"}),
		scoringJobs: f.NewCounterVec(prometheus.CounterOpts{
			Name: "compute_integrity_scoring_jobs_total",
			Help: "SPEC-036 teacher-forced scoring jobs by closed-set result status.",
		}, []string{"status"}),
		keys: f.NewGaugeVec(prometheus.GaugeOpts{
			Name: "compute_integrity_keys",
			Help: "SPEC-036 verification keys by closed-set state.",
		}, []string{"state"}),
		heldHolds: f.NewGauge(prometheus.GaugeOpts{
			Name: "compute_integrity_held_holds",
			Help: "SPEC-022 R-16 compute-integrity earnings holds currently held.",
		}),
	}
}

func ciState(v string) bool {
	switch v {
	case "unverified", "passing", "suspect", "failed", "recovering":
		return true
	}
	return false
}

func (m *Metrics) ci() *computeIntegrityMetrics {
	if m == nil {
		return nil
	}
	return m.computeIntegrity
}

// IncComputeIntegrityVerification counts one measurement outcome.
func (m *Metrics) IncComputeIntegrityVerification(outcome string) {
	c := m.ci()
	if c == nil {
		return
	}
	switch outcome {
	case "in_band", "out_of_band", "split", "inconclusive":
		c.verifications.WithLabelValues(outcome).Inc()
	}
}

// IncComputeIntegrityInconclusive counts one inconclusive reason.
func (m *Metrics) IncComputeIntegrityInconclusive(reason string) {
	c := m.ci()
	if c == nil {
		return
	}
	switch reason {
	case "dispatch", "no_scorer", "scorer_timeout", "short_output", "scorer_invalid":
		c.inconclusive.WithLabelValues(reason).Inc()
	}
}

// IncComputeIntegrityTransition counts one state transition.
func (m *Metrics) IncComputeIntegrityTransition(from, to string) {
	c := m.ci()
	if c == nil || !ciState(from) || !ciState(to) {
		return
	}
	c.transitions.WithLabelValues(from, to).Inc()
}

// IncComputeIntegrityScoringJob counts one scoring job result.
func (m *Metrics) IncComputeIntegrityScoringJob(status string) {
	c := m.ci()
	if c == nil {
		return
	}
	switch status {
	case "ok", "unavailable", "invalid", "too_long", "timeout":
		c.scoringJobs.WithLabelValues(status).Inc()
	}
}

// SetComputeIntegrityKeys sets the number of keys in one state.
func (m *Metrics) SetComputeIntegrityKeys(state string, n int) {
	c := m.ci()
	if c == nil || !ciState(state) {
		return
	}
	c.keys.WithLabelValues(state).Set(float64(n))
}

// SetComputeIntegrityHeldHolds sets the number of held holds.
func (m *Metrics) SetComputeIntegrityHeldHolds(n int) {
	c := m.ci()
	if c == nil {
		return
	}
	c.heldHolds.Set(float64(n))
}

package metrics

import (
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func histogramCount(t *testing.T, families []*dto.MetricFamily, name string, labels map[string]string) (uint64, float64, bool) {
	t.Helper()
	for _, mf := range families {
		if mf.GetName() != name {
			continue
		}
		for _, mt := range mf.GetMetric() {
			if metricLabelsMatch(mt, labels) && mt.GetHistogram() != nil {
				return mt.GetHistogram().GetSampleCount(), mt.GetHistogram().GetSampleSum(), true
			}
		}
	}
	return 0, 0, false
}

func TestRegisterAndIdlePrewarmLabelFiltering(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)
	m.IncRegisterRateLimitHit("ip")
	m.IncRegisterRateLimitHit("asn")
	m.IncRegisterRateLimitHit("provider-secret")
	m.IncRegisterSource("cli")
	m.IncRegisterSource("evil")
	m.IncRegisterHardwareProfileError()
	m.IncRegisterHardwareProfileError()
	m.IncIdlePrewarmEvent("idle_prewarm_fired", "")
	m.IncIdlePrewarmEvent("idle_prewarm_fired", "busy") // reason not allowed for fired
	m.IncIdlePrewarmEvent("idle_prewarm_skipped", "busy")
	m.IncIdlePrewarmEvent("idle_prewarm_skipped", "bogus")
	m.IncIdlePrewarmEvent("idle_prewarm_skipped", "")
	m.IncIdlePrewarmEvent("unknown_event", "")
	m.IncModelHashMismatch()
	m.IncCapacityOverClaim("hello")
	m.IncCapacityOverClaim("hello")
	m.IncCapacityOverClaim("heartbeat")

	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	assertMetricValue(t, families, "provider_register_rate_limit_hits_total", map[string]string{"scope": "ip"}, 1)
	assertMetricValue(t, families, "provider_register_rate_limit_hits_total", map[string]string{"scope": "asn"}, 1)
	if metricExists(families, "provider_register_rate_limit_hits_total", map[string]string{"scope": "provider-secret"}) {
		t.Fatal("unknown scope created a series")
	}
	assertMetricValue(t, families, "provider_register_source_total", map[string]string{"track": "cli"}, 1)
	if metricExists(families, "provider_register_source_total", map[string]string{"track": "evil"}) {
		t.Fatal("unknown track created a series")
	}
	assertMetricValue(t, families, "provider_register_hardware_profile_errors_total", nil, 2)
	assertMetricValue(t, families, "stats_idle_prewarm_event_total", map[string]string{"event": "idle_prewarm_fired", "reason": "none"}, 1)
	assertMetricValue(t, families, "stats_idle_prewarm_event_total", map[string]string{"event": "idle_prewarm_skipped", "reason": "busy"}, 1)
	for _, l := range []map[string]string{
		{"event": "idle_prewarm_fired", "reason": "busy"},
		{"event": "idle_prewarm_skipped", "reason": "bogus"},
		{"event": "idle_prewarm_skipped", "reason": ""},
		{"event": "unknown_event"},
	} {
		if metricExists(families, "stats_idle_prewarm_event_total", l) {
			t.Fatalf("invalid idle prewarm labels created a series: %v", l)
		}
	}
	assertMetricValue(t, families, "model_hash_mismatch_total", nil, 1)
	assertMetricValue(t, families, "provider_capacity_over_claim_total", map[string]string{"phase": "hello"}, 2)
	assertMetricValue(t, families, "provider_capacity_over_claim_total", map[string]string{"phase": "heartbeat"}, 1)
}

func TestReleaseIdentityAndCredentialBootstrapMetrics(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)
	m.SetPrivacyReleaseIdentityVersions([]string{"1.2.3", "not-a-version", "1.2.3.4", "10.20.30"})
	m.IncCredentialBootstrap("minted")
	m.IncCredentialBootstrap("minted")
	m.IncCredentialBootstrap("attacker")
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	assertMetricValue(t, families, "relayblind_privacy_release_identity_loaded", map[string]string{"binary_version": "1.2.3"}, 1)
	assertMetricValue(t, families, "relayblind_privacy_release_identity_loaded", map[string]string{"binary_version": "10.20.30"}, 1)
	for _, v := range []string{"not-a-version", "1.2.3.4"} {
		if metricExists(families, "relayblind_privacy_release_identity_loaded", map[string]string{"binary_version": v}) {
			t.Fatalf("invalid version %q exported", v)
		}
	}
	assertMetricValue(t, families, "credential_bootstrap_total", map[string]string{"outcome": "minted"}, 2)
	if metricExists(families, "credential_bootstrap_total", map[string]string{"outcome": "attacker"}) {
		t.Fatal("unknown outcome created a series")
	}

	// A later load replaces the earlier set.
	m.SetPrivacyReleaseIdentityVersions([]string{"2.0.0"})
	families, _ = reg.Gather()
	if metricExists(families, "relayblind_privacy_release_identity_loaded", map[string]string{"binary_version": "1.2.3"}) {
		t.Fatal("stale version survived reload")
	}
	assertMetricValue(t, families, "relayblind_privacy_release_identity_loaded", map[string]string{"binary_version": "2.0.0"}, 1)
}

func TestProviderConnectionEventMetrics(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)
	m.IncProviderConnectionEvent("auth_rejected", "failure", "invalid_token")
	m.IncProviderConnectionEvent("auth_accepted", "success", "")
	m.IncProviderConnectionEvent("disconnect", "failure", "some-raw-error")
	m.IncProviderConnectionEvent("bogus_kind", "success", "")
	m.IncProviderConnectionEvent("disconnect", "maybe", "")
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	assertMetricValue(t, families, "provider_connection_event_total", map[string]string{"kind": "auth_rejected", "outcome": "failure", "failure_reason": "invalid_token"}, 1)
	assertMetricValue(t, families, "provider_connection_event_total", map[string]string{"kind": "auth_accepted", "outcome": "success", "failure_reason": "none"}, 1)
	assertMetricValue(t, families, "provider_connection_event_total", map[string]string{"kind": "disconnect", "outcome": "failure", "failure_reason": "other"}, 1)
	if metricExists(families, "provider_connection_event_total", map[string]string{"kind": "bogus_kind"}) ||
		metricExists(families, "provider_connection_event_total", map[string]string{"outcome": "maybe"}) {
		t.Fatal("invalid kind/outcome created a series")
	}
}

func TestSQLiteTransactionDurationMetrics(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)
	m.ObserveSQLiteTransactionDuration("billing_hot_path", "success", 2*time.Second)
	m.ObserveSQLiteTransactionDuration("billing_hot_path", "success", time.Second)
	m.ObserveSQLiteTransactionDuration("not_a_component", "success", time.Second)
	m.ObserveSQLiteTransactionDuration("billing_hot_path", "weird", time.Second)
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	n, sum, ok := histogramCount(t, families, "money_sqlite_transaction_duration_seconds", map[string]string{"component": "billing_hot_path", "outcome": "success"})
	if !ok || n != 2 || sum != 3 {
		t.Fatalf("histogram count/sum = %d/%v ok=%v, want 2/3", n, sum, ok)
	}
	if _, _, ok := histogramCount(t, families, "money_sqlite_transaction_duration_seconds", map[string]string{"component": "not_a_component"}); ok {
		t.Fatal("invalid component created a series")
	}
	if _, _, ok := histogramCount(t, families, "money_sqlite_transaction_duration_seconds", map[string]string{"outcome": "weird"}); ok {
		t.Fatal("invalid outcome created a series")
	}
}

func TestSettlementReceiptAuditOutboxObserveAggregate(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)
	m.ObserveSettlementReceiptAuditOutbox(5, 2, 1, 7*time.Second)
	m.ObserveSettlementReceiptAuditOutboxStatsHealth(false, -time.Second)
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	assertMetricValue(t, families, "settlement_receipt_audit_outbox_pending_rows", nil, 5)
	assertMetricValue(t, families, "settlement_receipt_audit_outbox_poisoned_rows", nil, 2)
	assertMetricValue(t, families, "settlement_receipt_audit_outbox_poisoned_retained_rows", nil, 1)
	assertMetricValue(t, families, "settlement_receipt_audit_outbox_oldest_pending_age_seconds", nil, 7)
	assertMetricValue(t, families, "settlement_receipt_audit_outbox_stats_stale", nil, 0)
	assertMetricValue(t, families, "settlement_receipt_audit_outbox_stats_age_seconds", nil, 0)

	// Positive values pass through the individual setters.
	m.SetSettlementReceiptAuditOutboxPendingRows(9)
	families, _ = reg.Gather()
	assertMetricValue(t, families, "settlement_receipt_audit_outbox_pending_rows", nil, 9)
}

func TestComputeIntegrityClosedSetLabels(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := New(reg)
	m.IncComputeIntegrityInconclusive("scorer_timeout")
	m.IncComputeIntegrityInconclusive("raw-reason")
	m.IncComputeIntegrityScoringJob("ok", "peer")
	m.IncComputeIntegrityScoringJob("timeout", "reference")
	m.IncComputeIntegrityScoringJob("ok", "attacker")
	m.IncComputeIntegrityScoringJob("bogus", "peer")
	m.SetComputeIntegrityHeldHolds(4)
	m.SetComputeIntegrityReviewPending("suspect", 3)
	m.SetComputeIntegrityReviewPending("passing", 9)
	families, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	assertMetricValue(t, families, "compute_integrity_inconclusive_total", map[string]string{"reason": "scorer_timeout"}, 1)
	if metricExists(families, "compute_integrity_inconclusive_total", map[string]string{"reason": "raw-reason"}) {
		t.Fatal("unknown reason created a series")
	}
	assertMetricValue(t, families, "compute_integrity_scoring_jobs_total", map[string]string{"status": "ok", "scorer_kind": "peer"}, 1)
	assertMetricValue(t, families, "compute_integrity_scoring_jobs_total", map[string]string{"status": "timeout", "scorer_kind": "reference"}, 1)
	if metricExists(families, "compute_integrity_scoring_jobs_total", map[string]string{"scorer_kind": "attacker"}) ||
		metricExists(families, "compute_integrity_scoring_jobs_total", map[string]string{"status": "bogus"}) {
		t.Fatal("invalid scoring job labels created a series")
	}
	assertMetricValue(t, families, "compute_integrity_held_holds", nil, 4)
	assertMetricValue(t, families, "compute_integrity_review_pending", map[string]string{"state": "suspect"}, 3)
	if metricExists(families, "compute_integrity_review_pending", map[string]string{"state": "passing"}) {
		t.Fatal("review_pending accepted a non-review state")
	}
}

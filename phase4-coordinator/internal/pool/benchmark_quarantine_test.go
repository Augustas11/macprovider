package pool

import (
	"testing"
	"time"
)

func quarantineTestProvider() *Provider {
	return &Provider{
		ProviderID:       "provider-a",
		AssignedID:       "assigned-a",
		ModelID:          "model-a",
		State:            StateReady,
		MaxConcurrency:   1,
		SlotsTotal:       1,
		SlotsFree:        1,
		MaxContextTokens: 4096,
		AdmittedAt:       time.Now().UTC(),
	}
}

// Issue #765: the fail-suspect bucket must remove the provider from buyer
// routing without touching its state, tier, or session.
func TestBenchmarkQuarantineRemovesProviderFromRouting(t *testing.T) {
	t.Parallel()
	p := quarantineTestProvider()
	if !p.RoutingEligible() || !p.ServingCapable() {
		t.Fatalf("baseline provider must be routable: routing=%v serving=%v", p.RoutingEligible(), p.ServingCapable())
	}
	p.BenchmarkQuarantined = true
	if p.RoutingEligible() {
		t.Fatal("quarantined provider must not be routing eligible")
	}
	if p.ServingCapable() {
		t.Fatal("quarantined provider must not count as buyer-serving capacity")
	}
	if p.State != StateReady {
		t.Fatalf("quarantine must not mutate provider state, got %q", p.State)
	}
}

func TestAdmissionCeilingExclusionRemovesProviderFromRouting(t *testing.T) {
	t.Parallel()
	p := quarantineTestProvider()
	if !p.RoutingEligible() || !p.ServingCapable() {
		t.Fatalf("baseline provider must be routable: routing=%v serving=%v", p.RoutingEligible(), p.ServingCapable())
	}
	p.AdmissionCeilingExcluded = true
	if p.RoutingEligible() {
		t.Fatal("ceiling-excluded provider must not be routing eligible")
	}
	if p.ServingCapable() {
		t.Fatal("ceiling-excluded provider must not count as buyer-serving capacity")
	}
	if p.State != StateReady {
		t.Fatalf("ceiling exclusion must not mutate provider state, got %q", p.State)
	}
}

func TestAdmissionEvidenceStaleRemovesProviderFromRouting(t *testing.T) {
	t.Parallel()
	p := quarantineTestProvider()
	p.AdmissionEvidenceStale = true
	if p.RoutingEligible() {
		t.Fatal("stale-evidence provider must not be routing eligible")
	}
	if p.ServingCapable() {
		t.Fatal("stale-evidence provider must not count as buyer-serving capacity")
	}
	if p.State != StateReady {
		t.Fatalf("stale evidence must not mutate provider state, got %q", p.State)
	}
}

func TestSetBenchmarkQuarantineReportsTransitionsOnly(t *testing.T) {
	t.Parallel()
	r := NewRegistry(nil)
	if _, ok := r.RegisterAt(quarantineTestProvider(), nil, time.Now().UTC()); !ok {
		t.Fatal("register failed")
	}

	if changed := r.SetBenchmarkQuarantine("provider-a", "assigned-a", true); !changed {
		t.Fatal("first quarantine must report a transition")
	}
	if changed := r.SetBenchmarkQuarantine("provider-a", "assigned-a", true); changed {
		t.Fatal("repeat quarantine must not report a transition (log once, not per heartbeat)")
	}
	snap := r.Snapshot()
	if len(snap) != 1 || !snap[0].BenchmarkQuarantined {
		t.Fatalf("snapshot did not carry the quarantine flag: %+v", snap)
	}
	if snap[0].RoutingEligible() {
		t.Fatal("quarantined provider is still routing eligible in the snapshot")
	}

	if changed := r.SetBenchmarkQuarantine("provider-a", "assigned-a", false); !changed {
		t.Fatal("release must report a transition")
	}
	snap = r.Snapshot()
	if snap[0].BenchmarkQuarantined {
		t.Fatal("release did not clear the quarantine flag")
	}
	if !snap[0].RoutingEligible() {
		t.Fatal("released provider must be routable again")
	}

	// A stale session id must never move another session's flag.
	if changed := r.SetBenchmarkQuarantine("provider-a", "stale-assigned", true); changed {
		t.Fatal("stale assigned_id must not flip the quarantine flag")
	}
}

func TestSetAdmissionCeilingExcludedReportsTransitionsOnly(t *testing.T) {
	t.Parallel()
	r := NewRegistry(nil)
	if _, ok := r.RegisterAt(quarantineTestProvider(), nil, time.Now().UTC()); !ok {
		t.Fatal("register failed")
	}

	if changed := r.SetAdmissionCeilingExcluded("provider-a", "assigned-a", true); !changed {
		t.Fatal("first exclusion must report a transition")
	}
	if changed := r.SetAdmissionCeilingExcluded("provider-a", "assigned-a", true); changed {
		t.Fatal("repeat exclusion must not report a transition")
	}
	snap := r.Snapshot()
	if len(snap) != 1 || !snap[0].AdmissionCeilingExcluded {
		t.Fatalf("snapshot did not carry the ceiling exclusion flag: %+v", snap)
	}
	if snap[0].RoutingEligible() {
		t.Fatal("ceiling-excluded provider is still routing eligible in the snapshot")
	}

	if changed := r.SetAdmissionCeilingExcluded("provider-a", "assigned-a", false); !changed {
		t.Fatal("release must report a transition")
	}
	snap = r.Snapshot()
	if snap[0].AdmissionCeilingExcluded {
		t.Fatal("release did not clear the ceiling exclusion flag")
	}
	if !snap[0].RoutingEligible() {
		t.Fatal("released provider must be routable again")
	}

	if changed := r.SetAdmissionCeilingExcluded("provider-a", "stale-assigned", true); changed {
		t.Fatal("stale assigned_id must not flip the ceiling exclusion flag")
	}
}

func TestSetAdmissionEvidenceStaleReportsTransitionsOnly(t *testing.T) {
	t.Parallel()
	r := NewRegistry(nil)
	if _, ok := r.RegisterAt(quarantineTestProvider(), nil, time.Now().UTC()); !ok {
		t.Fatal("register failed")
	}

	if changed := r.SetAdmissionEvidenceStale("provider-a", "assigned-a", true); !changed {
		t.Fatal("first stale verdict must report a transition")
	}
	if changed := r.SetAdmissionEvidenceStale("provider-a", "assigned-a", true); changed {
		t.Fatal("repeat stale verdict must not report a transition")
	}
	snap := r.Snapshot()
	if len(snap) != 1 || !snap[0].AdmissionEvidenceStale {
		t.Fatalf("snapshot did not carry the stale-evidence flag: %+v", snap)
	}
	if snap[0].RoutingEligible() {
		t.Fatal("stale-evidence provider is still routing eligible in the snapshot")
	}

	if changed := r.SetAdmissionEvidenceStale("provider-a", "assigned-a", false); !changed {
		t.Fatal("fresh evidence must report a transition")
	}
	snap = r.Snapshot()
	if snap[0].AdmissionEvidenceStale {
		t.Fatal("fresh evidence did not clear the stale-evidence flag")
	}
	if !snap[0].RoutingEligible() {
		t.Fatal("fresh-evidence provider must be routable again")
	}

	if changed := r.SetAdmissionEvidenceStale("provider-a", "stale-assigned", true); changed {
		t.Fatal("stale assigned_id must not flip the stale-evidence flag")
	}
}

func TestRecordCanaryLatencyKeepsLastRealObservation(t *testing.T) {
	t.Parallel()
	r := NewRegistry(nil)
	if _, ok := r.RegisterAt(quarantineTestProvider(), nil, time.Now().UTC()); !ok {
		t.Fatal("register failed")
	}
	r.RecordCanaryLatency("provider-a", "assigned-a", 1200, 18.5)
	// A skipped / transport-failed probe measured nothing and must not zero it.
	r.RecordCanaryLatency("provider-a", "assigned-a", 0, 0)
	snap := r.Snapshot()
	if snap[0].CanaryLastTTFTMS != 1200 {
		t.Fatalf("ttft = %d, want 1200", snap[0].CanaryLastTTFTMS)
	}
	if snap[0].CanaryLastSustainedTPS != 18.5 {
		t.Fatalf("tps = %v, want 18.5", snap[0].CanaryLastSustainedTPS)
	}
}

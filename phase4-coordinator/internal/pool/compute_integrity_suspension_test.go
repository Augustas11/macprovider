package pool

import "testing"

// SPEC-036 FR-25: a failed (provider, model) key leaves routing for that
// model only, survives re-registration, and lifts when cleared.
func TestComputeIntegritySuspensionIsPerModel(t *testing.T) {
	r := NewRegistry(nil)
	p := quarantineTestProvider()
	r.Register(p, nil)
	if !r.SetComputeIntegritySuspended("provider-a", "model-a", true) {
		t.Fatal("first suspension must change the set")
	}
	if r.SetComputeIntegritySuspended("provider-a", "model-a", true) {
		t.Fatal("repeat suspension must be a no-op")
	}
	got, _ := r.Resolve("provider-a", "assigned-a")
	if !got.ComputeIntegritySuspended || got.RoutingEligible() {
		t.Fatal("suspended model must leave routing")
	}
	busy := got
	busy.SlotsFree = 0
	if busy.SlotQueueEligible() {
		t.Fatal("suspended model must leave the slot queue too")
	}

	// The same provider serving another model is routable.
	other := quarantineTestProvider()
	other.AssignedID = "assigned-b"
	other.ModelID = "model-b"
	r.Register(other, nil)
	got, _ = r.Resolve("provider-a", "assigned-b")
	if got.ComputeIntegritySuspended || !got.RoutingEligible() {
		t.Fatal("a different model must not be suspended")
	}

	// Re-registering the suspended model re-applies the suspension.
	again := quarantineTestProvider()
	again.AssignedID = "assigned-c"
	r.Register(again, nil)
	got, _ = r.Resolve("provider-a", "assigned-c")
	if !got.ComputeIntegritySuspended {
		t.Fatal("suspension must survive a reconnect")
	}

	if !r.SetComputeIntegritySuspended("provider-a", "model-a", false) {
		t.Fatal("clearing must change the set")
	}
	got, _ = r.Resolve("provider-a", "assigned-c")
	if got.ComputeIntegritySuspended || !got.RoutingEligible() {
		t.Fatal("cleared suspension must restore routing")
	}
}

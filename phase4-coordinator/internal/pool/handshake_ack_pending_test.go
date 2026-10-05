package pool

import (
	"testing"
	"time"
)

func TestHandshakeAckPendingHoldsSessionOutOfRouting(t *testing.T) {
	t.Parallel()
	r := NewRegistry(nil)
	p := quarantineTestProvider()
	p.HandshakeAckPending = true
	if p.RoutingEligible() || p.PoolExternalRuntimeRoutingEligible() {
		t.Fatal("pre-ack session must not be routing eligible")
	}
	if _, ok := r.RegisterAt(p, nil, time.Now().UTC()); !ok {
		t.Fatal("register failed")
	}
	if r.ClearHandshakeAckPending("provider-a", "assigned-other") {
		t.Fatal("clear for another session must not release this one")
	}
	if got, _ := r.Resolve("provider-a", "assigned-a"); got.RoutingEligible() {
		t.Fatal("session released by a mismatched clear")
	}
	if !r.ClearHandshakeAckPending("provider-a", "assigned-a") {
		t.Fatal("first clear must report a transition")
	}
	if r.ClearHandshakeAckPending("provider-a", "assigned-a") {
		t.Fatal("repeat clear must not report a transition")
	}
	if got, _ := r.Resolve("provider-a", "assigned-a"); !got.RoutingEligible() {
		t.Fatal("session must be routing eligible after its ack")
	}
}

// The ack hold must not open an eviction window: a Bearer-validated session
// waiting for its ack keeps FR-C9.4 protection against a non-Bearer
// replacement, and a replacement never inherits the hold.
func TestHandshakeAckPendingKeepsBearerDowngradeProtection(t *testing.T) {
	t.Parallel()
	r := NewRegistry(nil)
	proven := quarantineTestProvider()
	proven.AuthState = AuthBearerValidated
	proven.HandshakeAckPending = true
	if _, ok := r.RegisterAt(proven, nil, time.Now().UTC()); !ok {
		t.Fatal("register proven session failed")
	}
	downgrade := quarantineTestProvider()
	downgrade.AssignedID = "assigned-b"
	_, ok, refusal := r.RegisterAtDetailed(downgrade, nil, time.Now().UTC())
	if ok || refusal != RegisterRefusalBearerDowngrade {
		t.Fatalf("non-Bearer replacement of a pre-ack proven session: ok=%v refusal=%q", ok, refusal)
	}
	replacement := quarantineTestProvider()
	replacement.AssignedID = "assigned-c"
	replacement.AuthState = AuthBearerValidated
	if _, ok := r.RegisterAt(replacement, nil, time.Now().UTC()); !ok {
		t.Fatal("Bearer replacement failed")
	}
	got, _ := r.Resolve("provider-a", "assigned-c")
	if got.HandshakeAckPending || !got.RoutingEligible() {
		t.Fatalf("replacement inherited the ack hold: pending=%v eligible=%v", got.HandshakeAckPending, got.RoutingEligible())
	}
}

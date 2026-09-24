package ws

import (
	"context"
	"testing"
	"time"

	"github.com/gobwas/ws/wsutil"
)

// Audit R1 CODE M1: when the provider's normal terminal retired the request
// first, a later buyer cancel owes no cancel terminal, so the buyer handler
// must not sit out the whole grace window.
func TestRelayCancelAfterNormalTerminalDoesNotWait(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-ended-first", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-ended-first", "complete", "receipt-normal"))
	relay.Cancel("buyer_disconnected")
	started := time.Now()
	if end, ok := relay.AwaitCancelTerminal(CancelTerminalWait); ok {
		t.Fatalf("delivered a cancel terminal after a normal end: %#v", end)
	}
	if waited := time.Since(started); waited > 500*time.Millisecond {
		t.Fatalf("waited %s for a cancel terminal that cannot come", waited)
	}
}

// Audit R1 ARCH M: a pending cancel terminal holds a Tier-2 rekey, and
// delivering it releases the hold.
func TestPendingCancelTerminalHoldsRekeyUntilDelivered(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-hold", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	session, ok := s.storedSessionFor("p1", "s1")
	if !ok {
		t.Fatal("missing session")
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	if !session.hasPendingCancelTerminal() {
		t.Fatal("an owed cancel terminal does not hold the rekey barrier")
	}
	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-hold", "cancelled", "receipt"))
	if session.hasPendingCancelTerminal() {
		t.Fatal("a delivered cancel terminal still holds the rekey barrier")
	}
	if _, ok := relay.AwaitCancelTerminal(time.Second); !ok {
		t.Fatal("cancel terminal not delivered")
	}
}

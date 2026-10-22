package ws

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func newCancelTerminalHarness(t *testing.T) (*Server, *pool.Provider, net.Conn) {
	t.Helper()
	return newCancelTerminalHarnessWith(t, nil)
}

func newCancelTerminalHarnessWith(t *testing.T, mutate func(*pool.Provider)) (*Server, *pool.Provider, net.Conn) {
	t.Helper()
	serverConn, providerConn := net.Pipe()
	t.Cleanup(func() {
		_ = providerConn.Close()
		_ = serverConn.Close()
	})
	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled}
	if mutate != nil {
		mutate(provider)
	}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()
	return s, provider, providerConn
}

func cancelledEndPayload(t *testing.T, requestID, status, receipt string) []byte {
	t.Helper()
	payload, err := json.Marshal(InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: status, Receipt: receipt})
	if err != nil {
		t.Fatalf("marshal end: %v", err)
	}
	return payload
}

// A buyer cancel retires the request before the provider answers. Its
// "cancelled" terminal frame, which carries the buyer_cancel receipt, must
// still reach the buyer handler exactly once.
func TestRelayBuyerCancelDeliversProviderCancelledTerminalOnce(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-cancel-terminal", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}

	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-cancel-terminal", "cancelled", "receipt-1"))
	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-cancel-terminal", "cancelled", "receipt-2"))

	end, ok := relay.AwaitCancelTerminal(time.Second)
	if !ok {
		t.Fatal("cancelled terminal frame not delivered")
	}
	if end.Status != "cancelled" || end.Receipt != "receipt-1" {
		t.Fatalf("terminal = %#v, want the first cancelled frame", end)
	}
	if _, ok := relay.AwaitCancelTerminal(20 * time.Millisecond); ok {
		t.Fatal("a second cancelled frame was delivered")
	}
}

// A cancel for any reason other than a buyer disconnect waits for nothing.
func TestRelayNonBuyerCancelDoesNotArmCancelTerminal(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-cancel-other", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	relay.Cancel("tier2_output_truncated")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-cancel-other", "cancelled", "receipt-x"))
	if end, ok := relay.AwaitCancelTerminal(20 * time.Millisecond); ok {
		t.Fatalf("non-buyer cancel delivered a terminal: %#v", end)
	}
}

func TestEncryptedRelayBuyerCancelDeliversProviderCancelledTerminal(t *testing.T) {
	s, provider, providerConn := newEncryptedRelayHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-enc-cancel", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read encrypted inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	s.handleInferenceEnd("p1", "s1", encryptedResponseEnd(t, provider, "req-enc-cancel", true, 0, InferenceResponseEnd{
		Type:      "inference_response_end",
		RequestID: "req-enc-cancel",
		Status:    "cancelled",
		Receipt:   "receipt-enc",
	}))
	end, ok := relay.AwaitCancelTerminal(time.Second)
	if !ok {
		t.Fatal("encrypted cancelled terminal frame not delivered")
	}
	if end.RequestID != "req-enc-cancel" || end.Receipt != "receipt-enc" {
		t.Fatalf("terminal = %#v", end)
	}
	if _, ok := s.storedSessionFor("p1", "s1"); !ok {
		t.Fatal("session closed after a valid encrypted cancelled terminal")
	}
}

// SPEC-051-R019: a shard group head's cancelled terminal goes through the
// group attestation check like any other terminal frame, so a receipt
// without a valid attestation never reaches buyer-cancel settlement.
func TestRelayBuyerCancelTerminalOfShardHeadNeedsGroupAttestation(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarnessWith(t, func(p *pool.Provider) { p.ShardGroupHeadV1 = true })
	relay, err := s.DispatchInference(context.Background(), *provider, "req-cancel-shard", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-cancel-shard", "cancelled", "receipt-unattested"))
	end, ok := relay.AwaitCancelTerminal(time.Second)
	if !ok {
		t.Fatal("cancelled terminal frame not delivered")
	}
	if end.Status != "cancelled" || end.Receipt != "" {
		t.Fatalf("terminal = %#v, want the cancelled frame without its unattested receipt", end)
	}
}

// #2084 VM acceptance V-3: a provider that finished before the buyer's cancel
// reached it sends a "complete" terminal for the retired request; it reaches
// the buyer handler on CancelTerminal exactly once, like a cancelled one. The
// buyer handler settles it only for a stream the buyer read to its final
// [DONE]; everywhere else a buyer cancel binds only a "cancelled" terminal
// (withProviderCancelTerminal), because a complete frame signs normal_done.
func TestRelayBuyerCancelDeliversALateCompleteTerminalOnce(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-late-complete", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-late-complete", "complete", "receipt-complete"))
	s.handleInferenceEnd("p1", "s1", cancelledEndPayload(t, "req-late-complete", "complete", "receipt-again"))
	end, ok := relay.AwaitCancelTerminal(time.Second)
	if !ok || end.Status != "complete" || end.Receipt != "receipt-complete" {
		t.Fatalf("terminal = %#v ok=%v, want the first complete frame", end, ok)
	}
	if _, ok := relay.AwaitCancelTerminal(20 * time.Millisecond); ok {
		t.Fatal("a second terminal was delivered")
	}
}

package ws

import (
	"context"
	"encoding/json"
	"net"
	"testing"

	"github.com/gobwas/ws/wsutil"
)

func readCancelRequestRaw(t *testing.T, providerConn net.Conn) map[string]any {
	t.Helper()
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(payload, &raw); err != nil {
		t.Fatalf("cancel json: %v", err)
	}
	if raw["type"] != "cancel_request" {
		t.Fatalf("frame = %v, want cancel_request", raw)
	}
	return raw
}

// #1690 BUG-2: a buyer_disconnected cancel carries the delivered prefix the
// buyer handler recorded before the request was retired, and nothing the
// handler records afterwards counts.
func TestRelayBuyerCancelCarriesDeliveredOutputBoundary(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarness(t)
	relay, err := s.DispatchInference(context.Background(), *provider, "req-boundary", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	delivered := int64(0)
	relay.TrackDeliveredOutput(func() int64 { return delivered })
	if !relay.RecordDelivered(func() { delivered = 102 }) {
		t.Fatal("record before cancel refused")
	}
	relay.Cancel("buyer_disconnected")
	raw := readCancelRequestRaw(t, providerConn)
	if got, ok := raw["delivered_output_bytes"].(float64); !ok || got != 102 {
		t.Fatalf("delivered_output_bytes = %v, want 102", raw["delivered_output_bytes"])
	}
	if relay.RecordDelivered(func() { delivered = 191 }) {
		t.Fatal("record after the cancel boundary was sent must be refused")
	}
	if delivered != 102 {
		t.Fatalf("delivered = %d after refused record, want 102", delivered)
	}
}

// The buyer request context ends on a disconnect, and the relay's own cancel
// goroutine may retire the request first; it must carry the same boundary.
func TestRelayContextCancelCarriesDeliveredOutputBoundary(t *testing.T) {
	s, provider, providerConn := newCancelTerminalHarness(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	relay, err := s.DispatchInference(ctx, *provider, "req-boundary-ctx", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	relay.TrackDeliveredOutput(func() int64 { return 0 })
	cancel()
	raw := readCancelRequestRaw(t, providerConn)
	if raw["reason"] != "buyer_disconnected" {
		t.Fatalf("reason = %v", raw["reason"])
	}
	if got, ok := raw["delivered_output_bytes"].(float64); !ok || got != 0 {
		t.Fatalf("delivered_output_bytes = %v, want 0", raw["delivered_output_bytes"])
	}
}

// Without a registered measure (relay-blind, legacy paths) and on any other
// cancel reason the field is omitted, so providers keep today's behaviour.
func TestRelayCancelOmitsDeliveredOutputBoundaryWhenUnknown(t *testing.T) {
	for _, tc := range []struct {
		name   string
		track  bool
		reason string
	}{
		{name: "untracked buyer cancel", reason: "buyer_disconnected"},
		{name: "tracked non-buyer cancel", track: true, reason: "malformed_settlement_stream"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, provider, providerConn := newCancelTerminalHarness(t)
			relay, err := s.DispatchInference(context.Background(), *provider, "req-no-boundary", []byte(`{"model":"model-a"}`), true)
			if err != nil {
				t.Fatalf("dispatch: %v", err)
			}
			if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
				t.Fatalf("read inference_request: %v", err)
			}
			if tc.track {
				relay.TrackDeliveredOutput(func() int64 { return 7 })
			}
			relay.Cancel(tc.reason)
			raw := readCancelRequestRaw(t, providerConn)
			if _, ok := raw["delivered_output_bytes"]; ok {
				t.Fatalf("delivered_output_bytes present: %v", raw)
			}
			if !relay.RecordDelivered(func() {}) {
				t.Fatal("record refused without a sent boundary")
			}
		})
	}
}

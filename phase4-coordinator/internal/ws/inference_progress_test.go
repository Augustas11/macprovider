package ws

import (
	"net"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// SPEC-001-R015: an inference_response_progress frame signals only a
// streaming request active on the sending session, coalesces to one pending
// signal, and is dropped quietly otherwise (it carries no bytes).
func TestInferenceProgressSignalsOnlyTheActiveStream(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional,
		InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady,
		SlotsFree: 4, SlotsTotal: 4, MaxConcurrency: 4,
	}, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	streaming, err := session.addActive("req-stream", 4, true)
	if err != nil {
		t.Fatal(err)
	}
	unary, err := session.addActive("req-unary", 4, false)
	if err != nil {
		t.Fatal(err)
	}
	frame := func(id string) []byte {
		return mustJSON(map[string]string{"type": "inference_response_progress", "request_id": id})
	}

	s.handleInferenceProgress("p1", "s1", frame("req-stream"))
	s.handleInferenceProgress("p1", "s1", frame("req-stream"))
	if got := len(streaming.progress); got != 1 {
		t.Fatalf("pending progress=%d, want one coalesced signal", got)
	}
	s.handleInferenceProgress("p1", "s1", frame("req-unary"))
	if got := len(unary.progress); got != 0 {
		t.Fatalf("non-streaming request got progress")
	}
	// Unknown request, another session, and malformed IDs are ignored.
	s.handleInferenceProgress("p1", "s1", frame("req-gone"))
	s.handleInferenceProgress("p2", "s9", frame("req-stream"))
	s.handleInferenceProgress("p1", "s1", frame("req-\x1b[31m"))
	s.handleInferenceProgress("p1", "s1", []byte(`{`))
	<-streaming.progress
	s.handleInferenceProgress("p2", "s9", frame("req-stream"))
	if got := len(streaming.progress); got != 0 {
		t.Fatalf("progress from another session was delivered")
	}
	if len(streaming.chunks) != 0 {
		t.Fatalf("progress must never become a chunk")
	}
}

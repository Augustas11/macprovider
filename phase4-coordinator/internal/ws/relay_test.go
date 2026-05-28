package ws

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestRelayDispatchRoutesChunkAndEndByRequestID(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 1)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	relay, err := s.DispatchInference(context.Background(), *provider, "req-test", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	payload, op, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var req InferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("request json: %v", err)
	}
	if req.Type != "inference_request" || req.RequestID != "req-test" {
		t.Fatalf("request = %#v", req)
	}

	s.handleInferenceChunk("p1", mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: "req-test", Seq: 0, Data: `{"ok":true}`}))
	s.handleInferenceEnd("p1", mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: "req-test", Status: "complete", ChunksSent: 1}))

	select {
	case chunk := <-relay.Chunks:
		if chunk.Data != `{"ok":true}` {
			t.Fatalf("chunk = %#v", chunk)
		}
	case <-time.After(time.Second):
		t.Fatal("chunk timeout")
	}
	select {
	case end := <-relay.Done:
		if end.Status != "complete" {
			t.Fatalf("end = %#v", end)
		}
	case <-time.After(time.Second):
		t.Fatal("end timeout")
	}
}

func TestRelayBackpressureWhenWriteBufferFull(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	session := newProviderSession("p1", "s1", serverConn, 1)
	if err := session.send([]byte(`{"type":"one"}`)); err != nil {
		t.Fatalf("first send: %v", err)
	}
	if err := session.send([]byte(`{"type":"two"}`)); err != ErrRelayBackpressure {
		t.Fatalf("second send = %v, want backpressure", err)
	}
}

func TestRelaySendAfterCloseReturnsClosed(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	session := newProviderSession("p1", "s1", serverConn, 1)
	session.close()
	if err := session.send([]byte(`{"type":"after_close"}`)); err != ErrRelayClosed {
		t.Fatalf("send after close = %v, want ErrRelayClosed", err)
	}
}

func TestRelayMaxConcurrencyRejectsAdditionalActiveRequest(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled, MaxConcurrency: 1}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	if _, err := s.DispatchInference(context.Background(), *provider, "req-one", []byte(`{"model":"model-a"}`), false); err != nil {
		t.Fatalf("first dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read first inference_request: %v", err)
	}
	if _, err := s.DispatchInference(context.Background(), *provider, "req-two", []byte(`{"model":"model-a"}`), false); err != ErrRelayBackpressure {
		t.Fatalf("second dispatch = %v, want ErrRelayBackpressure", err)
	}
}

func TestRelayCancelSendsCancelRequest(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	relay, err := s.DispatchInference(context.Background(), *provider, "req-cancel", []byte(`{"model":"model-a"}`), true)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	relay.Cancel("buyer_disconnected")
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	var cancel CancelRequest
	if err := json.Unmarshal(payload, &cancel); err != nil {
		t.Fatalf("cancel json: %v", err)
	}
	if cancel.Type != "cancel_request" || cancel.RequestID != "req-cancel" || cancel.Reason != "buyer_disconnected" {
		t.Fatalf("cancel = %#v", cancel)
	}
}

func TestRelayTimeoutCancelsAndCompletesWithError(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled, MaxConcurrency: 1}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	relay, err := s.DispatchInference(ctx, *provider, "req-timeout", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	payload, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read cancel_request: %v", err)
	}
	var cancelMsg CancelRequest
	if err := json.Unmarshal(payload, &cancelMsg); err != nil {
		t.Fatalf("cancel json: %v", err)
	}
	if cancelMsg.RequestID != "req-timeout" || cancelMsg.Reason != "timeout" {
		t.Fatalf("cancel = %#v", cancelMsg)
	}

	select {
	case err := <-relay.Errors:
		if err != ErrRelayTimeout {
			t.Fatalf("err = %v, want ErrRelayTimeout", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout error not delivered")
	}
	if _, ok := session.activeFor("req-timeout"); ok {
		t.Fatal("timed out request still active")
	}
}

func TestRelayNAKFallbackMarksHTTPForwardingOnly(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{ProviderID: "p1", AssignedID: "s1", ModelID: "model-a", Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled}
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 4)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	relay, err := s.DispatchInference(context.Background(), *provider, "req-nak", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if _, _, err := wsutil.ReadServerData(providerConn); err != nil {
		t.Fatalf("read inference_request: %v", err)
	}
	s.handleNAK("p1", "s1", mustJSON(NAK{Type: "nak", RequestID: "req-nak", Code: "unknown_message_type"}))

	select {
	case err := <-relay.Errors:
		if err != ErrRelayNAKFallback {
			t.Fatalf("err = %v, want ErrRelayNAKFallback", err)
		}
	case <-time.After(time.Second):
		t.Fatal("nak error timeout")
	}
	got, ok := registry.Resolve("p1", "")
	if !ok || !got.HTTPForwardingOnly {
		t.Fatalf("provider = %#v ok=%v, want http_forwarding_only", got, ok)
	}
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}
